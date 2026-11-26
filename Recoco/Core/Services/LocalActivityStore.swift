import Foundation
import FirebaseAuth
import FirebaseCore

@MainActor
enum UserScopedStorage {
    static var currentUserID: String? {
        guard FirebaseApp.app() != nil,
              let userID = Auth.auth().currentUser?.uid,
              !userID.isEmpty else {
            return nil
        }
        return userID
    }

    /// Photos, curation and activity belong to this device, independently of the
    /// optional account. Signing in must never switch the visible library.
    static func key(_ baseKey: String) -> String { baseKey }

    /// Explicit legacy namespaces remain addressable for audits/migrations only.
    /// Optional sign-in never merges, copies or removes these values.
    static func key(_ baseKey: String, userID: String?) -> String {
        guard let userID, !userID.isEmpty else { return baseKey }
        return "\(baseKey)_\(userID)"
    }

    /// Variable photo IDs cannot safely share a suffix delimiter with account IDs.
    /// Keep anonymous/development draft keys intact; authenticated drafts get an
    /// unambiguous owner namespace. Unknown legacy drafts are never guessed at.
    static func draftKey(photoID: String, userID: String?) -> String {
        guard let userID, !userID.isEmpty else { return "recoco_record_draft_\(photoID)" }
        return draftPrefix(userID: userID) + Data(photoID.utf8).base64EncodedString()
    }

    static func draftKey(photoID: String) -> String {
        draftKey(photoID: photoID, userID: nil)
    }

    private static func draftPrefix(userID: String) -> String {
        "recoco_account_drafts_v2:\(Data(userID.utf8).base64EncodedString()):"
    }

    /// Only known account-owned storage is eligible. Never clear the app domain,
    /// SDK defaults, device preferences, or unowned development/legacy data.
    static func removeAccountData(for userID: String, defaults: UserDefaults = .standard) throws {
        guard !userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AccountDeletionScope.Error.invalidUser
        }
        let baseKeys = [
            SavedRecordStore.storageKey, "recoco_activity_events_v1", "recoco_daily_session_v1",
            "recoco_photo_review_dates_v1", "recoco_protected_photos_v1",
            "recoco_curation_scan_v1", "recoco_scanned_photos_v1", "recoco_reviewed_photos_v1",
            "recoco_recommendation_history_v1", "recoco_cleanup_selection_v1",
            "recoco_cleanup_selection_day_v1", SubscriptionStore.previewKey
        ]
        let accountKeys = baseKeys.map { key($0, userID: userID) }
        let draftKeys = defaults.dictionaryRepresentation().keys.filter {
            $0.hasPrefix(draftPrefix(userID: userID))
        }
        for key in accountKeys + draftKeys { defaults.removeObject(forKey: key) }
    }
}

/// Capture this identity BEFORE reauthentication or remote deletion can change
/// Firebase.currentUser. The optional-account path never owns device data.
@MainActor
struct AccountDeletionScope {
    enum Error: LocalizedError {
        case invalidUser
        case sessionChanged

        var errorDescription: String? {
            switch self {
            case .invalidUser: return String(localized: "로그인 상태를 확인한 뒤 다시 시도해주세요.")
            case .sessionChanged: return String(localized: "로그인한 계정이 바뀌었어요. 현재 계정을 확인한 뒤 다시 시도해주세요.")
            }
        }
    }

    let userID: String

    init(userID: String) throws {
        guard !userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Error.invalidUser }
        self.userID = userID
    }

    func validate(currentUserID: String?) throws {
        guard currentUserID == userID else { throw Error.sessionChanged }
    }

    /// The optional account owns identity only. Device and legacy UID libraries
    /// are deliberately not parameters of this operation and stay untouched.
    func deleteAccountOnly(currentUserID: () -> String?,
                           deleteRemote: () async throws -> Void,
                           finishSession: () -> Void) async throws {
        try validate(currentUserID: currentUserID())
        try await deleteRemote()
        let activeUserID = currentUserID()
        if activeUserID == nil || activeUserID == userID { finishSession() }
    }

    /// Legacy explicitly scoped cleanup, retained for migration audits/tests.
    /// The current account UI uses deleteAccountOnly instead.
    func delete(currentUserID: () -> String?,
                deleteRemote: () async throws -> Void,
                clearLocalData: (String) throws -> Void,
                finishSession: () -> Void) async throws {
        try validate(currentUserID: currentUserID())
        try await deleteRemote()
        // Failure/cancellation above must never erase local records.
        try clearLocalData(userID)
        // A different account may have signed in while the request was pending.
        // Its screen, notifications and provider session must remain untouched.
        let activeUserID = currentUserID()
        if activeUserID == nil || activeUserID == userID { finishSession() }
    }
}

enum ReportingWeek {
    // Explicit Monday–Sunday boundaries, independent of the device locale's first weekday.
    static func interval(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        let today = calendar.startOfDay(for: date)
        let offset = (calendar.component(.weekday, from: today) + 5) % 7
        let start = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? today
        return DateInterval(start: start, end: end)
    }

    static func label(containing date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let interval = interval(containing: date, calendar: calendar)
        let end = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        if locale.language.languageCode?.identifier == "ko" {
            formatter.dateFormat = "yyyy. M. d."
            return "\(formatter.string(from: interval.start)) – \(formatter.string(from: end)) · 월–일"
        }
        let dateRange = DateIntervalFormatter()
        dateRange.locale = locale
        dateRange.calendar = calendar
        dateRange.timeZone = calendar.timeZone
        dateRange.dateStyle = .medium
        dateRange.timeStyle = .none
        return dateRange.string(from: interval.start, to: end)
    }
}

struct WeeklyActivitySnapshot {
    let completedDays: Int
    let deletedPhotoCount: Int
    let savedRecordCount: Int
    let dailyDeletedCounts: [Int]
    let dailySavedCounts: [Int]
}

struct TodayActivitySummary {
    let deletedPhotoCount: Int
    let savedRecordCount: Int
    var reviewedPhotoCount: Int? = nil
}

struct DailySessionProgress {
    let curatedPhotoIdentifiers: [String]
    let processedDecisionKeys: Set<String>
    let deletedPhotoCount: Int
    let savedRecordCount: Int
    var comparisonReferences: [String: String] = [:]
    var curationVersion: Int? = nil
    var curationReasons: [String: CurationReasonCode] = [:]
}

/// User-chosen review dates only; no inferred usage/last-opened timestamps.
@MainActor
final class CurationReviewStore {
    static let shared = CurationReviewStore(defaults: .standard)
    private let defaults: UserDefaults
    private let key = "recoco_photo_review_dates_v1"

    init(defaults: UserDefaults) { self.defaults = defaults }

    func dates() -> [String: Date] {
        guard let data = defaults.data(forKey: UserScopedStorage.key(key)),
              let dates = try? JSONDecoder().decode([String: Date].self, from: data) else { return [:] }
        return dates
    }

    func set(_ date: Date?, for identifier: String) {
        var stored = dates()
        stored[identifier] = date
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: UserScopedStorage.key(key)) }
    }
}

/// Explicit keep/record choices survive daily sessions.
@MainActor
final class CurationProtectionStore {
    static let shared = CurationProtectionStore(defaults: .standard)
    private let defaults: UserDefaults
    private let storageKey = "recoco_protected_photos_v1"

    init(defaults: UserDefaults) { self.defaults = defaults }

    func identifiers() -> Set<String> {
        Set(defaults.stringArray(forKey: UserScopedStorage.key(storageKey)) ?? [])
            .union(SavedRecordStore(defaults: defaults).records().compactMap(\.photoLocalIdentifier))
    }

    /// Destructive operations must stop if saved-photo protection cannot be read.
    func validatedIdentifiers() throws -> Set<String> {
        let key = UserScopedStorage.key(storageKey)
        if defaults.object(forKey: key) != nil, defaults.stringArray(forKey: key) == nil {
            throw SavedRecordStore.StorageError.unreadableRecords
        }
        return Set(defaults.stringArray(forKey: key) ?? [])
            .union(try SavedRecordStore(defaults: defaults).readRecords().compactMap(\.photoLocalIdentifier))
    }

    func protect(_ identifiers: [String]) {
        let existing = Set(defaults.stringArray(forKey: UserScopedStorage.key(storageKey)) ?? [])
        defaults.set(Array(existing.union(identifiers)).sorted(), forKey: UserScopedStorage.key(storageKey))
    }
}

struct SavedMemoryRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let text: String
    let photoLocalIdentifier: String?
    let capturedDateDescription: String?
    var photoThumbnailData: Data? = nil
}

@MainActor
final class SavedRecordStore {
    enum StorageError: Error {
        case unreadableRecords
        case conflictingRecord
    }
    static let shared = SavedRecordStore(defaults: .standard)
    static let storageKey = "recoco_saved_records_v1"

    private let defaults: UserDefaults
    private let now: () -> Date

    init(defaults: UserDefaults, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    func records() -> [SavedMemoryRecord] {
        (try? readRecords()) ?? []
    }

    func readRecords() throws -> [SavedMemoryRecord] {
        let key = UserScopedStorage.key(Self.storageKey)
        guard defaults.object(forKey: key) != nil else { return [] }
        guard let data = defaults.data(forKey: key),
              let records = try? JSONDecoder().decode([SavedMemoryRecord].self, from: data),
              Set(records.map(\.id)).count == records.count else {
            throw StorageError.unreadableRecords
        }
        return records.sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func save(
        id: UUID = UUID(),
        text: String,
        photoLocalIdentifier: String?,
        capturedDateDescription: String?,
        photoThumbnailData: Data? = nil
    ) throws -> SavedMemoryRecord {
        // Read before writing: malformed existing data must never be replaced by an empty list.
        var storedRecords = try readRecords()
        if let existing = storedRecords.first(where: { $0.id == id }) {
            guard existing.text == text,
                  existing.photoLocalIdentifier == photoLocalIdentifier,
                  existing.capturedDateDescription == capturedDateDescription else {
                throw StorageError.conflictingRecord
            }
            return existing
        }
        let record = SavedMemoryRecord(
            id: id,
            createdAt: now(),
            text: text,
            photoLocalIdentifier: photoLocalIdentifier,
            capturedDateDescription: capturedDateDescription,
            photoThumbnailData: photoThumbnailData
        )
        storedRecords.append(record)
        let protectedPhotoIdentifiers = storedRecords.compactMap(\.photoLocalIdentifier)
        storedRecords.sort { $0.createdAt > $1.createdAt }
        defaults.set(
            try JSONEncoder().encode(storedRecords),
            forKey: UserScopedStorage.key(Self.storageKey)
        )
        CurationProtectionStore(defaults: defaults).protect(protectedPhotoIdentifiers)
        return record
    }

    /// Removes this memory only. PhotoKit is never called, and its source stays protected.
    @discardableResult
    func delete(id: UUID) throws -> Bool {
        var records = try readRecords()
        guard let index = records.firstIndex(where: { $0.id == id }) else { return false }
        let record = records.remove(at: index)
        if let identifier = record.photoLocalIdentifier {
            let protection = CurationProtectionStore(defaults: defaults)
            _ = try protection.validatedIdentifiers()
            protection.protect([identifier])
        }
        defaults.set(try JSONEncoder().encode(records), forKey: UserScopedStorage.key(Self.storageKey))
        return true
    }

}

@MainActor
final class LocalActivityStore {
    static let shared = LocalActivityStore(defaults: .standard)

    private struct ActivityEvent: Codable {
        var sessionID: String? = nil
        var independentMemory: Bool? = nil
        var recordID: UUID? = nil
        var reviewedPhotoCount: Int? = nil
        let date: Date
        let deletedPhotoCount: Int
        let savedRecordCount: Int
    }

    private struct DailySessionState: Codable {
        var sessionID: String? = nil
        var startedAt: Date? = nil
        let dayKey: String
        var curatedPhotoIdentifiers: [String]
        var processedDecisionKeys: [String]
        var deletedPhotoCount: Int
        var savedRecordCount: Int
        var comparisonReferences: [String: String]? = nil
        var curationVersion: Int? = nil
        var curationReasons: [String: CurationReasonCode]? = nil
    }

    private let defaults: UserDefaults
    private let calendar: Calendar
    private let now: () -> Date
    private let eventsKey = "recoco_activity_events_v1"
    private let dailySessionKey = "recoco_daily_session_v1"
    private let reviewedPhotosKey = "recoco_reviewed_photos_v1"
    private let recommendationHistoryKey = "recoco_recommendation_history_v1"
    private let preparedRecommendationsKey = "recoco_prepared_recommendations_v1"
    static let recommendationCooldownDays = 30

    /// These candidates have been checked locally but never shown. Preparing
    /// them is not an exposure, a review, a selection, or a deletion.
    struct PreparedRecommendations: Codable {
        let preparedAt: Date
        let curationVersion: Int
        var photoIdentifiers: [String]
        var comparisonReferences: [String: String]
        var curationReasons: [String: CurationReasonCode]
    }

    func preparedRecommendations(excluding identifiers: Set<String> = []) -> PreparedRecommendations? {
        let key = UserScopedStorage.key(preparedRecommendationsKey)
        guard let data = defaults.data(forKey: key),
              var prepared = try? JSONDecoder().decode(PreparedRecommendations.self, from: data),
              prepared.curationVersion == PhotoCurationService.curationVersion,
              now().timeIntervalSince(prepared.preparedAt) >= 0,
              now().timeIntervalSince(prepared.preparedAt) < 7 * 86400 else {
            defaults.removeObject(forKey: key)
            return nil
        }
        prepared.photoIdentifiers.removeAll { identifiers.contains($0) }
        let remaining = Set(prepared.photoIdentifiers)
        prepared.comparisonReferences = prepared.comparisonReferences.filter { remaining.contains($0.key) }
        prepared.curationReasons = prepared.curationReasons.filter { remaining.contains($0.key) }
        guard !remaining.isEmpty else { defaults.removeObject(forKey: key); return nil }
        return prepared
    }

    func savePreparedRecommendations(_ decisions: [DecisionUnit], excluding excluded: Set<String>) {
        var existing = preparedRecommendations(excluding: excluded)
        var identifiers = existing?.photoIdentifiers ?? []
        var references = existing?.comparisonReferences ?? [:]
        var reasons = existing?.curationReasons ?? [:]
        for decision in decisions where identifiers.count < 6 {
            guard decision.type == .cleanupSingle, let id = decision.displayIdentifier,
                  !id.isEmpty, !decision.removalIdentifiers.isEmpty,
                  !excluded.contains(id), !identifiers.contains(id),
                  !references.values.contains(id), let reason = decision.reasonCodes.first,
                  !reason.isReflection else { continue }
            if let reference = decision.comparisonLocalIdentifier {
                guard reference != id, !identifiers.contains(reference) else { continue }
                references[id] = reference
            }
            identifiers.append(id)
            reasons[id] = reason
        }
        guard !identifiers.isEmpty else { return }
        existing = PreparedRecommendations(preparedAt: existing?.preparedAt ?? now(),
            curationVersion: PhotoCurationService.curationVersion, photoIdentifiers: identifiers,
            comparisonReferences: references, curationReasons: reasons)
        guard let data = try? JSONEncoder().encode(existing) else { return }
        defaults.set(data, forKey: UserScopedStorage.key(preparedRecommendationsKey))
    }

    func removePreparedRecommendations(_ identifiers: Set<String>) {
        let key = UserScopedStorage.key(preparedRecommendationsKey)
        guard let remaining = preparedRecommendations(excluding: identifiers),
              let data = try? JSONEncoder().encode(remaining) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }

    /// A checked photo remains the user's unfinished choice across midnight.
    /// Archive completed actions on their original day and carry only checked,
    /// still-pending identifiers; never apply an old check to a new photo.
    @discardableResult
    func carrySelectedRecommendationsToCurrentDay(_ selected: Set<String>, matchingDay: String? = nil) -> Bool {
        guard !selected.isEmpty, let previous = loadStoredDailySession(),
              previous.dayKey != dayKey(for: now()),
              matchingDay == nil || matchingDay == previous.dayKey,
              previous.curationVersion == PhotoCurationService.curationVersion else { return false }
        let processed = Set(previous.processedDecisionKeys)
        let pending = previous.curatedPhotoIdentifiers.filter { selected.contains($0) && !processed.contains($0) }
        guard !pending.isEmpty else { return false }
        let existingEvents = loadEvents()
        guard !existingEvents.contains(where: { $0.sessionID != nil && $0.sessionID == previous.sessionID }) else { return false }
        if !processed.isEmpty || previous.deletedPhotoCount > 0 || previous.savedRecordCount > 0 {
            saveEvents(existingEvents + [event(for: previous)])
        }
        let pendingSet = Set(pending)
        let state = DailySessionState(sessionID: UUID().uuidString, startedAt: now(), dayKey: dayKey(for: now()),
            curatedPhotoIdentifiers: pending, processedDecisionKeys: [], deletedPhotoCount: 0, savedRecordCount: 0,
            comparisonReferences: (previous.comparisonReferences ?? [:]).filter { pendingSet.contains($0.key) },
            curationVersion: previous.curationVersion,
            curationReasons: (previous.curationReasons ?? [:]).filter { pendingSet.contains($0.key) })
        saveDailySession(state)
        // Deliberately do not renew the original recommendation's 30-day clock.
        return true
    }

    init(
        defaults: UserDefaults,
        calendar: Calendar = .autoupdatingCurrent,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.calendar = calendar
        self.now = now
    }

    /// Capture before an asynchronous search; results from another local date must not replace today's queue.
    var recommendationDayKey: String { dayKey(for: now()) }

    /// Candidate-only exclusions. These photos may still serve as a comparison reference.
    /// A nomination lasts for 30 calendar days, including its original day; merely
    /// reopening a queue does not restart that interval.
    func recommendationExcludedIdentifiers() -> Set<String> {
        _ = loadCurrentDailySession()
        let current = now()
        return Set(loadRecommendationHistory().compactMap { identifier, nominatedAt in
            guard let eligibleAt = calendar.date(byAdding: .day, value: Self.recommendationCooldownDays,
                                                to: calendar.startOfDay(for: nominatedAt)),
                  current < eligibleAt else { return nil }
            return identifier
        })
    }

    private func loadRecommendationHistory() -> [String: Date] {
        guard let data = defaults.data(forKey: UserScopedStorage.key(recommendationHistoryKey)),
              let history = try? JSONDecoder().decode([String: Date].self, from: data) else { return [:] }
        return history
    }

    private func recordRecommendations(_ identifiers: [String], at date: Date, onlyMissing: Bool = false) {
        var history = loadRecommendationHistory()
        var changed = false
        for identifier in Set(identifiers) where !identifier.isEmpty {
            if onlyMissing, history[identifier] != nil { continue }
            if history[identifier] == date { continue }
            history[identifier] = date
            changed = true
        }
        guard changed, let data = try? JSONEncoder().encode(history) else { return }
        defaults.set(data, forKey: UserScopedStorage.key(recommendationHistoryKey))
    }

    func recordCompletion(deletedPhotoCount: Int, savedRecordCount: Int, completesDailySession: Bool = true) {
        var events = loadEvents()
        let session = completesDailySession ? loadStoredDailySession() : nil
        if session?.sessionID == nil || !events.contains(where: { $0.sessionID == session?.sessionID }) {
            events.append(ActivityEvent(
                sessionID: session?.sessionID,
                reviewedPhotoCount: session.map { $0.processedDecisionKeys.count },
                date: session?.startedAt ?? now(),
                deletedPhotoCount: max(0, deletedPhotoCount),
                savedRecordCount: max(0, savedRecordCount)
            ))
        }
        saveEvents(events)
        if completesDailySession {
            // Retain today's choices after the completed queue is cleared, including
            // sessions recorded before the separate reviewed-photo key existed.
            recordReviewedPhotos([])
            defaults.removeObject(forKey: UserScopedStorage.key(dailySessionKey))
        }
    }

    /// An independent memory must not close or replace an unfinished cleanup batch.
    func recordIndependentMemory(recordID: UUID? = nil) {
        var events = loadEvents()
        if let recordID, events.contains(where: { $0.recordID == recordID }) { return }
        events.append(ActivityEvent(independentMemory: true, recordID: recordID,
                                    date: now(), deletedPhotoCount: 0, savedRecordCount: 1))
        saveEvents(events)
    }

    func hasCompletedCleanupToday() -> Bool {
        loadEvents().contains { $0.independentMemory != true && calendar.isDate($0.date, inSameDayAs: now()) }
    }

    /// Rotate the bounded analysis window when the user explicitly asks for more.
    func advanceCurationScan() -> Int {
        let key = UserScopedStorage.key("recoco_curation_scan_v1")
        let stored = defaults.dictionary(forKey: key) ?? [:]
        let previous = stored["day"] as? String == dayKey(for: now()) ? (stored["offset"] as? Int ?? 0) : 0
        let next = min(max(0, previous), Int.max - 64) + 64
        defaults.set(["day": dayKey(for: now()), "offset": next], forKey: key)
        return next
    }

    func scannedPhotoIdentifiers() -> Set<String> {
        let stored = defaults.dictionary(forKey: UserScopedStorage.key("recoco_scanned_photos_v1")) ?? [:]
        // Older scans may have retired photos before comparing the whole window.
        guard stored["day"] as? String == dayKey(for: now()),
              stored["version"] as? Int == PhotoCurationService.curationVersion else { return [] }
        return Set(stored["identifiers"] as? [String] ?? [])
    }

    func recordScannedPhotos(_ identifiers: Set<String>) {
        let merged = scannedPhotoIdentifiers().union(identifiers)
        defaults.set(["day": dayKey(for: now()), "version": PhotoCurationService.curationVersion,
                      "identifiers": Array(merged).sorted()],
                     forKey: UserScopedStorage.key("recoco_scanned_photos_v1"))
    }

    /// A changed library scope can introduce a match for an earlier photograph.
    /// Clear only scan coverage; keep decisions, records and activity intact.
    func resetScannedPhotos() {
        defaults.removeObject(forKey: UserScopedStorage.key("recoco_scanned_photos_v1"))
    }

    /// Explicit decisions survive completed batches and photo-scope refreshes.
    /// Scan coverage alone must never make an unreviewed photo ineligible for reflection.
    func reviewedPhotoIdentifiers() -> Set<String> {
        let today = dayKey(for: now())
        let stored = defaults.dictionary(forKey: UserScopedStorage.key(reviewedPhotosKey)) ?? [:]
        var identifiers = stored["day"] as? String == today
            ? Set(stored["identifiers"] as? [String] ?? []) : []
        if let session = loadStoredDailySession(), session.dayKey == today {
            identifiers.formUnion(session.processedDecisionKeys)
        }
        return identifiers
    }

    private func recordReviewedPhotos(_ identifiers: Set<String>) {
        let merged = reviewedPhotoIdentifiers().union(identifiers)
        defaults.set(["day": dayKey(for: now()), "identifiers": Array(merged).sorted()],
                     forKey: UserScopedStorage.key(reviewedPhotosKey))
    }

    func dailySessionProgress() -> DailySessionProgress {
        let state = loadCurrentDailySession()
        return DailySessionProgress(
            curatedPhotoIdentifiers: state.curatedPhotoIdentifiers,
            processedDecisionKeys: Set(state.processedDecisionKeys),
            deletedPhotoCount: state.deletedPhotoCount,
            savedRecordCount: state.savedRecordCount,
            comparisonReferences: state.comparisonReferences ?? [:],
            curationVersion: state.curationVersion,
            curationReasons: state.curationReasons ?? [:]
        )
    }

    func beginDailySession(photoIdentifiers: [String], comparisonReferences: [String: String] = [:],
                           curationReasons: [String: CurationReasonCode] = [:]) {
        var state = loadCurrentDailySession()
        guard state.curatedPhotoIdentifiers.isEmpty || state.curationVersion != PhotoCurationService.curationVersion else { return }
        state.curatedPhotoIdentifiers = photoIdentifiers
        state.comparisonReferences = comparisonReferences
        state.curationVersion = PhotoCurationService.curationVersion
        state.curationReasons = curationReasons
        saveDailySession(state)
        recordRecommendations(photoIdentifiers, at: now())
    }

    struct RecommendationAppendToken {
        fileprivate let dayKey: String
        fileprivate let storedState: Data
    }

    /// Capture the exact pending session before an asynchronous top-up. No
    /// recommendation may be appended after another action changes that session.
    func recommendationAppendToken() -> RecommendationAppendToken? {
        guard let state = loadStoredDailySession(), state.dayKey == dayKey(for: now()),
              state.curationVersion == PhotoCurationService.curationVersion,
              !state.curatedPhotoIdentifiers.isEmpty,
              let data = defaults.data(forKey: UserScopedStorage.key(dailySessionKey)) else { return nil }
        return RecommendationAppendToken(dayKey: state.dayKey, storedState: data)
    }

    func matchesRecommendationAppendToken(_ token: RecommendationAppendToken) -> Bool {
        token.dayKey == dayKey(for: now())
            && defaults.data(forKey: UserScopedStorage.key(dailySessionKey)) == token.storedState
    }

    @discardableResult
    func appendRecommendations(photoIdentifiers: [String], comparisonReferences: [String: String],
                               curationReasons: [String: CurationReasonCode],
                               matching token: RecommendationAppendToken) -> Bool {
        let key = UserScopedStorage.key(dailySessionKey)
        guard token.dayKey == dayKey(for: now()), defaults.data(forKey: key) == token.storedState,
              var state = try? JSONDecoder().decode(DailySessionState.self, from: token.storedState),
              !loadEvents().contains(where: { $0.sessionID != nil && $0.sessionID == state.sessionID }),
              state.curationVersion == PhotoCurationService.curationVersion else { return false }
        let additions = Set(photoIdentifiers)
        let existing = Set(state.curatedPhotoIdentifiers).union(state.processedDecisionKeys)
        let references = state.comparisonReferences ?? [:]
        guard !additions.isEmpty, additions.count == photoIdentifiers.count,
              !additions.contains(""), additions.isDisjoint(with: existing),
              existing.count + additions.count <= 3,
              Set(curationReasons.keys) == additions,
              !curationReasons.values.contains(where: \.isReflection),
              Set(comparisonReferences.keys).isSubset(of: additions),
              additions.isDisjoint(with: Set(references.values)),
              Set(comparisonReferences.values).isDisjoint(with: existing.union(additions)) else { return false }
        state.curatedPhotoIdentifiers.append(contentsOf: photoIdentifiers)
        state.comparisonReferences = references.merging(comparisonReferences) { original, _ in original }
        state.curationReasons = (state.curationReasons ?? [:]).merging(curationReasons) { original, _ in original }
        saveDailySession(state)
        recordRecommendations(photoIdentifiers, at: now())
        return true
    }

    /// Atomically improve only the pending mix; never change selected photos or accounting.
    @discardableResult
    func diversifyPendingRecommendations(_ decisions: [DecisionUnit], preserving pinned: Set<String>,
                                         matching token: RecommendationAppendToken) -> Bool {
        guard matchesRecommendationAppendToken(token),
              var state = try? JSONDecoder().decode(DailySessionState.self, from: token.storedState),
              state.curationVersion == PhotoCurationService.curationVersion,
              !loadEvents().contains(where: { $0.sessionID != nil && $0.sessionID == state.sessionID }) else { return false }
        let processed = Set(state.processedDecisionKeys)
        let oldPending = Set(state.curatedPhotoIdentifiers).subtracting(processed)
        let identifiers = decisions.compactMap(\.displayIdentifier)
        let updated = Set(identifiers)
        let oldReasons = state.curationReasons ?? [:]
        let oldReferences = state.comparisonReferences ?? [:]
        guard !updated.isEmpty, updated.count == identifiers.count, updated.count == oldPending.count,
              pinned.intersection(oldPending).isSubset(of: updated), updated.isDisjoint(with: processed),
              updated.union(processed).count <= 3,
              decisions.allSatisfy({ unit in
                  guard let id = unit.displayIdentifier, !id.isEmpty,
                        unit.type == .cleanupSingle, unit.status == .pending, unit.removalIdentifiers == [id],
                        let reason = unit.reasonCodes.first,
                        unit.evidence.map({ $0.reason == reason }) ?? true,
                        let group = CleanupReasonGroup(reason),
                        group == .contextReview || unit.comparisonLocalIdentifier?.isEmpty == false else { return false }
                  return !oldPending.contains(id) || (unit.reasonCodes.first == oldReasons[id]
                      && unit.comparisonLocalIdentifier == oldReferences[id])
              }) else { return false }
        let reasons = Dictionary(uniqueKeysWithValues: decisions.map { ($0.persistenceKey, $0.reasonCodes[0]) })
        let references = Dictionary(uniqueKeysWithValues: decisions.compactMap { unit in
            unit.comparisonLocalIdentifier.map { (unit.persistenceKey, $0) }
        })
        let previousGroups = Set(oldPending.compactMap { CleanupReasonGroup(oldReasons[$0]) })
        let nextGroups = Set(reasons.values.compactMap { CleanupReasonGroup($0) })
        let added = updated.subtracting(oldPending)
        guard nextGroups.count > previousGroups.count,
              updated.union(processed).isDisjoint(with: Set(references.values)),
              added.isDisjoint(with: Set(oldReferences.values)),
              added.isDisjoint(with: recommendationExcludedIdentifiers()) else { return false }
        // Only pending recommendations change. Counts, completion history,
        // selections, and the identities/reasons of retained photos survive.
        state.curatedPhotoIdentifiers = state.curatedPhotoIdentifiers.filter { processed.contains($0) } + identifiers
        state.curationReasons = oldReasons.filter { processed.contains($0.key) }.merging(reasons) { _, next in next }
        state.comparisonReferences = oldReferences.filter { processed.contains($0.key) }.merging(references) { _, next in next }
        saveDailySession(state)
        recordRecommendations(Array(added), at: now())
        return true
    }

    /// Explicitly move past inaccessible pending photos; completed choices and counts survive.
    func clearPendingRecommendations() {
        var state = loadCurrentDailySession()
        state.curatedPhotoIdentifiers = []
        state.comparisonReferences = [:]
        state.curationReasons = [:]
        state.curationVersion = nil
        saveDailySession(state)
    }

    func recordDailyDecision(
        decisionKey: String,
        deletedPhotoCount: Int,
        savedRecord: Bool
    ) {
        var state = loadCurrentDailySession()
        guard !state.processedDecisionKeys.contains(decisionKey) else { return }

        state.processedDecisionKeys.append(decisionKey)
        state.deletedPhotoCount += max(0, deletedPhotoCount)
        state.savedRecordCount += savedRecord ? 1 : 0
        saveDailySession(state)
        recordReviewedPhotos([decisionKey])
    }

    /// A successful Photos batch is recorded in one session write.
    func recordDailyDeletions(_ decisions: [(key: String, count: Int)]) {
        var state = loadCurrentDailySession()
        var added = Set<String>()
        for decision in decisions where decision.count > 0 {
            guard !state.processedDecisionKeys.contains(decision.key), added.insert(decision.key).inserted else { continue }
            state.processedDecisionKeys.append(decision.key)
            state.deletedPhotoCount += decision.count
        }
        guard !added.isEmpty else { return }
        saveDailySession(state)
        recordReviewedPhotos(added)
    }

    /// Calendar projection only: existing records and event storage remain unchanged.
    func cleanupDailyCounts(referenceDate: Date? = nil) -> [Date: Int] {
        let reference = referenceDate ?? now()
        return eventsForReporting().reduce(into: [:]) { counts, event in
            guard event.date <= reference, event.deletedPhotoCount > 0 else { return }
            counts[calendar.startOfDay(for: event.date), default: 0] += event.deletedPhotoCount
        }
    }

    /// Current-month cleanup total, including an unfinished batch exactly once.
    /// Reads the existing activity ledger without changing records or session state.
    func monthlyDeletedPhotoCount(referenceDate: Date? = nil) -> Int {
        let reference = referenceDate ?? now()
        guard let month = calendar.dateInterval(of: .month, for: reference) else { return 0 }
        return eventsForReporting().reduce(0) { total, event in
            guard event.date >= month.start, event.date < month.end,
                  event.date <= reference else { return total }
            return total + max(0, event.deletedPhotoCount)
        }
    }

    func todaySummary() -> TodayActivitySummary? {
        let startOfToday = calendar.startOfDay(for: now())
        guard let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) else {
            return nil
        }
        let todayEvents = eventsForReporting().filter {
            $0.date >= startOfToday && $0.date < startOfTomorrow
        }
        guard !todayEvents.isEmpty else { return nil }

        let cleanupEvents = todayEvents.filter { $0.independentMemory != true }
        let reviewed = cleanupEvents.compactMap(\.reviewedPhotoCount)
        return TodayActivitySummary(
            deletedPhotoCount: todayEvents.reduce(0) { $0 + $1.deletedPhotoCount },
            savedRecordCount: todayEvents.reduce(0) { $0 + $1.savedRecordCount },
            reviewedPhotoCount: !cleanupEvents.isEmpty && reviewed.count == cleanupEvents.count ? reviewed.reduce(0, +) : nil
        )
    }

    func weeklySnapshot(referenceDate: Date? = nil) -> WeeklyActivitySnapshot {
        let interval = ReportingWeek.interval(containing: referenceDate ?? now(), calendar: calendar)
        // DateInterval.contains includes its end; next Monday belongs to the next week.
        let events = eventsForReporting().filter { $0.date >= interval.start && $0.date < interval.end }
        let completedDays = Set(events.map { calendar.startOfDay(for: $0.date) }).count
        var dailyCounts = Array(repeating: 0, count: 7)
        var dailySaved = Array(repeating: 0, count: 7)

        for event in events {
            let weekday = calendar.component(.weekday, from: event.date)
            let mondayBasedIndex = (weekday + 5) % 7
            dailyCounts[mondayBasedIndex] += event.deletedPhotoCount
            dailySaved[mondayBasedIndex] += event.savedRecordCount
        }

        return WeeklyActivitySnapshot(
            completedDays: completedDays,
            deletedPhotoCount: events.reduce(0) { $0 + $1.deletedPhotoCount },
            savedRecordCount: events.reduce(0) { $0 + $1.savedRecordCount },
            dailyDeletedCounts: dailyCounts,
            dailySavedCounts: dailySaved
        )
    }

    private func loadEvents() -> [ActivityEvent] {
        guard
            let data = defaults.data(forKey: UserScopedStorage.key(eventsKey)),
            let events = try? JSONDecoder().decode([ActivityEvent].self, from: data)
        else {
            return []
        }
        return events
    }

    private func saveEvents(_ events: [ActivityEvent]) {
        guard let data = try? JSONEncoder().encode(events) else { return }
        defaults.set(data, forKey: UserScopedStorage.key(eventsKey))
    }

    private func loadCurrentDailySession() -> DailySessionState {
        let currentDayKey = dayKey(for: now())
        if let state = loadStoredDailySession() {
            let committed = loadEvents().contains { $0.sessionID != nil && $0.sessionID == state.sessionID }
            if !committed, state.dayKey == currentDayKey { return state }
            // An interrupted batch still represents real actions, including across midnight.
            // A stable session ID prevents replay if termination follows saving the event.
            if !committed, !state.processedDecisionKeys.isEmpty || state.deletedPhotoCount > 0 || state.savedRecordCount > 0 {
                var events = loadEvents()
                events.append(event(for: state))
                saveEvents(events)
            }
            // Each new local date starts a fresh queue. Yesterday's nominations
            // remain in the cooldown history, but are not counted as user actions.
            defaults.removeObject(forKey: UserScopedStorage.key(dailySessionKey))
        }
        return DailySessionState(sessionID: UUID().uuidString, startedAt: now(), dayKey: currentDayKey,
                                 curatedPhotoIdentifiers: [], processedDecisionKeys: [],
                                 deletedPhotoCount: 0, savedRecordCount: 0)
    }

    private func loadStoredDailySession() -> DailySessionState? {
        guard let data = defaults.data(forKey: UserScopedStorage.key(dailySessionKey)),
              var state = try? JSONDecoder().decode(DailySessionState.self, from: data) else { return nil }
        if state.sessionID == nil {
            state.sessionID = UUID().uuidString
            let parts = state.dayKey.split(separator: "-").compactMap { Int($0) }
            if parts.count == 3 {
                state.startedAt = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
            }
            saveDailySession(state)
        }
        // Upgrade without losing the current queue or inventing a fresh exposure
        // date on each launch. Older sessions already contain their nomination date.
        let parts = state.dayKey.split(separator: "-").compactMap { Int($0) }
        let sessionDate = state.startedAt ?? (parts.count == 3
            ? calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) : nil)
        if let sessionDate {
            recordRecommendations(state.curatedPhotoIdentifiers, at: sessionDate, onlyMissing: true)
        }
        return state
    }

    private func event(for state: DailySessionState) -> ActivityEvent {
        ActivityEvent(sessionID: state.sessionID, reviewedPhotoCount: state.processedDecisionKeys.count, date: state.startedAt ?? now(),
                      deletedPhotoCount: state.deletedPhotoCount, savedRecordCount: state.savedRecordCount)
    }

    private func eventsForReporting() -> [ActivityEvent] {
        var events = loadEvents()
        if let state = loadStoredDailySession(),
           !state.processedDecisionKeys.isEmpty || state.deletedPhotoCount > 0 || state.savedRecordCount > 0,
           !events.contains(where: { $0.sessionID == state.sessionID }) {
            events.append(event(for: state))
        }
        return events
    }

    private func saveDailySession(_ state: DailySessionState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: UserScopedStorage.key(dailySessionKey))
    }

    private func dayKey(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }
}
