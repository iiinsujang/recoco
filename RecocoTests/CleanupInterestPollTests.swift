import Foundation
import XCTest
@testable import Recoco

@MainActor
final class CleanupInterestPollTests: XCTestCase {
    func testLostReplyAndRelaunchReuseOneBallotThenIntentionalRepeatAddsOneVote() async throws {
        let suite = "recoco.cleanupPoll.tests.\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let api = PollFixture()
        let first = CleanupInterestPollModel(api: api, defaults: preferences, namespace: "qa")
        first.select(.video)
        await api.loseNextAcknowledgement()
        await first.submit()
        let pending = try XCTUnwrap(first.pending)
        XCTAssertNotNil(first.message)
        XCTAssertFalse(first.showingResults)

        let relaunched = CleanupInterestPollModel(api: api, defaults: preferences, namespace: "qa")
        XCTAssertEqual(relaunched.pending, pending)
        relaunched.select(.apps)
        XCTAssertEqual(relaunched.choice, .video)
        await relaunched.submit()
        XCTAssertTrue(relaunched.showingResults)
        XCTAssertEqual(relaunched.tally?[.video], 1)
        XCTAssertNil(relaunched.pending)

        relaunched.openChoices()
        XCTAssertNil(relaunched.choice)
        relaunched.select(.video)
        await relaunched.submit()
        XCTAssertEqual(relaunched.tally?.total, 2)
        let ids = await api.receivedIDs()
        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(ids[0], ids[1])
        XCTAssertNotEqual(ids[1], ids[2])
    }

    func testResultsOnlyDoesNotSubmitAndReadsOtherParticipantsVotes() async throws {
        let suite = "recoco.cleanupPoll.tests.\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let api = PollFixture()
        let viewer = CleanupInterestPollModel(api: api, defaults: preferences)
        viewer.openResults()
        await viewer.refreshResults()
        XCTAssertEqual(viewer.tally?.total, 0)
        let noVotes = await api.receivedIDs()
        XCTAssertTrue(noVotes.isEmpty)
        _ = try await api.submit(.init(choice: .alerts, requestId: UUID()))
        await viewer.refreshResults()
        XCTAssertEqual(viewer.tally?[.alerts], 1)
        await api.failReads()
        await viewer.refreshResults()
        XCTAssertNotNil(viewer.message)
        XCTAssertEqual(viewer.tally?[.alerts], 1)
    }

    func testInvalidCountsAreRejectedInsteadOfShowingZeroVotes() {
        for payload in [
            #"{"counts":{"apps":4}}"#,
            #"{"counts":{"apps":4,"contacts":1,"video":0,"messages":-1,"alerts":0}}"#
        ] {
            XCTAssertThrowsError(try JSONDecoder().decode(CleanupInterestTally.self, from: Data(payload.utf8)))
        }
    }

    func testAPISendsOnlyChoiceAndPerVoteRequestID() async throws {
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [PollRequestFixture.self]
        let client = CleanupInterestAPI(endpoint: URL(string: "https://poll.invalid/api/test")!,
                                        session: URLSession(configuration: session))
        let tally = try await client.submit(.init(choice: .contacts, requestId: UUID()))
        XCTAssertEqual(tally.total, 1)
    }
}

private actor PollFixture: CleanupInterestPolling {
    private var votes: [UUID: CleanupInterest] = [:]
    private var received: [UUID] = []
    private var dropReply = false
    private var offline = false

    func loseNextAcknowledgement() { dropReply = true }
    func failReads() { offline = true }
    func receivedIDs() -> [UUID] { received }

    func submit(_ ballot: CleanupInterestBallot) async throws -> CleanupInterestTally {
        received.append(ballot.requestId)
        votes[ballot.requestId] = ballot.choice
        if dropReply {
            dropReply = false
            throw URLError(.networkConnectionLost)
        }
        return try await fetchTally()
    }

    func fetchTally() async throws -> CleanupInterestTally {
        guard !offline else { throw URLError(.notConnectedToInternet) }
        let counts = Dictionary(uniqueKeysWithValues: CleanupInterest.allCases.map { option in
            (option.rawValue, votes.values.filter { $0 == option }.count)
        })
        return try JSONDecoder().decode(CleanupInterestTally.self,
            from: JSONSerialization.data(withJSONObject: ["counts": counts]))
    }
}

private final class PollRequestFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.host, "poll.invalid")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            let body: Data
            if let payload = request.httpBody {
                body = payload
            } else {
                let stream = try XCTUnwrap(request.httpBodyStream)
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                var result = Data()
                while true {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    if read < 0 { throw URLError(.cannotDecodeContentData) }
                    if read == 0 { break }
                    result.append(contentsOf: buffer.prefix(read))
                }
                body = result
            }
            let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(Set(keys.keys), ["choice", "requestId"])
            XCTAssertEqual(keys["choice"], "contacts")
            XCTAssertNotNil(keys["requestId"].flatMap(UUID.init(uuidString:)))
            let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 200,
                                                        httpVersion: "HTTP/1.1", headerFields: nil))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"counts":{"apps":0,"contacts":1,"video":0,"messages":0,"alerts":0}}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
