import SwiftUI
import Photos

/// The UI no longer displays per-image worker counts. Avoid rebuilding Home
/// dozens of times for a single group of concurrently prepared thumbnails.
final class CurationProgressPresentationGate {
    private let lock = NSLock()
    private var lastPhase: PhotoCurationService.ScanProgress.Phase?
    private var lastAccessibleCount: Int?

    func accepts(_ progress: PhotoCurationService.ScanProgress) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard lastPhase != progress.phase || lastAccessibleCount != progress.accessiblePhotoCount else { return false }
        lastPhase = progress.phase
        lastAccessibleCount = progress.accessiblePhotoCount
        return true
    }
}

enum CurationLibraryChangePolicy {
    static func requiresRefresh(relevantFetch: Bool, incremental: Bool,
                                inserted: Int, removed: Int, changed: Int, moved: Bool) -> Bool {
        relevantFetch && (!incremental || inserted > 0 || removed > 0 || changed > 0 || moved)
    }
}

/// PhotoKit also reports availability/bookkeeping updates while reading iCloud
/// previews. Only a changed image or a fact used by curation invalidates evidence.
struct CurationLibraryAssetRevision: Equatable {
    var modifiedAt: Date? = nil
    var capturedAt: Date? = nil
    var width = 0
    var height = 0
    var subtypes: UInt = 0
    var favorite = false
    var hidden = false
    var adjusted = false
    var burstIdentifier: String? = nil
    var latitude: Double? = nil
    var longitude: Double? = nil

    init() {}
    init(_ asset: PHAsset) {
        modifiedAt = asset.modificationDate
        capturedAt = asset.creationDate
        width = asset.pixelWidth; height = asset.pixelHeight
        subtypes = asset.mediaSubtypes.rawValue
        favorite = asset.isFavorite; hidden = asset.isHidden
        adjusted = asset.hasAdjustments
        burstIdentifier = asset.burstIdentifier
        latitude = asset.location?.coordinate.latitude
        longitude = asset.location?.coordinate.longitude
    }

    func requiresRefresh(after: Self?, contentChanged: Bool) -> Bool {
        contentChanged || after == nil || self != after
    }
}

private enum HomeCurationDiagnostics {
    private static let lock = NSLock()
    private static let started = ProcessInfo.processInfo.systemUptime
    private static var events: [[String: Any]] = []
    static func record(_ event: String, _ values: [String: Any]) {
        guard ProcessInfo.processInfo.arguments.contains("-recoco-curation-timing") else { return }
        lock.lock(); defer { lock.unlock() }
        events.append(["event": event, "elapsed": ProcessInfo.processInfo.systemUptime - started, "values": values])
        if events.count > 40 { events.removeFirst(events.count - 40) }
        guard let data = try? JSONSerialization.data(withJSONObject: ["events": events]),
              let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        try? data.write(to: folder.appendingPathComponent("recoco-home-curation-state.json"), options: .atomic)
    }
}

// MARK: - HomeViewModel
// 명세서 §8 S-04

enum HomeState {
    case loading                      // 분석 준비 중
    case scanPaused                   // 사용자 또는 화면 이탈로 일시 중지
    case searchPending                // 탐색 예산 소진; 다음 홈 방문에 이어서 탐색
    case noPermission                 // 사진 접근 권한 없음
    case ready(DecisionUnit)          // 오늘의 Decision Unit 존재
    case completed(summary: CompletionSummary) // 오늘 완료
    case noCandidate                  // 정리 후보 없음
    case subscriptionRequired
}

struct CompletionSummary {
    let deletedCount: Int
    let savedRecordCount: Int
    var reviewedCount: Int? = nil

    var title: String {
        if let reviewedCount, reviewedCount > 0 { return String(localized: "모두 살펴봤어요.") }
        return String(localized: "이번 정리를 마쳤어요.")
    }

    // A failed photo read is still unresolved, even after the visible queue ends.
    var partialTitle: String {
        if let reviewedCount, reviewedCount > 0 { return String(localized: "사진 \(reviewedCount)장을 살펴봤어요.") }
        return String(localized: "이번 정리를 마쳤어요.")
    }
}

/// Failures stay visible until the existing photos/access have been checked again.
/// No recovery path authorizes a deletion or advances the activity counts.
enum HomeCleanupRecovery: Equatable {
    case changedPhotos, accessDenied, accessRestricted, unconfirmed

    var title: String {
        switch self {
        case .changedPhotos: return String(localized: "사진을 비우기 전에 다시 확인이 필요해요.")
        case .accessDenied: return String(localized: "사진 접근을 다시 허용해주세요.")
        case .accessRestricted: return String(localized: "이 기기에서는 사진 접근이 제한되어 있어요.")
        case .unconfirmed: return String(localized: "비우기 완료 여부를 확인하지 못했어요.")
        }
    }

    var message: String {
        switch self {
        case .changedPhotos:
            return String(localized: "사진 상태나 접근 범위가 바뀌었을 수 있어요. 선택을 유지한 채 다시 확인할게요.")
        case .accessDenied:
            return String(localized: "설정에서 접근을 허용하면 다시 확인해요. 선택 상태와 기록은 유지돼요.")
        case .accessRestricted:
            return String(localized: "기기의 사용 제한이나 관리 설정을 확인해주세요. 선택 상태와 기록은 유지돼요.")
        case .unconfirmed:
            return String(localized: "선택 상태는 유지돼요. 사진을 다시 확인한 뒤 비우기를 시도해주세요.")
        }
    }
}

/// The same next step is used after a completed batch and an empty scan.
enum HomeEmptyAction: Equatable {
    case findMore, selectPhotos, retry, findOtherPhotos, refresh, subscription, finish
}

/// Presentation readiness is separate from curation evidence. A verified candidate
/// still needs a successfully rendered Home preview before it can be deleted.
enum HomePhotoPreviewState: Equatable {
    case loading, ready, failed
}

struct HomeDecisionProgress: Equatable {
    let completedBeforeLoad: Int
    let pendingCount: Int
    let currentPendingIndex: Int

    var totalCount: Int {
        completedBeforeLoad + pendingCount
    }

    var currentNumber: Int {
        guard totalCount > 0 else { return 0 }
        return min(completedBeforeLoad + currentPendingIndex + 1, totalCount)
    }
}

/// Browsing changes selection only. Completing any selected card preserves the others.
struct HomeDecisionQueue {
    var decisions: [DecisionUnit] = []
    var selectedIndex = 0

    mutating func replaceAfterValidation(_ updated: [DecisionUnit]) {
        let selectedKey = decisions.indices.contains(selectedIndex) ? decisions[selectedIndex].persistenceKey : nil
        decisions = updated
        selectedIndex = updated.firstIndex(where: { $0.persistenceKey == selectedKey }) ?? 0
    }

    mutating func select(_ index: Int) {
        guard decisions.indices.contains(index) else { return }
        selectedIndex = index
    }

    @discardableResult
    mutating func remove(key: String) -> DecisionUnit? {
        guard let index = decisions.firstIndex(where: { $0.persistenceKey == key }) else { return nil }
        let selectedKey = decisions.indices.contains(selectedIndex) ? decisions[selectedIndex].persistenceKey : nil
        let removed = decisions.remove(at: index)
        selectedIndex = decisions.firstIndex(where: { $0.persistenceKey == selectedKey })
            ?? max(0, min(index, decisions.count - 1))
        return removed
    }
}

/// Keep one Home request open while collecting up to three verified candidates.
/// The shared collector preserves comparison references and recommendation limits;
/// cancellation discards all temporary coverage before it can reach persistence.
@MainActor
enum HomeCurationSearch {
    // Try missing reasons first, then make verified alternatives usable.
    // A full Home can continue improving unchecked reasons in the background.
    nonisolated static let foregroundDiversityTimeLimit: TimeInterval = 3
    /// A foreground visit may continue a short, unfinished slice automatically.
    /// Keep the same verified choices and comparison protections across slices;
    /// never turn a time limit into an exhausted-library conclusion.
    static func curatedContinuing(
        excluding visited: Set<String>, protectedIdentifiers: Set<String> = [], initialDecisions: [DecisionUnit] = [], limit: Int = 3,
        excludingReasonGroups: Set<CleanupReasonGroup> = [], allowSameReasonFallback: Bool = true,
        diversityTimeLimit: TimeInterval = foregroundDiversityTimeLimit, maximumSlices: Int = 3,
        maximumAttempts: Int = 32, timeLimit: TimeInterval = 4, now: () -> Date = Date.init,
        onUpdate: ((PhotoCurationService.ScanBatch) async -> Void)? = nil,
        canContinue: @escaping () -> Bool = { true },
        fetch: (Set<String>, Set<String>, Int, Set<CleanupReasonGroup>) async -> PhotoCurationService.ScanBatch
    ) async -> PhotoCurationService.ScanBatch? {
        guard maximumSlices > 0, maximumAttempts > 0, !Task.isCancelled, canContinue() else { return nil }
        // One collector owns the entire visit. An internal four-second work
        // slice must not publish buffered duplicates and finish the Home set.
        var sourceAvailability: (hasMore: Bool, hasFresh: Bool)?
        func availability(_ snapshot: PhotoCurationService.ScanBatch) -> PhotoCurationService.ScanBatch {
            var value = PhotoCurationService.ScanBatch(decisions: snapshot.decisions,
                visitedIdentifiers: snapshot.visitedIdentifiers,
                hasMore: sourceAvailability?.hasMore ?? snapshot.hasMore,
                retryableFailureCount: snapshot.retryableFailureCount,
                hasFreshPhotos: sourceAvailability?.hasFresh ?? snapshot.hasFreshPhotos,
                accessiblePhotoCount: snapshot.accessiblePhotoCount,
                deferredIdentifiers: snapshot.deferredIdentifiers,
                deferredReferences: snapshot.deferredReferences, workRevision: snapshot.workRevision)
            // Missing-reason coverage can be exhausted while truthful fallback
            // work remains. The collector has already bounded that continuation.
            if !snapshot.decisions.isEmpty { value.hasFreshPhotos = snapshot.hasFreshPhotos }
            return value
        }
        let batch = await curated(excluding: visited, protectedIdentifiers: protectedIdentifiers,
            initialDecisions: initialDecisions, limit: limit, excludingReasonGroups: excludingReasonGroups,
            allowSameReasonFallback: allowSameReasonFallback, diversityTimeLimit: diversityTimeLimit,
            maximumAttempts: maximumAttempts * maximumSlices,
            timeLimit: max(0, timeLimit) * Double(maximumSlices), stopOnUnchangedWork: true, now: now,
            onUpdate: { snapshot in await onUpdate?(availability(snapshot)) }, canContinue: canContinue) {
                excluded, protected, remaining, represented in
                let next = await fetch(excluded, protected, remaining, represented)
                sourceAvailability = (next.hasMore, next.hasFreshPhotos)
                return next
            }
        return batch.map(availability)
    }

    static func curated(
        excluding visited: Set<String>, protectedIdentifiers: Set<String> = [], initialDecisions: [DecisionUnit] = [], limit: Int = 3,
        excludingReasonGroups: Set<CleanupReasonGroup> = [], allowSameReasonFallback: Bool = false,
        diversityTimeLimit: TimeInterval = 9, maximumAttempts: Int = 32, timeLimit: TimeInterval = 12,
        stopOnUnchangedWork: Bool = false, now: () -> Date = Date.init,
        onUpdate: ((PhotoCurationService.ScanBatch) async -> Void)? = nil,
        canContinue: @escaping () -> Bool = { true },
        fetch: (Set<String>, Set<String>, Int, Set<CleanupReasonGroup>) async -> PhotoCurationService.ScanBatch
    ) async -> PhotoCurationService.ScanBatch? {
        guard maximumAttempts > 0, !Task.isCancelled, canContinue() else { return nil }
        var invalidated = false
        let result = await PhotoCurationService.curatedBatch(
            excluding: visited, protectedIdentifiers: protectedIdentifiers, initialDecisions: initialDecisions, limit: limit,
            excludingReasonGroups: excludingReasonGroups, allowSameReasonFallback: allowSameReasonFallback,
            diversityTimeLimit: diversityTimeLimit, maximumPasses: maximumAttempts, timeLimit: timeLimit,
            stopOnUnchangedWork: stopOnUnchangedWork, now: now,
            onUpdate: { snapshot in
                guard !Task.isCancelled, canContinue() else { invalidated = true; return }
                await onUpdate?(snapshot)
            }
        ) { excluded, protected, remaining, represented in
            guard !Task.isCancelled, canContinue() else {
                invalidated = true
                return .init(decisions: [], visitedIdentifiers: [], hasMore: false)
            }
            let batch = await fetch(excluded, protected, remaining, represented)
            guard !Task.isCancelled, canContinue() else {
                invalidated = true
                return .init(decisions: [], visitedIdentifiers: [], hasMore: false)
            }
            return batch
        }
        guard !invalidated, !Task.isCancelled, canContinue() else { return nil }
        return result
    }
}

@MainActor
final class HomeViewModel: ObservableObject {
    private enum SessionKind {
        case daily
        case similarPhoto
    }

    @Published var state: HomeState = .loading
    @Published var weeklyProgress: WeeklyProgress = .init(
        completedDays: 0,
        deletedPhotoCount: 0,
        savedRecordCount: 0
    )
    @Published var userName: String = ""
    // More accessible, unscanned photos do not imply another verified recommendation.
    @Published var hasMorePhotos = true
    @Published var lastScanFoundNoCandidates = false
    @Published private(set) var additionalSearchFoundNoCandidates = false
    @Published private(set) var unavailablePhotoCount = 0
    @Published private(set) var hasFreshPhotos = false
    @Published private(set) var scanProgress = PhotoCurationService.ScanProgress()
    @Published private(set) var isLimitedAccess = false
    @Published private(set) var accessiblePhotoCount: Int?
    @Published private(set) var inaccessiblePhotoCount = 0
    @Published private(set) var permissionStatus: PHAuthorizationStatus = .notDetermined
    @Published private(set) var isRestoringSession = false
    @Published private(set) var preparingPhotoIdentifier: String?
    private(set) var scanStartedAt: Date?
    private var photoLibraryChanged = false
    private var hasCheckedAuthorization = false
    private struct CurationAuthorizationSnapshot: Codable {
        let dayKey: String
        let photoIdentifiers: Set<String>
        let curationVersion: Int
        let status: Int
    }
    private let curationAuthorizationStorageKey = "recoco_curation_authorization_v1"
    private var libraryObserver: CurationLibraryObserver?
    private let observesPhotoLibrary: Bool
    private let authorizationStatus: () -> PHAuthorizationStatus
    private let activity: LocalActivityStore
    private var retryRestoredSession = false
    @Published var showToast: Bool = false
    @Published var toastMessage: String = ""
    @Published var showSubscription = false
    private let subscriptions: SubscriptionStore

    let featureAccess: FeatureAccess
    @Published private var queue = HomeDecisionQueue()
    private var todayDecisions: [DecisionUnit] {
        get { queue.decisions }
        set {
            queue.decisions = newValue
            retainCurrentPhotoPreviews()
        }
    }
    var currentDecisionIndex: Int {
        get { queue.selectedIndex }
        set {
            guard !isCommittingSelection else { return }
            queue.select(newValue)
            if todayDecisions.indices.contains(queue.selectedIndex) {
                state = .ready(todayDecisions[queue.selectedIndex])
            }
        }
    }
    var photoIdentifiers: [String] { todayDecisions.compactMap(\.displayIdentifier) }
    @Published private(set) var selectedCleanupKeys = Set<String>()
    @Published private(set) var isCommittingSelection = false
    @Published private(set) var cleanupRecovery: HomeCleanupRecovery?
    @Published private(set) var cleanupResultMessage: String?
    @Published private(set) var stoppedReviewingEarly = false
    private let selectionDefaults: UserDefaults
    private let selectionStorageKey = "recoco_cleanup_selection_v1"
    private let selectionDayStorageKey = "recoco_cleanup_selection_day_v1"
    private var loadedRecommendationDay: String?
    private var reserveRequestID: UUID?
    private var cancelReservePreparation: (() -> Void)?
    private var reservePreparationToken: LocalActivityStore.RecommendationAppendToken?
    private var reserveAttemptVisitID: UUID?
    private var diversityAttemptVisitID: UUID?
    private var activeScanDay: String?
    private var isPreparingRecommendationDay = false
    @Published private(set) var hasRecentRecommendations = false
    @Published private(set) var photoPreviewGeneration = UUID()
    @Published private var photoPreviewStates: [String: HomePhotoPreviewState] = [:]
    private var photoPreviewRequests: [String: UUID] = [:]

    func isPhotoPreviewReady(_ identifier: String) -> Bool {
        photoIdentifiers.contains(identifier) && photoPreviewStates[identifier] == .ready
    }

    var selectedPhotosReadyForCleanup: Bool {
        let selected = selectedCleanupUnits
        return !selected.isEmpty && selected.allSatisfy { unit in
            unit.displayIdentifier.map(isPhotoPreviewReady) ?? false
        }
    }

    /// Only the main carousel image reports here. Selection-strip thumbnails and
    /// analysis previews cannot make an unreadable main photograph actionable.
    func updateHomePhotoPreview(identifier: String, generation: UUID, requestID: UUID,
                                state: HomePhotoPreviewState) {
        guard generation == photoPreviewGeneration, photoIdentifiers.contains(identifier) else { return }
        if state == .loading {
            guard photoPreviewRequests[identifier] != requestID else { return }
            photoPreviewRequests[identifier] = requestID
            photoPreviewStates[identifier] = .loading
        } else {
            guard photoPreviewRequests[identifier] == requestID,
                  photoPreviewStates[identifier] == .loading else { return }
            photoPreviewStates[identifier] = state
        }
        HomeCurationDiagnostics.record("home-preview", ["ready": state == .ready,
            "failed": state == .failed, "readyCount": photoPreviewStates.values.filter { $0 == .ready }.count,
            "queueCount": photoIdentifiers.count,
            "current": todayDecisions.indices.contains(currentDecisionIndex)
                && todayDecisions[currentDecisionIndex].displayIdentifier == identifier])
    }

    private func invalidateHomePhotoPreviews() {
        photoPreviewGeneration = UUID()
        photoPreviewRequests.removeAll()
        photoPreviewStates.removeAll()
    }

    private func retainCurrentPhotoPreviews() {
        let current = Set(photoIdentifiers)
        photoPreviewRequests = photoPreviewRequests.filter { current.contains($0.key) }
        photoPreviewStates = photoPreviewStates.filter { current.contains($0.key) }
    }

    private func replaceDecisionsAfterValidation(_ decisions: [DecisionUnit]) {
        queue.replaceAfterValidation(decisions)
        retainCurrentPhotoPreviews()
        retainHomeEvidence(including: decisions)
    }

    private func retainHomeEvidence(including decisions: [DecisionUnit] = []) {
        let session = activity.dailySessionProgress()
        let pending = Set(session.curatedPhotoIdentifiers).subtracting(session.processedDecisionKeys)
        var identifiers = pending.union(pending.compactMap { session.comparisonReferences[$0] })
        identifiers.formUnion(decisions.flatMap { unit in
            [unit.persistenceKey] + (unit.comparisonLocalIdentifier.map { [$0] } ?? [])
        })
        if let prepared = activity.preparedRecommendations() {
            identifiers.formUnion(prepared.photoIdentifiers)
            identifiers.formUnion(prepared.comparisonReferences.values)
        }
        curationService.retainRecommendationProofs(for: identifiers)
    }

    var selectedCleanupUnits: [DecisionUnit] {
        todayDecisions.filter { selectedCleanupKeys.contains($0.persistenceKey) && $0.type == .cleanupSingle && $0.removalCount == 1 }
    }
    var selectedCleanupCount: Int { Set(selectedCleanupUnits.flatMap(\.removalIdentifiers)).count }
    func isSelectedForCleanup(_ unit: DecisionUnit) -> Bool { selectedCleanupKeys.contains(unit.persistenceKey) }
    func toggleCleanupSelection(_ unit: DecisionUnit) {
        guard !isCommittingSelection, unit.type == .cleanupSingle, unit.removalCount == 1,
              todayDecisions.contains(where: { $0.persistenceKey == unit.persistenceKey }) else { return }
        cancelPreparedSearch()
        cleanupResultMessage = nil
        // Checking a visible photo does not change its identity or the session.
        // A verified later photo may append without undoing this choice.
        if !selectedCleanupKeys.insert(unit.persistenceKey).inserted { selectedCleanupKeys.remove(unit.persistenceKey) }
        persistCleanupSelection()
    }
    func focusSelectedPhoto(_ unit: DecisionUnit) {
        guard !isCommittingSelection, let index = todayDecisions.firstIndex(where: { $0.persistenceKey == unit.persistenceKey }) else { return }
        cleanupResultMessage = nil
        currentDecisionIndex = index
    }
    func browsePhoto(at index: Int) {
        guard !isCommittingSelection, todayDecisions.indices.contains(index), index != currentDecisionIndex else { return }
        cleanupResultMessage = nil
        currentDecisionIndex = index
    }
    private func persistCleanupSelection() {
        selectionDefaults.set(Array(selectedCleanupKeys).sorted(), forKey: UserScopedStorage.key(selectionStorageKey))
        selectionDefaults.set(loadedRecommendationDay ?? activity.recommendationDayKey,
                              forKey: UserScopedStorage.key(selectionDayStorageKey))
    }
    func beginSelectedCleanup() -> [DecisionUnit]? {
        guard !isCommittingSelection, cleanupRecovery == nil, selectedPhotosReadyForCleanup,
              case .ready = state else { return nil }
        cleanupResultMessage = nil
        cancelBackgroundTopUp()
        isCommittingSelection = true
        return selectedCleanupUnits
    }
    func endSelectedCleanup() {
        isCommittingSelection = false
        // Let the just-finished action show its success feedback. The next Home
        // visit can rotate the daily recommendations without replaying completion.
        if case .completed = state { return }
        if cleanupRecovery != nil { return }
        // A system confirmation owns its original selection even across midnight.
        // Refresh only after its success/cancellation has finished.
        if loadedRecommendationDay != activity.recommendationDayKey {
            Task { await self.refreshForNewDay() }
        }
    }

    /// Called on the next Home visit/foreground entry and on an iOS day change.
    /// Never replace photos underneath a system deletion confirmation.
    func refreshForNewDay() async {
        guard !isCommittingSelection, loadedRecommendationDay != activity.recommendationDayKey else { return }
        await checkPermissionAndLoad()
    }

    private func prepareRecommendationDay() async -> Bool {
        guard !isPreparingRecommendationDay else { return false }
        let day = activity.recommendationDayKey
        guard loadedRecommendationDay != day else { return true }
        isPreparingRecommendationDay = true
        defer { isPreparingRecommendationDay = false }
        let hadLoadedDay = loadedRecommendationDay != nil
        pauseCuration()
        let selectionDay = selectionDefaults.string(forKey: UserScopedStorage.key(selectionDayStorageKey))
        let carriedSelection = activity.carrySelectedRecommendationsToCurrentDay(selectedCleanupKeys, matchingDay: selectionDay)
        let session = activity.dailySessionProgress()
        if selectionDay == nil || selectionDay == day || carriedSelection {
            selectedCleanupKeys.formIntersection(Set(session.curatedPhotoIdentifiers).subtracting(session.processedDecisionKeys))
        } else {
            selectedCleanupKeys.removeAll()
        }
        loadedRecommendationDay = day
        persistCleanupSelection()
        invalidateHomePhotoPreviews()
        replaceDecisionsAfterValidation([])
        cleanupResultMessage = nil
        cleanupRecovery = nil
        retryRestoredSession = false
        stoppedReviewingEarly = false
        additionalSearchFoundNoCandidates = false
        lastScanFoundNoCandidates = false
        unavailablePhotoCount = 0
        inaccessiblePhotoCount = 0
        hasFreshPhotos = false
        automaticTopUpToken = nil
        foregroundContinuationStartedForVisit = false
        reserveAttemptVisitID = nil
        sessionDeletedPhotoCount = 0
        sessionSavedRecordCount = 0
        completedDecisionCountAtLoad = 0
        state = .loading
        if hadLoadedDay { await curationService.resetScan() }
        return true
    }
    func reportCleanupFailure(_ error: Error) {
        cleanupResultMessage = nil
        let status = authorizationStatus()
        let photoError = error as NSError
        let denied = photoError.domain == PHPhotosErrorDomain
            && photoError.code == PHPhotosError.Code.accessUserDenied.rawValue
        let restricted = photoError.domain == PHPhotosErrorDomain
            && photoError.code == PHPhotosError.Code.accessRestricted.rawValue
        if status == .restricted || restricted { cleanupRecovery = .accessRestricted }
        else if status == .denied || status == .notDetermined || denied { cleanupRecovery = .accessDenied }
        else if error is PhotoDeletionController.DeletionError { cleanupRecovery = .changedPhotos }
        else { cleanupRecovery = .unconfirmed }
        showToast = false
    }

    func recheckCleanupPhotos() async {
        guard !isCommittingSelection else { return }
        cleanupRecovery = nil
        await checkPermissionAndLoad()
    }

    func completeSelectedCleanup(_ units: [DecisionUnit]) {
        // Called only after one successful Photos transaction; no awaited operations here.
        let keys = Set(units.map(\.persistenceKey))
        let count = Set(units.flatMap(\.removalIdentifiers)).count
        guard count > 0, keys.count == units.count,
              keys.isSubset(of: Set(todayDecisions.map(\.persistenceKey))) else { return }
        if sessionKind == .daily {
            activity.recordDailyDeletions(units.map { (key: $0.persistenceKey, count: $0.removalCount) })
        }
        for unit in units {
            if let reference = unit.comparisonLocalIdentifier { CurationProtectionStore.shared.protect([reference]) }
            if let identifier = unit.displayIdentifier { CurationReviewStore.shared.set(nil, for: identifier) }
        }
        replaceDecisionsAfterValidation(todayDecisions.filter { !keys.contains($0.persistenceKey) })
        selectedCleanupKeys.subtract(keys)
        cleanupRecovery = nil
        persistCleanupSelection()
        sessionDeletedPhotoCount += count
        completedDecisionCountAtLoad += units.count
        refreshWeeklyProgress()
        let remainingCount = Set(photoIdentifiers).count
        cleanupResultMessage = remainingCount > 0
            ? String(localized: "사진 \(count)장을 비웠어요. 선택하지 않은 \(remainingCount)장은 그대로예요.")
            : nil
        if todayDecisions.isEmpty {
            if retryRestoredSession { state = .noCandidate }
            else { completeDailySession() }
        } else { state = .ready(todayDecisions[currentDecisionIndex]) }
    }
    func finishReviewing() {
        guard !isCommittingSelection else { return }
        cleanupResultMessage = nil
        stoppedReviewingEarly = true
        cancelBackgroundTopUp()
        selectedCleanupKeys.removeAll()
        persistCleanupSelection()
        for unit in todayDecisions {
            markTodayCompleted(unit: unit, deletedCount: 0, savedRecord: false, protectPhoto: false)
        }
    }
    var reflectionPhotoIdentifiers: Set<String> {
        Set(todayDecisions.filter { $0.type == .recallMoment }.compactMap(\.displayIdentifier))
    }
    private var completedDecisionCountAtLoad: Int = 0
    private var sessionDeletedPhotoCount: Int = 0
    private var sessionSavedRecordCount: Int = 0
    private var sessionKind: SessionKind = .daily
    private var isLoadingCuration = false
    private var isBackgroundTopUp = false
    private var activeScanID: UUID?
    private var activeScanAuthorizationStatus: PHAuthorizationStatus?
    private var cancelScan: (() -> Void)?
    private var resumeMorePhotos = false
    private var resumeInterruptedSearch = false
    private var validatedSessionToken: LocalActivityStore.RecommendationAppendToken?
    private var automaticTopUpToken: LocalActivityStore.RecommendationAppendToken?
    private var hasPendingForegroundSearch = false
    private var isHomeForeground = false
    private var foregroundVisitID = UUID()
    private var foregroundContinuationStartedForVisit = false
    private var foregroundContinuationID: UUID?
    private var foregroundContinuationTask: Task<Void, Never>?
    private var foregroundContinuationDeadline: Task<Void, Never>?
    private var lastScanWorkRevision: UInt64?
    private var validatedProtection = Set<String>()
    private var validatedReviewDates: [String: Date] = [:]
    // Keep the unfinished analysis window when the user asks to see more.
    private let curationService: PhotoCurationServing

    init(featureAccess: FeatureAccess? = nil, subscriptions: SubscriptionStore? = nil,
         curationService: PhotoCurationServing = PhotoCurationService(), activity: LocalActivityStore? = nil,
         authorizationStatus: @escaping () -> PHAuthorizationStatus = { PHPhotoLibrary.authorizationStatus(for: .readWrite) },
         observesPhotoLibrary: Bool = true, selectionDefaults: UserDefaults = .standard) {
        self.featureAccess = featureAccess ?? .current()
        self.subscriptions = subscriptions ?? .shared
        self.curationService = curationService
        self.activity = activity ?? .shared
        self.authorizationStatus = authorizationStatus
        self.observesPhotoLibrary = observesPhotoLibrary
        self.selectionDefaults = selectionDefaults
        self.selectedCleanupKeys = Set(selectionDefaults.stringArray(forKey: UserScopedStorage.key(selectionStorageKey)) ?? [])
    }

    var shouldShowSimilarPhotoCleanup: Bool {
        featureAccess.isSimilarPhotoCleanupEnabled
    }

    var canUseSimilarPhotoCleanup: Bool {
        featureAccess.canUseSimilarPhotoCleanup
    }

    var cloudPhotoCount: Int { hasScanIssue && inaccessiblePhotoCount == 0 ? curationService.cloudPhotoCount : 0 }
    var hasScanIssue: Bool { unavailablePhotoCount > 0 || inaccessiblePhotoCount > 0 }
    // A failed new read must not block other unexamined photos. Restoring an
    // existing recommendation is different: its candidate/reference still needs validation.
    var canSearchOtherPhotos: Bool {
        hasMorePhotos && hasFreshPhotos && accessiblePhotoCount != 0
            && inaccessiblePhotoCount == 0 && !retryRestoredSession
    }
    var hasBlockingScanIssue: Bool { hasScanIssue && !canSearchOtherPhotos }
    var canPauseCuration: Bool { isLoadingCuration && !isBackgroundTopUp }
    var scanIssueTitle: String { inaccessiblePhotoCount > 0 ? String(localized: "일부 사진에 접근할 수 없어요.") : cloudPhotoCount > 0 ? String(localized: "iCloud에서 사진을 불러와야 해요.") : String(localized: "사진을 확인하지 못했어요.") }
    var scanIssueMessage: String {
        if inaccessiblePhotoCount > 0 {
            return String(localized: "사진 \(inaccessiblePhotoCount)장에 접근할 수 없어요. 접근 범위를 바꾸거나 다른 사진에서 추천을 찾을 수 있어요. 이전 선택과 기록은 남아 있어요.")
        }
        if cloudPhotoCount > 0 {
            return String(localized: "사진 \(cloudPhotoCount)장의 원본에 접근이 필요해요. 허용한 사진은 다시 열 때도 iCloud를 사용할 수 있어요. 데이터가 사용될 수 있어요.")
        }
        return String(localized: "사진 \(unavailablePhotoCount)장을 읽지 못했어요. 아래 버튼을 누르면 다시 확인해요. 사진을 따로 고를 필요는 없어요.")
    }
    var scanRetryTitle: String { cloudPhotoCount > 0 ? String(localized: "iCloud에서 사진 불러오기") : String(localized: "사진 다시 확인하기") }

    /// Returning after a finished batch is still Home, but it is not a failed
    /// search. Pending photos, read/access issues and an explicit empty search
    /// keep their own recovery/result copy instead of inheriting this message.
    private var isReturningAfterCompletedBatch: Bool {
        guard case .noCandidate = state else { return false }
        return !hasScanIssue && !additionalSearchFoundNoCandidates
            && activity.dailySessionProgress().curatedPhotoIdentifiers.isEmpty
            && activity.hasCompletedCleanupToday()
    }

    private var completedHomeMessage: String {
        switch emptyPrimaryAction {
        case .findMore:
            return String(localized: "더 살펴보고 싶다면 이어서 찾아볼 수 있어요.")
        case .selectPhotos:
            return String(localized: "더 살펴보고 싶다면 다른 사진을 선택할 수 있어요.")
        case .subscription:
            return String(localized: "더 살펴보려면 구독 이용 조건을 먼저 확인해주세요.")
        case .refresh:
            return String(localized: "새 사진을 추가하면 다시 살펴볼 수 있어요.")
        default:
            return String(localized: "비움 내역은 리포트에 남아 있어요.")
        }
    }

    var emptyPrimaryAction: HomeEmptyAction {
        if inaccessiblePhotoCount > 0 { return isLimitedAccess ? .selectPhotos : .findOtherPhotos }
        if hasBlockingScanIssue { return .retry }
        if hasMorePhotos, accessiblePhotoCount != 0 { return subscriptions.canStartCuration ? .findMore : .subscription }
        if isLimitedAccess { return .selectPhotos }
        if accessiblePhotoCount == 0 { return .refresh }
        return .finish
    }

    /// Finishing a batch is always available. Continuing is an explicit, optional
    /// choice; a completed batch must not inherit an empty Home's recovery CTA.
    var completionSecondaryAction: HomeEmptyAction? {
        let action = emptyPrimaryAction
        // Explain the existing gate before asking for broader photo access.
        // Restoring access to an unfinished photo remains a recovery action.
        if action == .selectPhotos, !hasBlockingScanIssue, !subscriptions.canStartCuration {
            return .subscription
        }
        switch action {
        case .finish, .refresh: return nil
        default: return action
        }
    }

    var completionMessage: String {
        if hasBlockingScanIssue { return scanIssueMessage }
        let nextStep: String
        switch completionSecondaryAction {
        case .subscription:
            nextStep = String(localized: "조금 더 살펴보려면 구독이 필요해요. 이용 조건을 먼저 확인해주세요.")
        case .findMore:
            nextStep = String(localized: "지금 마쳐도 비움 내역은 이 기기에 남아요.")
        case .selectPhotos:
            nextStep = String(localized: "다른 사진을 더 선택하면 추천을 찾아볼게요.")
        default:
            nextStep = accessiblePhotoCount == 0
                ? String(localized: "새 사진이 생기면 다시 살펴볼 수 있어요.")
                : String(localized: "내일 앱을 열면 새 정리 후보를 찾아볼게요.")
        }
        return additionalSearchFoundNoCandidates
            ? String(localized: "추가로 추천할 사진을 찾지 못했어요. \(nextStep)")
            : nextStep
    }

    var emptyNextStepMessage: String {
        if hasBlockingScanIssue { return scanIssueMessage }
        if isReturningAfterCompletedBatch { return completedHomeMessage }
        if accessiblePhotoCount == 0 { return scanStatusMessage }
        if hasMorePhotos {
            if emptyPrimaryAction == .subscription {
                return String(localized: "추가 추천은 구독으로 이어갈 수 있어요. 이용 조건을 먼저 확인해보세요.")
            }
            return hasScanIssue && canSearchOtherPhotos
                ? String(localized: "읽지 못한 사진은 잠시 두고, 다른 사진에서 찾아볼게요.")
                : String(localized: "아직 살펴보지 않은 사진에서 찾아볼게요.")
        }
        return isLimitedAccess
            ? String(localized: "다른 사진을 선택하면 그 안에서 다시 찾아볼게요.")
            : String(localized: "새 사진을 추가한 뒤 다시 찾아보세요.")
    }
    func scanIsTakingLong(at date: Date) -> Bool {
        isLoadingCuration && scanStartedAt.map { date.timeIntervalSince($0) >= 8 } == true
    }

    var scanStatusTitle: String {
        if hasBlockingScanIssue { return scanIssueTitle }
        if isReturningAfterCompletedBatch { return String(localized: "오늘 고른 사진을 모두 살펴봤어요.") }
        if accessiblePhotoCount == 0 { return isLimitedAccess ? String(localized: "선택한 사진이 없어요.") : String(localized: "살펴볼 사진이 없어요.") }
        if hasMorePhotos { return String(localized: "아직 정리할 사진을 찾지 못했어요.") }
        if isLimitedAccess { return String(localized: "선택한 사진에서 정리 후보를 찾지 못했어요.") }
        if additionalSearchFoundNoCandidates && !isLimitedAccess { return String(localized: "추가로 추천할 사진을 찾지 못했어요.") }
        return String(localized: "지금은 추천할 사진이 없어요.")
    }

    var scanStatusMessage: String {
        if hasBlockingScanIssue { return scanIssueMessage }
        if isReturningAfterCompletedBatch { return completedHomeMessage }
        if accessiblePhotoCount == 0 {
            return isLimitedAccess ? String(localized: "선택한 사진 안에서만 추천을 찾아요.") : String(localized: "사진을 추가한 뒤 다시 확인해주세요.")
        }
        if hasMorePhotos { return emptyNextStepMessage }
        if isLimitedAccess {
            if let count = accessiblePhotoCount {
                return String(localized: "허용한 사진 \(count)장을 확인했어요. 사진을 더 선택하면 그 안에서 다시 찾아볼게요.")
            }
            return String(localized: "다른 사진을 선택하면 그 안에서 다시 찾아볼게요.")
        }
        if hasRecentRecommendations {
            return String(localized: "최근 추천한 사진은 30일 동안 다시 권하지 않아요. 새 후보가 있는지 내일 다시 찾아볼게요.")
        }
        return String(localized: "새 사진을 추가한 뒤 다시 찾아보세요.")
    }

    var scanProgressText: String {
        // A worker window (for example 32/64) is neither the whole library nor
        // the three-photo recommendation set, so it is not user progress.
        String(localized: "허용한 사진을 확인하고 있어요.")
    }

    private func beginScan(morePhotos: Bool = false, preservingVisibleQueue: Bool = false) -> UUID {
        if !preservingVisibleQueue { invalidateHomePhotoPreviews() }
        let id = UUID()
        activeScanID = id
        activeScanAuthorizationStatus = authorizationStatus()
        activeScanDay = activity.recommendationDayKey
        isLoadingCuration = true
        isBackgroundTopUp = preservingVisibleQueue
        resumeInterruptedSearch = false
        resumeMorePhotos = morePhotos
        hasPendingForegroundSearch = false
        scanProgress = .init()
        scanStartedAt = Date()
        isRestoringSession = false
        preparingPhotoIdentifier = nil
        isLimitedAccess = authorizationStatus() == .limited
        if !preservingVisibleQueue { state = .loading }
        return id
    }

    private func finishScan(_ id: UUID) {
        HomeCurationDiagnostics.record("scan-returned", ["ownsScan": activeScanID == id,
            "cancelled": Task.isCancelled, "queueCount": todayDecisions.count])
        guard activeScanID == id else { return }
        let dayChanged = activeScanDay != activity.recommendationDayKey
        let permissionChanged = activeScanAuthorizationStatus != authorizationStatus()
        if !Task.isCancelled, isBackgroundTopUp, hasPendingForegroundSearch {
            // Duplicate view callbacks are not a new foreground visit. Only
            // navigation/background interruption opens another bounded budget.
            automaticTopUpToken = activity.recommendationAppendToken()
        }
        activeScanID = nil
        activeScanAuthorizationStatus = nil
        activeScanDay = nil
        cancelScan = nil
        scanStartedAt = nil
        isLoadingCuration = false
        isBackgroundTopUp = false
        preparingPhotoIdentifier = nil
        if Task.isCancelled, case .loading = state {
            resumeInterruptedSearch = true
            state = .scanPaused
        }
        if !Task.isCancelled {
            recordContinuationState("scan-finished")
            if permissionChanged {
                Task { await self.checkPermissionAndLoad() }
            } else if dayChanged {
                Task { await self.refreshForNewDay() }
            } else {
                scheduleForegroundContinuationIfNeeded()
            }
        }
    }

    private func acceptsScan(_ id: UUID) -> Bool {
        guard activeScanID == id, activeScanDay == activity.recommendationDayKey,
              !Task.isCancelled else { return false }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-first-scan") { return true }
        #endif
        let status = authorizationStatus()
        guard status == .authorized || status == .limited else {
            permissionStatus = status
            state = .noPermission
            return false
        }
        // Even two allowed statuses describe different scopes. Do not publish
        // a full-library result after Settings has narrowed access to a subset.
        guard activeScanAuthorizationStatus == status else { return false }
        return true
    }

    private func progressHandler(for id: UUID) -> @Sendable (PhotoCurationService.ScanProgress) -> Void {
        let gate = CurationProgressPresentationGate()
        return { [weak self] progress in
            guard gate.accepts(progress) else { return }
            Task { @MainActor in
                guard let self, self.activeScanID == id else { return }
                self.scanProgress = progress
                self.accessiblePhotoCount = progress.accessiblePhotoCount
            }
        }
    }

    private func runScan<Value>(_ operation: @escaping () async -> Value) async -> Value {
        let task = Task { await operation() }
        cancelScan = { task.cancel() }
        return await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    func pauseCuration(resumingAutomatically: Bool = false) {
        HomeCurationDiagnostics.record("scan-paused", ["automatic": resumingAutomatically,
            "loading": isLoadingCuration, "queueCount": todayDecisions.count])
        if resumingAutomatically { isHomeForeground = false }
        cancelForegroundContinuation()
        cancelPreparedSearch()
        // A completed foreground budget can still leave resumable work. A new
        // Home visit may continue it without revalidating an unchanged queue.
        if resumingAutomatically, hasPendingForegroundSearch { automaticTopUpToken = nil }
        guard isLoadingCuration else { return }
        resumeInterruptedSearch = resumingAutomatically
        if resumingAutomatically { automaticTopUpToken = nil }
        else { hasPendingForegroundSearch = false }
        activeScanDay = nil
        let keepVisibleRecommendations = isBackgroundTopUp
        cancelScan?()
        activeScanID = nil
        activeScanAuthorizationStatus = nil
        cancelScan = nil
        scanStartedAt = nil
        isLoadingCuration = false
        isBackgroundTopUp = false
        preparingPhotoIdentifier = nil
        if !keepVisibleRecommendations { state = .scanPaused }
    }

    /// A record/delete/keep action owns the visible queue from this point onward.
    /// Background additions must never finish underneath that interaction.
    func cancelBackgroundTopUp() {
        cancelForegroundContinuation()
        cancelPreparedSearch()
        guard isBackgroundTopUp else { return }
        pauseCuration()
    }

    func resumeCuration() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-first-scan") {
            await loadFirstScanFixture()
            return
        }
        #endif
        state = .loading
        if resumeMorePhotos { await loadMoreDecisions() }
        else { await checkPermissionAndLoad() }
    }

    func refreshPhotoSelection() async {
        // A picker result is new input, not a duplicate scan request. Cancel the
        // older scope so its late result cannot hide newly permitted photos.
        pauseCuration()
        foregroundContinuationStartedForVisit = false
        reserveAttemptVisitID = nil
        await curationService.resetScan()
        activity.resetScannedPhotos()
        additionalSearchFoundNoCandidates = false
        // A completed day must not short-circuit checking newly allowed photos.
        // Pending recommendations still go through restoration and validation.
        if todayDecisions.isEmpty, !retryRestoredSession {
            photoLibraryChanged = false
            await loadMoreDecisions()
        } else {
            // The explicit picker completion resumes validation even if its
            // library-change notification has not arrived yet.
            state = .loading
            await checkPermissionAndLoad()
        }
    }

    /// The daily carousel is for evidence-backed cleanup decisions. A recent or
    /// anniversary photo is not a deletion reason and must never fill an empty slot.
    private func cleanupRecommendations(_ candidates: [DecisionUnit], excluding reviewed: Set<String>,
                                        limit: Int) -> [DecisionUnit] {
        var seen = reviewed
        return Array(candidates.filter { unit in
            guard !unit.reasonCodes.isEmpty, !unit.removalIdentifiers.isEmpty,
                  let id = unit.displayIdentifier, !id.isEmpty,
                  !unit.removalIdentifiers.contains(where: seen.contains),
                  seen.insert(id).inserted else { return false }
            seen.formUnion(unit.removalIdentifiers)
            return true
        }.prefix(max(0, limit)))
    }

    #if DEBUG
    private func loadFirstScanFixture() async {
        guard !isLoadingCuration else { return }
        let request = beginScan()
        defer { finishScan(request) }
        let arguments = ProcessInfo.processInfo.arguments
        isLimitedAccess = arguments.contains("-ui-testing-first-scan-limited")
        if arguments.contains("-ui-testing-first-scan-more") {
            accessiblePhotoCount = 24
            hasMorePhotos = true
            hasFreshPhotos = true
            lastScanFoundNoCandidates = true
            todayDecisions = []
            state = .noCandidate
            return
        }
        accessiblePhotoCount = isLimitedAccess ? 0 : 24
        if isLimitedAccess {
            hasMorePhotos = false
            state = .noCandidate
            return
        }
        scanProgress = .init(phase: .reading, checkedCount: 8, windowCount: 24, accessiblePhotoCount: 24)
        if arguments.contains("-ui-testing-first-scan-slow") { scanStartedAt = Date().addingTimeInterval(-9) }
        await runScan {
            try? await Task.sleep(nanoseconds: arguments.contains("-ui-testing-first-scan-slow") ? 30_000_000_000 : 1_000_000_000)
        }
        guard acceptsScan(request) else { return }
        let unit = DecisionUnit(id: UUID(), type: .cleanupSingle, status: .pending,
            candidateLocalIdentifiers: ["first-scan-fixture"], recommendedLocalIdentifier: "first-scan-fixture",
            reasonCodes: [.exactDuplicate], capturedDateDescription: "검증용 첫 추천", createdAt: Date())
        todayDecisions = [unit]
        currentDecisionIndex = 0
        state = .ready(unit)
    }
    #endif

    func findOtherPhotos() async {
        guard inaccessiblePhotoCount > 0, !isLoadingCuration else { return }
        let status = authorizationStatus()
        guard status == .authorized || status == .limited else { await checkPermissionAndLoad(); return }
        activity.clearPendingRecommendations()
        inaccessiblePhotoCount = 0; retryRestoredSession = false
        await loadTodayDecision(skipFinishedSessionScan: false)
    }

    func retryCuration() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-scan-unavailable") {
            unavailablePhotoCount = 0
            hasFreshPhotos = false
            hasMorePhotos = false
            lastScanFoundNoCandidates = true
            state = .noCandidate
            return
        }
        #endif
        guard !isLoadingCuration else { return }
        if cloudPhotoCount > 0 {
            curationService.allowCloudPhotoAccess()
            await curationService.resetScan()
        }
        if retryRestoredSession { await checkPermissionAndLoad() }
        else { await loadMoreDecisions() }
    }

    private func applyScanAvailability(_ batch: PhotoCurationService.ScanBatch) {
        unavailablePhotoCount = batch.retryableFailureCount
        inaccessiblePhotoCount = 0
        hasFreshPhotos = batch.hasFreshPhotos
        hasMorePhotos = batch.hasMore
        retryRestoredSession = false
        accessiblePhotoCount = batch.accessiblePhotoCount
        lastScanWorkRevision = batch.workRevision
        hasPendingForegroundSearch = batch.hasMore && batch.hasFreshPhotos
            && batch.decisions.count < max(0, 3 - activity.dailySessionProgress().processedDecisionKeys.count)
    }

    var currentDecisionNumber: Int {
        decisionProgress.currentNumber
    }

    var totalDecisionCount: Int {
        decisionProgress.totalCount
    }

    private var decisionProgress: HomeDecisionProgress {
        HomeDecisionProgress(
            completedBeforeLoad: completedDecisionCountAtLoad,
            pendingCount: todayDecisions.count,
            currentPendingIndex: currentDecisionIndex
        )
    }

    // MARK: - 초기화

    func onAppear(reuseValidatedQueue: Bool = false) async {
        guard !isCommittingSelection else { return }
        if !isHomeForeground {
            isHomeForeground = true
            foregroundVisitID = UUID()
            foregroundContinuationStartedForVisit = false
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-completion") {
            let args = ProcessInfo.processInfo.arguments
            hasMorePhotos = !args.contains("-ui-testing-completion-exhausted")
            unavailablePhotoCount = args.contains("-ui-testing-completion-unavailable") ? 2 : 0
            hasFreshPhotos = false
            isLimitedAccess = args.contains("-ui-testing-completion-limited")
            accessiblePhotoCount = 2
            additionalSearchFoundNoCandidates = args.contains("-ui-testing-completion-empty-search")
            if args.contains("-ui-testing-completion-subscription") {
                subscriptions.finishFirstExperience()
            }
            state = .completed(summary: .init(deletedCount: 0, savedRecordCount: 0, reviewedCount: 3))
            return
        }
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-first-scan") {
            if case .scanPaused = state, resumeInterruptedSearch { state = .loading }
            if case .loading = state { await loadFirstScanFixture() }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-scan-unavailable") {
            if case .loading = state {
                unavailablePhotoCount = 2
                if ProcessInfo.processInfo.arguments.contains("-ui-testing-scan-inaccessible") {
                    unavailablePhotoCount = 0; inaccessiblePhotoCount = 2
                    isLimitedAccess = true; retryRestoredSession = true
                }
                hasMorePhotos = true
                hasFreshPhotos = ProcessInfo.processInfo.arguments.contains("-ui-testing-scan-has-fresh")
                lastScanFoundNoCandidates = true
                state = .noCandidate
            }
            return
        }
        // Design regression fixtures never request or mutate the device photo library.
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-design-cluster")
            || ProcessInfo.processInfo.arguments.contains("-ui-testing-design-recall") {
            if todayDecisions.isEmpty {
                let recall = ProcessInfo.processInfo.arguments.contains("-ui-testing-design-recall")
                todayDecisions = [DecisionUnit(id: UUID(), type: recall ? .recallMoment : .cleanupCluster,
                    status: .pending, candidateLocalIdentifiers: recall ? ["design-1"] : ["design-1", "design-2", "design-3"],
                    recommendedLocalIdentifier: "design-1", reasonCodes: [recall ? .dailyReflection : .visuallySimilar],
                    capturedDateDescription: "2년 전 오늘", createdAt: Date())]
                currentDecisionIndex = 0
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-home-batch")
            || ProcessInfo.processInfo.arguments.contains("-ui-testing-home-carousel")
            || ProcessInfo.processInfo.arguments.contains("-ui-testing-anniversary") {
            isLimitedAccess = ProcessInfo.processInfo.arguments.contains("-ui-testing-limited-access")
            // These fixtures already represent today's loaded recommendation set.
            // Keep completion/cancellation from mistaking them for a new-day load.
            if loadedRecommendationDay == nil { loadedRecommendationDay = activity.recommendationDayKey }
            if todayDecisions.isEmpty {
                let arguments = ProcessInfo.processInfo.arguments
                let anniversaryFixture = arguments.contains("-ui-testing-anniversary")
                let metadataFixture = arguments.contains("-photo-context-testing=complete")
                    || arguments.contains("-photo-context-testing=offline")
                    || arguments.contains("-ui-testing-recent-selection")
                let fixtureNow = Date()
                todayDecisions = (1...3).map { index in
                    let contextTest = arguments.contains("-ui-testing-curation-context")
                    let shortTitle = arguments.contains("-ui-testing-home-short-reason")
                    let exactDuplicate = arguments.contains("-ui-testing-exact-duplicate")
                    let anniversary = anniversaryFixture && index == 1
                    let recentSelection = arguments.contains("-ui-testing-recent-selection")
                    let reflection = recentSelection || anniversaryFixture || (index > 1 && arguments.contains("-ui-testing-mixed-reflection"))
                    let capturedAt: Date? = anniversary
                        ? Calendar.current.date(byAdding: .year, value: -1, to: fixtureNow)
                        : ((metadataFixture || anniversaryFixture)
                            ? Calendar.current.date(byAdding: .day, value: -index, to: fixtureNow) : nil)
                    let reason: CurationReasonCode = anniversary ? .anniversaryReflection
                        : (reflection ? .dailyReflection : (exactDuplicate ? .exactDuplicate : (shortTitle ? .duplicate : .visuallySimilar)))
                    return DecisionUnit(id: UUID(), type: reflection ? .recallMoment : .cleanupSingle, status: .pending,
                                 candidateLocalIdentifiers: ["carousel-test-\(index)"],
                                 recommendedLocalIdentifier: "carousel-test-\(index)",
                                 reasonCodes: [reason], capturedDateDescription: capturedAt.map {
                                     DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .none)
                                 } ?? "테스트 사진 \(index)", createdAt: fixtureNow,
                                 comparisonLocalIdentifier: !reflection && arguments.contains("-ui-testing-curation-comparison") ? "comparison-test-reference" : nil,
                                 evidence: recentSelection
                                    ? PhotoCurationService.reflectionEvidence(reason: .dailyReflection, capturedAt: capturedAt, now: fixtureNow)
                                    : (contextTest && !reflection ? CurationEvidence(reason: index == 1 ? .expiredScreen : .shoppingScreen,
                                     photoDescription: index == 1 ? "기한이 표시된 스크린샷" : "구매·배송을 참고한 스크린샷",
                                     detail: index == 1 ? "화면의 사용 기한이 지났어요. 날짜가 맞는지 확인해주세요." : "구매·배송 문구가 있고 캡처 후 40일이 지났어요.") : nil),
                                 capturedAt: capturedAt)
                }
                currentDecisionIndex = 0
                if arguments.contains("-ui-testing-preview-preselected"), let first = todayDecisions.first {
                    selectedCleanupKeys.insert(first.persistenceKey)
                    persistCleanupSelection()
                }
            }
            return
        }
        #endif
        await checkPermissionAndLoad(reuseValidatedQueue: reuseValidatedQueue)
    }

    // MARK: - 권한 확인 및 로드

    /// Settings may terminate the app when access changes. Remember only the
    /// scope that successfully validated this same day's queue, not a guess
    /// from missing assets or a generic Photo Library notification.
    private func persistedAuthorizationForCurrentSession() -> PHAuthorizationStatus? {
        let session = activity.dailySessionProgress()
        let pending = Set(session.curatedPhotoIdentifiers).subtracting(session.processedDecisionKeys)
        guard !pending.isEmpty,
              let data = selectionDefaults.data(forKey: UserScopedStorage.key(curationAuthorizationStorageKey)),
              let snapshot = try? JSONDecoder().decode(CurationAuthorizationSnapshot.self, from: data),
              snapshot.dayKey == activity.recommendationDayKey,
              snapshot.curationVersion == session.curationVersion,
              pending.isSubset(of: snapshot.photoIdentifiers) else { return nil }
        return PHAuthorizationStatus(rawValue: snapshot.status)
    }

    private func persistValidatedAuthorization(for request: UUID) {
        guard activeScanID == request, activeScanDay == activity.recommendationDayKey,
              activeScanAuthorizationStatus == authorizationStatus(), !Task.isCancelled else { return }
        let session = activity.dailySessionProgress()
        let key = UserScopedStorage.key(curationAuthorizationStorageKey)
        guard !session.curatedPhotoIdentifiers.isEmpty else {
            selectionDefaults.removeObject(forKey: key)
            return
        }
        // A different photo in the library may fail to read while every photo
        // in this queue has been validated. Persist the displayed queue's
        // provenance, never infer it from the overall scan's failure count.
        let pending = Set(session.curatedPhotoIdentifiers).subtracting(session.processedDecisionKeys)
        let validated = Set(todayDecisions.compactMap(\.displayIdentifier))
        guard case .ready = state, !pending.isEmpty, pending.isSubset(of: validated),
              let version = session.curationVersion,
              let status = activeScanAuthorizationStatus,
              status == .authorized || status == .limited else { return }
        let snapshot = CurationAuthorizationSnapshot(dayKey: activity.recommendationDayKey,
            photoIdentifiers: pending, curationVersion: version, status: status.rawValue)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        selectionDefaults.set(data, forKey: key)
        validatedSessionToken = activity.recommendationAppendToken()
        validatedProtection = CurationProtectionStore.shared.identifiers()
        validatedReviewDates = CurationReviewStore.shared.dates()
    }

    private func checkPermissionAndLoad(reuseValidatedQueue: Bool = false) async {
        guard !isCommittingSelection else { return }
        guard await prepareRecommendationDay() else { return }
        refreshWeeklyProgress()
        let status = authorizationStatus()
        let persistedStatus = persistedAuthorizationForCurrentSession()
        let previousStatus = hasCheckedAuthorization ? permissionStatus : persistedStatus
        let scopeChanged = previousStatus.map { $0 != status } == true || photoLibraryChanged
        let session = activity.dailySessionProgress()
        let narrowedPending = (previousStatus == .authorized || persistedStatus == .authorized) && status == .limited
            ? Set(session.curatedPhotoIdentifiers).subtracting(session.processedDecisionKeys) : nil
        hasCheckedAuthorization = true
        permissionStatus = status
        isLimitedAccess = status == .limited
        guard status == .authorized || status == .limited else {
            // Revoke in-flight results before awaiting the worker's cancellation.
            pauseCuration()
            HomePhotoPreviewCache.invalidateAll()
            invalidateHomePhotoPreviews()
            state = .noPermission
            unavailablePhotoCount = 0; inaccessiblePhotoCount = 0
            retryRestoredSession = false
            await curationService.resetScan()
            return
        }
        if cleanupRecovery == .accessDenied || cleanupRecovery == .accessRestricted {
            cleanupRecovery = nil
        }
        if observesPhotoLibrary, libraryObserver == nil {
            libraryObserver = CurationLibraryObserver { [weak self] identifiers in
                Task { @MainActor in self?.photoLibraryDidChange(affectedIdentifiers: identifiers) }
            }
        }
        if scopeChanged {
            pauseCuration()
            foregroundContinuationStartedForVisit = false
            reserveAttemptVisitID = nil
            HomePhotoPreviewCache.invalidateAll()
            automaticTopUpToken = nil
            invalidateHomePhotoPreviews()
            if narrowedPending?.isEmpty == false { state = .loading }
            photoLibraryChanged = false
            await curationService.resetScan()
            activity.resetScannedPhotos()
            additionalSearchFoundNoCandidates = false
        } else if case .scanPaused = state {
            // An explicit pause is a choice. A tab change or interruption is not.
            guard resumeInterruptedSearch else { return }
        } else if reuseValidatedQueue, case .ready = state, !retryRestoredSession,
                  cleanupRecovery == nil,
                  let token = validatedSessionToken, activity.matchesRecommendationAppendToken(token),
                  validatedProtection == CurationProtectionStore.shared.identifiers(),
                  validatedReviewDates == CurationReviewStore.shared.dates() {
            // This in-memory queue already passed validation. Photo library and
            // permission changes take the branch above; deletion rechecks again.
            // A short set may have exhausted the first search budget. Continue
            // once for this unchanged queue without hiding its verified photos.
            let remaining = max(0, 3 - session.processedDecisionKeys.count)
            if todayDecisions.count < remaining, hasMorePhotos, hasFreshPhotos,
               automaticTopUpToken.map(activity.matchesRecommendationAppendToken) != true {
                automaticTopUpToken = token
                await loadTodayDecision(reuseValidatedQueue: true)
            }
            return
        }
        let unfinished: Bool
        if case .searchPending = state { unfinished = true }
        else { unfinished = resumeInterruptedSearch }
        if unfinished, resumeMorePhotos, todayDecisions.isEmpty {
            await loadMoreDecisions()
        } else {
            await loadTodayDecision(skipFinishedSessionScan: !unfinished, recoveringRevokedScope: narrowedPending)
        }
    }

    // Mark stale now; validate only when returning to Home so an open draft or
    // confirmation is never replaced by a library callback.
    func photoLibraryDidChange(affectedIdentifiers: Set<String>? = nil) {
        photoLibraryChanged = true
        // An unrelated photo update must not discard an in-flight carousel
        // image. Known visible changes still revoke readiness immediately.
        if affectedIdentifiers.map({ !$0.isDisjoint(with: photoIdentifiers) }) ?? true {
            HomePhotoPreviewCache.invalidateAll()
            invalidateHomePhotoPreviews()
        }
        cancelForegroundContinuation()
        cancelPreparedSearch()
        recordContinuationState("library-invalidated")
    }

    private func cancelForegroundContinuation() {
        foregroundContinuationID = nil
        foregroundContinuationTask?.cancel()
        foregroundContinuationTask = nil
        foregroundContinuationDeadline?.cancel()
        foregroundContinuationDeadline = nil
    }

    private var canContinueVisibleRecommendations: Bool {
        guard isHomeForeground, !photoLibraryChanged, !isCommittingSelection,
              !retryRestoredSession, cleanupRecovery == nil, subscriptions.canStartCuration,
              case .ready = state, !todayDecisions.isEmpty,
              hasMorePhotos, hasFreshPhotos, hasPendingForegroundSearch,
              let token = validatedSessionToken, activity.matchesRecommendationAppendToken(token),
              validatedProtection == CurationProtectionStore.shared.identifiers(),
              validatedReviewDates == CurationReviewStore.shared.dates() else { return false }
        let status = authorizationStatus()
        return (status == .authorized || status == .limited)
            && status == permissionStatus
            && loadedRecommendationDay == activity.recommendationDayKey
            && todayDecisions.count < max(0, 3 - activity.dailySessionProgress().processedDecisionKeys.count)
    }

    private func recordContinuationState(_ event: String) {
        let ready: Bool
        if case .ready = state { ready = true } else { ready = false }
        HomeCurationDiagnostics.record(event, ["ready": ready, "queueCount": todayDecisions.count,
            "foreground": isHomeForeground, "libraryChanged": photoLibraryChanged,
            "restorationRetry": retryRestoredSession, "hasMore": hasMorePhotos, "hasFresh": hasFreshPhotos,
            "pending": hasPendingForegroundSearch, "loading": isLoadingCuration,
            "canContinue": canContinueVisibleRecommendations,
            "tokenMatches": validatedSessionToken.map(activity.matchesRecommendationAppendToken) ?? false,
            "protectionMatches": validatedProtection == CurationProtectionStore.shared.identifiers(),
            "reviewDatesMatch": validatedReviewDates == CurationReviewStore.shared.dates(),
            "dayMatches": loadedRecommendationDay == activity.recommendationDayKey,
            "continuationStarted": foregroundContinuationStartedForVisit,
            "continuationRunning": foregroundContinuationTask != nil])
    }

    /// The first useful photo stays actionable while one bounded continuation
    /// fills the current set. Repeated view callbacks cannot restart this budget.
    private func scheduleForegroundContinuationIfNeeded() {
        guard !Task.isCancelled, !isLoadingCuration, canContinueVisibleRecommendations,
              foregroundContinuationTask == nil, !foregroundContinuationStartedForVisit else { return }
        foregroundContinuationStartedForVisit = true
        automaticTopUpToken = activity.recommendationAppendToken()
        let request = UUID()
        let visit = foregroundVisitID
        foregroundContinuationID = request
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.foregroundContinuationID == request {
                    self.foregroundContinuationID = nil
                    self.foregroundContinuationTask = nil
                    self.foregroundContinuationDeadline?.cancel()
                    self.foregroundContinuationDeadline = nil
                    if self.isHomeForeground, self.foregroundVisitID == visit {
                        // Even a timed-out continuation has used this visit's
                        // budget; duplicate callbacks must not reopen it.
                        self.automaticTopUpToken = self.activity.recommendationAppendToken()
                        if !Task.isCancelled, !self.hasPendingForegroundSearch {
                            Task { await self.prepareHomeRecommendations() }
                        }
                    }
                }
            }
            for _ in 0..<3 {
                guard !Task.isCancelled, self.foregroundContinuationID == request,
                      self.foregroundVisitID == visit, self.canContinueVisibleRecommendations else { return }
                let previousCount = self.todayDecisions.count
                let previousRevision = self.lastScanWorkRevision
                // Reuse the verified queue and its preview generation. Only
                // append new evidence; do not spend another restoration budget.
                await self.loadTodayDecision(reuseValidatedQueue: true, searchSlices: 1,
                                             usePreparedRecommendations: false)
                guard !Task.isCancelled, self.foregroundContinuationID == request,
                      self.foregroundVisitID == visit, self.isHomeForeground else { return }
                let addedPhoto = self.todayDecisions.count > previousCount
                let advancedEvidence = self.lastScanWorkRevision.map { current in
                    previousRevision.map { current > $0 } ?? (current > 0)
                } ?? false
                guard addedPhoto || advancedEvidence else { return }
                await Task.yield()
            }
        }
        foregroundContinuationTask = task
        // This timer also cancels an in-flight PhotoKit/Vision slice. The
        // worker's cancellation boundary keeps already published photos intact.
        foregroundContinuationDeadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 12_000_000_000) }
            catch { return }
            guard let self, self.foregroundContinuationID == request else { return }
            task.cancel()
        }
    }

    private func cancelPreparedSearch() {
        // A navigation interruption may resume once on a later Home visit.
        // The visit marker prevents duplicate callbacks from starting a loop;
        // a partial reserve can be extended on the next foreground visit.
        if reserveRequestID != nil { reservePreparationToken = nil }
        reserveRequestID = nil
        cancelReservePreparation?()
        cancelReservePreparation = nil
    }

    /// A better mix may replace only unchecked duplicates outside the current
    /// carousel page. Keep the existing Home usable throughout this search.
    func diversifyVisibleRecommendations() async {
        guard isHomeForeground, case .ready = state, !isLoadingCuration, !isCommittingSelection,
              !photoLibraryChanged, !retryRestoredSession, !Task.isCancelled, reserveRequestID == nil,
              diversityAttemptVisitID != foregroundVisitID,
              subscriptions.canStartCuration, let startingToken = activity.recommendationAppendToken() else { return }
        let groups = Set(todayDecisions.compactMap { CleanupReasonGroup($0.reasonCodes.first) })
        guard todayDecisions.count > groups.count, groups.count < 3,
              todayDecisions.contains(where: { !selectedCleanupKeys.contains($0.persistenceKey)
                  && $0.persistenceKey != todayDecisions[currentDecisionIndex].persistenceKey }) else { return }
        let status = authorizationStatus()
        guard status == .authorized || status == .limited else { return }
        let day = activity.recommendationDayKey
        let session = activity.dailySessionProgress()
        let unavailable = activity.recommendationExcludedIdentifiers().union(session.curatedPhotoIdentifiers)
            .union(session.processedDecisionKeys).union(session.comparisonReferences.values)
            .union(CurationProtectionStore.shared.identifiers())
        let excludedGroups = groups.union(session.processedDecisionKeys.compactMap { CleanupReasonGroup(session.curationReasons[$0]) })
        let visited = activity.scannedPhotoIdentifiers().union(unavailable)
        let dates = CurationReviewStore.shared.dates()
        let request = UUID()
        reserveRequestID = request
        diversityAttemptVisitID = foregroundVisitID
        var token = startingToken
        let accepts: () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.reserveRequestID == request && !Task.isCancelled && self.isHomeForeground
                && !self.isCommittingSelection && !self.photoLibraryChanged && self.authorizationStatus() == status
                && self.activity.recommendationDayKey == day && self.activity.matchesRecommendationAppendToken(token)
        }
        let publish: (PhotoCurationService.ScanBatch) -> Void = { [weak self] batch in
            guard let self, accepts(), self.todayDecisions.indices.contains(self.currentDecisionIndex) else { return }
            let pinned = self.selectedCleanupKeys.union([self.todayDecisions[self.currentDecisionIndex].persistenceKey])
            let improved = PhotoCurationService.diversifiedPendingRecommendations(self.todayDecisions,
                additions: batch.decisions, pinned: pinned)
            guard improved.map(\.persistenceKey) != self.todayDecisions.map(\.persistenceKey),
                  self.activity.diversifyPendingRecommendations(improved, preserving: pinned, matching: token) else { return }
            self.replaceDecisionsAfterValidation(improved)
            self.state = .ready(self.todayDecisions[self.currentDecisionIndex])
            self.activity.removePreparedRecommendations(Set(improved.map(\.persistenceKey)))
            if let next = self.activity.recommendationAppendToken() { token = next }
        }
        let task = Task { [curationService] in
            let result = await HomeCurationSearch.curatedContinuing(excluding: visited,
                protectedIdentifiers: unavailable, limit: 3 - groups.count,
                excludingReasonGroups: excludedGroups, allowSameReasonFallback: false,
                onUpdate: { publish($0) }, canContinue: accepts) { excluded, protected, remaining, represented in
                    let batch = await curationService.fetchNextBatch(excluding: excluded, protectedIdentifiers: protected,
                        reviewDates: dates, limit: remaining, firstResult: true, excludingReasonGroups: represented, onProgress: nil)
                    if accepts() {
                        let currentCandidates = Set(self.todayDecisions.flatMap(\.removalIdentifiers))
                        let alreadyPrepared = self.activity.preparedRecommendations(excluding: unavailable.union(currentCandidates))?.photoIdentifiers.count ?? 0
                        let reserve = batch.deferredDecisions.filter {
                            $0.comparisonLocalIdentifier.map { !currentCandidates.contains($0) } ?? true
                        }.prefix(max(0, 3 - alreadyPrepared))
                        self.activity.savePreparedRecommendations(Array(reserve), excluding: unavailable.union(currentCandidates))
                        self.retainHomeEvidence()
                    }
                    return batch
                }
            if let result { publish(result) }
            if accepts() { await self.prepareReservedPhotoPreviews(canContinue: accepts) }
        }
        cancelReservePreparation = { task.cancel() }
        let deadline = Task {
            do { try await Task.sleep(nanoseconds: 12_000_000_000) } catch { return }
            task.cancel()
        }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        deadline.cancel()
        if reserveRequestID == request { reserveRequestID = nil; cancelReservePreparation = nil }
    }

    /// At most one bounded background job per Home visit. Improve today's mix
    /// first; an already diverse set can use that time to prepare the next one.
    func prepareHomeRecommendations() async {
        await diversifyVisibleRecommendations()
        guard diversityAttemptVisitID != foregroundVisitID else { return }
        await prepareNextRecommendations()
    }

    /// Prepare unseen candidates only after the visible daily queue is complete.
    /// This runs once per foreground visit, never changes Home or selections,
    /// and has its own cancellation deadline even while PhotoKit is reading.
    func prepareNextRecommendations() async {
        guard isHomeForeground, case .ready = state, !isLoadingCuration, !isCommittingSelection,
              !photoLibraryChanged, !retryRestoredSession, !Task.isCancelled, reserveRequestID == nil,
              subscriptions.canStartCuration,
              let token = activity.recommendationAppendToken(),
              reserveAttemptVisitID != foregroundVisitID,
              reservePreparationToken.map(activity.matchesRecommendationAppendToken) != true else { return }
        let session = activity.dailySessionProgress()
        guard Set(session.curatedPhotoIdentifiers).union(session.processedDecisionKeys).count >= 3 else { return }
        let status = authorizationStatus()
        guard status == .authorized || status == .limited else { return }
        let day = activity.recommendationDayKey
        let cooldown = activity.recommendationExcludedIdentifiers()
        let prepared = activity.preparedRecommendations(excluding: cooldown)
        let preparedCount = prepared?.photoIdentifiers.count ?? 0
        let preparedGroups = Set(prepared?.curationReasons.values.compactMap { CleanupReasonGroup($0) } ?? [])
        guard preparedCount < 6, preparedCount < 3 || preparedGroups.count < 3 else { return }
        let unavailableForReserve = CurationProtectionStore.shared.identifiers().union(cooldown)
            .union(session.curatedPhotoIdentifiers).union(session.comparisonReferences.values)
        let protected = unavailableForReserve
            .union(prepared?.photoIdentifiers ?? []).union(prepared?.comparisonReferences.values.map { $0 } ?? [])
        let dates = CurationReviewStore.shared.dates()
        let visited = activity.scannedPhotoIdentifiers().union(prepared?.photoIdentifiers ?? [])
        let request = UUID()
        reserveRequestID = request
        reserveAttemptVisitID = foregroundVisitID
        let accepts: () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.reserveRequestID == request && !Task.isCancelled && self.isHomeForeground && !self.isCommittingSelection
                && !self.photoLibraryChanged && self.authorizationStatus() == status
                && self.activity.recommendationDayKey == day && self.activity.matchesRecommendationAppendToken(token)
        }
        let save: (PhotoCurationService.ScanBatch) -> Void = { [weak self] batch in
            guard let self, accepts() else { return }
            self.activity.savePreparedRecommendations(batch.decisions, excluding: unavailableForReserve)
            self.retainHomeEvidence()
        }
        let task = Task { [curationService] in
            let batch = await HomeCurationSearch.curatedContinuing(excluding: visited,
                protectedIdentifiers: protected, limit: 3 - min(preparedCount, preparedGroups.count),
                excludingReasonGroups: preparedGroups, allowSameReasonFallback: preparedCount < 3,
                diversityTimeLimit: 9, maximumSlices: 3, maximumAttempts: 12, timeLimit: 4,
                onUpdate: { save($0) }, canContinue: accepts) { excluded, protection, remaining, represented in
                    await curationService.fetchNextBatch(excluding: excluded, protectedIdentifiers: protection,
                        reviewDates: dates, limit: remaining, firstResult: true, excludingReasonGroups: represented, onProgress: nil)
                }
            if let batch { save(batch) }
            if accepts() { await self.prepareReservedPhotoPreviews(canContinue: accepts) }
        }
        cancelReservePreparation = { task.cancel() }
        let deadline = Task {
            do { try await Task.sleep(nanoseconds: 12_000_000_000) }
            catch { return }
            task.cancel()
        }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        deadline.cancel()
        if reserveRequestID == request {
            let reasons = activity.preparedRecommendations(excluding: cooldown)?.curationReasons.values
            let groupCount = Set(reasons?.compactMap { CleanupReasonGroup($0) } ?? []).count
            reservePreparationToken = groupCount >= 3 ? token : nil
            reserveRequestID = nil
            cancelReservePreparation = nil
        }
    }

    private func prepareReservedPhotoPreviews(canContinue: () -> Bool) async {
        guard canContinue(), let prepared = activity.preparedRecommendations() else { return }
        var groups = Set<CleanupReasonGroup>()
        let diverse = prepared.photoIdentifiers.filter { id in
            guard let group = CleanupReasonGroup(prepared.curationReasons[id]) else { return false }
            return groups.insert(group).inserted
        }
        let first = Set(diverse)
        let ordered = diverse + prepared.photoIdentifiers.filter { !first.contains($0) }
        await HomePhotoPreviewCache.prepare(ordered, preserving: photoIdentifiers, canContinue: canContinue)
    }

    private func restorePreparedRecommendations(request: UUID, excluding excluded: Set<String>,
                                                protected: Set<String>, reviewDates: [String: Date],
                                                limit: Int, represented: Set<CleanupReasonGroup> = []) async -> [DecisionUnit] {
        guard limit > 0, let prepared = activity.preparedRecommendations(excluding: excluded.union(protected)) else { return [] }
        // A reserve can contain more photos than Home needs. Do not let an
        // evicted proof for an optional fourth photo hold the verified three
        // behind fresh PhotoKit/Vision work. Permission, revision and every
        // comparison are still checked by the cache-only restoration boundary.
        let cached = await runScan { [curationService] in
            await curationService.restoreCachedDecisions(localIdentifiers: prepared.photoIdentifiers,
                references: prepared.comparisonReferences, reasons: prepared.curationReasons,
                protectedIdentifiers: protected, reviewDates: reviewDates)
        }
        guard acceptsScan(request) else { return [] }
        if let cached {
            let ready = await usablePreparedRecommendations(cached.decisions, excluding: excluded,
                protected: protected, limit: limit, represented: represented)
            guard acceptsScan(request) else { return [] }
            if !ready.isEmpty {
                HomeCurationDiagnostics.record("prepared-cached-presented", ["count": ready.count,
                    "pending": cached.hasPendingAnalysis])
                // Publish even a partial verified set now. The existing bounded
                // top-up fills remaining slots; unreadable reserve IDs stay saved.
                return ready
            }
            if !cached.hasPendingAnalysis { return [] }
        }
        let restored = await runScan { [curationService] in
            await curationService.restoreDecisions(localIdentifiers: prepared.photoIdentifiers,
                references: prepared.comparisonReferences, reasons: prepared.curationReasons,
                protectedIdentifiers: protected, reviewDates: reviewDates)
        }
        guard acceptsScan(request) else { return [] }
        let ready = await usablePreparedRecommendations(restored.decisions, excluding: excluded,
            protected: protected, limit: limit, represented: represented)
        return acceptsScan(request) ? ready : []
    }

    private func usablePreparedRecommendations(_ decisions: [DecisionUnit], excluding excluded: Set<String>,
                                               protected: Set<String>, limit: Int,
                                               represented: Set<CleanupReasonGroup>) async -> [DecisionUnit] {
        // Never silently discard temporarily unreadable prepared photos. Every
        // returned decision still passes current permission/evidence validation.
        let valid = cleanupRecommendations(decisions, excluding: excluded, limit: 6).filter {
            !(CleanupReasonGroup($0.reasonCodes.first) == .contextReview && represented.contains(.contextReview))
        }
        var groups = represented
        let diverse = valid.filter { unit in
            guard let group = CleanupReasonGroup(unit.reasonCodes.first) else { return false }
            return groups.insert(group).inserted
        }
        let firstIDs = Set(diverse.map(\.persistenceKey))
        let ordered = diverse + valid.filter { !firstIDs.contains($0.persistenceKey) }
        // Reuse the same cross-reference and category safety rules as a fresh
        // search before anything can be published or enter exposure history.
        let checked = await PhotoCurationService.curatedBatch(excluding: [], protectedIdentifiers: protected.union(excluded),
            initialDecisions: ordered, limit: limit, maximumPasses: 0) { _, _, _, _ in
                .init(decisions: [], visitedIdentifiers: [], hasMore: false)
            }
        return checked.decisions
    }

    /// Restoring the queue from an older build may have no reusable proofs yet.
    /// Reveal each verified subset immediately, then continue only work that
    /// stopped at the service's shared four-second budget. Missing permission
    /// and actual read failures retain their recovery path without a retry loop.
    private func restoreCurrentRecommendations(_ session: DailySessionProgress, request: UUID,
                                               protected: Set<String>, reviewDates: [String: Date]) async
        -> PhotoCurationService.RestoredDecisions {
        let token = activity.recommendationAppendToken()
        let identifiers = session.curatedPhotoIdentifiers.filter { !session.processedDecisionKeys.contains($0) }
        var restored = PhotoCurationService.RestoredDecisions(decisions: [], retryableFailureCount: 0)
        func present(_ value: PhotoCurationService.RestoredDecisions) {
            guard !value.decisions.isEmpty else { return }
            replaceDecisionsAfterValidation(value.decisions)
            completedDecisionCountAtLoad = session.processedDecisionKeys.count
            lastScanFoundNoCandidates = false
            additionalSearchFoundNoCandidates = false
            isRestoringSession = false
            preparingPhotoIdentifier = nil
            isBackgroundTopUp = true
            state = .ready(todayDecisions[currentDecisionIndex])
            // Pending checks retain their stored ownership until all evidence is validated.
            persistValidatedAuthorization(for: request)
        }
        let cached = await runScan { [curationService] in
            await curationService.restoreCachedDecisions(localIdentifiers: identifiers,
                references: session.comparisonReferences, reasons: session.curationReasons,
                protectedIdentifiers: protected, reviewDates: reviewDates)
        }
        guard acceptsScan(request), !isCommittingSelection,
              token.map(activity.matchesRecommendationAppendToken) == true else { return restored }
        if let cached {
            restored = cached
            present(cached)
            HomeCurationDiagnostics.record("restore-cached-presented", ["count": cached.decisions.count,
                "pending": cached.hasPendingAnalysis, "cancelled": Task.isCancelled])
            if !cached.hasPendingAnalysis { return cached }
        }
        for attempt in 0..<3 {
            guard acceptsScan(request), !isCommittingSelection,
                  token.map(activity.matchesRecommendationAppendToken) == true else { return restored }
            HomeCurationDiagnostics.record("restore-live-start", ["attempt": attempt])
            let next = await runScan { [curationService] in
                await curationService.restoreDecisions(localIdentifiers: identifiers,
                    references: session.comparisonReferences, reasons: session.curationReasons,
                    protectedIdentifiers: protected, reviewDates: reviewDates)
            }
            HomeCurationDiagnostics.record("restore-live-returned", ["attempt": attempt,
                "count": next.decisions.count, "pending": next.hasPendingAnalysis, "cancelled": Task.isCancelled])
            guard acceptsScan(request), !isCommittingSelection,
                  token.map(activity.matchesRecommendationAppendToken) == true else { return restored }
            let returned = Set(next.decisions.map(\.persistenceKey))
            let retained = restored.decisions.filter { unit in
                guard !photoLibraryChanged, !returned.contains(unit.persistenceKey),
                      next.retryableIdentifiers.contains(unit.persistenceKey) else { return false }
                let evidenceIDs = [unit.persistenceKey] + (unit.comparisonLocalIdentifier.map { [$0] } ?? [])
                return evidenceIDs.allSatisfy { id in
                    guard !next.inaccessibleIdentifiers.contains(id),
                          let previous = restored.assetRevisions[id], !previous.isEmpty else { return false }
                    return next.assetRevisions[id] == previous
                }
            }
            if retained.isEmpty {
                restored = next
            } else {
                let known = Dictionary(uniqueKeysWithValues: (next.decisions + retained).map { ($0.persistenceKey, $0) })
                let combined = identifiers.compactMap { known[$0] }
                let missing = Set(identifiers).subtracting(known.keys)
                let pending = next.retryableIdentifiers.intersection(missing)
                restored = .init(decisions: combined, retryableFailureCount: pending.count,
                    inaccessibleIdentifiers: next.inaccessibleIdentifiers,
                    hasPendingAnalysis: next.hasPendingAnalysis && !missing.isEmpty,
                    retryableIdentifiers: pending, assetRevisions: next.assetRevisions)
            }
            present(restored)
            guard restored.hasPendingAnalysis, restored.inaccessibleIdentifiers.isEmpty else { break }
            await Task.yield()
        }
        return restored
    }

    func requestPhotoPermission() async {
        guard authorizationStatus() == .notDetermined else { await checkPermissionAndLoad(); return }
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        await checkPermissionAndLoad()
    }

    private struct RecommendationPublication {
        let startingSession: DailySessionProgress
        var token: LocalActivityStore.RecommendationAppendToken?
        var identifiers: [String] = []
        var invalidated = false
    }

    /// Commit only verified recommendations before revealing the carousel. A
    /// later cancellation keeps these displayed photos, never an unshown result.
    private func publishRecommendations(_ batch: PhotoCurationService.ScanBatch, request: UUID,
                                        excluding: Set<String>, limit: Int,
                                        publication: inout RecommendationPublication) {
        guard acceptsScan(request), !isCommittingSelection, subscriptions.canStartCuration else {
            publication.invalidated = true
            return
        }
        let decisions = cleanupRecommendations(batch.decisions, excluding: excluding, limit: limit)
        let identifiers = decisions.compactMap(\.displayIdentifier)
        guard !identifiers.isEmpty else { return }
        guard Array(identifiers.prefix(publication.identifiers.count)) == publication.identifiers else {
            publication.invalidated = true
            return
        }
        let references = Dictionary(uniqueKeysWithValues: decisions.compactMap { unit -> (String, String)? in
            guard let id = unit.displayIdentifier, let reference = unit.comparisonLocalIdentifier else { return nil }
            return (id, reference)
        })
        let reasons = Dictionary(uniqueKeysWithValues: decisions.compactMap { unit -> (String, CurationReasonCode)? in
            guard let id = unit.displayIdentifier, let reason = unit.reasonCodes.first else { return nil }
            return (id, reason)
        })
        if publication.identifiers.isEmpty {
            let current = activity.dailySessionProgress()
            let before = publication.startingSession
            guard current.curatedPhotoIdentifiers == before.curatedPhotoIdentifiers,
                  current.processedDecisionKeys == before.processedDecisionKeys,
                  current.comparisonReferences == before.comparisonReferences,
                  current.curationReasons == before.curationReasons,
                  current.curationVersion == before.curationVersion,
                  current.deletedPhotoCount == before.deletedPhotoCount,
                  current.savedRecordCount == before.savedRecordCount else {
                publication.invalidated = true
                return
            }
            activity.beginDailySession(photoIdentifiers: identifiers,
                                       comparisonReferences: references, curationReasons: reasons)
            guard activity.dailySessionProgress().curatedPhotoIdentifiers == identifiers else {
                publication.invalidated = true
                return
            }
        } else {
            guard let token = publication.token, activity.matchesRecommendationAppendToken(token) else {
                publication.invalidated = true
                return
            }
            let additions = Array(identifiers.dropFirst(publication.identifiers.count))
            if !additions.isEmpty {
                let added = Set(additions)
                guard activity.appendRecommendations(photoIdentifiers: additions,
                    comparisonReferences: references.filter { added.contains($0.key) },
                    curationReasons: reasons.filter { added.contains($0.key) }, matching: token) else {
                    publication.invalidated = true
                    return
                }
            }
        }
        publication.identifiers = identifiers
        publication.token = activity.recommendationAppendToken()
        activity.removePreparedRecommendations(Set(identifiers))
        activity.recordScannedPhotos(batch.visitedIdentifiers)
        applyScanAvailability(batch)
        replaceDecisionsAfterValidation(decisions)
        completedDecisionCountAtLoad = publication.startingSession.processedDecisionKeys.count
        selectedCleanupKeys.formIntersection(Set(identifiers))
        persistCleanupSelection()
        lastScanFoundNoCandidates = false
        additionalSearchFoundNoCandidates = false
        preparingPhotoIdentifier = nil
        isRestoringSession = false
        isBackgroundTopUp = true
        state = .ready(todayDecisions[currentDecisionIndex])
        persistValidatedAuthorization(for: request)
    }

    func loadTodayDecision(skipFinishedSessionScan: Bool = true,
                           recoveringRevokedScope: Set<String>? = nil,
                           reuseValidatedQueue: Bool = false, searchSlices: Int = 3,
                           usePreparedRecommendations: Bool = true) async {
        guard !isCommittingSelection else { return }
        guard await prepareRecommendationDay() else { return }
        guard !isLoadingCuration else { return }
        let request = beginScan(preservingVisibleQueue: reuseValidatedQueue)
        defer { persistValidatedAuthorization(for: request); finishScan(request) }
        sessionKind = .daily

        refreshWeeklyProgress()
        userName = ""

        let session = activity.dailySessionProgress()
        // A completion is feedback for a just-finished action, never a restored route.
        retainHomeEvidence()
        // Pending identifiers take precedence over today's aggregate completion record.
        if skipFinishedSessionScan, session.curatedPhotoIdentifiers.isEmpty, activity.hasCompletedCleanupToday() {
            let visited = activity.scannedPhotoIdentifiers()
            let hasMore = await runScan { [curationService] in
                await curationService.hasUnscannedPhotos(excluding: visited)
            }
            guard acceptsScan(request) else { return }
            hasMorePhotos = hasMore
            todayDecisions = []
            state = .noCandidate
            return
        }

        sessionDeletedPhotoCount = session.deletedPhotoCount
        sessionSavedRecordCount = session.savedRecordCount

        let protectedIdentifiers = CurationProtectionStore.shared.identifiers()
        let recentRecommendations = activity.recommendationExcludedIdentifiers()
        hasRecentRecommendations = !recentRecommendations.isEmpty
        let reviewDates = CurationReviewStore.shared.dates()
        let decisions: [DecisionUnit]
        if session.curatedPhotoIdentifiers.isEmpty || session.curationVersion != PhotoCurationService.curationVersion {
            // Existing recommendations can be restored after access expires.
            // Only searching for a new batch consumes recommendation access.
            guard subscriptions.canStartCuration else {
                todayDecisions = []
                state = .subscriptionRequired
                return
            }
            let visited = activity.scannedPhotoIdentifiers()
            let progress = progressHandler(for: request)
            var publication = RecommendationPublication(startingSession: session)
            let excluded = session.processedDecisionKeys.union(activity.reviewedPhotoIdentifiers()).union(recentRecommendations)
            let limit = max(0, 3 - session.processedDecisionKeys.count)
            let prepared = await restorePreparedRecommendations(request: request, excluding: excluded,
                protected: protectedIdentifiers, reviewDates: reviewDates, limit: limit)
            guard acceptsScan(request) else { return }
            if !prepared.isEmpty {
                publishRecommendations(.init(decisions: prepared, visitedIdentifiers: [], hasMore: true, hasFreshPhotos: true),
                    request: request, excluding: excluded, limit: limit, publication: &publication)
            }
            let batch = await runScan { [curationService] in
                await HomeCurationSearch.curatedContinuing(excluding: visited,
                    protectedIdentifiers: protectedIdentifiers.union(session.processedDecisionKeys).union(recentRecommendations),
                    initialDecisions: prepared, limit: limit, maximumSlices: searchSlices,
                    onUpdate: { snapshot in
                        self.publishRecommendations(snapshot, request: request, excluding: excluded,
                                                    limit: limit, publication: &publication)
                    },
                    canContinue: {
                        !publication.invalidated && self.acceptsScan(request)
                            && (publication.token.map(self.activity.matchesRecommendationAppendToken) ?? true)
                    }) { excluded, protected, remaining, represented in
                    await curationService.fetchNextBatch(excluding: excluded,
                        protectedIdentifiers: protected, reviewDates: reviewDates,
                        limit: remaining, firstResult: true, excludingReasonGroups: represented, onProgress: progress)
                }
            }
            if publication.invalidated, acceptsScan(request) {
                finishScan(request)
                await checkPermissionAndLoad()
                return
            }
            guard let batch, acceptsScan(request) else { return }
            decisions = cleanupRecommendations(batch.decisions,
                excluding: session.processedDecisionKeys.union(activity.reviewedPhotoIdentifiers()).union(recentRecommendations),
                limit: max(0, 3 - session.processedDecisionKeys.count))
            activity.recordScannedPhotos(batch.visitedIdentifiers)
            applyScanAvailability(batch)
            lastScanFoundNoCandidates = decisions.isEmpty
            activity.beginDailySession(
                photoIdentifiers: decisions.compactMap(\.displayIdentifier),
                comparisonReferences: Dictionary(uniqueKeysWithValues: decisions.compactMap { decision in
                    guard let candidate = decision.displayIdentifier,
                          let reference = decision.comparisonLocalIdentifier else { return nil }
                    return (candidate, reference)
                }),
                curationReasons: Dictionary(uniqueKeysWithValues: decisions.compactMap { decision in
                    guard let id = decision.displayIdentifier, let reason = decision.reasonCodes.first else { return nil }
                    return (id, reason)
                })
            )
        } else {
            isRestoringSession = true
            // Preview only. Keep state/loading and all decisions disabled until revalidated.
            let pending = session.curatedPhotoIdentifiers.filter {
                !session.processedDecisionKeys.contains($0)
                    && (session.curationReasons[$0]?.isReflection == true || !protectedIdentifiers.contains($0))
            }
            let selected = todayDecisions.indices.contains(currentDecisionIndex)
                ? todayDecisions[currentDecisionIndex].displayIdentifier : nil
            let access = authorizationStatus()
            preparingPhotoIdentifier = (access == .authorized || access == .limited)
                ? selected.flatMap { pending.contains($0) ? $0 : nil } ?? pending.first : nil
            let appendToken = activity.recommendationAppendToken()
            let restored: PhotoCurationService.RestoredDecisions
            if reuseValidatedQueue {
                restored = .init(decisions: todayDecisions, retryableFailureCount: 0)
            } else {
                restored = await restoreCurrentRecommendations(session, request: request,
                    protected: protectedIdentifiers, reviewDates: reviewDates)
            }
            guard acceptsScan(request) else { return }
            let visited = activity.scannedPhotoIdentifiers()
            let hasMore: Bool
            if reuseValidatedQueue { hasMore = hasMorePhotos }
            else {
                hasMore = await runScan { [curationService] in
                    await curationService.hasUnscannedPhotos(excluding: visited)
                }
            }
            guard acceptsScan(request) else { return }
            hasMorePhotos = hasMore
            var validated = restored.decisions
            unavailablePhotoCount = restored.retryableFailureCount
            inaccessiblePhotoCount = restored.inaccessibleIdentifiers.count
            retryRestoredSession = restored.retryableFailureCount > 0 || inaccessiblePhotoCount > 0
            if retryRestoredSession { hasMorePhotos = true; hasFreshPhotos = false }
            let validatedIDs = Set(validated.compactMap(\.displayIdentifier))
            let remainingLimit = max(0, 3 - session.processedDecisionKeys.count)
            // Complete a previously short set without discarding, reordering or
            // charging for the already validated recommendations. A failed
            // restoration still takes precedence over searching for replacements.
            let originalPendingIDs = Set(session.curatedPhotoIdentifiers).subtracting(session.processedDecisionKeys)
            if recoveringRevokedScope == originalPendingIDs, !originalPendingIDs.isEmpty,
               authorizationStatus() == .limited, !isCommittingSelection, cleanupRecovery == nil,
               restored.decisions.isEmpty, restored.retryableFailureCount == 0,
               !restored.inaccessibleIdentifiers.isEmpty,
               selectedCleanupKeys.isDisjoint(with: originalPendingIDs),
               remainingLimit > 0, subscriptions.canStartCuration,
               let appendToken, activity.matchesRecommendationAppendToken(appendToken) {
                // Only a confirmed full -> limited change can retire an entirely
                // inaccessible, unchecked queue. Read/iCloud failures and any
                // surviving or checked choice keep their explicit recovery path.
                activity.clearPendingRecommendations()
                activity.resetScannedPhotos()
                replaceDecisionsAfterValidation([])
                invalidateHomePhotoPreviews()
                unavailablePhotoCount = 0
                inaccessiblePhotoCount = 0
                retryRestoredSession = false
                additionalSearchFoundNoCandidates = false
                finishScan(request)
                await loadTodayDecision(skipFinishedSessionScan: false)
                return
            }
            if !retryRestoredSession, !validated.isEmpty, validatedIDs == originalPendingIDs,
               validated.allSatisfy({ $0.type == .cleanupSingle && !$0.removalIdentifiers.isEmpty }),
               validated.count < remainingLimit,
               Set(session.curatedPhotoIdentifiers).union(session.processedDecisionKeys).count < 3,
               (hasMorePhotos || activity.preparedRecommendations(excluding: recentRecommendations.union(protectedIdentifiers)) != nil),
               subscriptions.canStartCuration, let appendToken,
               activity.matchesRecommendationAppendToken(appendToken) {
                // Restoration is complete: show the known photos immediately,
                // while a cancellable search tries to fill the remaining slot.
                replaceDecisionsAfterValidation(validated)
                completedDecisionCountAtLoad = session.processedDecisionKeys.count
                lastScanFoundNoCandidates = false
                additionalSearchFoundNoCandidates = false
                isRestoringSession = false
                preparingPhotoIdentifier = nil
                isBackgroundTopUp = true
                state = .ready(todayDecisions[currentDecisionIndex])
                // Settings can terminate the process before the optional top-up
                // finishes. The already validated visible queue must survive it.
                persistValidatedAuthorization(for: request)
                let visited = activity.scannedPhotoIdentifiers()
                let progress = progressHandler(for: request)
                let exclusions = session.processedDecisionKeys.union(recentRecommendations.subtracting(validatedIDs))
                var publication = RecommendationPublication(startingSession: session, token: appendToken,
                    identifiers: validated.compactMap(\.displayIdentifier))
                let prepared = usePreparedRecommendations ? await restorePreparedRecommendations(request: request, excluding: exclusions.union(validatedIDs),
                    protected: protectedIdentifiers.union(validatedIDs).union(session.comparisonReferences.values),
                    reviewDates: reviewDates, limit: remainingLimit - validated.count,
                    represented: Set(validated.compactMap { CleanupReasonGroup($0.reasonCodes.first) })
                        .union(session.processedDecisionKeys.compactMap { CleanupReasonGroup(session.curationReasons[$0]) })) : []
                guard acceptsScan(request) else { return }
                let batch = await runScan { [curationService] in
                    await HomeCurationSearch.curatedContinuing(excluding: visited,
                        protectedIdentifiers: protectedIdentifiers.union(session.processedDecisionKeys)
                            .union(recentRecommendations.subtracting(validatedIDs)),
                        initialDecisions: validated + prepared, limit: remainingLimit,
                        excludingReasonGroups: Set(session.processedDecisionKeys.compactMap { CleanupReasonGroup(session.curationReasons[$0]) }),
                        maximumSlices: searchSlices,
                        onUpdate: { snapshot in
                            self.publishRecommendations(snapshot, request: request, excluding: exclusions,
                                                        limit: remainingLimit, publication: &publication)
                        },
                        canContinue: {
                            !publication.invalidated && self.acceptsScan(request) && self.subscriptions.canStartCuration
                                && (publication.token.map(self.activity.matchesRecommendationAppendToken) ?? false)
                        }
                    ) { excluded, protected, remaining, represented in
                        await curationService.fetchNextBatch(excluding: excluded, protectedIdentifiers: protected,
                            reviewDates: reviewDates, limit: remaining, firstResult: true, excludingReasonGroups: represented, onProgress: progress)
                    }
                }
                guard acceptsScan(request) else { return }
                guard let batch, subscriptions.canStartCuration,
                      !publication.invalidated,
                      publication.token.map(activity.matchesRecommendationAppendToken) == true else { return }
                // If a legacy seed cannot meet the collector's safety rules,
                // retain its restored queue and do not merge any new nominations.
                if validatedIDs.isSubset(of: Set(batch.decisions.compactMap(\.displayIdentifier))) {
                    publishRecommendations(batch, request: request, excluding: exclusions,
                                           limit: remainingLimit, publication: &publication)
                    guard !publication.invalidated else { return }
                    validated = todayDecisions
                }
            }
            decisions = validated
            lastScanFoundNoCandidates = decisions.isEmpty
        }
        replaceDecisionsAfterValidation(decisions.filter {
            !session.processedDecisionKeys.contains($0.persistenceKey)
        })
        // Keep today's checks for temporarily unreadable photos so a retry can
        // restore them. Only the persisted pending queue owns their lifetime.
        let currentSession = activity.dailySessionProgress()
        selectedCleanupKeys.formIntersection(Set(currentSession.curatedPhotoIdentifiers)
            .subtracting(currentSession.processedDecisionKeys))
        persistCleanupSelection()
        let curatedIdentifiers = Set(session.curatedPhotoIdentifiers)
        completedDecisionCountAtLoad = session.processedDecisionKeys.count
        let completedEveryCuratedPhoto = !curatedIdentifiers.isEmpty
            && curatedIdentifiers.isSubset(of: session.processedDecisionKeys)

        if todayDecisions.indices.contains(currentDecisionIndex) {
            additionalSearchFoundNoCandidates = false
            state = .ready(todayDecisions[currentDecisionIndex])
        } else if hasPendingForegroundSearch, !hasBlockingScanIssue {
            state = .searchPending
        } else if hasScanIssue {
            // A failed replacement scan is also unfinished; preserve previous
            // choices and the free session until recovery or an explicit decision.
            state = .noCandidate
        } else if completedEveryCuratedPhoto || !session.processedDecisionKeys.isEmpty {
            completeDailySession(showCompletion: false)
        } else {
            state = .noCandidate
        }
    }

    func loadMoreDecisions() async {
        guard !isCommittingSelection else { return }
        guard await prepareRecommendationDay() else { return }
        stoppedReviewingEarly = false
        guard !isLoadingCuration else { return }
        guard subscriptions.canStartCuration else { showSubscription = true; return }
        let access = authorizationStatus()
        guard access == .authorized || access == .limited else { await checkPermissionAndLoad(); return }
        if todayDecisions.indices.contains(currentDecisionIndex) { state = .ready(todayDecisions[currentDecisionIndex]); return }
        let request = beginScan(morePhotos: true)
        defer { persistValidatedAuthorization(for: request); finishScan(request) }
        let status = authorizationStatus()
        guard status == .authorized || status == .limited else {
            await curationService.resetScan()
            unavailablePhotoCount = 0
            retryRestoredSession = false
            state = .noPermission
            return
        }
        let visited = activity.scannedPhotoIdentifiers()
        let recentRecommendations = activity.recommendationExcludedIdentifiers()
        hasRecentRecommendations = !recentRecommendations.isEmpty
        let protection = CurationProtectionStore.shared.identifiers()
            .union(activity.dailySessionProgress().processedDecisionKeys).union(recentRecommendations)
        let dates = CurationReviewStore.shared.dates()
        let progress = progressHandler(for: request)
        var publication = RecommendationPublication(startingSession: activity.dailySessionProgress())
        let excluded = publication.startingSession.processedDecisionKeys.union(activity.reviewedPhotoIdentifiers()).union(recentRecommendations)
        sessionKind = .daily
        sessionDeletedPhotoCount = 0
        sessionSavedRecordCount = 0
        completedDecisionCountAtLoad = 0
        let prepared = await restorePreparedRecommendations(request: request, excluding: excluded,
            protected: protection, reviewDates: dates, limit: 3)
        guard acceptsScan(request) else { return }
        if !prepared.isEmpty {
            publishRecommendations(.init(decisions: prepared, visitedIdentifiers: [], hasMore: true, hasFreshPhotos: true),
                request: request, excluding: excluded, limit: 3, publication: &publication)
        }
        let batch = await runScan { [curationService] in
            await HomeCurationSearch.curatedContinuing(excluding: visited, protectedIdentifiers: protection,
                initialDecisions: prepared,
                onUpdate: { snapshot in
                    self.publishRecommendations(snapshot, request: request, excluding: excluded,
                                                limit: 3, publication: &publication)
                },
                canContinue: {
                    !publication.invalidated && self.acceptsScan(request)
                            && (publication.token.map(self.activity.matchesRecommendationAppendToken) ?? true)
                }) { excluded, protected, remaining, represented in
                await curationService.fetchNextBatch(excluding: excluded,
                    protectedIdentifiers: protected,
                    reviewDates: dates, limit: remaining, firstResult: true, excludingReasonGroups: represented, onProgress: progress)
            }
        }
        if publication.invalidated, acceptsScan(request) {
            finishScan(request)
            await checkPermissionAndLoad()
            return
        }
        guard let batch, acceptsScan(request) else { return }
        let processed = activity.dailySessionProgress().processedDecisionKeys.union(activity.reviewedPhotoIdentifiers())
        let decisions = cleanupRecommendations(batch.decisions, excluding: processed.union(recentRecommendations), limit: 3)
        activity.recordScannedPhotos(batch.visitedIdentifiers)
        applyScanAvailability(batch)
        lastScanFoundNoCandidates = decisions.isEmpty
        additionalSearchFoundNoCandidates = decisions.isEmpty
        guard let first = decisions.first else {
            state = hasPendingForegroundSearch && !hasBlockingScanIssue ? .searchPending : .noCandidate
            return
        }
        activity.beginDailySession(
            photoIdentifiers: decisions.compactMap(\.displayIdentifier),
            comparisonReferences: Dictionary(uniqueKeysWithValues: decisions.compactMap { unit in
                guard let id = unit.displayIdentifier, let reference = unit.comparisonLocalIdentifier else { return nil }
                return (id, reference)
            }),
            curationReasons: Dictionary(uniqueKeysWithValues: decisions.compactMap { unit in
                guard let id = unit.displayIdentifier, let reason = unit.reasonCodes.first else { return nil }
                return (id, reason)
            })
        )
        sessionKind = .daily
        sessionDeletedPhotoCount = 0
        sessionSavedRecordCount = 0
        completedDecisionCountAtLoad = 0
        replaceDecisionsAfterValidation(decisions)
        selectedCleanupKeys.formIntersection(Set(decisions.map(\.persistenceKey)))
        persistCleanupSelection()
        state = .ready(todayDecisions.indices.contains(currentDecisionIndex) ? todayDecisions[currentDecisionIndex] : first)
    }

    func savedIndependentMemory() {
        activity.recordIndependentMemory()
        refreshWeeklyProgress()
        if case .completed = state, let summary = activity.todaySummary() {
            state = .completed(summary: CompletionSummary(deletedCount: summary.deletedPhotoCount, savedRecordCount: summary.savedRecordCount, reviewedCount: summary.reviewedPhotoCount))
        }
    }

    func loadSimilarPhotoCluster() async {
        guard subscriptions.canStartCuration else { showSubscription = true; return }
        guard featureAccess.isSimilarPhotoCleanupEnabled else { return }
        guard featureAccess.canUseSimilarPhotoCleanup else {
            showToastMessage(String(localized: "Premium 구독에서 이용할 수 있어요."))
            return
        }

        let previousState = state
        state = .loading
        let curationService = PhotoCurationService()
        guard let cluster = await curationService.fetchSimilarPhotoDecision(
            protectedIdentifiers: CurationProtectionStore.shared.identifiers(), reviewDates: CurationReviewStore.shared.dates()
        ) else {
            state = previousState
            showToastMessage(String(localized: "정리할 비슷한 사진 묶음을 찾지 못했어요."))
            return
        }

        todayDecisions = [cluster]
        currentDecisionIndex = 0
        completedDecisionCountAtLoad = 0
        sessionDeletedPhotoCount = 0
        sessionSavedRecordCount = 0
        sessionKind = .similarPhoto
        state = .ready(cluster)
    }

    // MARK: - 액션

    /// 나중에 — deferred 상태로 전환
    func deferDecision(_ unit: DecisionUnit) {
        // TODO: CurationRepository에 deferred 상태 저장
        // deferredUntil = 오늘 자정
        state = .noCandidate
        showToastMessage(String(localized: "나중에 다시 보여드릴게요."))
    }

    /// 오늘 완료 처리
    func scheduleReview(_ unit: DecisionUnit, afterDays days: Int) {
        guard let id = unit.displayIdentifier,
              let date = Calendar.current.date(byAdding: .day, value: days, to: Calendar.current.startOfDay(for: Date())) else { return }
        CurationReviewStore.shared.set(date, for: id)
        markTodayCompleted(unit: unit, deletedCount: 0, savedRecord: false, protectPhoto: false)
        showToastMessage(String(localized: "\(days)일 뒤부터 다시 확인할 사진에 넣어둘게요."))
    }

    var hasDeletedPhotosInSession: Bool { sessionDeletedPhotoCount > 0 }

    @discardableResult
    func markTodayCompleted(unit: DecisionUnit, deletedCount: Int, savedRecord: Bool, protectPhoto: Bool = true) -> Bool {
        guard todayDecisions.contains(where: { $0.persistenceKey == unit.persistenceKey }) else { return false }
        cancelBackgroundTopUp()
        guard let currentDecision = queue.remove(key: unit.persistenceKey) else { return false }
        retainCurrentPhotoPreviews()
        if protectPhoto, let id = currentDecision.displayIdentifier { CurationReviewStore.shared.set(nil, for: id) }
        if deletedCount == 0, protectPhoto, let identifier = currentDecision.displayIdentifier {
            CurationProtectionStore.shared.protect([identifier])
        } else if deletedCount > 0, unit.type != .recallMoment,
                  let keptIdentifier = unit.type == .cleanupSingle ? unit.comparisonLocalIdentifier : unit.displayIdentifier {
            CurationProtectionStore.shared.protect([keptIdentifier])
        }
        if sessionKind == .daily {
            activity.recordDailyDecision(
                decisionKey: currentDecision.persistenceKey,
                deletedPhotoCount: deletedCount,
                savedRecord: savedRecord
            )
        }
        sessionDeletedPhotoCount += deletedCount
        sessionSavedRecordCount += savedRecord ? 1 : 0
        completedDecisionCountAtLoad += 1
        refreshWeeklyProgress()

        if currentDecisionIndex < todayDecisions.count {
            state = .ready(todayDecisions[currentDecisionIndex])
        } else if retryRestoredSession {
            state = .noCandidate
        } else {
            completeDailySession()
        }
        return true
    }

    private func refreshWeeklyProgress() {
        let snapshot = activity.weeklySnapshot()
        // The reporting snapshot already includes the unfinished daily session.
        weeklyProgress = WeeklyProgress(
            completedDays: snapshot.completedDays,
            deletedPhotoCount: snapshot.deletedPhotoCount,
            savedRecordCount: snapshot.savedRecordCount
        )
    }

    private func completeDailySession(showCompletion: Bool = true) {
        // Empty/error scans never consume the introductory experience.
        if completedDecisionCountAtLoad > 0 { subscriptions.finishFirstExperience() }
        let progress = activity.dailySessionProgress()
        activity.recordCompletion(
            deletedPhotoCount: sessionKind == .daily ? progress.deletedPhotoCount : sessionDeletedPhotoCount,
            savedRecordCount: sessionKind == .daily ? progress.savedRecordCount : sessionSavedRecordCount,
            completesDailySession: sessionKind == .daily
        )
        let snapshot = activity.weeklySnapshot()
        weeklyProgress = WeeklyProgress(
            completedDays: snapshot.completedDays,
            deletedPhotoCount: snapshot.deletedPhotoCount,
            savedRecordCount: snapshot.savedRecordCount
        )
        state = showCompletion ? .completed(summary: CompletionSummary(
            deletedCount: activity.todaySummary()?.deletedPhotoCount ?? sessionDeletedPhotoCount,
            savedRecordCount: activity.todaySummary()?.savedRecordCount ?? sessionSavedRecordCount,
            reviewedCount: activity.todaySummary()?.reviewedPhotoCount
        )) : .noCandidate
    }

    /// Recall — 남기기 완료
    func keepRecallMoment(_ unit: DecisionUnit) {
        markTodayCompleted(unit: unit, deletedCount: 0, savedRecord: false)
    }

    private func showToastMessage(_ message: String) {
        toastMessage = message
        showToast = true
    }
}

/// Observe scope/library changes without rescanning underneath an open editor or confirmation.
private final class CurationLibraryObserver: NSObject, PHPhotoLibraryChangeObserver {
    private let changed: (Set<String>?) -> Void
    private let queue = DispatchQueue(label: "app.recoco.photo-library-changes")
    private var assets: PHFetchResult<PHAsset>
    init(changed: @escaping (Set<String>?) -> Void) {
        self.changed = changed
        let options = PHFetchOptions()
        options.includeAllBurstAssets = true
        options.includeHiddenAssets = true
        self.assets = PHAsset.fetchAssets(with: .image, options: options)
        super.init()
        PHPhotoLibrary.shared().register(self)
    }
    deinit { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        queue.async { [self] in
            let details = changeInstance.changeDetails(for: assets)
            var relevantChanges = Set<String>()
            var contentChanges = 0
            var metadataChanges = 0
            var unknownChanges = 0
            if let details, details.hasIncrementalChanges {
                for updated in details.changedObjects {
                    let index = details.fetchResultBeforeChanges.index(of: updated)
                    var original: PHAsset?
                    if index != NSNotFound {
                        original = details.fetchResultBeforeChanges.object(at: index)
                    } else {
                        // PHObject equality can differ across revisions. Fall
                        // back to identity without treating missing data as safe.
                        details.fetchResultBeforeChanges.enumerateObjects { candidate, _, stop in
                            if candidate.localIdentifier == updated.localIdentifier {
                                original = candidate; stop.pointee = true
                            }
                        }
                    }
                    guard let original, let objectChange = changeInstance.changeDetails(for: original) else {
                        unknownChanges += 1
                        relevantChanges.insert(updated.localIdentifier)
                        continue
                    }
                    let before = CurationLibraryAssetRevision(original)
                    let after = objectChange.objectAfterChanges.map(CurationLibraryAssetRevision.init)
                    if objectChange.assetContentChanged { contentChanges += 1 }
                    if after != before { metadataChanges += 1 }
                    if before.requiresRefresh(after: after, contentChanged: objectChange.assetContentChanged) {
                        relevantChanges.insert(updated.localIdentifier)
                    }
                }
            }
            let refresh = CurationLibraryChangePolicy.requiresRefresh(relevantFetch: details != nil,
                incremental: details?.hasIncrementalChanges ?? false,
                inserted: details?.insertedIndexes?.count ?? 0, removed: details?.removedIndexes?.count ?? 0,
                changed: relevantChanges.count, moved: details?.hasMoves ?? false)
            if let details { assets = details.fetchResultAfterChanges }
            HomeCurationDiagnostics.record("library-notification", ["relevant": details != nil,
                "refresh": refresh, "inserted": details?.insertedIndexes?.count ?? 0,
                "removed": details?.removedIndexes?.count ?? 0, "changed": details?.changedIndexes?.count ?? 0,
                "contentChanges": contentChanges, "metadataChanges": metadataChanges,
                "unknownChanges": unknownChanges, "relevantChanges": relevantChanges.count])
            // Albums and unrelated library bookkeeping cannot cancel this
            // photo queue. Actual photo/content/scope changes still invalidate it.
            if refresh {
                if let details, details.hasIncrementalChanges {
                    relevantChanges.formUnion(details.insertedObjects.map(\.localIdentifier))
                    relevantChanges.formUnion(details.removedObjects.map(\.localIdentifier))
                    changed(relevantChanges)
                } else { changed(nil) }
            }
        }
    }
}
