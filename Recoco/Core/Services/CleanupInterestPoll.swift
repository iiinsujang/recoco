import Foundation
import Combine

enum CleanupInterest: String, CaseIterable, Codable, Identifiable {
    case video, apps, contacts, messages, alerts

    var id: Self { self }

    var title: String {
        switch self {
        case .video: return String(localized: "비슷하게 찍은 영상 정리하기")
        case .apps: return String(localized: "한동안 쓰지 않은 앱 정리하기")
        case .contacts: return String(localized: "겹쳐 저장된 연락처 정리하기")
        case .messages: return String(localized: "쌓인 안내 문자·메시지 정리하기")
        case .alerts: return String(localized: "자꾸 뜨는 광고 알림 줄이기")
        }
    }

    var shortTitle: String {
        switch self {
        case .video: return String(localized: "영상")
        case .apps: return String(localized: "앱")
        case .contacts: return String(localized: "연락처")
        case .messages: return String(localized: "문자·메시지")
        case .alerts: return String(localized: "광고 알림")
        }
    }
}

struct CleanupInterestBallot: Codable, Equatable {
    let choice: CleanupInterest
    // One ID per intentional vote. Retries after a lost acknowledgement reuse it.
    let requestId: UUID
}

struct CleanupInterestTally: Decodable, Equatable {
    private let counts: [String: Int]

    enum CodingKeys: CodingKey { case counts }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        counts = try fields.decode([String: Int].self, forKey: .counts)
        let choices = CleanupInterest.allCases
        guard choices.allSatisfy({ choice in
            guard let votes = counts[choice.rawValue] else { return false }
            return (0...(Int.max / choices.count)).contains(votes)
        }) else { throw URLError(.cannotParseResponse) }
    }

    subscript(_ interest: CleanupInterest) -> Int { counts[interest.rawValue, default: 0] }

    var total: Int { CleanupInterest.allCases.reduce(0) { $0 + self[$1] } }

    func fraction(for interest: CleanupInterest) -> Double {
        total == 0 ? 0 : Double(self[interest]) / Double(total)
    }
}

protocol CleanupInterestPolling {
    func fetchTally() async throws -> CleanupInterestTally
    func submit(_ ballot: CleanupInterestBallot) async throws -> CleanupInterestTally
}

struct CleanupInterestAPI: CleanupInterestPolling {
    static let endpoint: URL = {
        #if DEBUG
        let path = "api/qa/poll"
        #else
        let path = "api/ios/poll"
        #endif
        return URL(string: "https://recoco-photo-poll-test.blush-tick-8008.chatgpt.site")!
            .appendingPathComponent(path)
    }()

    private static let anonymousSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()

    let endpoint: URL
    private let session: URLSession

    init(endpoint: URL = Self.endpoint, session: URLSession? = nil) {
        self.endpoint = endpoint
        self.session = session ?? Self.anonymousSession
    }

    func fetchTally() async throws -> CleanupInterestTally {
        try await request()
    }

    func submit(_ ballot: CleanupInterestBallot) async throws -> CleanupInterestTally {
        try await request(ballot)
    }

    private func request(_ ballot: CleanupInterestBallot? = nil) async throws -> CleanupInterestTally {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let ballot {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(ballot)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(CleanupInterestTally.self, from: data)
    }
}

@MainActor
final class CleanupInterestPollModel: ObservableObject {
    @Published private(set) var choice: CleanupInterest?
    @Published private(set) var pending: CleanupInterestBallot?
    @Published private(set) var isSubmitting = false
    @Published private(set) var showingResults = false
    @Published private(set) var hasVoted: Bool
    @Published private(set) var tally: CleanupInterestTally?
    @Published private(set) var message: String?

    private let api: CleanupInterestPolling
    private let defaults: UserDefaults
    private let pendingKey: String
    private let votedKey: String
    private var latestRead: UUID?

    init(api: CleanupInterestPolling = CleanupInterestAPI(), defaults: UserDefaults = .standard,
         namespace: String = CleanupInterestAPI.endpoint.absoluteString) {
        self.api = api
        self.defaults = defaults
        pendingKey = "recoco.cleanupPoll.pending." + namespace
        votedKey = "recoco.cleanupPoll.voted." + namespace
        hasVoted = defaults.bool(forKey: votedKey)
        if let data = defaults.data(forKey: pendingKey),
           let ballot = try? JSONDecoder().decode(CleanupInterestBallot.self, from: data) {
            pending = ballot
            choice = ballot.choice
            message = String(localized: "반영 여부를 확인 중인 표가 있어요. 같은 표로 다시 확인해 주세요.")
        }
    }

    func select(_ interest: CleanupInterest) {
        guard !isSubmitting, pending == nil else { return }
        choice = interest
    }

    func openChoices() {
        latestRead = nil
        showingResults = false
        choice = pending?.choice
        message = pending == nil ? nil : String(localized: "이 표가 반영됐는지 다시 확인해 주세요.")
    }

    func openResults() {
        guard !isSubmitting else { return }
        message = nil
        showingResults = true
    }

    func refreshResults() async {
        guard showingResults, !isSubmitting else { return }
        let read = UUID()
        latestRead = read
        do {
            let updated = try await api.fetchTally()
            guard read == latestRead, !Task.isCancelled else { return }
            tally = updated
            message = nil
        } catch {
            guard read == latestRead, !Task.isCancelled else { return }
            message = String(localized: "투표 결과를 불러오지 못했어요. 연결을 확인해 주세요.")
        }
    }

    func submit() async {
        guard !showingResults, !isSubmitting, let choice else { return }
        let ballot = pending ?? CleanupInterestBallot(choice: choice, requestId: UUID())
        do {
            defaults.set(try JSONEncoder().encode(ballot), forKey: pendingKey)
        } catch {
            message = String(localized: "표를 준비하지 못했어요. 다시 시도해 주세요.")
            return
        }
        pending = ballot
        isSubmitting = true
        message = nil
        latestRead = nil
        defer { isSubmitting = false }
        do {
            tally = try await api.submit(ballot)
            // A dismissed sheet can still receive its response after another sheet retried.
            if let stored = defaults.data(forKey: pendingKey),
               (try? JSONDecoder().decode(CleanupInterestBallot.self, from: stored)) == ballot {
                defaults.removeObject(forKey: pendingKey)
            }
            pending = nil
            hasVoted = true
            defaults.set(true, forKey: votedKey)
            self.choice = nil
            showingResults = true
        } catch {
            message = String(localized: "투표가 반영됐는지 확인하지 못했어요. 같은 표로 다시 확인해 주세요.")
        }
    }
}
