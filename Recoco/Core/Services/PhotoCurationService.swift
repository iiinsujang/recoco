import Photos
import UIKit
import Vision
import CoreLocation
import CryptoKit

struct PhotoContextMetadata {
    let identifier: String
    let capturedAt: Date?
    var place: String? = nil
    fileprivate var location: CLLocation? = nil
    fileprivate var modifiedAt: Date? = nil
}

/// Context describes stored metadata, never a venue, subject or personal value.
enum PhotoContextFormatter {
    static func dateText(_ date: Date?, timeZone: TimeZone = .current, locale: Locale = .current) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("yyyyMMMMd")
        return formatter.string(from: date)
    }

    static func placeText(locality: String?, subLocality: String?, subAdministrativeArea: String?,
                          administrativeArea: String?, country: String?) -> String? {
        func clean(_ value: String?) -> String? {
            guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        let city = clean(locality) ?? clean(administrativeArea)
        let district = clean(subLocality) ?? clean(subAdministrativeArea)
        if let city, let district {
            if city == district || city.hasSuffix(" " + district) { return city }
            if district.hasPrefix(city + " ") { return district }
            return "\(city) \(district)"
        }
        // A country alone is too broad to help recall the scene ("대한민국 인근").
        return city ?? district
    }

    static func caption(capturedAt: Date?, place: String?, timeZone: TimeZone = .current, locale: Locale = .current) -> String? {
        let region = place?.trimmingCharacters(in: .whitespacesAndNewlines)
        let location = region.flatMap { $0.isEmpty ? nil : String(localized: "\($0) 인근") }
        let parts = [dateText(capturedAt, timeZone: timeZone, locale: locale), location].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

@MainActor
struct PhotoMetadataService {
    private static var placeCache: [String: String] = [:]
    private static var cachedKeys: [String] = []

    /// The date can appear immediately; reverse geocoding never blocks the photo or actions.
    func localContext(for localIdentifier: String?, capturedAt: Date? = nil) -> PhotoContextMetadata? {
        guard let localIdentifier, !localIdentifier.isEmpty, !Task.isCancelled else { return nil }
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-ui-testing") {
            // UI fixtures never inspect a person's photo library.
            return PhotoContextMetadata(identifier: localIdentifier,
                capturedAt: arguments.contains("-photo-context-testing=missing") ? nil : capturedAt)
        }
        #endif
        guard Self.hasPhotoAccess else { return nil }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = assets.firstObject, asset.localIdentifier == localIdentifier,
              asset.mediaType == .image, !asset.isHidden else { return nil }
        return PhotoContextMetadata(identifier: localIdentifier, capturedAt: asset.creationDate,
                                    location: asset.location, modifiedAt: asset.modificationDate)
    }

    func context(for localIdentifier: String?, capturedAt: Date? = nil) async -> PhotoContextMetadata? {
        guard var metadata = localContext(for: localIdentifier, capturedAt: capturedAt) else { return nil }
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-ui-testing") {
            if arguments.contains("-photo-context-delay-first"), metadata.identifier.hasSuffix("-1") {
                do { try await Task.sleep(nanoseconds: 1_500_000_000) } catch { return nil }
                guard !Task.isCancelled else { return nil }
            }
            if arguments.contains("-photo-context-testing=complete"),
               !arguments.contains("-photo-context-testing=missing"), !arguments.contains("-photo-context-testing=offline") {
                metadata.place = metadata.identifier.hasSuffix("-1") ? "서울 마포구"
                    : (metadata.identifier.hasSuffix("-2") ? "부산 해운대구" : nil)
            }
            // Missing GPS / offline fixtures simply retain any known date.
            return metadata
        }
        #endif
        guard let location = metadata.location, CLLocationCoordinate2DIsValid(location.coordinate),
              location.horizontalAccuracy >= 0 else { return metadata }
        let key = Self.cacheKey(location)
        if let cached = Self.placeCache[key] {
            metadata.place = cached
            return metadata
        }
        let place = await CoarsePlaceRequest().resolve(location)
        guard !Task.isCancelled,
              let current = localContext(for: metadata.identifier),
              current.modifiedAt == metadata.modifiedAt, current.capturedAt == metadata.capturedAt,
              current.location?.coordinate.latitude == location.coordinate.latitude,
              current.location?.coordinate.longitude == location.coordinate.longitude else { return nil }
        if let place {
            if Self.placeCache[key] == nil {
                if Self.cachedKeys.count >= 64 { Self.placeCache.removeValue(forKey: Self.cachedKeys.removeFirst()) }
                Self.cachedKeys.append(key)
            }
            Self.placeCache[key] = place
            metadata.place = place
        }
        return metadata
    }

    func locationName(for localIdentifier: String?) async -> String? {
        await context(for: localIdentifier)?.place
    }

    private static var hasPhotoAccess: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }

    private static func cacheKey(_ location: CLLocation) -> String {
        "\(Int((location.coordinate.latitude * 1_000).rounded())):\(Int((location.coordinate.longitude * 1_000).rounded()))"
    }
}

/// A bounded, cancellable lookup of the photo's stored coordinates, not the device's current location.
@MainActor
private final class CoarsePlaceRequest {
    private let geocoder = CLGeocoder()
    private var continuation: CheckedContinuation<String?, Never>?
    private var timeout: Task<Void, Never>?
    private var finished = false

    func resolve(_ location: CLLocation) async -> String? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !finished, !Task.isCancelled else { continuation.resume(returning: nil); return }
                self.continuation = continuation
                geocoder.reverseGeocodeLocation(location, preferredLocale: .current) { [weak self] placemarks, _ in
                    let placemark = placemarks?.first
                    let place = PhotoContextFormatter.placeText(locality: placemark?.locality,
                        subLocality: placemark?.subLocality, subAdministrativeArea: placemark?.subAdministrativeArea,
                        administrativeArea: placemark?.administrativeArea, country: placemark?.country)
                    Task { @MainActor [weak self] in self?.finish(place) }
                }
                timeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                    self?.finish(nil)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(nil) }
        }
    }

    private func finish(_ place: String?) {
        guard !finished else { return }
        finished = true
        timeout?.cancel()
        timeout = nil
        geocoder.cancelGeocode()
        let pending = continuation
        continuation = nil
        pending?.resume(returning: place)
    }
}

/// Rules intentionally prefer missed candidates over unsupported deletion suggestions.
/// Thresholds are conservative starting values, not a calibrated probability of safe deletion.
struct PhotoCurationPolicy {
    struct Photo {
        let id: String
        let date: Date?
        let width: Int
        let height: Int
        var isFavorite = false
        var isProtected = false
        var isExcluded = false
        var quality: Double = 0

        var canRemove: Bool { !isFavorite && !isProtected && !isExcluded }
    }

    struct Pair: Equatable {
        let candidateID: String
        let referenceID: String
    }

    static func canCompare(_ lhs: Photo, _ rhs: Photo) -> Bool {
        guard lhs.id != rhs.id, !lhs.isExcluded, !rhs.isExcluded,
              let leftDate = lhs.date, let rightDate = rhs.date,
              lhs.width > 0, lhs.height > 0,
              lhs.width == rhs.width, lhs.height == rhs.height else { return false }
        return abs(leftDate.timeIntervalSince(rightDate)) <= 30
    }

    static func accepts(distance: Float?, meanDifference: Double, largestTileDifference: Double, detail: Double) -> Bool {
        guard let distance, distance.isFinite, distance >= 0,
              meanDifference.isFinite, meanDifference >= 0,
              largestTileDifference.isFinite, largestTileDifference >= 0,
              detail.isFinite else { return false }
        // Vision revision 1 only. Pixel checks reject broad semantic matches and local changes.
        return distance <= 6 && meanDifference <= 0.035
            && largestTileDifference <= 0.12 && detail >= 0.004
    }

    static func selectPairs(
        from photos: [Photo], limit: Int,
        requiresNearbyCapture: Bool = true,
        matches: (Photo, Photo) -> Bool
    ) -> [Pair] {
        guard limit > 0 else { return [] }
        let ordered = photos.filter { !$0.isExcluded }.sorted {
            if $0.canRemove != $1.canRemove { return !$0.canRemove }
            if $0.quality != $1.quality { return $0.quality > $1.quality }
            return $0.id < $1.id
        }
        var removed = Set<String>()
        var references = Set<String>()
        var result: [Pair] = []
        for (index, reference) in ordered.enumerated() where !removed.contains(reference.id) {
            for candidate in ordered.dropFirst(index + 1) {
                guard candidate.canRemove, !removed.contains(candidate.id),
                      !references.contains(candidate.id),
                      (!requiresNearbyCapture || canCompare(candidate, reference)),
                      matches(candidate, reference) else { continue }
                result.append(Pair(candidateID: candidate.id, referenceID: reference.id))
                removed.insert(candidate.id)
                references.insert(reference.id)
                if result.count == limit { return result }
            }
        }
        return result
    }
}

/// One verified reason per new Home card. File-identical photos and screenshots
/// share the same rationale. The existing single context-review limit also applies.
enum CleanupReasonGroup: Hashable {
    case identicalFile, similarCapture, contextReview

    init?(_ reason: CurationReasonCode?) {
        switch reason {
        case .exactDuplicate, .duplicateScreenshot: self = .identicalFile
        case .visuallySimilar: self = .similarCapture
        case .expiredScreen, .temporaryReference, .shoppingScreen, .lowDetail, .reviewDateReached: self = .contextReview
        default: return nil
        }
    }
}

/// Filled reasons must not spend the remaining nomination budget or reserve a
/// photo before the still-needed evidence can be considered.
struct CurationEvidenceDemand {
    let excluding: Set<CleanupReasonGroup>

    func originalIdentifiers(_ candidates: () -> Set<String>) -> Set<String> {
        guard !excluding.contains(.identicalFile) || !excluding.contains(.similarCapture) else { return [] }
        return candidates()
    }

    func collect(limit: Int, pairsOnly: Bool,
                 pairs: (CleanupReasonGroup, Int, Set<String>) -> [DecisionUnit],
                 context: (Set<String>) -> DecisionUnit?) -> [DecisionUnit] {
        guard limit > 0 else { return [] }
        var decisions: [DecisionUnit] = []
        var reserved = Set<String>()
        for group in [CleanupReasonGroup.identicalFile, .similarCapture] where !excluding.contains(group) {
            guard decisions.count < limit else { break }
            let additions = pairs(group, limit - decisions.count, reserved)
            decisions += additions
            reserved.formUnion(additions.flatMap(\.removalIdentifiers))
            reserved.formUnion(additions.compactMap(\.comparisonLocalIdentifier))
        }
        if !pairsOnly, !excluding.contains(.contextReview), decisions.count < limit,
           let review = context(reserved) { decisions.append(review) }
        return decisions
    }
}

/// Two missing kinds of proof share the bounded foreground work. Giving OCR
/// every first turn can exhaust each slice before any original-file comparison.
struct CurationMissingReasonSchedule {
    private var contextNext = true

    mutating func prioritizesContext(excluding groups: Set<CleanupReasonGroup>) -> Bool {
        guard groups.contains(.similarCapture), !groups.contains(.contextReview) else { return false }
        guard !groups.contains(.identicalFile) else { return true }
        defer { contextNext.toggle() }
        return contextNext
    }
}

protocol PhotoCurationServing {
    var cloudPhotoCount: Int { get }
    func allowCloudPhotoAccess()
    func retainRecommendationProofs(for identifiers: Set<String>)
    func resetScan() async
    func hasUnscannedPhotos(excluding: Set<String>) async -> Bool
    func fetchNextBatch(excluding: Set<String>, protectedIdentifiers: Set<String>, reviewDates: [String: Date],
                        limit: Int, firstResult: Bool, excludingReasonGroups: Set<CleanupReasonGroup>,
                        onProgress: (@Sendable (PhotoCurationService.ScanProgress) -> Void)?) async -> PhotoCurationService.ScanBatch
    func fetchReflectionPhotos(excluding: Set<String>, reviewDates: [String: Date], limit: Int) async -> [DecisionUnit]
    func restoreDecisions(localIdentifiers: [String], references: [String: String], reasons: [String: CurationReasonCode],
                          protectedIdentifiers: Set<String>, reviewDates: [String: Date]) async -> PhotoCurationService.RestoredDecisions
    func restoreCachedDecisions(localIdentifiers: [String], references: [String: String], reasons: [String: CurationReasonCode],
                               protectedIdentifiers: Set<String>, reviewDates: [String: Date]) async -> PhotoCurationService.RestoredDecisions?
    func fetchSimilarPhotoDecision(scanLimit: Int, protectedIdentifiers: Set<String>, reviewDates: [String: Date]) async -> DecisionUnit?
}

extension PhotoCurationServing {
    var cloudPhotoCount: Int { 0 }
    func allowCloudPhotoAccess() {}
    func retainRecommendationProofs(for identifiers: Set<String>) {}
    func restoreCachedDecisions(localIdentifiers: [String], references: [String: String], reasons: [String: CurationReasonCode],
                               protectedIdentifiers: Set<String>, reviewDates: [String: Date]) async -> PhotoCurationService.RestoredDecisions? { nil }
    func fetchReflectionPhotos(excluding: Set<String>, reviewDates: [String: Date], limit: Int) async -> [DecisionUnit] { [] }
}

/// Consent is tied to an exact asset revision, not the whole library. PhotoKit
/// may require the network again after relaunch even after an earlier read.
/// Store permission only; never persist original bytes, thumbnails or OCR here.
final class PhotoCloudAccess {
    static let shared = PhotoCloudAccess()
    static let storageKey = "recoco_photo_cloud_access_v1"
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var pending: [String: String] = [:]

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func revision(for asset: PHAsset) -> String {
        "\(asset.modificationDate?.timeIntervalSince1970 ?? 0):\(asset.pixelWidth):\(asset.pixelHeight):\(asset.hasAdjustments)"
    }

    func allows(id: String, revision: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return (defaults.dictionary(forKey: Self.storageKey) as? [String: String])?[id] == revision
    }

    func noteCloudFailure(id: String, revision: String) {
        lock.lock(); defer { lock.unlock() }
        // Analysis windows are bounded; retain only a bounded list of failed IDs.
        if pending.count < 64 || pending[id] != nil { pending[id] = revision }
    }

    func resolved(id: String) {
        lock.lock(); defer { lock.unlock() }
        pending.removeValue(forKey: id)
    }

    var pendingRevisions: [String: String] {
        lock.lock(); defer { lock.unlock() }; return pending
    }

    func approve(_ currentRevisions: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        var approved = defaults.dictionary(forKey: Self.storageKey) as? [String: String] ?? [:]
        let eligible = currentRevisions.filter { pending[$0.key] == $0.value }
        guard !eligible.isEmpty else { return }
        // Avoid an unbounded authorization history. Removed entries require a new choice.
        if approved.count + eligible.count > 128 { approved = [:] }
        approved.merge(eligible) { _, new in new }
        defaults.set(approved, forKey: Self.storageKey)
    }

    func observe(_ info: [AnyHashable: Any]?, asset: PHAsset, succeeded: Bool) {
        if succeeded { resolved(id: asset.localIdentifier); return }
        let error = info?[PHImageErrorKey] as? NSError
        if (error?.domain == PHPhotosErrorDomain && error?.code == PHPhotosError.Code.networkAccessRequired.rawValue)
            || info?[PHImageResultIsInCloudKey] as? Bool == true {
            noteCloudFailure(id: asset.localIdentifier, revision: Self.revision(for: asset))
        }
    }
}

/// A small, bounded preparation queue. Only its caller publishes results
/// into the analysis cache; canceled or late workers cannot publish anything.
final class CurationConcurrentPreparation<Value> {
    final class Cancellation {
        private let lock = NSLock()
        private var stopped = false
        private var handler: (() -> Void)?
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
        func setHandler(_ action: @escaping () -> Void) {
            lock.lock()
            if stopped { lock.unlock(); action() }
            else { handler = action; lock.unlock() }
        }
        func cancel() {
            lock.lock(); stopped = true; let action = handler; handler = nil; lock.unlock()
            action?()
        }
    }
    struct Snapshot {
        let values: [Int: Value]
        let completed: Set<Int>
    }
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private let queue: OperationQueue
    private let cancellation = Cancellation()
    private let count: Int
    private var values: [Int: Value] = [:]
    private var completed = Set<Int>()

    init(count: Int, concurrency: Int = 4, maximumConcurrency: Int = 4,
         deadline: PhotoCurationService.AnalysisDeadline,
         itemTimeout: TimeInterval,
         work: @escaping (Int, PhotoCurationService.AnalysisDeadline, Cancellation) -> Value?) {
        self.count = max(0, count)
        queue = OperationQueue()
        queue.maxConcurrentOperationCount = min(min(12, max(1, maximumConcurrency)), max(1, concurrency))
        queue.qualityOfService = .userInitiated
        for index in 0..<self.count {
            queue.addOperation { [self] in
                guard !cancellation.isCancelled, !deadline.expired else { finish(index, value: nil); return }
                let itemDeadline = PhotoCurationService.AnalysisDeadline(seconds: min(itemTimeout, deadline.remaining))
                let value = autoreleasepool { work(index, itemDeadline, cancellation) }
                finish(index, value: value)
            }
        }
    }

    private func finish(_ index: Int, value: Value?) {
        lock.lock()
        if !cancellation.isCancelled {
            if let value { values[index] = value }
            completed.insert(index)
        }
        lock.unlock()
        signal.signal()
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(values: values, completed: completed)
    }

    func discardValues(at indices: Set<Int>) {
        lock.lock(); defer { lock.unlock() }
        for index in indices { values.removeValue(forKey: index) }
    }

    @discardableResult
    func wait(until deadline: PhotoCurationService.AnalysisDeadline, forAll: Bool) -> Snapshot {
        while !Task.isCancelled, !cancellation.isCancelled, !deadline.expired {
            let current = snapshot()
            if current.completed.count == count || (!forAll && !current.values.isEmpty) { return current }
            _ = signal.wait(timeout: .now() + min(0.02, deadline.remaining))
        }
        if Task.isCancelled { cancel() }
        return snapshot()
    }

    /// Wait only for unconsumed inputs. An earlier ready image must not make a
    /// later waiter start a second PhotoKit request for an image still loading.
    @discardableResult
    func wait(until deadline: PhotoCurationService.AnalysisDeadline, forAnyOf indices: Set<Int>) -> Snapshot {
        let requested = indices.intersection(0..<count)
        while !Task.isCancelled, !cancellation.isCancelled, !deadline.expired {
            let current = snapshot()
            if requested.isSubset(of: current.completed)
                || requested.contains(where: { current.values[$0] != nil }) { return current }
            _ = signal.wait(timeout: .now() + min(0.02, deadline.remaining))
        }
        if Task.isCancelled { cancel() }
        return snapshot()
    }

    func cancel() {
        cancellation.cancel()
        queue.cancelAllOperations()
        signal.signal()
    }
}

/// Separate image I/O from image analysis. A cloud read occupies a bounded I/O
/// slot, but must not hold the CPU slot needed by a different, already-local
/// photo. All windows share these limits and the caller's existing deadline.
final class CurationWorkGate {
    private let permits: DispatchSemaphore
    init(limit: Int) { permits = DispatchSemaphore(value: max(1, limit)) }

    func perform<Value>(until deadline: PhotoCurationService.AnalysisDeadline,
                        cancelled: () -> Bool, work: () -> Value?) -> Value? {
        while !Task.isCancelled, !cancelled(), !deadline.expired {
            if permits.wait(timeout: .now() + min(0.02, deadline.remaining)) == .success {
                defer { permits.signal() }
                guard !Task.isCancelled, !cancelled(), !deadline.expired else { return nil }
                return work()
            }
        }
        return nil
    }
}

/// Run a bounded preparation once. Real feature work waits for this single
/// owner, so two cold model loads never compete for the same device resources.
final class CurationOncePreparation {
    private let condition = NSCondition()
    private var started = false
    private var finished = false
    private let cancellation = CurationConcurrentPreparation<Bool>.Cancellation()

    func start(_ work: @escaping (PhotoCurationService.AnalysisDeadline,
                                 CurationConcurrentPreparation<Bool>.Cancellation) -> Void) {
        condition.lock()
        guard !started else { condition.unlock(); return }
        started = true; condition.unlock()
        let deadline = PhotoCurationService.AnalysisDeadline(seconds: 8)
        DispatchQueue.global(qos: .utility).async { [self] in
            if !cancellation.isCancelled, !deadline.expired { work(deadline, cancellation) }
            condition.lock(); finished = true; condition.broadcast(); condition.unlock()
        }
    }

    func awaitCompletion(until deadline: PhotoCurationService.AnalysisDeadline) -> Bool {
        condition.lock()
        while started && !finished {
            if Task.isCancelled || deadline.expired {
                // This waiter's short slice does not own the shared model
                // load. Canceling it made every following photo start cold.
                condition.unlock(); return false
            }
            _ = condition.wait(until: Date().addingTimeInterval(min(0.02, deadline.remaining)))
        }
        condition.unlock()
        return !Task.isCancelled && !deadline.expired
    }

    func cancel() {
        condition.lock(); let shouldCancel = started && !finished; condition.unlock()
        if shouldCancel { cancellation.cancel() }
    }
}

/// A bounded read survives a shorter presentation slice. Workers only produce
/// values; the next owner rechecks current revisions before publishing them.
final class CurationWindowPreparation<R: Equatable, Value> {
    let identifiers: [String]
    let revisions: [String: R]
    let inputs: [Value]
    let pool: CurationConcurrentPreparation<Value>
    var consumed = Set<Int>()
    init(identifiers: [String], revisions: [String: R], inputs: [Value],
         pool: CurationConcurrentPreparation<Value>) {
        self.identifiers = identifiers; self.revisions = revisions
        self.inputs = inputs; self.pool = pool
    }
    var hasReadyResult: Bool { !pool.snapshot().values.isEmpty }
    var isFinished: Bool { pool.snapshot().completed.count == identifiers.count }
    deinit { pool.cancel() }
}

/// One analysis window in memory. Preview evidence remains usable across small
/// passes when the full-file read still needs retry; it never counts as scanned.
final class CurationAnalysisMemory<R: Equatable, Value> {
    typealias Revision = R
    struct Entry {
        let revision: R
        let analysis: Value
    }
    private(set) var entries: [String: Entry] = [:]
    private(set) var partials: [String: Entry] = [:]
    private(set) var failures: [String: R] = [:]
    private(set) var deferredPreviews: [String: R] = [:]
    private(set) var workRevision: UInt64 = 0
    private var enrichmentAttempts: [String: (revision: R, sequence: UInt64)] = [:]
    private var enrichmentSequence: UInt64 = 0
    var preparation: CurationWindowPreparation<R, Value>?
    var enrichmentAttemptRevision: UInt64 { enrichmentSequence }
    func enrichmentAttemptOrder(for id: String) -> UInt64? { enrichmentAttempts[id]?.sequence }

    var analyses: [String: Value] {
        partials.mapValues(\.analysis).merging(entries.mapValues(\.analysis)) { _, complete in complete }
    }

    func retain(revisions: [String: R]) {
        if let preparation, !preparation.identifiers.contains(where: {
            revisions[$0] == preparation.revisions[$0]
        }) { preparation.pool.cancel(); self.preparation = nil }
        entries = entries.filter { revisions[$0.key] == $0.value.revision }
        partials = partials.filter { revisions[$0.key] == $0.value.revision }
        failures = failures.filter { revisions[$0.key] == $0.value }
        deferredPreviews = deferredPreviews.filter { revisions[$0.key] == $0.value }
        enrichmentAttempts = enrichmentAttempts.filter { revisions[$0.key] == $0.value.revision }
    }

    func enrichmentOrder(among identifiers: [String], priority: Set<String>) -> [String] {
        identifiers.enumerated().sorted { lhs, rhs in
            let left = enrichmentAttempts[lhs.element], right = enrichmentAttempts[rhs.element]
            // A timed-out item cannot repeatedly preempt an untouched peer or
            // context nominee. Within each turn, real pair work remains first.
            if (left == nil) != (right == nil) { return left == nil }
            if let left, let right, left.sequence != right.sequence { return left.sequence < right.sequence }
            if priority.contains(lhs.element) != priority.contains(rhs.element) { return priority.contains(lhs.element) }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    func noteEnrichmentAttempt(for id: String, revision: R) {
        enrichmentSequence &+= 1
        enrichmentAttempts[id] = (revision, enrichmentSequence)
    }

    func nextPreviewWork(among identifiers: [String], hasPendingEnrichment: Bool = false) -> (identifiers: [String], allowsNetwork: Bool) {
        let available = analyses
        let local = identifiers.filter {
            available[$0] == nil && failures[$0] == nil && deferredPreviews[$0] == nil
        }
        if !local.isEmpty { return (local, false) }
        // Pending OCR can delay speculative network recovery, never new local
        // photos. Explicit recovery turns bypass this ordinary work selector.
        if hasPendingEnrichment { return ([], false) }
        return (identifiers.filter { deferredPreviews[$0] != nil }, true)
    }

    func deferPreview(for id: String, revision: R) {
        if deferredPreviews[id] != revision { workRevision &+= 1 }
        deferredPreviews[id] = revision
    }

    func record(_ analysis: Value?, for id: String, revision: R, complete: Bool, failed: Bool = true,
                advancesWork: Bool = true) {
        // Repeated nil facts or reloading an identical preview is not progress.
        // Keep updated retry scheduling without extending Home's useful-work budget.
        if advancesWork && (analysis != nil || failures[id] != revision || entries[id] != nil || partials[id] != nil) {
            workRevision &+= 1
        }
        entries.removeValue(forKey: id)
        partials.removeValue(forKey: id)
        deferredPreviews.removeValue(forKey: id)
        guard let analysis else { failures[id] = revision; return }
        let entry = Entry(revision: revision, analysis: analysis)
        if complete {
            entries[id] = entry
            failures.removeValue(forKey: id)
        } else {
            partials[id] = entry
            if failed { failures[id] = revision }
            else { failures.removeValue(forKey: id) }
        }
    }

    func transformAnalyses(_ transform: (Value) -> Value) {
        entries = entries.mapValues { Entry(revision: $0.revision, analysis: transform($0.analysis)) }
        partials = partials.mapValues { Entry(revision: $0.revision, analysis: transform($0.analysis)) }
    }

    func reset() {
        preparation?.pool.cancel(); preparation = nil
        entries.removeAll(); partials.removeAll(); failures.removeAll(); deferredPreviews.removeAll()
        enrichmentAttempts.removeAll(); enrichmentSequence = 0
    }
}

/// Semantic evidence state excludes request counts and retained image bytes.
/// Repeating the same unfinished OCR cannot masquerade as newly analyzed data.
struct CurationAnalysisWorkState: Equatable {
    var fullPreview = false
    var hasFeature = false
    var fingerprint: String? = nil
    var textLines: [String]? = nil
    var confidentTextLines: [String] = []
    var hasFace: Bool? = nil
    var detail: Double? = nil
    var luminanceRange: Double? = nil
    var originalStage = 0
    var enrichmentAttempted = false
    var needsRetry = true
    var contextDeferred = false
}

/// Per-window revisions are local counters; Home observes this session counter.
/// Merely rotating/repeating a deferred window cannot manufacture progress.
struct CurationWorkProgress {
    private(set) var value: UInt64 = 0
    mutating func record(before: UInt64, after: UInt64, consumed: Int = 0) {
        if after > before { value &+= after - before }
        value &+= UInt64(max(0, consumed))
    }
}

/// Bounded unfinished comparison windows. Parking is not scan coverage: no
/// identifier becomes visited, and eviction only forfeits cached work.
struct CurationParkedWindows<Value> {
    struct Window { let identifiers: [String]; let value: Value }
    struct WorkSelection {
        let parked: Window?
        let recovery: CurationPreviewRecoverySchedule.Turn?
    }
    private(set) var windows: [Window] = []
    // Eviction discards only cached analysis. Coherent peer identifiers remain
    // queued so a small library cannot appear exhausted after three windows.
    private(set) var evictedIdentifiers: [[String]] = []
    var hasPendingWork: Bool { !windows.isEmpty || !evictedIdentifiers.isEmpty }
    private(set) var freshTurns = 0
    private var residentTurnsSinceRestoration = 0
    private var priorityIdentifiers: Set<String>?
    private var productiveBypassedDueRecovery = false
    let capacity: Int
    init(capacity: Int = 3) { self.capacity = max(1, capacity) }

    mutating func park(identifiers: [String], value: Value, freshTurn: Bool, productive: Bool = false) {
        guard !identifiers.isEmpty else { return }
        let ids = Set(identifiers)
        windows.removeAll { Set($0.identifiers) == ids }
        evictedIdentifiers.removeAll { Set($0) == ids }
        windows.append(Window(identifiers: identifiers, value: value))
        if productive { priorityIdentifiers = ids }
        while windows.count > capacity {
            let evicted = windows.removeFirst().identifiers
            if !evictedIdentifiers.contains(where: { Set($0) == Set(evicted) }) {
                evictedIdentifiers.append(evicted)
            }
        }
        if freshTurn { freshTurns += 1 }
    }

    mutating func take(eligible: Set<String>, freshAvailable: Bool, freshPassesBeforeRetry: Int = 2,
                       restoring: (() -> Value)? = nil) -> Window? {
        windows.removeAll { eligible.isDisjoint(with: $0.identifiers) }
        evictedIdentifiers.removeAll { eligible.isDisjoint(with: $0) }
        if let priorityIdentifiers,
           let index = windows.firstIndex(where: { Set($0.identifiers) == priorityIdentifiers }) {
            self.priorityIdentifiers = nil
            residentTurnsSinceRestoration += 1
            return windows.remove(at: index)
        }
        priorityIdentifiers = nil
        guard hasPendingWork, !freshAvailable || freshTurns >= max(1, freshPassesBeforeRetry) else { return nil }
        freshTurns = 0
        // Repeatedly timing out and re-parking resident windows must not starve
        // metadata-only work. Restore the oldest evicted peer window at least
        // every third ordinary parked turn; publishing a verified result keeps
        // its immediate productive continuation above this fairness boundary.
        if let restoring, !evictedIdentifiers.isEmpty,
           windows.isEmpty || residentTurnsSinceRestoration >= 2 {
            residentTurnsSinceRestoration = 0
            return Window(identifiers: evictedIdentifiers.removeFirst(), value: restoring())
        }
        guard !windows.isEmpty else { return nil }
        residentTurnsSinceRestoration += 1
        return windows.removeFirst()
    }

    /// Choose between the two retry queues in one place. An always-present
    /// parked OCR window must not hide the bounded preview-recovery turn.
    mutating func selectWork(eligible: Set<String>, freshAvailable: Bool,
        recoveryEligible: Set<String>, recoverySchedule: inout CurationPreviewRecoverySchedule,
        freshPassesBeforeRetry: Int = 2, preferFreshReason: Bool = false,
        ready: (Value) -> Bool = { _ in false },
        restoring: (() -> Value)? = nil) -> WorkSelection {
        // A newly filled reason changes what we are looking for. Give the
        // missing-reason nomination its first turn before continuing the old
        // productive window. Neither its facts nor a due recovery are removed.
        if preferFreshReason && freshAvailable {
            return WorkSelection(parked: nil, recovery: nil)
        }
        if let index = windows.firstIndex(where: {
            !eligible.isDisjoint(with: $0.identifiers) && ready($0.value)
        }) {
            if priorityIdentifiers == Set(windows[index].identifiers) { priorityIdentifiers = nil }
            return WorkSelection(parked: windows.remove(at: index), recovery: nil)
        }
        let recovery = recoverySchedule.next(eligible: recoveryEligible, localWorkAvailable: freshAvailable,
            minimumLocalPasses: freshPassesBeforeRetry)
        let productiveReady = priorityIdentifiers.map { priority in
            windows.contains { Set($0.identifiers) == priority && !eligible.isDisjoint(with: $0.identifiers) }
        } ?? false
        if let recovery {
            // A newly proven pair gets one immediate continuation. Even if it
            // publishes another result and re-parks productively, the already
            // due missing peer receives the following bounded recovery turn.
            if productiveReady && !productiveBypassedDueRecovery {
                productiveBypassedDueRecovery = true
                return WorkSelection(parked: take(eligible: eligible, freshAvailable: freshAvailable,
                    freshPassesBeforeRetry: freshPassesBeforeRetry, restoring: restoring), recovery: nil)
            }
            return WorkSelection(parked: nil, recovery: recovery)
        }
        productiveBypassedDueRecovery = false
        return WorkSelection(parked: take(eligible: eligible, freshAvailable: freshAvailable,
            freshPassesBeforeRetry: freshPassesBeforeRetry, restoring: restoring), recovery: nil)
    }

    mutating func takeMatching(_ identifiers: [String]) -> Value? {
        let ids = Set(identifiers)
        evictedIdentifiers.removeAll { Set($0) == ids }
        guard let index = windows.firstIndex(where: { Set($0.identifiers) == ids }) else { return nil }
        residentTurnsSinceRestoration += 1
        return windows.remove(at: index).value
    }
}

/// Give deferred previews a bounded turn even while fresh library rows remain.
/// Windows retain comparison peers; each failed preview gets one interleaved
/// attempt per scan session, rather than blocking every following local read.
struct CurationPreviewRecoverySchedule {
    struct Turn: Equatable {
        let identifier: String
        let window: [String]
    }
    private struct Group {
        let window: [String]
        var pending: [String]
    }
    private var groups: [Group] = []
    private var registered = Set<String>()
    private var attempted = Set<String>()
    private(set) var localPasses = 0

    mutating func noteLocalProgress() { localPasses += 1 }

    mutating func register(window: [String], missing: Set<String>) {
        let added = window.filter { missing.contains($0) && !registered.contains($0) && !attempted.contains($0) }
        guard !added.isEmpty else { return }
        if let index = groups.firstIndex(where: { $0.window == window }) {
            groups[index].pending += added
        } else { groups.append(Group(window: window, pending: added)) }
        registered.formUnion(added)
    }

    mutating func next(eligible: Set<String>, localWorkAvailable: Bool, minimumLocalPasses: Int = 2) -> Turn? {
        for index in groups.indices {
            groups[index].pending.removeAll { !eligible.contains($0) }
        }
        groups.removeAll { $0.pending.isEmpty }
        registered = Set(groups.flatMap(\.pending))
        guard localPasses >= max(1, minimumLocalPasses) || !localWorkAvailable,
              let first = groups.first, let identifier = first.pending.first else { return nil }
        // Taking a turn is non-destructive. Cancellation before completing the
        // request leaves the same candidate available on the next foreground visit.
        return Turn(identifier: identifier, window: first.window)
    }

    mutating func finished(_ turn: Turn) {
        attempted.insert(turn.identifier); registered.remove(turn.identifier)
        for index in groups.indices { groups[index].pending.removeAll { $0 == turn.identifier } }
        groups.removeAll { $0.pending.isEmpty }
        // Round-robin windows instead of downloading every missing image from
        // one cloud-heavy window before another comparison gets an opportunity.
        if let index = groups.firstIndex(where: { $0.window == turn.window }) {
            let group = groups.remove(at: index); groups.append(group)
        }
        localPasses = 0
    }
}

/// Bounded device-only evidence cache. The caller supplies a current PhotoKit
/// revision; neither a cache hit nor a persisted identifier grants photo access.
/// Each proof is a separate atomic file so reading six candidates never decodes
/// the entire library. The analysis-proof instance stores no image bytes.
final class CurationDiskProofCache<Value: Codable> {
    private struct ProjectedEnvelope<Projection: Decodable>: Decodable {
        let version: Int
        let revision: String
        let value: Projection
    }
    private struct Envelope: Codable {
        let version: Int
        let revision: String
        let value: Value
    }
    private let directory: URL
    private let version: Int
    private let capacity: Int
    private let lock = NSLock()
    private var retainedFileNames = Set<String>()

    init(directory: URL, version: Int, capacity: Int = 256) {
        self.directory = directory; self.version = version; self.capacity = max(1, capacity)
    }

    /// Keep the small displayed/prepared queue inside the existing capacity.
    /// This is eviction priority only: every read still checks version/revision.
    /// Home re-establishes the set before restoring after each process launch.
    func retainIdentifiers(_ identifiers: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        retainedFileNames = Set(identifiers.filter { !$0.isEmpty }.sorted()
            .prefix(min(capacity, 24)).map { location($0).lastPathComponent })
    }

    private func location(_ identifier: String) -> URL {
        let name = SHA256.hash(data: Data(identifier.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".proof")
    }

    func value(for identifier: String, revision: String) -> Value? {
        lock.lock(); defer { lock.unlock() }
        guard !revision.isEmpty, let data = try? Data(contentsOf: location(identifier)),
              let entry = try? PropertyListDecoder().decode(Envelope.self, from: data),
              entry.version == version, entry.revision == revision else { return nil }
        return entry.value
    }

    func removeValue(for identifier: String) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: location(identifier))
    }

    func removeValues(olderThan cutoff: Date) {
        lock.lock(); defer { lock.unlock() }
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files where file.pathExtension == "proof" {
            if let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               modified < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// Read only the small fields needed to order future work. Callers must
    /// still re-resolve asset access and validate its current complete proof.
    func projectedValues<Projection: Decodable>(as type: Projection.Type) -> [(revision: String, value: Projection)] {
        lock.lock(); defer { lock.unlock() }
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "proof" }.prefix(capacity).compactMap { file in
            guard !Task.isCancelled, let data = try? Data(contentsOf: file),
                  let entry = try? PropertyListDecoder().decode(ProjectedEnvelope<Projection>.self, from: data),
                  entry.version == version else { return nil }
            return (revision: entry.revision, value: entry.value)
        }
    }

    func store(_ value: Value, for identifier: String, revision: String) {
        guard !Task.isCancelled, !identifier.isEmpty, !revision.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
            let data = try encoder.encode(Envelope(version: version, revision: revision, value: value))
            try data.write(to: location(identifier), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var excluded = directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try? excluded.setResourceValues(values)
            let files = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { $0.pathExtension == "proof" }
            if files.count > capacity {
                let oldest = files.filter { !retainedFileNames.contains($0.lastPathComponent) }.sorted {
                    let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return lhs < rhs
                }
                for file in oldest.prefix(files.count - capacity) { try? FileManager.default.removeItem(at: file) }
            }
        } catch { /* Eviction, a locked device or a full disk falls back to live analysis. */ }
    }
}

struct PhotoCurationService: PhotoCurationServing {
    private var accessibleCloudRevisions: [String: String] {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return [:] }
        let pending = PhotoCloudAccess.shared.pendingRevisions
        guard !pending.isEmpty else { return [:] }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(pending.keys), options: nil)
        var current: [String: String] = [:]
        assets.enumerateObjects { asset, _, _ in
            let revision = PhotoCloudAccess.revision(for: asset)
            if pending[asset.localIdentifier] == revision { current[asset.localIdentifier] = revision }
        }
        return current
    }
    var cloudPhotoCount: Int { accessibleCloudRevisions.count }
    func allowCloudPhotoAccess() { PhotoCloudAccess.shared.approve(accessibleCloudRevisions) }

    static let curationVersion = 6
    private let scanSession: ScanSession
    private let usePersistentProofs: Bool

    init(usePersistentProofs: Bool = true) {
        self.usePersistentProofs = usePersistentProofs
        self.scanSession = ScanSession(usePersistentProofs: usePersistentProofs)
    }

    func retainRecommendationProofs(for identifiers: Set<String>) {
        guard usePersistentProofs else { return }
        Self.proofCache.retainIdentifiers(identifiers)
    }

    struct CandidateMetadata: Equatable {
        let localIdentifier: String
        let creationDate: Date
        let burstIdentifier: String?
    }

    struct ImageMetrics: Codable {
        let sharpness: Double
        let exposure: Double
        let colors: [Double]
        var luminanceRange: Double = 1
    }

    struct PairPreparationCandidate {
        let identifiers: [String]
        let attemptOrders: [UInt64?]
        let visualDifference: Double
        var localPreviewCount: Int = 0
    }

    /// Nomination order only: it never changes the full-image acceptance rules.
    /// Try untouched promising pairs before paying for a less similar neighbour;
    /// timed-out work keeps its fair retry turn instead of monopolizing the pass.
    static func preferredPreparationPair(_ candidates: [PairPreparationCandidate]) -> [String] {
        candidates.enumerated().filter { $0.element.visualDifference.isFinite }
            .min { lhs, rhs in
                let l = lhs.element, r = rhs.element
                if l.localPreviewCount != r.localPreviewCount { return l.localPreviewCount > r.localPreviewCount }
                let la = l.attemptOrders.compactMap { $0 }, ra = r.attemptOrders.compactMap { $0 }
                if la.count != ra.count { return la.count < ra.count }
                if let lv = la.max(), let rv = ra.max(), lv != rv { return lv < rv }
                if l.visualDifference != r.visualDifference { return l.visualDifference < r.visualDifference }
                return lhs.offset < rhs.offset
            }?.element.identifiers ?? []
    }

    /// A rejected first comparison must not leave the next pair or screen
    /// waiting for a new serial image request. Keep two small waves ready;
    /// the worker pool still permits only four simultaneous reads.
    static func fullPreparationIdentifiers(pairs: [PairPreparationCandidate], context: [String],
                                           alreadyPrepared: Set<String> = [], limit: Int = 8) -> [String] {
        let bound = min(12, max(0, limit))
        var remainingPairs = pairs
        var remainingContext = context
        var result: [String] = []
        var seen = alreadyPrepared
        var contextOpportunityGiven = false
        while result.count < bound {
            let pair = preferredPreparationPair(remainingPairs)
            guard !pair.isEmpty || !remainingContext.isEmpty else { break }
            // Never start only one member of a newly nominated comparison.
            let missing = pair.filter { !seen.contains($0) }
            if !missing.isEmpty, missing.count <= bound - result.count {
                for id in missing where seen.insert(id).inserted { result.append(id) }
            }
            remainingPairs.removeAll { $0.identifiers.allSatisfy { seen.contains($0) }
                || $0.identifiers == pair || !$0.visualDifference.isFinite }
            // Keep two context reads in the first wave, then finish other
            // nominated pairs before filling spare slots with more context.
            let contextSlots = !contextOpportunityGiven || remainingPairs.isEmpty ? 2 : 0
            contextOpportunityGiven = true
            for _ in 0..<contextSlots where result.count < bound && !remainingContext.isEmpty {
                let id = remainingContext.removeFirst()
                if seen.insert(id).inserted { result.append(id) }
            }
        }
        return result
    }

    /// A shared monotonic deadline covers reads as well as the gaps between photos.
    /// The original-photo path must never restart its own 30-second allowance.
    struct AnalysisDeadline {
        let expiresAt: TimeInterval
        init(seconds: TimeInterval) {
            expiresAt = ProcessInfo.processInfo.systemUptime + max(0, seconds)
        }
        var remaining: TimeInterval { max(0, expiresAt - ProcessInfo.processInfo.systemUptime) }
        var expired: Bool { remaining <= 0 }
        func readTimeout(maximum: TimeInterval) -> TimeInterval { min(maximum, remaining) }
    }

    enum OriginalAnalysisState {
        case notRequested, awaitingFullBudget, resolved, unavailable
        func permitsCompletedPreview(originalRequired: Bool) -> Bool {
            !originalRequired || self == .resolved
        }
    }

    private struct AnalyzedAsset {
        let asset: PHAsset
        var photo: PhotoCurationPolicy.Photo
        let featurePrint: VNFeaturePrintObservation?
        let metrics: ImageMetrics
        var fingerprint: String?
        let facts: CurationContextPolicy.Facts
        // This describes preview evidence only. Similar/context recommendations
        // do not require a full original-file read.
        var needsRetry: Bool
        var originalState: OriginalAnalysisState = .notRequested
        // A preview awaiting OCR/Vision is work in progress, not a read failure.
        var enrichmentAttempted = true
        // Only pending first-pass previews retain their bitmap. Enrichment drops
        // it immediately; the normal incremental pass retains at most eight.
        var previewImage: CGImage? = nil
        // At most four ready full previews survive in each of three parked
        // windows. They are memory-only and are never recommendation evidence.
        var preparedPreview: AnalysisPreview? = nil
        // A fast local thumbnail only nominates work. OCR/Vision must still use
        // the established full analysis preview before producing those claims.
        var previewIsReduced = false
        // A scheduling result, never a substitute for OCR or a claim of no text.
        var contextDeferred = false

        var workState: CurationAnalysisWorkState {
            let stage: Int
            switch originalState {
            case .notRequested: stage = 0
            case .awaitingFullBudget: stage = 1
            case .resolved: stage = 2
            case .unavailable: stage = 3
            }
            return CurationAnalysisWorkState(fullPreview: !previewIsReduced, hasFeature: featurePrint != nil,
                fingerprint: fingerprint, textLines: facts.textLines, confidentTextLines: facts.confidentTextLines,
                hasFace: facts.hasFace, detail: facts.detail, luminanceRange: facts.luminanceRange,
                originalStage: stage, enrichmentAttempted: enrichmentAttempted,
                needsRetry: needsRetry, contextDeferred: contextDeferred)
        }
    }

    private struct AnalysisProof: Codable {
        let metrics: ImageMetrics
        let fingerprint: String?
        let feature: Data?
        let textLines: [String]?
        let confidentTextLines: [String]
        let hasFace: Bool?
        let detail: Double?
        let luminanceRange: Double?
        let contextComplete: Bool
    }

    // This projection deliberately omits image metrics and Vision feature data.
    // A positive proof is an ordering hint only, never a restored recommendation.
    struct ContextProofNomination: Codable {
        let textLines: [String]?
        let confidentTextLines: [String]
        let hasFace: Bool?
        let detail: Double?
        let luminanceRange: Double?
        let contextComplete: Bool
    }

    private static let proofCache = CurationDiskProofCache<AnalysisProof>(directory:
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RecocoCurationProofs", isDirectory: true), version: 1)
    private static let analysisImageManager = PHCachingImageManager()
    private static let featureModelPreparation = CurationOncePreparation()
    private static let fullPreviewReads = CurationWorkGate(limit: 12)
    private static let fullEvidenceAnalysis = CurationWorkGate(limit: 4)

    private static func prepareFeatureModel() {
        featureModelPreparation.start { deadline, cancellation in
            let started = ProcessInfo.processInfo.systemUptime
            var ready = false
            defer { CurationTimingDiagnostics.record("featureModelPreparation", [
                "seconds": ProcessInfo.processInfo.systemUptime - started, "ready": ready ? 1 : 0,
                "cancelled": cancellation.isCancelled ? 1 : 0, "deadlineExpired": deadline.expired ? 1 : 0]) }
            guard !cancellation.isCancelled, let context = CGContext(data: nil, width: 224, height: 224,
                bitsPerComponent: 8, bytesPerRow: 224 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            // A generated neutral pattern is used only to load Vision's model.
            // Its pixels/results never enter a photo proof or recommendation.
            for y in 0..<224 {
                let shade = CGFloat(y) / 223
                context.setFillColor(red: shade, green: shade, blue: shade, alpha: 1)
                context.fill(CGRect(x: 0, y: CGFloat(y), width: 224, height: 1))
            }
            guard let image = context.makeImage(), !cancellation.isCancelled else { return }
            let request = VNGenerateImageFeaturePrintRequest()
            request.revision = VNGenerateImageFeaturePrintRequestRevision1
            request.imageCropAndScaleOption = .scaleFit
            #if targetEnvironment(simulator)
            request.usesCPUOnly = true
            #endif
            cancellation.setHandler { request.cancel() }
            do {
                try performVision([request], image: image, deadline: deadline)
                ready = !cancellation.isCancelled && request.results?.first != nil
            } catch { /* The real request can still initialize the model later. */ }
        }
    }

    private static func proofRevision(_ asset: PHAsset) -> String? {
        // A missing modification date cannot safely establish unchanged bytes.
        guard let modified = asset.modificationDate else { return nil }
        return "\(modified.timeIntervalSince1970)|\(asset.creationDate?.timeIntervalSince1970 ?? -1)|\(asset.pixelWidth)|\(asset.pixelHeight)|\(asset.mediaSubtypes.rawValue)|\(asset.isFavorite)|\(asset.isHidden)|\(asset.hasAdjustments)"
    }

    private static func persistProof(_ value: AnalyzedAsset) {
        let contextComplete = value.facts.textLines != nil && value.facts.hasFace != nil && !value.previewIsReduced
        guard !Task.isCancelled, let revision = proofRevision(value.asset),
              value.fingerprint != nil || contextComplete else { return }
        let feature = value.featurePrint.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
        proofCache.store(AnalysisProof(metrics: value.metrics, fingerprint: value.fingerprint,
            feature: feature, textLines: value.facts.textLines, confidentTextLines: value.facts.confidentTextLines,
            hasFace: value.facts.hasFace, detail: value.facts.detail, luminanceRange: value.facts.luminanceRange,
            contextComplete: contextComplete),
            for: value.photo.id, revision: revision)
    }

    private static func cachedAnalysis(_ asset: PHAsset, protectedIdentifiers: Set<String>, reviewDate: Date?) -> AnalyzedAsset? {
        guard !Task.isCancelled, let revision = proofRevision(asset),
              let proof = proofCache.value(for: asset.localIdentifier, revision: revision) else { return nil }
        var photo = metadata(for: asset, protectedIdentifiers: protectedIdentifiers)
        guard !photo.isExcluded else { return nil }
        photo.quality = min(proof.metrics.sharpness * 6, 1) * 0.55 + proof.metrics.exposure * 0.30
            + min(Double(asset.pixelWidth) * Double(asset.pixelHeight) / 12_000_000, 1) * 0.15
        let feature = proof.feature.flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: $0) }
        guard proof.metrics.colors.count == 48 * 48 * 3,
              proof.metrics.colors.allSatisfy(\.isFinite), proof.feature == nil || feature != nil else { return nil }
        return AnalyzedAsset(asset: asset, photo: photo, featurePrint: feature,
            metrics: proof.metrics, fingerprint: proof.fingerprint,
            facts: .init(capturedAt: asset.creationDate, isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
                textLines: proof.textLines, confidentTextLines: proof.confidentTextLines, hasFace: proof.hasFace,
                detail: proof.detail, luminanceRange: proof.luminanceRange, reviewDate: reviewDate),
            needsRetry: !proof.contextComplete, originalState: proof.fingerprint == nil ? .notRequested : .resolved,
            enrichmentAttempted: proof.contextComplete, previewIsReduced: !proof.contextComplete)
    }

    struct ScanProgress: Equatable, Sendable {
        enum Phase: Equatable, Sendable { case preparing, reading, comparing }
        var phase: Phase = .preparing
        var checkedCount = 0
        var windowCount = 0
        var accessiblePhotoCount = 0
    }

    struct ScanBatch {
        let decisions: [DecisionUnit]
        let visitedIdentifiers: Set<String>
        let hasMore: Bool
        var retryableFailureCount: Int = 0
        var hasFreshPhotos: Bool = false
        var accessiblePhotoCount: Int? = nil
        // Verified alternatives skipped only for this mix. Their comparison
        // references must remain available when a later batch considers them.
        var deferredIdentifiers = Set<String>()
        var deferredReferences = Set<String>()
        var workRevision: UInt64? = nil
        // Keep the verified units as well as their IDs. A focused search must
        // not discard the only proof available to a later truthful fallback.
        var deferredDecisions: [DecisionUnit] = []
    }

    /// Deliver the first verified result without waiting to fill three slots.
    /// Empty partial windows may continue, but unavailable-only windows must stop.
    /// The time budget is checked between passes, not a PhotoKit timeout promise.
    static func firstAvailableBatch(
        excluding visited: Set<String>, maximumPasses: Int = 8,
        now: () -> Date = Date.init,
        fetch: (Set<String>) async -> ScanBatch
    ) async -> ScanBatch {
        let started = now()
        var consumed = Set<String>()
        var latest = ScanBatch(decisions: [], visitedIdentifiers: [], hasMore: true)
        for _ in 0..<max(0, maximumPasses) {
            guard !Task.isCancelled else { break }
            latest = await fetch(visited.union(consumed))
            guard !Task.isCancelled else { break }
            consumed.formUnion(latest.visitedIdentifiers)
            if !latest.decisions.isEmpty || !latest.hasMore || !latest.hasFreshPhotos
                || now().timeIntervalSince(started) >= 12 { break }
        }
        guard !Task.isCancelled else {
            return ScanBatch(decisions: [], visitedIdentifiers: [], hasMore: true)
        }
        return ScanBatch(decisions: latest.decisions, visitedIdentifiers: consumed,
                         hasMore: latest.hasMore, retryableFailureCount: latest.retryableFailureCount,
                         hasFreshPhotos: latest.hasFreshPhotos, accessiblePhotoCount: latest.accessiblePhotoCount,
                         workRevision: latest.workRevision)
    }

    /// Collect a small daily set without replacing missing evidence with recent
    /// photos. Passes share the same bounded budget, and each kept comparison is
    /// protected before the next pass can nominate another removal candidate.
    /// Seeds must already have passed restoration checks. They may be in scanned
    /// coverage, but do not become newly visited merely because this call keeps them.
    static func diversifiedPendingRecommendations(_ current: [DecisionUnit],
                                                  additions: [DecisionUnit], pinned: Set<String>) -> [DecisionUnit] {
        var result = current
        let existingReferences = Set(current.compactMap(\.comparisonLocalIdentifier))
        for addition in additions {
            guard let id = addition.displayIdentifier, !id.isEmpty,
                  addition.type == .cleanupSingle, addition.status == .pending,
                  addition.removalIdentifiers == [id],
                  let group = CleanupReasonGroup(addition.evidence?.reason ?? addition.reasonCodes.first),
                  !result.contains(where: { $0.persistenceKey == id }), !existingReferences.contains(id) else { continue }
            let groups = result.compactMap { CleanupReasonGroup($0.evidence?.reason ?? $0.reasonCodes.first) }
            guard !groups.contains(group), let index = result.indices.reversed().first(where: { index in
                guard !pinned.contains(result[index].persistenceKey),
                      let oldGroup = CleanupReasonGroup(result[index].evidence?.reason ?? result[index].reasonCodes.first) else { return false }
                return groups.filter { $0 == oldGroup }.count > 1
            }) else { continue }
            var proposed = result
            proposed[index] = addition
            let candidates = Set(proposed.compactMap(\.displayIdentifier))
            let references = Set(proposed.compactMap(\.comparisonLocalIdentifier))
            guard candidates.count == proposed.count, candidates.isDisjoint(with: references),
                  group == .contextReview || addition.comparisonLocalIdentifier?.isEmpty == false else { continue }
            result = proposed
        }
        return result
    }

    static func curatedBatch(
        excluding visited: Set<String>, protectedIdentifiers: Set<String>,
        initialDecisions: [DecisionUnit] = [], limit: Int = 3, excludingReasonGroups: Set<CleanupReasonGroup> = [],
        allowSameReasonFallback: Bool = false, diversityTimeLimit: TimeInterval = 9,
        maximumPasses: Int = 32, timeLimit: TimeInterval = 12, stopOnUnchangedWork: Bool = false,
        now: () -> Date = Date.init,
        onUpdate: ((ScanBatch) async -> Void)? = nil,
        fetch: (Set<String>, Set<String>, Int, Set<CleanupReasonGroup>) async -> ScanBatch
    ) async -> ScanBatch {
        let target = min(3, max(0, limit))
        guard target > 0 else { return ScanBatch(decisions: [], visitedIdentifiers: [], hasMore: true) }
        let started = now()
        var decisions: [DecisionUnit] = []
        var candidates = Set<String>()
        var references = Set<String>()
        var consumed = Set<String>()
        var seedIdentifiers = Set<String>()
        // Rejected nominations are skipped only in this request, not recorded as
        // reviewed or permanently scanned. Another explicit batch may use them.
        var deferredIdentifiers = Set<String>()
        var deferredReferences = Set<String>()
        var represented = excludingReasonGroups
        var seedGroups = Set<CleanupReasonGroup>()
        var accessiblePhotoCount: Int?
        var latest = ScanBatch(decisions: [], visitedIdentifiers: [], hasMore: true)
        var fallbackDecisions: [DecisionUnit] = []
        var fallbackIdentifiers = Set<String>()
        var diversityExhausted = false
        var diversityStarted: Date?
        var previousWork: (revision: UInt64, groups: Set<CleanupReasonGroup>)?

        func diversityBudgetExpired() -> Bool {
            guard let diversityStarted else { return false }
            return now().timeIntervalSince(diversityStarted) >= max(0, diversityTimeLimit)
        }

        func append(_ unit: DecisionUnit, isSeed: Bool, allowRepeatedPair: Bool = false) {
            guard let candidate = unit.displayIdentifier else { return }
            let reason = unit.evidence?.reason ?? unit.reasonCodes.first
            let group = CleanupReasonGroup(reason)
            let reference = unit.comparisonLocalIdentifier
            let validReference = reference.map {
                !$0.isEmpty && $0 != candidate && !candidates.contains($0)
            } ?? (group == .contextReview)
            let allowsGroup = group.map {
                isSeed ? ($0 != .contextReview || !seedGroups.contains($0))
                    : (!excludingReasonGroups.contains($0)
                        && (!represented.contains($0) || (allowRepeatedPair && $0 != .contextReview)))
            } ?? false
            guard decisions.count < target, unit.type == .cleanupSingle, unit.status == .pending,
                  !candidate.isEmpty, unit.removalIdentifiers == [candidate],
                  (isSeed || !visited.contains(candidate)), !candidates.contains(candidate),
                  !protectedIdentifiers.contains(candidate), !references.contains(candidate),
                  let group, validReference else {
                if !candidates.contains(candidate) {
                    deferredIdentifiers.insert(candidate)
                    if let reference, validReference { deferredReferences.insert(reference) }
                }
                return
            }
            guard allowsGroup else {
                deferredIdentifiers.insert(candidate)
                if let reference { deferredReferences.insert(reference) }
                if allowSameReasonFallback, group != .contextReview,
                   fallbackIdentifiers.insert(candidate).inserted { fallbackDecisions.append(unit) }
                return
            }
            candidates.insert(candidate)
            if let reference { references.insert(reference) }
            represented.insert(group)
            decisions.append(unit)
            if diversityStarted == nil { diversityStarted = now() }
            if isSeed {
                seedIdentifiers.insert(candidate)
                seedGroups.insert(group)
            } else { consumed.insert(candidate) }
            deferredIdentifiers.remove(candidate)
        }

        func fillFromVerifiedPairs() {
            guard allowSameReasonFallback else { return }
            let pending = fallbackDecisions
            fallbackDecisions.removeAll()
            // Re-run candidate/reference/protection/coverage checks after every
            // addition: two individually valid pairs can conflict with each other.
            for unit in pending { append(unit, isSeed: false, allowRepeatedPair: true) }
        }

        // A returning user keeps the already-visible choices and their order,
        // even when an older build selected several file-identical copies.
        for unit in initialDecisions { append(unit, isSeed: true) }
        var publishedCount = decisions.count
        func publish() async {
            guard decisions.count > publishedCount, let onUpdate else { return }
            await onUpdate(ScanBatch(decisions: decisions,
                visitedIdentifiers: consumed.subtracting(deferredReferences.subtracting(candidates)),
                hasMore: latest.hasMore || !deferredIdentifiers.isEmpty,
                retryableFailureCount: latest.retryableFailureCount,
                hasFreshPhotos: latest.hasFreshPhotos || !deferredIdentifiers.isEmpty,
                accessiblePhotoCount: accessiblePhotoCount,
                deferredIdentifiers: deferredIdentifiers, deferredReferences: deferredReferences,
                workRevision: latest.workRevision))
            publishedCount = decisions.count
        }
        for _ in 0..<max(0, maximumPasses) {
            guard !Task.isCancelled, decisions.count < target,
                  now().timeIntervalSince(started) < max(0, timeLimit) else { break }
            let prefersMissingReasons = !allowSameReasonFallback
                || (!diversityExhausted && !diversityBudgetExpired())
            if allowSameReasonFallback, !prefersMissingReasons {
                fillFromVerifiedPairs()
                await publish()
                guard !Task.isCancelled, decisions.count < target else { break }
            }
            // Give missing evidence its own search turns. Merely sorting an
            // unrestricted stream lets easy similar pairs consume every turn.
            let queryGroups = prefersMissingReasons ? represented
                : excludingReasonGroups.union(represented.intersection([.contextReview]))
            let bufferedReferences = Set(fallbackDecisions.compactMap(\.comparisonLocalIdentifier))
            latest = await fetch(visited.union(consumed).union(seedIdentifiers).union(deferredIdentifiers),
                                 protectedIdentifiers.union(references).union(bufferedReferences)
                                    .union(deferredReferences.subtracting(candidates)),
                                 target - decisions.count, queryGroups)
            guard !Task.isCancelled else { break }
            accessiblePhotoCount = latest.accessiblePhotoCount ?? accessiblePhotoCount
            consumed.formUnion(latest.visitedIdentifiers)
            deferredIdentifiers.formUnion(latest.deferredIdentifiers)
            deferredReferences.formUnion(latest.deferredReferences)
            for unit in latest.decisions + latest.deferredDecisions { append(unit, isSeed: false) }
            consumed.subtract(deferredIdentifiers)
            consumed.subtract(seedIdentifiers)
            let sourceFinished = !latest.hasMore || !latest.hasFreshPhotos
            if allowSameReasonFallback, diversityBudgetExpired()
                || sourceFinished { fillFromVerifiedPairs() }
            // Publish only evidence-checked additions. The UI can persist and
            // display them before the next slow read; cancellation must never
            // invalidate the subset already committed by the caller.
            await publish()
            guard !Task.isCancelled else { break }
            if decisions.count == target { break }
            if sourceFinished {
                // Exhausting the missing-reason search is not exhausting all
                // real alternatives. Relax only after that search has finished.
                if allowSameReasonFallback, prefersMissingReasons, latest.hasMore,
                   queryGroups != excludingReasonGroups.union(represented.intersection([.contextReview])) {
                    diversityExhausted = true
                    previousWork = nil
                    continue
                }
                break
            }
            if let revision = latest.workRevision {
                if stopOnUnchangedWork, let previousWork, previousWork.groups == queryGroups,
                   revision <= previousWork.revision { break }
                previousWork = (revision, queryGroups)
            }
        }
        guard !Task.isCancelled else {
            return ScanBatch(decisions: [], visitedIdentifiers: [], hasMore: true)
        }
        // Do not drop verified alternatives at a bounded slice boundary.
        fillFromVerifiedPairs()
        await publish()
        guard !Task.isCancelled else { return ScanBatch(decisions: [], visitedIdentifiers: [], hasMore: true) }
        // Empty later passes may have exhausted a reference once its candidate
        // was skipped. Retire that reference for this scan only.
        consumed.subtract(deferredReferences.subtracting(candidates))
        return ScanBatch(decisions: decisions, visitedIdentifiers: consumed,
                         hasMore: latest.hasMore || !deferredIdentifiers.isEmpty,
                         retryableFailureCount: latest.retryableFailureCount,
                         hasFreshPhotos: latest.hasFreshPhotos || !deferredIdentifiers.isEmpty,
                         accessiblePhotoCount: accessiblePhotoCount, deferredIdentifiers: deferredIdentifiers,
                         deferredReferences: deferredReferences, workRevision: latest.workRevision)
    }

    /// One bounded window, held only in memory. A cancelled/restarted scan may redo
    /// work, but must not persist half a comparison as permanently visited.
    private struct AnalysisRevision: Equatable {
        let modifiedAt: Date?
        let capturedAt: Date?
        let width: Int
        let height: Int
        let subtypes: UInt
        let favorite: Bool
        let hidden: Bool
        let adjusted: Bool
        let reviewDate: Date?

        init(_ asset: PHAsset, protectedIdentifiers: Set<String>, reviewDates: [String: Date]) {
            modifiedAt = asset.modificationDate
            capturedAt = asset.creationDate
            width = asset.pixelWidth
            height = asset.pixelHeight
            subtypes = asset.mediaSubtypes.rawValue
            favorite = asset.isFavorite
            hidden = asset.isHidden
            adjusted = asset.hasAdjustments
            reviewDate = reviewDates[asset.localIdentifier]
        }
    }

    private typealias AnalysisCache = CurationAnalysisMemory<AnalysisRevision, AnalyzedAsset>

    /// A fetch-local catalog keeps PhotoKit traversal out of each small analysis
    /// pass. Store lightweight metadata and indices; images stay in one bounded window.
    struct ScanCatalogEntry: Equatable {
        let identifier: String
        let assetIndex: Int
        var facts: ScanCatalogFacts? = nil
    }

    struct ScanCatalogFacts: Equatable {
        let capturedAt: Date?
        let width: Int
        let height: Int
        var isScreenshot = false
        var isFavorite = false
        var isExcluded = false
        var isHidden = false
        var isLivePhoto = false
    }

    private struct ScanCaptureKey: Hashable {
        let capturedAt: Date
        let width: Int
        let height: Int
        let isScreenshot: Bool
    }

    private struct ScanCaptureGroup {
        let first: ScanCatalogEntry
        var second: ScanCatalogEntry?
        var hasRemovable: Bool
    }

    struct ScanWindow {
        let entries: [ScanCatalogEntry]
        let remaining: Set<String>
        let isRetryWindow: Bool
        var nominationCounts: [String: Double] = [:]
    }

    /// Scalar-only diagnostics. These buckets describe the accessible metadata
    /// pool, not proof that any of its photos should be removed.
    static func metadataDiagnosticCounts(_ facts: [ScanCatalogFacts], now: Date = Date(),
                                         calendar: Calendar = .current) -> [String: Double] {
        var result: [String: Double] = ["total": Double(facts.count), "favorite": 0, "excludedHidden": 0,
            "excludedLive": 0, "metadataExcluded": 0, "ordinaryUnder7Days": 0, "ordinary7PlusDays": 0,
            "screenshotUnder7Days": 0, "screenshot7To29Days": 0, "screenshot30PlusDays": 0,
            "missingCaptureDate": 0, "futureCaptureDate": 0]
        let today = calendar.startOfDay(for: now)
        for value in facts {
            if value.isFavorite { result["favorite", default: 0] += 1 }
            if value.isHidden { result["excludedHidden", default: 0] += 1 }
            if value.isLivePhoto { result["excludedLive", default: 0] += 1 }
            if value.isExcluded { result["metadataExcluded", default: 0] += 1 }
            guard let date = value.capturedAt else { result["missingCaptureDate", default: 0] += 1; continue }
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day ?? 0
            if days < 0 { result["futureCaptureDate", default: 0] += 1; continue }
            if value.isScreenshot {
                result[days < 7 ? "screenshotUnder7Days" : (days < 30 ? "screenshot7To29Days" : "screenshot30PlusDays"), default: 0] += 1
            } else { result[days < 7 ? "ordinaryUnder7Days" : "ordinary7PlusDays", default: 0] += 1 }
        }
        return result
    }

    static func canDeferLocalPreviewWindow(_ identifiers: Set<String>, attempted: Set<String>,
                                          localMisses: Set<String>, recovering: Set<String> = []) -> Bool {
        !localMisses.isEmpty && identifiers.isDisjoint(with: recovering)
            && identifiers.isSubset(of: attempted.union(localMisses))
    }

    static func scanCatalog(count: Int, entryAt: (Int) -> ScanCatalogEntry) -> [ScanCatalogEntry]? {
        var catalog: [ScanCatalogEntry] = []
        catalog.reserveCapacity(max(0, count))
        for index in curationScanIndices(count: count) {
            guard !Task.isCancelled else { return nil }
            catalog.append(entryAt(index))
        }
        return Task.isCancelled ? nil : catalog
    }

    /// Resolving PHAsset metadata can be expensive for a large iCloud library.
    /// Advance a lazy cursor in bounded pages; a partial catalog is never
    /// reported as exhausted while unvisited indices remain.
    struct CatalogCursor {
        private(set) var readCount = 0
        let totalCount: Int
        var hasMore: Bool { readCount < totalCount }
        init(count: Int) {
            totalCount = max(0, count)
        }
        mutating func nextPage(limit: Int = 256, entryAt: (Int) -> ScanCatalogEntry) -> [ScanCatalogEntry] {
            var page: [ScanCatalogEntry] = []
            for _ in 0..<max(0, limit) {
                guard !Task.isCancelled, hasMore else { break }
                let window = readCount / 64
                let offset = readCount % 64
                let group = window / 2
                let index = window.isMultiple(of: 2)
                    ? totalCount - 1 - group * 64 - offset : group * 64 + offset
                page.append(entryAt(index)); readCount += 1
            }
            return page
        }
    }

    /// Keep reason sources and capture ages represented before unrelated filler.
    /// Metadata changes only read order; every result still needs its own proof.
    static func scanWindow(in catalog: [ScanCatalogEntry], excluding visited: Set<String>,
                           deferred: Set<String>, protectedIdentifiers: Set<String> = [],
                           reviewDates: [String: Date],
                           now: Date = Date(), excludingReasonGroups: Set<CleanupReasonGroup> = [],
                           contextExamined: Set<String> = [],
                           cachedContextIdentifiers: Set<String> = [], windowLimit: Int = 64) -> ScanWindow {
        let capacity = min(128, max(1, windowLimit))
        let laneScale = capacity > 64 ? 2 : 1
        let today = Calendar.current.startOfDay(for: now)
        var remaining = Set<String>()
        var due: [ScanCatalogEntry] = []
        var fresh: [ScanCatalogEntry] = []
        var retries: [ScanCatalogEntry] = []
        var groups: [ScanCaptureKey: ScanCaptureGroup] = [:]
        for entry in catalog where !visited.contains(entry.identifier) {
            let id = entry.identifier
            guard remaining.insert(id).inserted else { continue }
            if deferred.contains(id) {
                if retries.count < capacity { retries.append(entry) }
                continue
            }
            let reviewDay = reviewDates[id].map { Calendar.current.startOfDay(for: $0) }
            if let facts = entry.facts, !facts.isExcluded, let capturedAt = facts.capturedAt,
               facts.width > 0, facts.height > 0, reviewDay.map({ $0 <= today }) ?? true {
                let key = ScanCaptureKey(capturedAt: capturedAt, width: facts.width,
                                         height: facts.height, isScreenshot: facts.isScreenshot)
                let canRemove = !facts.isFavorite && !protectedIdentifiers.contains(id)
                if var group = groups[key] {
                    if group.second == nil || (!group.hasRemovable && canRemove) { group.second = entry }
                    group.hasRemovable = group.hasRemovable || canRemove
                    groups[key] = group
                } else {
                    groups[key] = ScanCaptureGroup(first: entry, hasRemovable: canRemove)
                }
            }
            if let reviewDay, reviewDay <= today {
                due.append(entry)
                due.sort { reviewDates[$0.identifier]! < reviewDates[$1.identifier]! }
                if due.count > capacity { due.removeLast() }
            } else { fresh.append(entry) }
        }
        let exactGroups = groups.filter { $0.value.second != nil && $0.value.hasRemovable }
            .sorted {
                if $0.key.capturedAt != $1.key.capturedAt { return $0.key.capturedAt > $1.key.capturedAt }
                return $0.value.first.assetIndex > $1.value.first.assetIndex
            }
        let exactPriority = interleavedCaptureCohorts(exactGroups, limit: 8 * laneScale, now: now,
            capturedAt: { $0.key.capturedAt }).flatMap { [$0.value.first, $0.value.second!] }
        let exactMembers = Set(groups.values.filter { $0.second != nil }.flatMap {
            [$0.first.identifier, $0.second!.identifier]
        })
        let priority = excludingReasonGroups.contains(.identicalFile) ? [] : exactPriority
        let nearby = excludingReasonGroups.contains(.similarCapture) ? [] : nearbyPriorityEntries(in: catalog,
            excluding: visited.union(deferred).union(priority.isEmpty ? [] : exactMembers),
            protectedIdentifiers: protectedIdentifiers, reviewDates: reviewDates, now: now, pairLimit: 16 * laneScale)
        let prioritizesContext = excludingReasonGroups.contains(.similarCapture)
            && !excludingReasonGroups.contains(.contextReview)
        let contextPriority = excludingReasonGroups.contains(.contextReview) ? [] : contextPriorityEntries(in: catalog,
            excluding: visited.union(deferred).union(contextExamined), protectedIdentifiers: protectedIdentifiers,
            reviewDates: reviewDates, now: now, limit: (prioritizesContext ? 32 : 16) * laneScale)
        // Ordinary context reasons require seven elapsed days. Nominate a few
        // older singles for cheap screening, without using age as evidence.
        let paired = Set(priority.map(\.identifier)).union(nearby.map(\.identifier))
        let ordinaryContext = excludingReasonGroups.contains(.contextReview) ? [] : contextPriorityEntries(in: catalog,
            excluding: visited.union(deferred).union(paired).union(exactMembers).union(contextExamined), protectedIdentifiers: protectedIdentifiers,
            reviewDates: reviewDates, now: now, screenshots: false, limit: (prioritizesContext ? 8 : 4) * laneScale)
        let knownContextCatalog = catalog.filter { cachedContextIdentifiers.contains($0.identifier) }
        let unavailableContext = visited.union(deferred).union(contextExamined)
        let knownContext = excludingReasonGroups.contains(.contextReview) ? [] :
            contextPriorityEntries(in: knownContextCatalog, excluding: unavailableContext,
                protectedIdentifiers: protectedIdentifiers, reviewDates: reviewDates, now: now, limit: 2)
            + contextPriorityEntries(in: knownContextCatalog, excluding: unavailableContext,
                protectedIdentifiers: protectedIdentifiers, reviewDates: reviewDates, now: now,
                screenshots: false, limit: 2)
        var diversePriority: [ScanCatalogEntry] = []
        for offset in 0..<max(priority.count / 2, nearby.count / 2, contextPriority.count, ordinaryContext.count) {
            // Both members of each nominated pair stay adjacent. The initial
            // five reads retain exact/nearby/context opportunities when present.
            if prioritizesContext { diversePriority += contextPriority.dropFirst(offset * 2).prefix(2) }
            diversePriority += priority.dropFirst(offset * 2).prefix(2)
            diversePriority += nearby.dropFirst(offset * 2).prefix(2)
            if !prioritizesContext { diversePriority += contextPriority.dropFirst(offset).prefix(1) }
            diversePriority += ordinaryContext.dropFirst(offset).prefix(1)
        }
        // A large newest-photo run must not keep older eligible photos out of
        // every first window. Unknown metadata retains its original fallback.
        let fairFresh = interleavedCaptureCohorts(fresh, limit: capacity, now: now,
            capturedAt: { $0.facts?.capturedAt })
        var seen = Set<String>()
        var window: [ScanCatalogEntry] = []
        for entry in due + knownContext + diversePriority + fairFresh + fresh where seen.insert(entry.identifier).inserted {
            window.append(entry)
            if window.count == capacity { break }
        }
        return ScanWindow(entries: window.isEmpty ? retries : window, remaining: remaining,
                          isRetryWindow: window.isEmpty, nominationCounts: [
                            "exactNomineePhotos": Double(priority.count), "nearbyNomineePhotos": Double(nearby.count),
                            "contextNomineePhotos": Double(contextPriority.count),
                            "ordinaryContextNomineePhotos": Double(ordinaryContext.count),
                            "cachedContextNomineePhotos": Double(knownContext.count),
                            "dueNomineePhotos": Double(due.count)])
    }

    static func cachedContextNominationIdentifiers(in catalog: [ScanCatalogEntry],
        proofs: [(revision: String, value: ContextProofNomination)], now: Date = Date()) -> Set<String> {
        var keys = Set<ScanCaptureKey>()
        for proof in proofs where proof.value.contextComplete {
            let parts = proof.revision.split(separator: "|")
            guard parts.count == 8, let captured = Double(parts[1]), captured >= 0, captured.isFinite,
                  let width = Int(parts[2]), let height = Int(parts[3]), width > 0, height > 0,
                  let subtypes = UInt(parts[4]), parts[5] == "false", parts[6] == "false" else { continue }
            let date = Date(timeIntervalSince1970: captured)
            let screenshot = PHAssetMediaSubtype(rawValue: subtypes).contains(.photoScreenshot)
            let facts = CurationContextPolicy.Facts(capturedAt: date, isScreenshot: screenshot,
                textLines: proof.value.textLines, confidentTextLines: proof.value.confidentTextLines,
                hasFace: proof.value.hasFace, detail: proof.value.detail,
                luminanceRange: proof.value.luminanceRange)
            guard CurationContextPolicy.evidence(for: facts, now: now) != nil else { continue }
            keys.insert(ScanCaptureKey(capturedAt: date, width: width, height: height, isScreenshot: screenshot))
        }
        guard !keys.isEmpty else { return [] }
        return Set(catalog.compactMap { entry in
            guard let facts = entry.facts, !facts.isExcluded, !facts.isFavorite,
                  let date = facts.capturedAt, keys.contains(ScanCaptureKey(capturedAt: date,
                    width: facts.width, height: facts.height, isScreenshot: facts.isScreenshot)) else { return nil }
            return entry.identifier
        })
    }

    /// Age cohorts are a scheduling preference, never a recommendation reason.
    /// Bound each lane while allowing a sparse cohort to borrow unused slots.
    private static func interleavedCaptureCohorts<T>(_ values: [T], limit: Int, now: Date,
        order: [Int] = [0, 1, 2, 3], recentLimit: Int? = nil, spreadWithinCohort: Bool = false,
        capturedAt: (T) -> Date?) -> [T] {
        guard limit > 0 else { return [] }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -6, to: today)!
        let thirtyDaysAgo = calendar.date(byAdding: .day, value: -29, to: today)!
        let sixMonthsAgo = calendar.date(byAdding: .day, value: -179, to: today)!
        var lanes = [[T]](repeating: [], count: 4)
        for value in values {
            guard let date = capturedAt(value), date <= now else { continue }
            let cohort = date >= sevenDaysAgo ? 0 : date >= thirtyDaysAgo ? 1 : date >= sixMonthsAgo ? 2 : 3
            let laneLimit = cohort == 0 ? min(limit, recentLimit ?? limit) : limit
            if spreadWithinCohort || lanes[cohort].count < laneLimit { lanes[cohort].append(value) }
        }
        if spreadWithinCohort {
            for cohort in lanes.indices {
                let laneLimit = cohort == 0 ? min(limit, recentLimit ?? limit) : limit
                lanes[cohort] = spreadContextNominations(lanes[cohort], limit: laneLimit)
            }
        }
        var result: [T] = []
        for row in 0..<limit {
            for cohort in order where lanes[cohort].indices.contains(row) {
                result.append(lanes[cohort][row])
                if result.count == limit { return result }
            }
        }
        return result
    }

    /// A long age cohort can span years. Visit both ends and then the middle
    /// of each remaining interval before taking adjacent captures. This changes
    /// only nomination order, never the age, OCR or protection evidence rules.
    private static func spreadContextNominations<T>(_ values: [T], limit: Int) -> [T] {
        guard limit > 0 else { return [] }
        guard values.count > limit else { return values }
        var indices = [0]
        if limit > 1 { indices.append(values.count - 1) }
        var intervals: [Range<Int>] = [1..<(values.count - 1)]
        var cursor = 0
        while indices.count < limit, cursor < intervals.count {
            let range = intervals[cursor]
            cursor += 1
            guard !range.isEmpty else { continue }
            let middle = range.lowerBound + range.count / 2
            indices.append(middle)
            if range.lowerBound < middle { intervals.append(range.lowerBound..<middle) }
            if middle + 1 < range.upperBound { intervals.append((middle + 1)..<range.upperBound) }
        }
        return indices.map { values[$0] }
    }

    /// Old shopping/reference screens and recent explicit-expiry screens get
    /// separate opportunities; OCR and the context policy still decide validity.
    static func contextPriorityEntries(in catalog: [ScanCatalogEntry], excluding: Set<String>,
        protectedIdentifiers: Set<String>, reviewDates: [String: Date], now: Date,
        screenshots: Bool = true, limit: Int = 8) -> [ScanCatalogEntry] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -6, to: today)!
        var seen = Set<String>()
        let eligible = catalog.filter { entry in
            guard seen.insert(entry.identifier).inserted, !excluding.contains(entry.identifier),
                  !protectedIdentifiers.contains(entry.identifier), let facts = entry.facts,
                  facts.isScreenshot == screenshots, !facts.isExcluded, !facts.isFavorite,
                  facts.width > 0, facts.height > 0,
                  let captured = facts.capturedAt, captured <= now,
                  screenshots || captured < sevenDaysAgo else { return false }
            return reviewDates[entry.identifier].map { calendar.startOfDay(for: $0) <= today } ?? true
        }.sorted {
            let left = $0.facts!.capturedAt!, right = $1.facts!.capturedAt!
            return left == right ? $0.assetIndex > $1.assetIndex : left > right
        }
        return interleavedCaptureCohorts(eligible, limit: max(0, limit), now: now,
            order: [2, 1, 3, 0], recentLimit: screenshots ? 1 : 0, spreadWithinCohort: true,
            capturedAt: { $0.facts?.capturedAt })
    }

    /// Nominate nearby ordinary photos across capture ages. Each pair remains
    /// intact and still requires unchanged OCR, Vision and pixel evidence.
    static func nearbyPriorityEntries(in catalog: [ScanCatalogEntry], excluding: Set<String>,
                                      protectedIdentifiers: Set<String>, reviewDates: [String: Date],
                                      now: Date, pairLimit: Int = 8) -> [ScanCatalogEntry] {
        guard pairLimit > 0 else { return [] }
        struct Dimensions: Hashable { let width: Int; let height: Int }
        let today = Calendar.current.startOfDay(for: now)
        var seen = Set<String>()
        let eligible = catalog.filter { entry in
            guard seen.insert(entry.identifier).inserted, !excluding.contains(entry.identifier), let facts = entry.facts,
                  !facts.isExcluded, !facts.isScreenshot, facts.capturedAt != nil,
                  facts.width > 0, facts.height > 0 else { return false }
            return reviewDates[entry.identifier].map { Calendar.current.startOfDay(for: $0) <= today } ?? true
        }.sorted {
            let left = $0.facts!.capturedAt!, right = $1.facts!.capturedAt!
            return left == right ? $0.assetIndex > $1.assetIndex : left > right
        }
        var previous: [Dimensions: ScanCatalogEntry] = [:]
        var used = Set<String>()
        var pairs: [[ScanCatalogEntry]] = []
        for entry in eligible {
            let facts = entry.facts!
            let key = Dimensions(width: facts.width, height: facts.height)
            defer { previous[key] = entry }
            guard let peer = previous[key], !used.contains(peer.identifier),
                  abs(facts.capturedAt!.timeIntervalSince(peer.facts!.capturedAt!)) <= 30 else { continue }
            let removable = !facts.isFavorite && !protectedIdentifiers.contains(entry.identifier)
            let peerRemovable = !peer.facts!.isFavorite && !protectedIdentifiers.contains(peer.identifier)
            guard removable || peerRemovable else { continue }
            pairs.append([peer, entry])
            used.formUnion([peer.identifier, entry.identifier])
        }
        return interleavedCaptureCohorts(pairs, limit: pairLimit, now: now,
            capturedAt: { $0.first?.facts?.capturedAt }).flatMap { $0 }
    }

    /// Serializes access to the window even when a caller cancels and retries.
    static func completedScanCoverage(examined: Set<String>, missing: Set<String>,
                                      chosen: Set<String>, preserved: Set<String>, complete: Bool,
                                      excludingReasonGroups: Set<CleanupReasonGroup>) -> Set<String> {
        if !chosen.isEmpty { return chosen }
        // An OCR-only pass has not ruled out an identical/nearby pair. It can
        // advance the search in memory, but may not permanently retire photos.
        return complete && excludingReasonGroups.isEmpty ? examined.subtracting(preserved) : missing
    }

    private actor ScanSession {
        let usePersistentProofs: Bool
        init(usePersistentProofs: Bool) { self.usePersistentProofs = usePersistentProofs }
        var cache = AnalysisCache()
        private var activeWindow: [String] = []
        private var parkedWindows = CurationParkedWindows<AnalysisCache>()
        private var accumulatedWork = CurationWorkProgress()
        // Keep IDs, not image data, for failed windows. Successful peers remain
        // retryable too, so the recovered photo can still find its comparison.
        var deferred = Set<String>()
        private var reasonFilteredCoverage = Set<String>()
        private var activeReasonGroups = Set<CleanupReasonGroup>()
        private var contextExamined = Set<String>()
        private var cachedContextIdentifiers = Set<String>()
        private var missingReasonSchedule = CurationMissingReasonSchedule()
        var retryable = Set<String>()
        var localPreviewRecovery = Set<String>()
        private var recoverySchedule = CurationPreviewRecoverySchedule()
        private var retiredCoverage: UInt64 = 0
        private var catalogSnapshot: [ScanCatalogEntry]?
        private var catalogAuthorization: PHAuthorizationStatus?
        private var catalogFetch: PHFetchResult<PHAsset>?
        private var catalogCursor: CatalogCursor?

        var accessiblePhotoCount: Int { catalogCursor?.totalCount ?? 0 }

        func reset() {
            cache.reset(); activeWindow = []; parkedWindows = CurationParkedWindows<AnalysisCache>()
            accumulatedWork = CurationWorkProgress()
            deferred.removeAll(); retryable.removeAll(); localPreviewRecovery.removeAll()
            reasonFilteredCoverage.removeAll(); activeReasonGroups.removeAll()
            contextExamined.removeAll()
            cachedContextIdentifiers.removeAll()
            missingReasonSchedule = CurationMissingReasonSchedule()
            recoverySchedule = CurationPreviewRecoverySchedule()
            catalogSnapshot = nil; catalogAuthorization = nil; catalogFetch = nil; catalogCursor = nil
        }

        private func retainPreparedPreviewBudget(_ identifiers: [String]) {
            let analyses = cache.analyses
            let keep = Set(identifiers.filter { analyses[$0]?.preparedPreview != nil }.prefix(4))
            cache.transformAnalyses { value in
                var bounded = value
                bounded.previewImage = nil
                if !keep.contains(value.photo.id) { bounded.preparedPreview = nil }
                return bounded
            }
        }

        /// Home invalidates this snapshot on library, access and day changes.
        /// Short analysis passes reuse metadata, never stale PHAsset objects.
        func catalogForCurrentAccess(excluding visited: Set<String>) -> [ScanCatalogEntry]? {
            let catalogStarted = ProcessInfo.processInfo.systemUptime
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard status == .authorized || status == .limited, !Task.isCancelled else { return nil }
            if status != catalogAuthorization { reset() }
            PhotoCurationService.prepareFeatureModel()
            if let catalogSnapshot,
               catalogCursor?.hasMore != true || catalogSnapshot.filter({ !visited.contains($0.identifier) && !deferred.contains($0.identifier) }).count >= 64 {
                CurationTimingDiagnostics.record("catalog", ["count": Double(catalogSnapshot.count), "cached": 1, "seconds": 0])
                return catalogSnapshot
            }
            if catalogFetch == nil {
                let options = PHFetchOptions()
                options.includeAllBurstAssets = true
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
                catalogFetch = PHAsset.fetchAssets(with: .image, options: options)
                catalogCursor = CatalogCursor(count: catalogFetch!.count)
            }
            let fetched = catalogFetch!
            let fetchFinished = ProcessInfo.processInfo.systemUptime
            var nextCursor = catalogCursor!
            // The physical22k library takes about0.5s to inspect metadata.
            // Keep global capture neighbours together: narrowing to256 rows
            // lost more useful comparisons than that small saving justified.
            let page = nextCursor.nextPage(limit: fetched.count) { index in
                let asset = fetched.object(at: index)
                return ScanCatalogEntry(identifier: asset.localIdentifier, assetIndex: index,
                    facts: ScanCatalogFacts(capturedAt: asset.creationDate, width: asset.pixelWidth,
                        height: asset.pixelHeight, isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
                        isFavorite: asset.isFavorite,
                        isExcluded: asset.isHidden || asset.mediaType != .image || asset.mediaSubtypes.contains(.photoLive),
                        isHidden: asset.isHidden, isLivePhoto: asset.mediaSubtypes.contains(.photoLive)))
            }
            guard !Task.isCancelled,
                  status == PHPhotoLibrary.authorizationStatus(for: .readWrite) else { return nil }
            catalogCursor = nextCursor
            var catalog = (catalogSnapshot ?? []) + page
            if catalogSnapshot == nil {
                // PhotoKit's indexed screenshots collection supplies a small
                // second source without walking 20,000 unrelated metadata rows.
                // Age only nominates these for OCR; it is never deletion proof.
                let collections = PHAssetCollection.fetchAssetCollections(with: .smartAlbum,
                    subtype: .smartAlbumScreenshots, options: nil)
                if let screenshots = collections.firstObject {
                    let options = PHFetchOptions()
                    options.fetchLimit = 16
                    options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                    options.predicate = NSPredicate(format: "creationDate < %@",
                        Date().addingTimeInterval(-7 * 86_400) as NSDate)
                    let sampled = PHAsset.fetchAssets(in: screenshots, options: options)
                    sampled.enumerateObjects { asset, index, stop in
                        if Task.isCancelled { stop.pointee = true; return }
                        catalog.append(ScanCatalogEntry(identifier: asset.localIdentifier, assetIndex: -index - 1,
                            facts: ScanCatalogFacts(capturedAt: asset.creationDate, width: asset.pixelWidth,
                                height: asset.pixelHeight, isScreenshot: true, isFavorite: asset.isFavorite,
                                isExcluded: asset.isHidden || asset.mediaType != .image)))
                    }
                }
            }
            var seen = Set<String>()
            catalog = catalog.filter { seen.insert($0.identifier).inserted }
            catalogSnapshot = catalog
            catalogAuthorization = status
            if usePersistentProofs {
                let began = ProcessInfo.processInfo.systemUptime
                let proofs = PhotoCurationService.proofCache.projectedValues(as: ContextProofNomination.self)
                cachedContextIdentifiers = PhotoCurationService.cachedContextNominationIdentifiers(in: catalog, proofs: proofs)
                CurationTimingDiagnostics.record("cachedContextNomination", ["proofs": Double(proofs.count),
                    "nominees": Double(cachedContextIdentifiers.count),
                    "seconds": ProcessInfo.processInfo.systemUptime - began])
            }
            var catalogCounts: [String: Double] = ["count": Double(catalog.count), "accessibleCount": Double(fetched.count), "cached": 0,
                "seconds": ProcessInfo.processInfo.systemUptime - catalogStarted,
                "fetchSeconds": fetchFinished - catalogStarted,
                "metadataSeconds": ProcessInfo.processInfo.systemUptime - fetchFinished]
            if CurationTimingDiagnostics.enabled {
                for (key, value) in PhotoCurationService.metadataDiagnosticCounts(catalog.compactMap(\.facts)) {
                    catalogCounts["eligibility." + key] = value
                }
            }
            CurationTimingDiagnostics.record("catalog", catalogCounts)
            return catalog
        }

        func batch(in catalog: [ScanCatalogEntry],
                   excluding visited: Set<String>, protectedIdentifiers: Set<String>,
                   reviewDates: [String: Date], limit: Int, analysisLimit: Int = 64,
                   remainingCount: Int? = nil, timeLimit: TimeInterval = 12,
                   excludingReasonGroups: Set<CleanupReasonGroup> = [],
                   onProgress: ((ScanProgress) -> Void)? = nil) -> ScanBatch {
            guard limit > 0, !Task.isCancelled else {
                return ScanBatch(decisions: [], visitedIdentifiers: [], hasMore: catalog.contains { !visited.contains($0.identifier) })
            }
            let seekingNewReason = !excludingReasonGroups.subtracting(activeReasonGroups).isEmpty
            if !excludingReasonGroups.isSuperset(of: activeReasonGroups) {
                deferred.subtract(reasonFilteredCoverage)
                reasonFilteredCoverage.removeAll()
            }
            activeReasonGroups = excludingReasonGroups
            let normalSelection = PhotoCurationService.scanWindow(in: catalog, excluding: visited,
                deferred: deferred, protectedIdentifiers: protectedIdentifiers, reviewDates: reviewDates,
                excludingReasonGroups: excludingReasonGroups, contextExamined: contextExamined,
                cachedContextIdentifiers: cachedContextIdentifiers, windowLimit: analysisLimit)
            let freshAvailable = !normalSelection.isRetryWindow && !normalSelection.entries.isEmpty
            let workSelection = parkedWindows.selectWork(eligible: normalSelection.remaining,
                freshAvailable: freshAvailable, recoveryEligible: localPreviewRecovery.subtracting(visited),
                recoverySchedule: &recoverySchedule,
                // While filling a visible Home, local candidates get four
                // bounded turns before an unproductive/cloud retry. Exhausted
                // small libraries and productive comparisons still resume now.
                freshPassesBeforeRetry: timeLimit <= 2 ? 4 : 2,
                preferFreshReason: seekingNewReason,
                ready: { $0.preparation?.hasReadyResult == true }, restoring: { AnalysisCache() })
            let parkedTurn = workSelection.parked
            let recoveryTurn = workSelection.recovery
            let selection: ScanWindow
            if let parkedTurn {
                let byID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.identifier, $0) })
                selection = ScanWindow(entries: parkedTurn.identifiers.compactMap { id in
                    visited.contains(id) ? nil : byID[id]
                }, remaining: normalSelection.remaining, isRetryWindow: true)
            } else if let recoveryTurn {
                let byID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.identifier, $0) })
                selection = ScanWindow(entries: recoveryTurn.window.compactMap { id in
                    visited.contains(id) ? nil : byID[id]
                }, remaining: normalSelection.remaining, isRetryWindow: true)
            } else { selection = normalSelection }
            let remaining = selection.remaining
            deferred.formIntersection(remaining)
            retryable.formIntersection(remaining)
            localPreviewRecovery.formIntersection(remaining)
            // Re-resolve every selected identifier so edits, protection and
            // revoked access cannot reuse an old photo through the catalog cache.
            let selectedIDs = selection.entries.map(\.identifier)
            if let parkedTurn { cache = parkedTurn.value }
            else if Set(activeWindow) != Set(selectedIDs) {
                cache = parkedWindows.takeMatching(selectedIDs) ?? AnalysisCache()
            }
            activeWindow = selectedIDs
            let previouslyDeferred = deferred.intersection(selectedIDs)
            if selection.isRetryWindow { deferred.subtract(selectedIDs) }
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: selectedIDs, options: nil)
            var currentAssets: [String: PHAsset] = [:]
            fetched.enumerateObjects { asset, _, _ in currentAssets[asset.localIdentifier] = asset }
            let window = selectedIDs.compactMap { currentAssets[$0] }
            let missingIDs = Set(selectedIDs).subtracting(currentAssets.keys)
            CurationTimingDiagnostics.record("window", ["selected": Double(selectedIDs.count),
                "available": Double(window.count), "remaining": Double(remaining.count),
                "protected": Double(window.filter { protectedIdentifiers.contains($0.localIdentifier) }.count),
                "removable": Double(window.filter { PhotoCurationService.metadata(for: $0, protectedIdentifiers: protectedIdentifiers).canRemove }.count),
                "missing": Double(missingIDs.count), "retryWindow": selection.isRetryWindow ? 1 : 0])
            if CurationTimingDiagnostics.enabled {
                let facts = window.map { asset in
                    ScanCatalogFacts(capturedAt: asset.creationDate, width: asset.pixelWidth, height: asset.pixelHeight,
                        isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot), isFavorite: asset.isFavorite,
                        isExcluded: asset.isHidden || asset.mediaType != .image || asset.mediaSubtypes.contains(.photoLive),
                        isHidden: asset.isHidden, isLivePhoto: asset.mediaSubtypes.contains(.photoLive))
                }
                var counts = PhotoCurationService.metadataDiagnosticCounts(facts)
                counts.merge(selection.nominationCounts) { _, next in next }
                counts["protected"] = Double(window.filter { protectedIdentifiers.contains($0.localIdentifier) }.count)
                counts["futureReviewDate"] = Double(window.filter { reviewDates[$0.localIdentifier].map { Calendar.current.startOfDay(for: $0) > Calendar.current.startOfDay(for: Date()) } ?? false }.count)
                CurationTimingDiagnostics.record("windowEligibility", counts)
            }
            let windowStarted = ProcessInfo.processInfo.systemUptime
            let revisionBefore = cache.workRevision
            let enrichmentAttemptBefore = cache.enrichmentAttemptRevision
            var examined = Set<String>()
            var attempted = Set<String>()
            var deferredNominations = Set<String>()
            var deferredReferences = Set<String>()
            var completedContext = Set<String>()
            var deferredDecisions: [DecisionUnit] = []
            let contextFirst = missingReasonSchedule.prioritizesContext(excluding: excludingReasonGroups)
            // Drain a completed background read without spending another
            // two-second slice on that window's still-unavailable neighbours.
            // Other ready windows can then publish in the same foreground turn.
            let preparedResultsOnly = parkedTurn?.value.preparation?.hasReadyResult == true
            CurationTimingDiagnostics.record("evidencePriority", ["contextFirst": contextFirst ? 1 : 0,
                "fileFirst": contextFirst ? 0 : 1])
            let decisions = PhotoCurationService.findDecisions(in: window, limit: limit,
                protectedIdentifiers: protectedIdentifiers, reviewDates: reviewDates,
                onExamined: { examined = $0 }, onAttempted: { attempted = $0 }, cache: cache,
                analysisLimit: recoveryTurn == nil ? analysisLimit : 1,
                timeLimit: preparedResultsOnly ? 0 : timeLimit, usePersistentProofs: usePersistentProofs,
                excludingReasonGroups: excludingReasonGroups,
                previewRecoveryIdentifiers: localPreviewRecovery,
                priorityRecoveryIdentifier: recoveryTurn?.identifier,
                allowDeferredContext: parkedTurn != nil
                    || (excludingReasonGroups.contains(.similarCapture) && !excludingReasonGroups.contains(.contextReview)),
                prioritizeContextEvidence: contextFirst,
                onDeferred: { deferredNominations = $0; deferredReferences = $1; deferredDecisions = $2 },
                onContextExamined: { completedContext = $0 }, onProgress: onProgress)
            guard !Task.isCancelled else {
                // A tab/background interruption does not invalidate completed
                // facts. The next pass re-resolves revisions; real scope/day/
                // library changes still call reset explicitly.
                cache.transformAnalyses { value in
                    var metadata = value; metadata.previewImage = nil; metadata.preparedPreview = nil; return metadata
                }
                parkedWindows.park(identifiers: selectedIDs, value: cache, freshTurn: false)
                deferred.formUnion(selectedIDs)
                return ScanBatch(decisions: [], visitedIdentifiers: [], hasMore: !remaining.isEmpty,
                                 workRevision: accumulatedWork.value &+ retiredCoverage)
            }
            accumulatedWork.record(before: revisionBefore, after: cache.workRevision)
            retiredCoverage &+= UInt64(completedContext.subtracting(contextExamined).count)
            contextExamined.formUnion(completedContext)
            examined.formUnion(missingIDs)
            attempted.formUnion(missingIDs)
            let windowIDs = Set(selectedIDs)
            let complete = windowIDs.isSubset(of: examined)
            let localMisses = Set(cache.deferredPreviews.keys)
            if let recoveryTurn, !localMisses.contains(recoveryTurn.identifier) { recoverySchedule.finished(recoveryTurn) }
            else if parkedTurn == nil && recoveryTurn == nil && cache.workRevision > revisionBefore {
                // Draining a finished result is not another fresh-library pass.
                // Counting it here repeatedly promoted an unavailable cloud
                // image before a new local comparison had a turn.
                recoverySchedule.noteLocalProgress()
            }
            recoverySchedule.register(window: selectedIDs, missing: localMisses)
            localPreviewRecovery.formUnion(localMisses)
            let deferLocalWindow = !selection.isRetryWindow && PhotoCurationService.canDeferLocalPreviewWindow(
                windowIDs, attempted: attempted, localMisses: localMisses)
            retryable.subtract(examined)
            retryable.formUnion(cache.failures.keys)
            localPreviewRecovery.subtract(cache.analyses.keys)
            localPreviewRecovery.subtract(cache.failures.keys)
            let preserved = deferredNominations.union(deferredReferences)
            // Only retire an empty window once every available comparison was made.
            let consumed = PhotoCurationService.completedScanCoverage(examined: examined, missing: missingIDs,
                chosen: Set(decisions.flatMap(\.removalIdentifiers)), preserved: preserved,
                complete: complete, excludingReasonGroups: excludingReasonGroups)
            if complete, decisions.isEmpty, !excludingReasonGroups.isEmpty {
                let filtered = windowIDs.subtracting(consumed)
                retiredCoverage &+= UInt64(filtered.subtracting(reasonFilteredCoverage).count)
                reasonFilteredCoverage.formUnion(filtered)
                deferred.formUnion(filtered)
            }
            deferred.formUnion(preserved)
            let shouldPark = decisions.isEmpty && !complete
                && (cache.workRevision > revisionBefore || cache.enrichmentAttemptRevision > enrichmentAttemptBefore)
            if shouldPark {
                // Preserve partial facts for a later full-context turn, but do
                // not let this window monopolize every foreground slice. Keep
                // at most four ready images per window, in memory only.
                retainPreparedPreviewBudget(selectedIDs)
                parkedWindows.park(identifiers: selectedIDs, value: cache,
                    freshTurn: parkedTurn == nil && recoveryTurn == nil)
                deferred.formUnion(windowIDs)
            } else if !decisions.isEmpty, !windowIDs.subtracting(consumed).isEmpty {
                // A productive window can contain another verified pair. Give
                // its remaining peers the next turn instead of hiding them in
                // deferred coverage after publishing its first candidate.
                retainPreparedPreviewBudget(selectedIDs.filter { !consumed.contains($0) })
                parkedWindows.park(identifiers: selectedIDs.filter { !consumed.contains($0) },
                    value: cache, freshTurn: false, productive: true)
            } else if deferLocalWindow {
                localPreviewRecovery.formUnion(localMisses)
                deferred.formUnion(windowIDs)
            } else if windowIDs.isSubset(of: attempted), !cache.failures.isEmpty {
                deferred.formUnion(windowIDs)
            } else if complete && decisions.isEmpty { cache.reset() }
            if recoveryTurn != nil || parkedTurn != nil { deferred.formUnion(previouslyDeferred.subtracting(consumed)) }
            retryable.subtract(consumed)
            retiredCoverage &+= UInt64(consumed.count)
            let workRevision = accumulatedWork.value &+ retiredCoverage
            let pending = remaining.subtracting(consumed)
            CurationTimingDiagnostics.record("windowResult", ["seconds": ProcessInfo.processInfo.systemUptime - windowStarted,
                "decisions": Double(decisions.count), "examined": Double(examined.count),
                "attempted": Double(attempted.count), "consumed": Double(consumed.count),
                "localWindowDeferred": deferLocalWindow ? 1 : 0,
                "localRecoveryPending": Double(localPreviewRecovery.count),
                "recoveryTurn": recoveryTurn == nil ? 0 : 1,
                "parkedTurn": parkedTurn == nil ? 0 : 1, "parkedWindows": Double(parkedWindows.windows.count),
                "evictedUnknownWindows": Double(parkedWindows.evictedIdentifiers.count),
                "retryable": Double(retryable.count), "pending": Double(pending.count),
                "workRevision": Double(workRevision)])
            return ScanBatch(decisions: decisions, visitedIdentifiers: consumed,
                             hasMore: (remainingCount ?? remaining.count) > consumed.count
                                || parkedWindows.hasPendingWork || catalogCursor?.hasMore == true,
                             retryableFailureCount: retryable.count,
                             hasFreshPhotos: !pending.subtracting(deferred).isEmpty
                                || !pending.intersection(localPreviewRecovery).isEmpty
                                || parkedWindows.hasPendingWork || catalogCursor?.hasMore == true,
                             deferredIdentifiers: deferredNominations, deferredReferences: deferredReferences,
                             workRevision: workRevision, deferredDecisions: deferredDecisions)
        }
    }

    func resetScan() async { await scanSession.reset() }

    func hasUnscannedPhotos(excluding visited: Set<String>) async -> Bool {
        // PhotoKit's synchronous fetch can wait for the photo library. Keep
        // both fetching and enumeration off the UI actor; return only a Bool.
        let task = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return false }
            let options = PHFetchOptions()
            options.includeAllBurstAssets = true
            let assets = PHAsset.fetchAssets(with: .image, options: options)
            var found = false
            assets.enumerateObjects { asset, _, stop in
                if Task.isCancelled { stop.pointee = true; return }
                if !visited.contains(asset.localIdentifier) { found = true; stop.pointee = true }
            }
            return !Task.isCancelled && found
        }
        return await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    /// Visit recent (newest first) and older (oldest first) windows fairly
    /// without materializing the library. Start with the newest local previews
    /// instead of waiting on the older edge of the first window.
    /// Keep capture neighbours together so changing scan priority does not split
    /// every adjacent pair. Each iterator visits every index exactly once.
    static func curationScanIndices(count: Int, windowSize: Int = 64) -> AnySequence<Int> {
        AnySequence {
            var lower = 0
            var upper = max(0, count)
            var window = 0..<0
            var recentNext = true
            var descending = false
            return AnyIterator<Int> {
                if window.isEmpty {
                    guard lower < upper else { return nil }
                    let size = min(max(1, windowSize), upper - lower)
                    descending = recentNext
                    if recentNext {
                        window = (upper - size)..<upper
                        upper -= size
                    } else {
                        window = lower..<(lower + size)
                        lower += size
                    }
                    recentNext.toggle()
                }
                if descending {
                    let index = window.upperBound - 1
                    window = window.lowerBound..<index
                    return index
                }
                let index = window.lowerBound
                window = (index + 1)..<window.upperBound
                return index
            }
        }
    }

    /// Resume a bounded window across requests before marking it visited.
    func fetchNextBatch(excluding visited: Set<String>, protectedIdentifiers: Set<String>,
                        reviewDates: [String: Date], limit: Int = 3, firstResult: Bool = false,
                        excludingReasonGroups: Set<CleanupReasonGroup> = [], onProgress: (@Sendable (ScanProgress) -> Void)? = nil) async -> ScanBatch {
        let task = Task.detached(priority: .userInitiated) {
            onProgress?(ScanProgress())
            guard let catalog = await scanSession.catalogForCurrentAccess(excluding: visited) else {
                return ScanBatch(decisions: [], visitedIdentifiers: [], hasMore: true)
            }
            let accessibleCount = await scanSession.accessiblePhotoCount
            let report: (ScanProgress) -> Void = { progress in
                var value = progress
                value.accessiblePhotoCount = accessibleCount
                onProgress?(value)
            }
            let fetch: (Set<String>, Set<String>, Int) async -> ScanBatch = { excluded, protected, remaining in
                // All verified nominations fit within this 64-asset window.
                // Truncating here would let file copies hide other evidence.
                var batch = await scanSession.batch(in: catalog,
                    excluding: excluded, protectedIdentifiers: protected,
                    reviewDates: reviewDates, limit: firstResult ? 128 : remaining, analysisLimit: firstResult ? 128 : 64,
                    timeLimit: firstResult ? 2 : 12,
                    excludingReasonGroups: excludingReasonGroups, onProgress: report)
                batch.accessiblePhotoCount = accessibleCount
                return batch
            }
            // Return one small pass to Home. Its collector owns the shared
            // budget, diversity and progressive presentation; nesting another
            // collector here hid verified photos behind repeated 12-second waits.
            let batchStarted = ProcessInfo.processInfo.systemUptime
            let result = await fetch(visited, protectedIdentifiers, limit)
            CurationTimingDiagnostics.record("fetchResult", ["seconds": ProcessInfo.processInfo.systemUptime - batchStarted,
                "decisions": Double(result.decisions.count), "retryable": Double(result.retryableFailureCount),
                "hasMore": result.hasMore ? 1 : 0, "hasFresh": result.hasFreshPhotos ? 1 : 0])
            return result
        }
        return await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    /// Fill an ordinary daily set with real, readable photos for reflection.
    /// Cleanup evidence and protection remain independent of this non-deletion path.
    func fetchReflectionPhotos(excluding: Set<String>, reviewDates: [String: Date], limit: Int) async -> [DecisionUnit] {
        let count = min(max(0, limit), 3)
        guard count > 0 else { return [] }
        let task = Task.detached(priority: .userInitiated) {
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard status == .authorized || status == .limited, !Task.isCancelled else { return [DecisionUnit]() }
            let deadline = ProcessInfo.processInfo.systemUptime + 6
            let now = Date()
            var selected: [DecisionUnit] = []
            var seen = excluding

            func appendReadable(from assets: PHFetchResult<PHAsset>, reason: CurationReasonCode,
                                targetCount: Int, until phaseDeadline: TimeInterval) {
                for index in 0..<assets.count {
                    let remaining = min(deadline, phaseDeadline) - ProcessInfo.processInfo.systemUptime
                    guard selected.count < targetCount, !Task.isCancelled, remaining > 0 else { return }
                    let asset = assets.object(at: index)
                    guard seen.insert(asset.localIdentifier).inserted,
                          Self.canReflect(on: asset, reviewDates: reviewDates, now: now) else { continue }
                    if reason == .anniversaryReflection,
                       !PhotoAnniversaryPolicy.matches(asset.creationDate, relativeTo: now) { continue }
                    let readable = autoreleasepool {
                        Self.reflectionPreviewIsReadable(for: asset, timeout: min(1.5, remaining))
                    }
                    guard !Task.isCancelled else { return }
                    guard readable else { continue }
                    selected.append(Self.reflectionDecision(for: asset, reason: reason, now: now))
                }
            }

            // Reserve most of the existing budget for recent photos if an old
            // local preview is unavailable. Both passes fetch at most 64 entries.
            var anniversaryMetadataCount = 0
            if let window = PhotoAnniversaryPolicy.window(relativeTo: now) {
                let options = PHFetchOptions()
                options.fetchLimit = 16
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate < %@",
                                                window.start as NSDate, window.end as NSDate)
                let assets = PHAsset.fetchAssets(with: .image, options: options)
                anniversaryMetadataCount = assets.count
                appendReadable(from: assets, reason: .anniversaryReflection, targetCount: 1,
                               until: min(deadline, ProcessInfo.processInfo.systemUptime + 1.5))
            }
            guard !Task.isCancelled else { return [] }
            if selected.count < count, ProcessInfo.processInfo.systemUptime < deadline {
                let options = PHFetchOptions()
                options.fetchLimit = max(1, 64 - anniversaryMetadataCount)
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                let assets = PHAsset.fetchAssets(with: .image, options: options)
                appendReadable(from: assets, reason: .dailyReflection, targetCount: count, until: deadline)
            }
            let currentStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard !Task.isCancelled, currentStatus == .authorized || currentStatus == .limited else { return [] }
            // Limited access may change while a preview is loading.
            let current = PHAsset.fetchAssets(withLocalIdentifiers: selected.compactMap(\.displayIdentifier), options: nil)
            var accessible: [String: PHAsset] = [:]
            current.enumerateObjects { asset, _, _ in
                if Self.canReflect(on: asset, reviewDates: reviewDates, now: now) {
                    accessible[asset.localIdentifier] = asset
                }
            }
            return selected.compactMap { unit in
                guard let id = unit.displayIdentifier, let asset = accessible[id] else { return nil }
                let reason = unit.reasonCodes.first ?? .dailyReflection
                let validatedAt = Date()
                // Do not persist a just-invalidated anniversary as a recent-order choice.
                if reason == .anniversaryReflection,
                   !PhotoAnniversaryPolicy.matches(asset.creationDate, relativeTo: validatedAt) { return nil }
                return Self.reflectionDecision(for: asset, reason: reason, now: validatedAt)
            }
        }
        return await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    func fetchTodayDecisions(limit: Int = 3, protectedIdentifiers: Set<String> = [], reviewDates: [String: Date] = [:], scanOffset: Int = 0) async -> [DecisionUnit] {
        await Task.detached(priority: .userInitiated) {
            guard limit > 0 else { return [] }
            let options = PHFetchOptions()
            options.includeAllBurstAssets = true
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            let fetched = PHAsset.fetchAssets(with: .image, options: options)
            guard fetched.count > 0 else { return [] }
            // Rotate a bounded scan across the library; don't remain stuck on the oldest 500.
            let scanLimit = 500
            let pageCount = (fetched.count + scanLimit - 1) / scanLimit
            let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
            let start = ((day % pageCount) * scanLimit + max(0, scanOffset) % fetched.count) % fetched.count
            var assets = (0..<min(scanLimit, fetched.count)).map { fetched.object(at: (start + $0) % fetched.count) }
            let dueIDs = reviewDates.filter { Calendar.current.startOfDay(for: $0.value) <= Calendar.current.startOfDay(for: Date()) }.keys.sorted()
            let dueAssets = PHAsset.fetchAssets(withLocalIdentifiers: dueIDs, options: nil)
            var seen = Set<String>()
            assets = ((0..<dueAssets.count).map { dueAssets.object(at: $0) } + assets).filter { seen.insert($0.localIdentifier).inserted }
            return Self.findDecisions(in: assets, limit: limit, protectedIdentifiers: protectedIdentifiers, reviewDates: reviewDates)
        }.value
    }

    func fetchSimilarPhotoDecision(scanLimit: Int = 300, protectedIdentifiers: Set<String> = [], reviewDates: [String: Date] = [:]) async -> DecisionUnit? {
        await Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.includeAllBurstAssets = true
            options.fetchLimit = max(2, scanLimit)
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let fetched = PHAsset.fetchAssets(with: .image, options: options)
            let assets = (0..<fetched.count).map { fetched.object(at: $0) }
            guard let single = Self.findDecisions(in: assets, limit: 1, protectedIdentifiers: protectedIdentifiers, reviewDates: reviewDates, pairsOnly: true).first,
                  let reference = single.comparisonLocalIdentifier,
                  let candidate = single.displayIdentifier else { return nil }
            let capturedAt = assets.first { $0.localIdentifier == reference }?.creationDate
            // A pair, rather than a transitive group, gives every removal a verified reference.
            return DecisionUnit(id: UUID(), type: .cleanupCluster, status: .pending,
                                candidateLocalIdentifiers: [reference, candidate],
                                recommendedLocalIdentifier: reference, selectedLocalIdentifier: nil,
                                reasonCodes: single.reasonCodes, capturedDateDescription: capturedAt.map(Self.dateDescription),
                                createdAt: Date(), evidence: single.evidence, capturedAt: capturedAt)
        }.value
    }

    func fetchDecisions(
        localIdentifiers: [String], references: [String: String] = [:],
        reasons: [String: CurationReasonCode] = [:], protectedIdentifiers: Set<String> = [],
        reviewDates: [String: Date] = [:]
    ) async -> [DecisionUnit] {
        await restoreDecisions(localIdentifiers: localIdentifiers, references: references, reasons: reasons,
            protectedIdentifiers: protectedIdentifiers, reviewDates: reviewDates).decisions
    }

    struct RestoredDecisions {
        let decisions: [DecisionUnit]
        let retryableFailureCount: Int
        // PhotoKit cannot distinguish a removed photo from one outside limited access.
        var inaccessibleIdentifiers: Set<String> = []
        // Distinguish bounded work left for the next slice from a genuine
        // unavailable image, so Home can continue automatically only as needed.
        var hasPendingAnalysis = false
        var retryableIdentifiers: Set<String> = []
        // Metadata signatures let a progressive presenter retain a verified
        // subset only if the next slice still sees the exact same asset revision.
        var assetRevisions: [String: String] = [:]
    }

    func restoreDecisions(
        localIdentifiers: [String], references: [String: String] = [:],
        reasons: [String: CurationReasonCode] = [:], protectedIdentifiers: Set<String> = [],
        reviewDates: [String: Date] = [:]
    ) async -> RestoredDecisions {
        await restoreDecisions(localIdentifiers: localIdentifiers, references: references, reasons: reasons,
            protectedIdentifiers: protectedIdentifiers, reviewDates: reviewDates, allowCachedProof: usePersistentProofs)
    }

    func restoreCachedDecisions(localIdentifiers: [String], references: [String: String], reasons: [String: CurationReasonCode],
                               protectedIdentifiers: Set<String>, reviewDates: [String: Date]) async -> RestoredDecisions? {
        guard usePersistentProofs else { return nil }
        return await restoreDecisions(localIdentifiers: localIdentifiers, references: references, reasons: reasons,
            protectedIdentifiers: protectedIdentifiers, reviewDates: reviewDates, allowCachedProof: true, cachedOnly: true)
    }

    private func restoreDecisions(
        localIdentifiers: [String], references: [String: String], reasons: [String: CurationReasonCode],
        protectedIdentifiers: Set<String>, reviewDates: [String: Date], allowCachedProof: Bool, cachedOnly: Bool = false
    ) async -> RestoredDecisions {
        let task = Task.detached(priority: .userInitiated) {
            let restorationStarted = ProcessInfo.processInfo.systemUptime
            let ids = Array(Set(localIdentifiers + localIdentifiers.compactMap { references[$0] }))
            // A missing/evicted proof must not create six fresh6s waits before
            // Home can continue. Cache hits remain usable after this read budget;
            // unfinished live work is reported as retryable, never invalidated.
            let restoreDeadline = AnalysisDeadline(seconds: 9)
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard status == .authorized || status == .limited else {
                return RestoredDecisions(decisions: [], retryableFailureCount: 0, inaccessibleIdentifiers: Set(ids))
            }
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            var assets: [String: PHAsset] = [:]
            fetched.enumerateObjects { asset, _, _ in assets[asset.localIdentifier] = asset }
            var cache: [String: AnalyzedAsset] = [:]
            var unavailable = Set<String>()
            var deferredByBudget = Set<String>()
            var attemptedKeys = Set<String>()
            let originalCandidates = Set(localIdentifiers.filter {
                CleanupReasonGroup(reasons[$0]) == .identicalFile || (reasons[$0] == nil && references[$0] != nil)
            })
            let originalIDs = originalCandidates.union(originalCandidates.compactMap { references[$0] })
            func complete(_ proof: AnalyzedAsset, original: Bool, feature: Bool) -> Bool {
                original ? proof.fingerprint != nil
                    : proof.enrichmentAttempted && !proof.needsRetry && (!feature || proof.featurePrint != nil)
            }
            // Recover missing candidate AND comparison proofs together. A slow
            // first image must not consume the next reference's entire allowance
            // on every retry. Only this owner publishes completed live evidence.
            if allowCachedProof && !cachedOnly {
                let work = ids.compactMap { id -> (PHAsset, Bool, Bool, AnalyzedAsset?)? in
                    guard let asset = assets[id], !Self.metadata(for: asset, protectedIdentifiers: protectedIdentifiers).isExcluded,
                          reasons[id]?.isReflection != true else { return nil }
                    let original = originalIDs.contains(id)
                    let feature = !original && (references[id] != nil || references.values.contains(id))
                    let key = (original ? "original:" : "preview:") + id
                    let prior = Self.cachedAnalysis(asset, protectedIdentifiers: protectedIdentifiers, reviewDate: reviewDates[id])
                    if let prior, complete(prior, original: original, feature: feature) {
                        cache[key] = prior
                        return nil
                    }
                    attemptedKeys.insert(key)
                    return (asset, original, feature, prior)
                }
                let preparation = CurationConcurrentPreparation<AnalyzedAsset>(count: work.count,
                    deadline: restoreDeadline, itemTimeout: 9) { index, deadline, cancellation in
                    let (asset, original, feature, prior) = work[index]
                    guard !cancellation.isCancelled else { return nil }
                    let value = original
                        ? Self.analyzeOriginal(asset, protectedIdentifiers: protectedIdentifiers,
                            reviewDate: reviewDates[asset.localIdentifier], deadline: deadline, previewTimeout: 8)
                        : Self.analyze(asset, protectedIdentifiers: protectedIdentifiers,
                            reviewDate: reviewDates[asset.localIdentifier], deadline: deadline, prior: prior,
                            requiresFeature: feature, previewTimeout: 8, cancelled: { cancellation.isCancelled })
                    return cancellation.isCancelled ? nil : value
                }
                let prepared = preparation.wait(until: restoreDeadline, forAll: true)
                preparation.cancel()
                guard !Task.isCancelled else { return RestoredDecisions(decisions: [], retryableFailureCount: 0) }
                for (index, item) in work.enumerated() {
                    let (asset, original, _, _) = item
                    let id = asset.localIdentifier
                    let key = (original ? "original:" : "preview:") + id
                    if let value = prepared.values[index] {
                        cache[key] = value
                        Self.persistProof(value)
                        if !value.needsRetry { continue }
                    }
                    unavailable.insert(id)
                    deferredByBudget.insert(id)
                }
            }
            func analyzed(_ id: String, originalRequired: Bool) -> AnalyzedAsset? {
                guard !Task.isCancelled else { return nil }
                let cacheKey = (originalRequired ? "original:" : "preview:") + id
                if let cached = cache[cacheKey] { return cached }
                guard let asset = assets[id] else { return nil }
                let requiresFeature = !originalRequired && (references[id] != nil || references.values.contains(id))
                let storedProof = allowCachedProof
                    ? Self.cachedAnalysis(asset, protectedIdentifiers: protectedIdentifiers, reviewDate: reviewDates[id]) : nil
                CurationTimingDiagnostics.record("restorationProof", [
                    "candidate": localIdentifiers.contains(id) ? 1 : 0,
                    "contextReason": CleanupReasonGroup(reasons[id]) == .contextReview ? 1 : 0,
                    "cached": storedProof == nil ? 0 : 1,
                    "complete": storedProof?.enrichmentAttempted == true && storedProof?.needsRetry == false ? 1 : 0,
                    "requiresFeature": requiresFeature ? 1 : 0,
                    "feature": storedProof?.featurePrint == nil ? 0 : 1])
                if let proof = storedProof, complete(proof, original: originalRequired, feature: requiresFeature) {
                    cache[cacheKey] = proof
                    return proof
                }
                if cachedOnly || attemptedKeys.contains(cacheKey) {
                    if !Self.metadata(for: asset, protectedIdentifiers: protectedIdentifiers).isExcluded {
                        unavailable.insert(id)
                        deferredByBudget.insert(id)
                    }
                    return nil
                }
                let deadline = allowCachedProof ? restoreDeadline : AnalysisDeadline(seconds: 6)
                let result = originalRequired
                    ? Self.analyzeOriginal(asset, protectedIdentifiers: protectedIdentifiers,
                                           reviewDate: reviewDates[id], deadline: deadline)
                    : Self.analyze(asset, protectedIdentifiers: protectedIdentifiers,
                                   reviewDate: reviewDates[id], deadline: deadline, prior: storedProof,
                                   requiresFeature: requiresFeature)
                guard let analysis = result else {
                    if !Self.metadata(for: asset, protectedIdentifiers: protectedIdentifiers).isExcluded { unavailable.insert(id) }
                    if allowCachedProof && deadline.expired { deferredByBudget.insert(id) }
                    return nil
                }
                if analysis.needsRetry {
                    unavailable.insert(id)
                    if allowCachedProof && deadline.expired { deferredByBudget.insert(id) }
                }
                if usePersistentProofs { Self.persistProof(analysis) }
                cache[cacheKey] = analysis
                return analysis
            }
            let candidateIDs = Set(localIdentifiers)
            let decisions: [DecisionUnit] = localIdentifiers.compactMap { id in
                guard !Task.isCancelled else { return nil }
                if reasons[id]?.isReflection == true {
                    guard let asset = assets[id],
                          Self.canReflect(on: asset, reviewDates: reviewDates, now: Date()) else { return nil }
                    if cachedOnly { unavailable.insert(id); deferredByBudget.insert(id); return nil }
                    let approvedCloudRead = PhotoCloudAccess.shared.allows(id: id, revision: PhotoCloudAccess.revision(for: asset))
                    let timeout = allowCachedProof ? min(restoreDeadline.remaining, approvedCloudRead ? 8 : 1.5)
                        : (approvedCloudRead ? 8 : 1.5)
                    guard Self.reflectionPreviewIsReadable(for: asset, timeout: timeout,
                                                          allowsApprovedCloudAccess: approvedCloudRead) else {
                        if !Task.isCancelled { unavailable.insert(id) }
                        if allowCachedProof && restoreDeadline.expired { deferredByBudget.insert(id) }
                        return nil
                    }
                    return Task.isCancelled ? nil : Self.reflectionDecision(for: asset, reason: reasons[id] ?? .dailyReflection)
                }
                let originalRequired = CleanupReasonGroup(reasons[id]) == .identicalFile
                    || (reasons[id] == nil && references[id] != nil)
                guard let candidate = analyzed(id, originalRequired: originalRequired), candidate.photo.canRemove else { return nil }
                if let reviewDate = candidate.facts.reviewDate,
                   Calendar.current.startOfDay(for: reviewDate) > Calendar.current.startOfDay(for: Date()) { return nil }
                if let referenceID = references[id] {
                    guard !candidateIDs.contains(referenceID), let reference = analyzed(referenceID, originalRequired: originalRequired),
                          let reason = Self.pairReason(candidate, reference),
                          reasons[id] == nil || reasons[id] == reason else { return nil }
                    return Self.decision(candidate: candidate, reference: reference, reason: reason)
                }
                // Missing comparison evidence must never silently become a weaker suggestion.
                guard let expected = reasons[id],
                      let evidence = CurationContextPolicy.evidence(for: candidate.facts),
                      evidence.reason == expected else { return nil }
                return Self.decision(candidate: candidate, evidence: evidence)
            }
            // A missing optional analysis must not hold a successfully restored
            // decision hostage (for example an explicit user review date).
            let missing = Set(localIdentifiers).subtracting(decisions.compactMap(\.displayIdentifier))
            let needed = missing.union(missing.compactMap { references[$0] })
            let retryableCandidates = Set(missing.filter { id in
                unavailable.contains(id) || references[id].map { unavailable.contains($0) } == true
            })
            CurationTimingDiagnostics.record("restorationResult", [
                "cachedOnly": cachedOnly ? 1 : 0,
                "requested": Double(localIdentifiers.count), "restored": Double(decisions.count),
                "similar": Double(decisions.filter { CleanupReasonGroup($0.reasonCodes.first) == .similarCapture }.count),
                "context": Double(decisions.filter { CleanupReasonGroup($0.reasonCodes.first) == .contextReview }.count),
                "retryable": Double(retryableCandidates.count),
                "pending": deferredByBudget.isDisjoint(with: needed) ? 0 : 1,
                "inaccessible": Double(needed.subtracting(Set(assets.keys)).count),
                "seconds": ProcessInfo.processInfo.systemUptime - restorationStarted])
            return RestoredDecisions(decisions: decisions, retryableFailureCount: unavailable.intersection(needed).count,
                                     inaccessibleIdentifiers: needed.subtracting(Set(assets.keys)),
                                     hasPendingAnalysis: !deferredByBudget.isDisjoint(with: needed),
                                     retryableIdentifiers: retryableCandidates,
                                     assetRevisions: assets.compactMapValues { Self.proofRevision($0) })
        }
        return await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    /// Revalidate the displayed reason and current protection immediately before Photos deletion.
    func canDelete(_ unit: DecisionUnit, protectedIdentifiers: Set<String>, reviewDates: [String: Date] = [:]) async -> Bool {
        guard unit.type != .recallMoment, !unit.reasonCodes.contains(where: \.isReflection),
              unit.evidence?.reason.isReflection != true else { return false }
        let ids = unit.removalIdentifiers
        guard !ids.isEmpty, Set(ids).count == ids.count else { return false }
        let reference = unit.type == .cleanupSingle ? unit.comparisonLocalIdentifier : unit.displayIdentifier
        if let reference, ids.contains(reference) { return false }
        guard let reason = unit.evidence?.reason ?? unit.reasonCodes.first else { return false }
        if reference == nil && unit.evidence == nil { return false }
        // Deletion retains a live evidence check. Fast restore proofs are for
        // presenting unchanged candidates, never a shortcut around this boundary.
        let decisions = await restoreDecisions(localIdentifiers: ids,
            references: reference.map { ref in Dictionary(uniqueKeysWithValues: ids.map { ($0, ref) }) } ?? [:],
            reasons: Dictionary(uniqueKeysWithValues: ids.map { ($0, reason) }),
            protectedIdentifiers: protectedIdentifiers, reviewDates: reviewDates, allowCachedProof: false).decisions
        guard decisions.count == ids.count else { return false }
        // OCR dates or user-set dates may have changed while the confirmation was open.
        return decisions.allSatisfy { $0.evidence?.observedDate == unit.evidence?.observedDate }
    }

    /// Explicit deletion of the single photo the user chose has no curation claim.
    /// Favorites and record-linked photos remain eligible only through this path.
    func canDeleteSelectedPhoto(_ identifier: String) async -> Bool {
        guard !identifier.isEmpty, !Task.isCancelled else { return false }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return false }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard assets.count == 1, let asset = assets.firstObject,
              asset.localIdentifier == identifier, asset.mediaType == .image,
              !asset.isHidden, asset.canPerform(.delete) else { return false }
        return !Task.isCancelled
    }

    private static func findDecisions(in assets: [PHAsset], limit: Int, protectedIdentifiers: Set<String>,
                                      reviewDates: [String: Date] = [:], pairsOnly: Bool = false, onExamined: ((Set<String>) -> Void)? = nil,
                                      onAttempted: ((Set<String>) -> Void)? = nil,
                                      cache: AnalysisCache = AnalysisCache(), analysisLimit: Int = 64,
                                      timeLimit: TimeInterval = 12,
                                      usePersistentProofs: Bool = true,
                                      excludingReasonGroups: Set<CleanupReasonGroup> = [],
                                      previewRecoveryIdentifiers: Set<String> = [],
                                      priorityRecoveryIdentifier: String? = nil,
                                      allowDeferredContext: Bool = false,
                                      prioritizeContextEvidence: Bool = false,
                                      onDeferred: ((Set<String>, Set<String>, [DecisionUnit]) -> Void)? = nil,
                                      onContextExamined: ((Set<String>) -> Void)? = nil,
                                      onProgress: ((ScanProgress) -> Void)? = nil) -> [DecisionUnit] {
        guard limit > 0 else { return [] }
        let now = Date()
        let eligible = assets.filter { asset in
            guard !metadata(for: asset, protectedIdentifiers: protectedIdentifiers).isExcluded else { return false }
            // A user's future review date pauses all curation, including duplicate suggestions.
            return reviewDates[asset.localIdentifier].map { Calendar.current.startOfDay(for: $0) <= Calendar.current.startOfDay(for: now) } ?? true
        }
        var examined = Set(assets.map(\.localIdentifier)).subtracting(eligible.map(\.localIdentifier))
        var pendingAnalysis = Set<String>()
        let analysisStarted = ProcessInfo.processInfo.systemUptime
        defer {
            CurationTimingDiagnostics.record("analysisResult", ["seconds": ProcessInfo.processInfo.systemUptime - analysisStarted,
                "eligible": Double(eligible.count), "cachedPreviews": Double(cache.analyses.count),
                "completed": Double(cache.entries.count), "pending": Double(pendingAnalysis.count),
                "localPreviewDeferred": Double(cache.deferredPreviews.count), "failures": Double(cache.failures.count), "cancelled": Task.isCancelled ? 1 : 0])
            onExamined?(examined)
            // An OCR failure is an attempted preview, not an attempted original.
            // Keep the window until each promising pair got its first hash read.
            onAttempted?(examined.union(cache.failures.keys).subtracting(pendingAnalysis))
        }
        let byID = Dictionary(uniqueKeysWithValues: eligible.map { ($0.localIdentifier, $0) })
        let grouped = candidateGroups(from: eligible.compactMap { asset in
            asset.creationDate.map { CandidateMetadata(localIdentifier: asset.localIdentifier, creationDate: $0, burstIdentifier: asset.burstIdentifier) }
        }).flatMap { $0.prefix(12) }.compactMap { byID[$0.localIdentifier] }
        // Give each source a scan budget so screenshots cannot starve ordinary photos or vice versa.
        let due = eligible.filter { reviewDates[$0.localIdentifier] != nil }
        let screenshots = eligible.filter { $0.mediaSubtypes.contains(.photoScreenshot) }
        let nearby = grouped.filter { !$0.mediaSubtypes.contains(.photoScreenshot) }
        let nominated = Array(eligible.prefix(16))
        let nominationLimit = min(128, max(64, analysisLimit))
        var scanOrder = Array(due.prefix(2)) + nominated
        for offset in stride(from: 0, to: nominationLimit, by: 2) {
            scanOrder += screenshots.dropFirst(offset).prefix(2)
            scanOrder += nearby.dropFirst(offset).prefix(2)
            scanOrder += eligible.dropFirst(offset).prefix(2)
        }
        var seen = Set<String>()
        let prioritized = scanOrder.filter { seen.insert($0.localIdentifier).inserted }.prefix(nominationLimit)
        let revisions = Dictionary(uniqueKeysWithValues: prioritized.map {
            ($0.localIdentifier, AnalysisCache.Revision($0, protectedIdentifiers: protectedIdentifiers, reviewDates: reviewDates))
        })
        // Refetch every request: removed/inaccessible/edited photos invalidate
        // their evidence. Protecting an unchanged comparison partner changes
        // deletion eligibility, not its pixels, OCR or feature print. Rebind
        // that policy below instead of throwing its completed analysis away.
        cache.retain(revisions: revisions)
        var protectionChanges = 0
        cache.transformAnalyses { previous in
            var current = previous
            let isProtected = protectedIdentifiers.contains(current.photo.id)
            if current.photo.isProtected != isProtected { protectionChanges += 1 }
            current.photo.isProtected = isProtected
            return current
        }
        if protectionChanges > 0 {
            CurationTimingDiagnostics.record("comparisonProtectionRebound", ["count": Double(protectionChanges)])
        }
        if usePersistentProofs {
            for asset in prioritized where cache.analyses[asset.localIdentifier] == nil {
                guard let proof = cachedAnalysis(asset, protectedIdentifiers: protectedIdentifiers,
                    reviewDate: reviewDates[asset.localIdentifier]) else { continue }
                cache.record(proof, for: asset.localIdentifier, revision: revisions[asset.localIdentifier]!,
                    complete: proof.enrichmentAttempted && !proof.needsRetry, failed: false)
            }
        }
        for id in previewRecoveryIdentifiers where revisions[id] != nil
            && cache.analyses[id] == nil && cache.failures[id] == nil {
            cache.deferPreview(for: id, revision: revisions[id]!)
        }
        let demand = CurationEvidenceDemand(excluding: excludingReasonGroups)
        let prioritizesContext = prioritizeContextEvidence && excludingReasonGroups.contains(.similarCapture)
            && !excludingReasonGroups.contains(.contextReview)
        let previewDeadline = AnalysisDeadline(seconds: timeLimit)
        var checked = examined.union(cache.entries.keys).union(cache.failures.keys)
        onProgress?(ScanProgress(phase: .reading, checkedCount: checked.count, windowCount: assets.count))
        func store(_ analysis: AnalyzedAsset?, for id: String, failure: Bool = true) {
            guard let analysis else {
                if failure { cache.record(nil, for: id, revision: revisions[id]!, complete: false) }
                return
            }
            // A worker may have started before this partner became protected.
            // Publish current eligibility together with unchanged image facts.
            var current = analysis
            current.photo.isProtected = protectedIdentifiers.contains(id)
            let failed = (current.enrichmentAttempted && current.needsRetry)
                || current.originalState == .unavailable
            let complete = current.enrichmentAttempted && !current.needsRetry
                && current.originalState != .unavailable && current.originalState != .awaitingFullBudget
            let changedEvidence = cache.analyses[id]?.workState != current.workState
            cache.record(current, for: id, revision: revisions[id]!, complete: complete, failed: failed,
                advancesWork: changedEvidence)
            if usePersistentProofs && changedEvidence { persistProof(current) }
        }
        func previews() -> [AnalyzedAsset] {
            // `analyses` merges two dictionaries. Materialize it once per
            // snapshot, not once per photo (and again for every peer check).
            let analyses = cache.analyses
            return prioritized.compactMap { analyses[$0.localIdentifier] }
        }
        var originalNominationRevision: UInt64?
        var originalNominees = Set<String>()
        func originalNominationIDs() -> Set<String> {
            if originalNominationRevision != cache.workRevision {
                originalNominees = demand.originalIdentifiers { originalComparisonIdentifiers(previews()) }
                originalNominationRevision = cache.workRevision
            }
            return originalNominees
        }
        func readOriginals(deadline: AnalysisDeadline, fullRetry: Bool) {
            let values = previews()
            let originalIDs = originalNominationIDs()
            for preview in values where originalIDs.contains(preview.photo.id) {
                guard !Task.isCancelled, !deadline.expired else { return }
                let retry = preview.originalState == .awaitingFullBudget
                guard preview.originalState == .notRequested || (retry && fullRetry) else { continue }
                // A short first slice is allowed to defer once. The next attempt
                // starts with its own full local-read budget; iCloud failures do
                // not consume every following window.
                let readDeadline = retry ? AnalysisDeadline(seconds: min(3, deadline.remaining)) : deadline
                var updated = preview
                let originalStarted = ProcessInfo.processInfo.systemUptime
                let original = fingerprintResult(for: preview.asset, deadline: readDeadline)
                guard !Task.isCancelled else { return }
                CurationTimingDiagnostics.record("original", ["seconds": ProcessInfo.processInfo.systemUptime - originalStarted,
                    "verified": original.value == nil ? 0 : 1, "needsRetry": original.needsRetry ? 1 : 0,
                    "fullBudgetRetry": retry ? 1 : 0, "deadlineExpired": readDeadline.expired ? 1 : 0])
                updated.fingerprint = original.value
                if original.needsRetry {
                    updated.originalState = !retry && readDeadline.expired ? .awaitingFullBudget : .unavailable
                } else { updated.originalState = .resolved }
                store(updated, for: preview.photo.id)
            }
        }
        var featureNominationRevision: UInt64?
        var featureNominees = Set<String>()
        func needsFeature(_ value: AnalyzedAsset) -> Bool {
            guard !excludingReasonGroups.contains(.similarCapture), !value.facts.isScreenshot else { return false }
            if featureNominationRevision != cache.workRevision {
                featureNominees.removeAll(keepingCapacity: true)
                let values = previews().filter { !$0.facts.isScreenshot }
                for (index, first) in values.enumerated() {
                    for peer in values.dropFirst(index + 1) {
                        guard first.photo.canRemove || peer.photo.canRemove,
                              PhotoCurationPolicy.canCompare(first.photo, peer.photo),
                              comparisonNominationIsCompatible(first.metrics, peer.metrics,
                                reduced: first.previewIsReduced || peer.previewIsReduced) else { continue }
                        featureNominees.insert(first.photo.id)
                        featureNominees.insert(peer.photo.id)
                    }
                }
                featureNominationRevision = cache.workRevision
            }
            return featureNominees.contains(value.photo.id)
        }
        var decisionRevision: UInt64?
        var usefulDecision = false
        func hasUsefulDecision() -> Bool {
            if decisionRevision == cache.workRevision { return usefulDecision }
            let pairLaneAvailable = !excludingReasonGroups.contains(.identicalFile)
                || !excludingReasonGroups.contains(.similarCapture)
            // A foreground slice publishes its first proof immediately. The
            // collector then requests missing reasons; waiting for three of
            // the same kind here consumed that opportunity before publication.
            let desiredCount = min(limit, timeLimit <= 2 ? 1 : (pairLaneAvailable ? 3 : 1))
            usefulDecision = decisionsFromAnalyses(previews(), limit: limit, pairsOnly: pairsOnly, now: now,
                                 excludingReasonGroups: excludingReasonGroups).filter { decision in
                guard let group = CleanupReasonGroup(decision.evidence?.reason ?? decision.reasonCodes.first) else { return false }
                return !excludingReasonGroups.contains(group)
            }.count >= desiredCount
            decisionRevision = cache.workRevision
            return usefulDecision
        }
        var retainedPreparation = cache.preparation
        var fullPreparation = retainedPreparation?.pool
        var fullPreparationAssets = retainedPreparation?.inputs.map(\.asset) ?? []
        var consumedPrepared = Set((retainedPreparation?.consumed ?? []).compactMap { index in
            fullPreparationAssets.indices.contains(index) ? fullPreparationAssets[index].localIdentifier : nil
        })
        func consumePreparedAnalyses() {
            guard !Task.isCancelled, let prepared = fullPreparation?.snapshot() else { return }
            var drained = Set<Int>()
            for (index, result) in prepared.values.sorted(by: { $0.key < $1.key }) {
                guard fullPreparationAssets.indices.contains(index) else { continue }
                let asset = fullPreparationAssets[index], id = asset.localIdentifier
                drained.insert(index)
                guard !consumedPrepared.contains(id), let current = cache.analyses[id],
                      retainedPreparation?.revisions[id] == revisions[id],
                      revisions[id] == AnalysisCache.Revision(asset,
                        protectedIdentifiers: protectedIdentifiers, reviewDates: reviewDates) else { continue }
                var value = result
                // Original-file verification may have progressed while these
                // independent preview/OCR workers were running. Keep its newer
                // result; a stale worker cannot replace or invent that proof.
                value.fingerprint = current.fingerprint
                value.originalState = current.originalState
                if !value.needsRetry { value.preparedPreview = nil }
                else { value.enrichmentAttempted = false }
                store(value, for: id)
                consumedPrepared.insert(id)
            }
            retainedPreparation?.consumed.formUnion(drained)
            fullPreparation?.discardValues(at: drained)
        }
        defer {
            consumePreparedAnalyses()
            if let prepared = fullPreparation?.snapshot() {
                CurationTimingDiagnostics.record("fullPreparation", ["requested": Double(fullPreparationAssets.count),
                    "completed": Double(prepared.completed.count), "ready": Double(prepared.values.count),
                    "consumed": Double(consumedPrepared.count), "readConcurrency": 12, "analysisConcurrency": 4])
                if !Task.isCancelled {
                    for (index, value) in prepared.values {
                        guard fullPreparationAssets.indices.contains(index) else { continue }
                        let asset = fullPreparationAssets[index]
                        let id = asset.localIdentifier
                        guard !consumedPrepared.contains(id), var prior = cache.analyses[id],
                              revisions[id] == AnalysisCache.Revision(asset,
                                protectedIdentifiers: protectedIdentifiers, reviewDates: reviewDates),
                              needsFullImage(prior) else { continue }
                        prior.preparedPreview = value.preparedPreview
                        store(prior, for: id)
                    }
                }
            }
            if Task.isCancelled || retainedPreparation?.isFinished == true {
                fullPreparation?.cancel(); cache.preparation = nil
            } else { cache.preparation = retainedPreparation }
        }
        func needsFullImage(_ value: AnalyzedAsset) -> Bool {
            value.preparedPreview == nil
                && !evidenceIsComplete(fullPreview: !value.previewIsReduced, textKnown: value.facts.textLines != nil,
                facesKnown: value.facts.hasFace != nil,
                requiresFeature: needsFeature(value), hasFeature: value.featurePrint != nil)
                && (value.previewIsReduced || value.previewImage == nil)
        }
        func needsEvidence(_ value: AnalyzedAsset) -> Bool {
            !evidenceIsComplete(fullPreview: !value.previewIsReduced, textKnown: value.facts.textLines != nil,
                facesKnown: value.facts.hasFace != nil, requiresFeature: needsFeature(value), hasFeature: value.featurePrint != nil)
        }
        func hasPreparedImage(_ value: AnalyzedAsset) -> Bool {
            value.preparedPreview != nil || (!value.previewIsReduced && value.previewImage != nil)
                || !needsEvidence(value)
        }
        func beginFullPreparation() {
            guard fullPreparation == nil, !previewDeadline.expired, !hasUsefulDecision() else { return }
            let began = ProcessInfo.processInfo.systemUptime
            defer { CurationTimingDiagnostics.record("preparationNomination", [
                "seconds": ProcessInfo.processInfo.systemUptime - began,
                "selected": Double(fullPreparationAssets.count)]) }
            let byIdentifier = Dictionary(uniqueKeysWithValues: previews().map { ($0.photo.id, $0) })
            let ordered = cache.enrichmentOrder(among: prioritized.map(\.localIdentifier),
                priority: Set(previews().filter(needsFeature).map(\.photo.id)))
            let available = ordered.compactMap { byIdentifier[$0] }.filter(needsEvidence)
            let pairPeers = ordered.compactMap { byIdentifier[$0] }.filter(needsFeature)
            let pairs = pairPeers.filter(needsEvidence)
            let pairIDs = Set(pairs.map(\.photo.id))
            var context = available.filter { value in
                value.photo.canRemove && !pairIDs.contains(value.photo.id)
                    && (value.facts.isScreenshot || value.facts.reviewDate != nil
                        || (prioritizesContext && value.facts.capturedAt.map { now.timeIntervalSince($0) >= 7 * 86400 } == true)
                        || (value.metrics.sharpness < 0.003 && value.metrics.luminanceRange < 0.15))
            }
            if prioritizesContext {
                // A missing context slot should inspect actual screen text
                // before spending its remaining turns on ordinary landscapes.
                context = context.filter { $0.facts.isScreenshot || $0.facts.reviewDate != nil }
                    + context.filter { !$0.facts.isScreenshot && $0.facts.reviewDate == nil }
            }
            context = context.filter { !$0.previewIsReduced } + context.filter(\.previewIsReduced)
            // Prepare a compatible pair together, rather than two unrelated
            // pair members whose partners would need serial image reads later.
            var pairNominations: [PairPreparationCandidate] = []
            for (index, first) in pairPeers.enumerated() {
                for peer in pairPeers.dropFirst(index + 1) {
                    guard first.photo.canRemove || peer.photo.canRemove,
                          pairIDs.contains(first.photo.id) || pairIDs.contains(peer.photo.id),
                          PhotoCurationPolicy.canCompare(first.photo, peer.photo),
                          comparisonNominationIsCompatible(first.metrics, peer.metrics,
                            reduced: first.previewIsReduced || peer.previewIsReduced) else { continue }
                    let difference = pixelDifference(first.metrics.colors, peer.metrics.colors)
                    pairNominations.append(.init(identifiers: [first.photo.id, peer.photo.id],
                        attemptOrders: [cache.enrichmentAttemptOrder(for: first.photo.id),
                                        cache.enrichmentAttemptOrder(for: peer.photo.id)],
                        visualDifference: difference.mean + difference.largestTile * 0.15,
                        localPreviewCount: (hasPreparedImage(first) ? 1 : 0) + (hasPreparedImage(peer) ? 1 : 0)))
                }
            }
            // A previously read comparison partner is reusable. Only its
            // missing peer needs a new read; neither is deletion evidence yet.
            let preparedIDs = Set(pairPeers.map(\.photo.id)).subtracting(pairIDs)
            // Prefer complete local pairs, but keep another promising pair in
            // the bounded queue. A local-only lane can be full of unrelated
            // screenshots while a useful comparison needs one more image.
            let nominees = fullPreparationIdentifiers(pairs: pairNominations, context: context.map(\.photo.id),
                alreadyPrepared: preparedIDs, limit: analysisLimit > 64 ? 12 : 8)
            fullPreparationAssets = nominees.compactMap { byIdentifier[$0]?.asset }
            guard !fullPreparationAssets.isEmpty else { return }
            let inputs = fullPreparationAssets
            let priorValues = inputs.compactMap { byIdentifier[$0.localIdentifier] }
            let featureRequirements = priorValues.map(needsFeature)
            for asset in inputs {
                cache.noteEnrichmentAttempt(for: asset.localIdentifier, revision: revisions[asset.localIdentifier]!)
            }
            // The read has its own bounded lifetime across two-second UI
            // slices. Ending a slice no longer restarts the same iCloud decode
            // or cold Vision work. At most three parked windows retain it.
            let preparationDeadline = AnalysisDeadline(seconds: 6)
            fullPreparation = CurationConcurrentPreparation<AnalyzedAsset>(count: inputs.count,
                concurrency: 12, maximumConcurrency: 12, deadline: preparationDeadline, itemTimeout: 5) { index, deadline, cancellation in
                // This is the same authorized preview access used by analyze;
                // original-file networking still requires its separate consent.
                let prior = priorValues[index]
                let local = !prior.previewIsReduced ? prior.previewImage.map {
                    AnalysisPreview(image: UIImage(cgImage: $0), isAnalysisQuality: true)
                } : nil
                let prepared = local ?? prior.preparedPreview
                let value = prepared ?? fullPreviewReads.perform(until: deadline, cancelled: { cancellation.isCancelled }) {
                    thumbnail(for: inputs[index], deadline: deadline,
                        allowsNetwork: true, cancelled: { cancellation.isCancelled })
                }
                guard let value, value.isAnalysisQuality else { return nil }
                // Complete evidence on the same bounded worker as the image
                // read. Ready images no longer queue behind serial OCR of an
                // unrelated screen; all thresholds and the shared deadline stay.
                var result = fullEvidenceAnalysis.perform(until: deadline, cancelled: { cancellation.isCancelled }) {
                    analyze(inputs[index], protectedIdentifiers: protectedIdentifiers,
                        reviewDate: reviewDates[inputs[index].localIdentifier], deadline: deadline,
                        prior: prior, requiresFeature: featureRequirements[index], preparedPreview: value,
                        cancelled: { cancellation.isCancelled })
                } ?? prior
                result.preparedPreview = value
                return result
            }
            CurationTimingDiagnostics.record("preparationSource", [
                "inputs": Double(inputs.count), "readyImages": Double(priorValues.filter(hasPreparedImage).count),
                "pairNominations": Double(pairNominations.count),
                "localPairs": Double(pairNominations.filter { $0.localPreviewCount == 2 }.count),
                "mixedPairs": Double(pairNominations.filter { $0.localPreviewCount == 1 }.count),
                "contextNominees": Double(context.count)])
            retainedPreparation = CurationWindowPreparation(
                identifiers: inputs.map(\.localIdentifier), revisions: revisions,
                inputs: priorValues, pool: fullPreparation!)
            cache.preparation = retainedPreparation
        }
        func preparedPreviews() -> [String: AnalysisPreview] {
            let retained = Dictionary(uniqueKeysWithValues: previews().compactMap { value in
                value.preparedPreview.map { (value.photo.id, $0) }
            })
            guard let snapshot = fullPreparation?.snapshot() else { return retained }
            return retained.merging(Dictionary(uniqueKeysWithValues: snapshot.values.compactMap { index, value in
                guard fullPreparationAssets.indices.contains(index) else { return nil }
                let id = fullPreparationAssets[index].localIdentifier
                guard !consumedPrepared.contains(id), revisions[id] == AnalysisCache.Revision(fullPreparationAssets[index],
                    protectedIdentifiers: protectedIdentifiers, reviewDates: reviewDates) else { return nil }
                return value.preparedPreview.map { (id, $0) }
            })) { _, current in current }
        }

        var chunkCount = 0
        consumePreparedAnalyses()
        repeat {
            let workBeforeChunk = cache.workRevision
            chunkCount += 1
        // Fresh local thumbnails get a turn before a deferred original. A slow
        // cloud-backed pair must not block every later readable candidate.
        let hadPendingEnrichment = previews().contains { !$0.enrichmentAttempted && !$0.contextDeferred }
        if !hasUsefulDecision() {
            // Thumbnail metrics are cheap and can nominate exact pairs without
            // waiting for unrelated OCR or a cold Vision model.
            // A local miss is deferred, not an error and not examined coverage.
            // Finish the other fast local candidates before network recovery.
            let previewWork: (identifiers: [String], allowsNetwork: Bool)
            if let id = priorityRecoveryIdentifier, cache.deferredPreviews[id] != nil {
                previewWork = ([id], true)
            } else { previewWork = cache.nextPreviewWork(among: prioritized.map(\.localIdentifier),
                hasPendingEnrichment: hadPendingEnrichment) }
            let recoveringPreviews = previewWork.allowsNetwork
            let work = previewWork.identifiers.compactMap { byID[$0] }
            // PhotoKit can prepare the next few local thumbnails while the
            // first one is read; this never starts iCloud downloads.
            let preheated = recoveringPreviews ? [] : Array(work.prefix(min(8, analysisLimit)))
            let localOptions = previewRequestOptions(authorization: PHPhotoLibrary.authorizationStatus(for: .readWrite), nominationOnly: true)
            if let localOptions, !preheated.isEmpty {
                    analysisImageManager.startCachingImages(for: preheated, targetSize: CGSize(width: 384, height: 384),
                    contentMode: .aspectFit, options: localOptions)
            }
            defer {
                if let localOptions, !preheated.isEmpty {
                    analysisImageManager.stopCachingImages(for: preheated, targetSize: CGSize(width: 384, height: 384),
                        contentMode: .aspectFit, options: localOptions)
                }
            }
            // Cover this whole cheap metadata window before OCR or full images
            // can consume the slice. The shared wall-clock deadline is unchanged.
            let boundedWork = Array(work.prefix(min(128, analysisLimit)))
            var prepared: [Int: AnalyzedAsset] = [:]
            var finished = Set<Int>()
            if !recoveringPreviews && !boundedWork.isEmpty {
                // Check actual full-quality local availability before choosing
                // expensive pairs. Tiny iCloud thumbnails alone made the best
                // looking nominations wait for remote originals. This phase is
                // capped at0.6s and never downloads an image.
                let localDeadline = AnalysisDeadline(seconds: min(0.6, previewDeadline.remaining))
                let local = CurationConcurrentPreparation<AnalyzedAsset>(count: boundedWork.count,
                    concurrency: 4, deadline: localDeadline, itemTimeout: 0.12) { index, deadline, cancellation in
                    let asset = boundedWork[index]
                    return analyze(asset, protectedIdentifiers: protectedIdentifiers,
                        reviewDate: reviewDates[asset.localIdentifier], deadline: deadline,
                        previewOnly: true, allowsPreviewNetwork: false, preferAnalysisPreview: true,
                        cancelled: { cancellation.isCancelled })
                }
                let localResult = local.wait(until: localDeadline, forAll: true)
                local.cancel()
                prepared = localResult.values
                CurationTimingDiagnostics.record("localFullAvailability", ["requested": Double(boundedWork.count),
                    "completed": Double(localResult.completed.count), "ready": Double(prepared.count)])
                let localPrepared = prepared
                let batch = CurationConcurrentPreparation<AnalyzedAsset>(count: boundedWork.count,
                    concurrency: 4, deadline: previewDeadline, itemTimeout: 0.08) { index, deadline, cancellation in
                    if let ready = localPrepared[index] { return ready }
                    let asset = boundedWork[index]
                    return analyze(asset, protectedIdentifiers: protectedIdentifiers,
                        reviewDate: reviewDates[asset.localIdentifier], deadline: deadline,
                        previewOnly: true, allowsPreviewNetwork: false,
                        cancelled: { cancellation.isCancelled })
                }
                let snapshot = batch.wait(until: previewDeadline, forAll: true)
                batch.cancel()
                prepared.merge(snapshot.values) { _, newer in newer }; finished = snapshot.completed.union(localPrepared.keys)
                CurationTimingDiagnostics.record("localPreparation", ["requested": Double(boundedWork.count),
                    "completed": Double(finished.count), "ready": Double(prepared.count), "concurrency": 4])
            } else {
                // An explicit network-preview recovery remains one bounded
                // request, never part of the parallel local preparation queue.
                for (index, asset) in boundedWork.enumerated() {
                    guard !Task.isCancelled else { return [] }
                    guard !previewDeadline.expired else { break }
                    let readDeadline = AnalysisDeadline(seconds: min(previewDeadline.remaining,
                        priorityRecoveryIdentifier == nil ? 3 : 1))
                    if let value = autoreleasepool(invoking: {
                        analyze(asset, protectedIdentifiers: protectedIdentifiers,
                            reviewDate: reviewDates[asset.localIdentifier], deadline: readDeadline,
                            previewOnly: true, allowsPreviewNetwork: true)
                    }) { prepared[index] = value }
                    finished.insert(index)
                }
            }
            guard !Task.isCancelled else { return [] }
            for index in finished.sorted() {
                let asset = boundedWork[index]
                if prepared[index] == nil && !recoveringPreviews {
                    cache.deferPreview(for: asset.localIdentifier, revision: revisions[asset.localIdentifier]!)
                } else {
                    store(prepared[index], for: asset.localIdentifier)
                }
                checked.insert(asset.localIdentifier)
                onProgress?(ScanProgress(phase: .reading, checkedCount: checked.count, windowCount: assets.count))
            }
            beginFullPreparation()
            // Retain the images actually nominated for evidence, rather than
            // the first unrelated images returned by PhotoKit. Workers already
            // hold immutable inputs; all other temporary bitmaps can be freed.
            let nominatedImages = Set(fullPreparationAssets.map(\.localIdentifier))
            let spareImages = Set(previews().filter { !nominatedImages.contains($0.photo.id)
                && !$0.previewIsReduced && $0.previewImage != nil }.prefix(4).map(\.photo.id))
            cache.transformAnalyses { value in
                var bounded = value
                if !nominatedImages.contains(value.photo.id) && !spareImages.contains(value.photo.id) {
                    bounded.previewImage = nil
                }
                return bounded
            }
            prepared.removeAll()
            if !prioritizesContext { readOriginals(deadline: previewDeadline, fullRetry: false) }
        }
        beginFullPreparation()
        if !prioritizesContext { readOriginals(deadline: previewDeadline, fullRetry: true) }
        // Deliver proven file copies immediately. A subsequent pass enriches
        // remaining previews, using a fresh bounded budget instead of repeatedly
        // cancelling the same cold OCR request after a leftover 1.5 seconds.
        if !hasUsefulDecision() {
            // The same wall-clock budget covers previews, originals and Vision.
            // Restarting a fresh8s allowance here made an advertised1.5s slice
            // take10s+ and prevented Home from honoring its foreground limit.
            let enrichmentDeadline = previewDeadline
            let pairIDs = Set(previews().filter(needsFeature).map(\.photo.id))
            var enrichmentIDs = cache.enrichmentOrder(among: prioritized.map(\.localIdentifier), priority: pairIDs)
            while !enrichmentIDs.isEmpty {
                guard !Task.isCancelled else { return [] }
                guard enrichmentDeadline.remaining >= 0.25 else { break }
                consumePreparedAnalyses()
                if hasUsefulDecision() { break }
                if retainedPreparation?.isFinished == true {
                    fullPreparation?.cancel(); fullPreparation = nil; retainedPreparation = nil; cache.preparation = nil
                    fullPreparationAssets = []; consumedPrepared.removeAll()
                    beginFullPreparation()
                }
                var ready = preparedPreviews()
                if let preparation = fullPreparation,
                   Set(ready.keys).isDisjoint(with: enrichmentIDs) {
                    let snapshot = preparation.snapshot()
                    let pending = Set(fullPreparationAssets.indices.filter { index in
                        enrichmentIDs.contains(fullPreparationAssets[index].localIdentifier)
                            && !snapshot.completed.contains(index)
                    })
                    if !pending.isEmpty {
                        _ = preparation.wait(until: enrichmentDeadline, forAnyOf: pending)
                        consumePreparedAnalyses()
                        if hasUsefulDecision() { break }
                        ready = preparedPreviews()
                    }
                }
                let next = preparedEnrichmentIndex(in: enrichmentIDs, ready: Set(ready.keys))
                let id = enrichmentIDs.remove(at: next)
                guard let asset = byID[id], let existing = cache.analyses[id] else { continue }
                let requiresFeature = needsFeature(existing)
                // A newly arrived peer can make a previous single image worth
                // comparing. Missing feature prints must be generated lazily.
                guard !existing.enrichmentAttempted || (requiresFeature && existing.featurePrint == nil && !existing.needsRetry) else { continue }
                if existing.contextDeferred && !requiresFeature && !allowDeferredContext { continue }
                guard enrichmentDeadline.remaining >= 0.25 else { break }
                if needsFullImage(existing), ready[id] == nil,
                   timeLimit <= 2 || fullPreparationAssets.contains(where: { $0.localIdentifier == id }) {
                    // A failed or pending prepared read remains unknown. Do not
                    // duplicate it synchronously, nor turn it into completed
                    // evidence; a later fair pass may retry the image.
                    continue
                }
                var demand = !existing.photo.canRemove && !requiresFeature ? .deferUnknown : contextEnrichmentDemand(capturedAt: existing.facts.capturedAt,
                    isScreenshot: existing.facts.isScreenshot, hasReviewDate: existing.facts.reviewDate != nil,
                    requiresFeature: requiresFeature, sharpness: existing.metrics.sharpness,
                    luminanceRange: existing.metrics.luminanceRange, resumeDeferred: allowDeferredContext, now: now)
                if demand == .screenTextRegions {
                    // A negative or interrupted region detector does not become
                    // empty OCR. It defers this single-photo context work only.
                    let screen = existing.previewImage.flatMap { image in
                        try? hasTextRegions(image, deadline: enrichmentDeadline)
                    }
                    demand = screen == true ? .fullEvidence : .deferUnknown
                }
                if demand == .deferUnknown {
                    if !existing.contextDeferred {
                        var deferred = existing
                        deferred.contextDeferred = true
                        store(deferred, for: asset.localIdentifier, failure: false)
                    }
                    continue
                }
                let availableBudget = enrichmentDeadline.remaining
                cache.noteEnrichmentAttempt(for: asset.localIdentifier, revision: revisions[asset.localIdentifier]!)
                let analysis = autoreleasepool(invoking: {
                    analyze(asset, protectedIdentifiers: protectedIdentifiers,
                            reviewDate: reviewDates[asset.localIdentifier], deadline: enrichmentDeadline,
                            prior: existing, requiresFeature: requiresFeature,
                            preparedPreview: ready[asset.localIdentifier])
                })
                if ready[asset.localIdentifier] != nil { consumedPrepared.insert(asset.localIdentifier) }
                guard !Task.isCancelled else { return [] }
                // The preview remains available for SHA comparisons even if the
                // full-budget enrichment cannot finish on this device.
                let exhaustedPartialBudget = enrichmentDeadline.expired && availableBudget < 7.5
                if var analysis {
                    // Work started late in a slice receives a full opportunity
                    // next time; keep any already completed OCR/feature facts.
                    if exhaustedPartialBudget && analysis.needsRetry {
                        analysis.enrichmentAttempted = false
                        // The returned metrics/facts describe the final image
                        // just loaded. Do not demote it to the old coarse state
                        // and count the same HQ reload as new work next time.
                        analysis.previewImage = existing.previewIsReduced ? nil : existing.previewImage
                    }
                    if analysis.needsRetry {
                        analysis.preparedPreview = ready[asset.localIdentifier] ?? existing.preparedPreview
                    }
                    store(analysis, for: asset.localIdentifier)
                } else {
                    var failed = existing
                    failed.needsRetry = true
                    failed.enrichmentAttempted = !exhaustedPartialBudget
                    if !exhaustedPartialBudget { failed.previewImage = nil }
                    store(failed, for: asset.localIdentifier)
                }
                onProgress?(ScanProgress(phase: .reading, checkedCount: checked.count, windowCount: assets.count))
                if hasUsefulDecision() { break }
            }
        }
            if prioritizesContext, !hasUsefulDecision() { readOriginals(deadline: previewDeadline, fullRetry: true) }
            guard !hasUsefulDecision(), !Task.isCancelled, previewDeadline.remaining >= 0.25,
                  cache.workRevision > workBeforeChunk, chunkCount < 2 else { break }
            let nextLocal = cache.nextPreviewWork(among: prioritized.map(\.localIdentifier))
            guard !nextLocal.allowsNetwork, !nextLocal.identifiers.isEmpty else { break }
            // Use the remaining shared budget for the next local chunk. No new
            // deadline is started and no unresolved window is marked scanned.
            if retainedPreparation?.isFinished != true { break }
            fullPreparation?.cancel(); fullPreparation = nil; retainedPreparation = nil; cache.preparation = nil
            fullPreparationAssets = []; consumedPrepared.removeAll()
        } while true
        guard !Task.isCancelled else { return [] }
        consumePreparedAnalyses()
        onProgress?(ScanProgress(phase: .comparing, checkedCount: checked.count, windowCount: assets.count))
        let analyses = previews()
        // A completed negative context check advances just that evidence lane.
        // The same photo remains eligible as a member of a real duplicate pair.
        // Unknown/partial OCR is never counted as negative evidence.
        onContextExamined?(Set(analyses.filter {
            !$0.previewIsReduced && $0.facts.textLines != nil && $0.facts.hasFace != nil
                && CurationContextPolicy.evidence(for: $0.facts, now: now) == nil
        }.map(\.photo.id)))
        let originalIDs = originalNominationIDs()
        examined.formUnion(cache.entries.keys)
        // A prior pair pass may have left an otherwise complete preview waiting
        // for its original. Context-only work no longer needs that original.
        examined.formUnion(analyses.filter {
            $0.enrichmentAttempted && !$0.needsRetry
                && $0.originalState.permitsCompletedPreview(originalRequired: originalIDs.contains($0.photo.id))
        }.map(\.photo.id))
        let pendingFeatures = Set(analyses.filter {
            needsFeature($0) && $0.featurePrint == nil && !$0.needsRetry
        }.map(\.photo.id))
        pendingAnalysis = Set(analyses.filter {
            !$0.enrichmentAttempted || pendingFeatures.contains($0.photo.id)
                || (originalIDs.contains($0.photo.id)
                    && ($0.originalState == .notRequested || $0.originalState == .awaitingFullBudget))
        }.map(\.photo.id)).union(cache.deferredPreviews.keys)
        examined.subtract(analyses.filter {
            !$0.enrichmentAttempted || pendingFeatures.contains($0.photo.id)
                || (originalIDs.contains($0.photo.id) && $0.originalState != .resolved)
        }.map(\.photo.id))
        let decisions = decisionsFromAnalyses(analyses, limit: limit, pairsOnly: pairsOnly, now: now,
                                            excludingReasonGroups: excludingReasonGroups)
        if !excludingReasonGroups.isEmpty {
            let otherGroups = Set<CleanupReasonGroup>([.identicalFile, .similarCapture, .contextReview])
                .subtracting(excludingReasonGroups)
            // Already proven, represented candidates remain available to a later
            // request; suppressing them here must not retire them as scanned.
            let deferred = decisionsFromAnalyses(analyses, limit: 64, pairsOnly: pairsOnly, now: now,
                                                excludingReasonGroups: otherGroups)
            let chosen = Set(decisions.flatMap(\.removalIdentifiers))
            onDeferred?(Set(deferred.flatMap(\.removalIdentifiers)).subtracting(chosen),
                        Set(deferred.compactMap(\.comparisonLocalIdentifier)).subtracting(chosen),
                        deferred.filter { $0.displayIdentifier.map { !chosen.contains($0) } == true })
        }
        if CurationTimingDiagnostics.enabled {
            CurationTimingDiagnostics.record("analysisEligibility", analysisDiagnosticCounts(analyses, decisions: decisions, now: now))
        }
        return decisions
    }

    private static func analysisDiagnosticCounts(_ analyses: [AnalyzedAsset], decisions: [DecisionUnit],
                                                now: Date) -> [String: Double] {
        let started = ProcessInfo.processInfo.systemUptime
        var counts: [String: Double] = ["analyzedPhotos": Double(analyses.count),
            "removablePhotos": Double(analyses.filter { $0.photo.canRemove }.count),
            "contextTextComplete": Double(analyses.filter { $0.facts.textLines != nil && $0.facts.hasFace != nil }.count),
            "withRecognizedText": Double(analyses.filter { $0.facts.textLines?.isEmpty == false }.count),
            "withConfidentText": Double(analyses.filter { !$0.facts.confidentTextLines.isEmpty }.count),
            "withFingerprint": Double(analyses.filter { $0.fingerprint != nil }.count),
            "withFeaturePrint": Double(analyses.filter { $0.featurePrint != nil }.count),
            "nearbyMetadataPairs": 0, "coarseSimilarPairs": 0, "coarseOriginalPairs": 0,
            "verifiedExactPairs": 0, "verifiedSimilarPairs": 0, "rawContextCandidates": 0,
            "selectedDecisions": Double(decisions.count)]
        for value in analyses where value.photo.canRemove {
            if let evidence = CurationContextPolicy.evidence(for: value.facts, now: now) {
                counts["rawContextCandidates", default: 0] += 1
                counts["rawReason." + evidence.reason.rawValue, default: 0] += 1
            }
        }
        for (index, lhs) in analyses.enumerated() {
            for rhs in analyses.dropFirst(index + 1) where lhs.photo.canRemove || rhs.photo.canRemove {
                if identicalFileReason(lhs, rhs) != nil { counts["verifiedExactPairs", default: 0] += 1 }
                if !lhs.asset.hasAdjustments, !rhs.asset.hasAdjustments,
                   lhs.photo.width == rhs.photo.width, lhs.photo.height == rhs.photo.height,
                   Double(lhs.photo.width) * Double(lhs.photo.height) <= 32_000_000,
                   lhs.facts.isScreenshot == rhs.facts.isScreenshot,
                   originalPreviewsAreCompatible(lhs.metrics.colors, rhs.metrics.colors) {
                    counts["coarseOriginalPairs", default: 0] += 1
                }
                if !lhs.facts.isScreenshot, !rhs.facts.isScreenshot, PhotoCurationPolicy.canCompare(lhs.photo, rhs.photo) {
                    counts["nearbyMetadataPairs", default: 0] += 1
                    if visualPreviewsAreCompatible(lhs.metrics, rhs.metrics) {
                        counts["coarseSimilarPairs", default: 0] += 1
                    }
                    if pairReason(lhs, rhs) == .visuallySimilar { counts["verifiedSimilarPairs", default: 0] += 1 }
                }
            }
        }
        for decision in decisions {
            if let reason = decision.evidence?.reason ?? decision.reasonCodes.first {
                counts["selectedReason." + reason.rawValue, default: 0] += 1
            }
        }
        counts["diagnosticSeconds"] = ProcessInfo.processInfo.systemUptime - started
        return counts
    }

    private static func decisionsFromAnalyses(_ analyses: [AnalyzedAsset], limit: Int,
                                              pairsOnly: Bool, now: Date,
                                              excludingReasonGroups: Set<CleanupReasonGroup> = []) -> [DecisionUnit] {
        let byAnalysisID = Dictionary(uniqueKeysWithValues: analyses.map { ($0.photo.id, $0) })
        // Exact file identity is stronger than thumbnail similarity and needs no time window.
        return CurationEvidenceDemand(excluding: excludingReasonGroups).collect(limit: limit, pairsOnly: pairsOnly) { group, remaining, reserved in
            let exactOnly = group == .identicalFile
            let available = analyses.filter { !reserved.contains($0.photo.id) }
            let pairs = PhotoCurationPolicy.selectPairs(from: available.map(\.photo), limit: remaining,
                                                       requiresNearbyCapture: !exactOnly) { left, right in
                guard let lhs = byAnalysisID[left.id], let rhs = byAnalysisID[right.id] else { return false }
                if exactOnly { return identicalFileReason(lhs, rhs) != nil }
                return pairReason(lhs, rhs) == .visuallySimilar
            }
            return pairs.compactMap { pair in
                guard let candidate = byAnalysisID[pair.candidateID], let reference = byAnalysisID[pair.referenceID],
                      let reason = pairReason(candidate, reference) else { return nil }
                return decision(candidate: candidate, reference: reference, reason: reason)
            }
        } context: { reserved in
        let reviews = analyses.compactMap { candidate -> (AnalyzedAsset, CurationEvidence)? in
            guard candidate.photo.canRemove, !reserved.contains(candidate.photo.id),
                  let evidence = CurationContextPolicy.evidence(for: candidate.facts, now: now) else { return nil }
            return (candidate, evidence)
        }.sorted {
            let order: [CurationReasonCode] = [.reviewDateReached, .expiredScreen, .temporaryReference, .shoppingScreen, .lowDetail]
            let lhs = order.firstIndex(of: $0.1.reason) ?? 99
            let rhs = order.firstIndex(of: $1.1.reason) ?? 99
            return lhs == rhs ? $0.0.photo.id < $1.0.photo.id : lhs < rhs
        }
        // At most one uncertain review per daily set; never pad with age-only candidates.
            return reviews.first.map { decision(candidate: $0.0, evidence: $0.1) }
        }
    }

    private static func decision(candidate: AnalyzedAsset, reference: AnalyzedAsset, reason: CurationReasonCode) -> DecisionUnit {
        let description: String
        if let line = candidate.facts.confidentTextLines.first(where: { $0.count >= 4 }) {
            let excerpt = String(line.prefix(20)) + (line.count > 20 ? "…" : "")
            description = String(localized: "‘\(excerpt)’ 문구가 담긴 사진")
        } else if candidate.facts.hasFace == true {
            description = String(localized: "얼굴이 보이는 사진")
        } else {
            description = candidate.facts.isScreenshot ? String(localized: "같은 화면을 저장한 스크린샷") : String(localized: "오늘 비교해볼 사진")
        }
        let detail = reason == .visuallySimilar
            ? String(localized: "30초 안에 촬영된 두 사진의 이미지가 비슷해요. 표정·작은 글자까지 같다는 뜻은 아니니 비교해서 골라주세요.")
            : String(localized: "기기에 있는 현재 이미지 파일의 전체 데이터가 같아요. 아래 비교 사진은 남겨두고, 이 사진만 비울 수 있어요.")
        let evidence = CurationEvidence(reason: reason, photoDescription: description, detail: detail)
        var result = decision(candidate: candidate, evidence: evidence)
        result.comparisonLocalIdentifier = reference.photo.id
        return result
    }

    private static func decision(candidate: AnalyzedAsset, evidence: CurationEvidence) -> DecisionUnit {
        DecisionUnit(id: UUID(), type: .cleanupSingle, status: .pending,
                     candidateLocalIdentifiers: [candidate.photo.id], recommendedLocalIdentifier: candidate.photo.id,
                     selectedLocalIdentifier: nil, reasonCodes: [evidence.reason],
                     capturedDateDescription: candidate.asset.creationDate.map(dateDescription), createdAt: Date(),
                     evidence: evidence, capturedAt: candidate.asset.creationDate)
    }

    private static func canReflect(on asset: PHAsset, reviewDates: [String: Date], now: Date) -> Bool {
        guard asset.mediaType == .image, !asset.isHidden else { return false }
        return reviewDates[asset.localIdentifier].map {
            Calendar.current.startOfDay(for: $0) <= Calendar.current.startOfDay(for: now)
        } ?? true
    }

    private static func reflectionDecision(for asset: PHAsset, reason: CurationReasonCode = .dailyReflection,
                                           now: Date = Date()) -> DecisionUnit {
        let capturedDate = asset.creationDate.map(dateDescription)
        let evidence = Self.reflectionEvidence(reason: reason, capturedAt: asset.creationDate, now: now)
        return DecisionUnit(id: UUID(), type: .recallMoment, status: .pending,
            candidateLocalIdentifiers: [asset.localIdentifier], recommendedLocalIdentifier: asset.localIdentifier,
            selectedLocalIdentifier: nil, reasonCodes: [evidence.reason],
            capturedDateDescription: capturedDate, createdAt: Date(), evidence: evidence, capturedAt: asset.creationDate)
    }

    /// Keep the headline tied to the actual selection path, including restored anniversaries.
    static func reflectionEvidence(reason: CurationReasonCode, capturedAt: Date?, now: Date = Date()) -> CurationEvidence {
        let capturedDate = capturedAt.map(dateDescription)
        let validReason: CurationReasonCode = reason == .anniversaryReflection
            && PhotoAnniversaryPolicy.matches(capturedAt, relativeTo: now) ? .anniversaryReflection : .dailyReflection
        let selectedByRecency = reason == .dailyReflection && capturedAt != nil
        return CurationEvidence(reason: validReason,
            photoDescription: capturedDate.map { String(localized: "\($0)의 사진") } ?? String(localized: "오늘 다시 만난 사진"),
            detail: validReason == .anniversaryReflection
                ? String(localized: "지난해 같은 날짜에서 앞뒤 7일 안에 찍은 사진이에요.")
                : (selectedByRecency ? String(localized: "허용한 사진 중 최근 사진부터 골랐어요.") : String(localized: "허용한 사진 중 다시 살펴보도록 골랐어요.")),
            selectionSummary: validReason == .anniversaryReflection ? CurationReasonCode.anniversaryReflection.displayText
                : (selectedByRecency ? String(localized: "최근 사진부터 골랐어요.") : CurationReasonCode.dailyReflection.displayText))
    }

    /// A displayable preview is enough for reflection, without original-file or
    /// cleanup analysis. New selection stays local; restoration may use existing
    /// approval for this exact asset revision to recover an evicted preview.
    private static func reflectionPreviewIsReadable(for asset: PHAsset, timeout: TimeInterval,
                                                   allowsApprovedCloudAccess: Bool = false) -> Bool {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = allowsApprovedCloudAccess
            && PhotoCloudAccess.shared.allows(id: asset.localIdentifier, revision: PhotoCloudAccess.revision(for: asset))
        options.isSynchronous = false
        let image: UIImage? = boundedPhotoRead(timeout: timeout) { complete in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 1024, height: 1024),
                                                 contentMode: .aspectFit, options: options) { image, info in
                guard info?[PHImageResultIsDegradedKey] as? Bool != true else { return }
                let succeeded = image != nil && info?[PHImageErrorKey] == nil
                    && info?[PHImageCancelledKey] as? Bool != true
                PhotoCloudAccess.shared.observe(info, asset: asset, succeeded: succeeded)
                guard succeeded else { complete(nil); return }
                complete(image)
            }
        }
        guard !Task.isCancelled, let image else { return false }
        return image.size.width > 0 && image.size.height > 0
    }

    private static func metadata(for asset: PHAsset, protectedIdentifiers: Set<String>) -> PhotoCurationPolicy.Photo {
        PhotoCurationPolicy.Photo(id: asset.localIdentifier, date: asset.creationDate,
                                  width: asset.pixelWidth, height: asset.pixelHeight,
                                  isFavorite: asset.isFavorite, isProtected: protectedIdentifiers.contains(asset.localIdentifier),
                                  isExcluded: asset.isHidden || asset.mediaType != .image || asset.creationDate == nil
                                    || asset.mediaSubtypes.contains(.photoLive))
    }

    static func preparedEnrichmentIndex(in identifiers: [String], ready: Set<String>) -> Int {
        identifiers.firstIndex(where: { ready.contains($0) }) ?? 0
    }

    static func evidenceIsComplete(fullPreview: Bool, textKnown: Bool, facesKnown: Bool,
                                    requiresFeature: Bool, hasFeature: Bool) -> Bool {
        fullPreview && textKnown && facesKnown && (!requiresFeature || hasFeature)
    }

    private static func analyze(_ asset: PHAsset, protectedIdentifiers: Set<String>, reviewDate: Date? = nil,
                                deadline: AnalysisDeadline = AnalysisDeadline(seconds: 6),
                                prior: AnalyzedAsset? = nil, previewOnly: Bool = false,
                                requiresFeature: Bool = true, allowsPreviewNetwork: Bool = true,
                                preferAnalysisPreview: Bool = false,
                                preparedPreview: AnalysisPreview? = nil,
                                previewTimeout: TimeInterval = 3,
                                cancelled: () -> Bool = { Task.isCancelled }) -> AnalyzedAsset? {
        var photo = metadata(for: asset, protectedIdentifiers: protectedIdentifiers)
        let needsFullPreview = !previewOnly && prior?.previewIsReduced == true
        let retainedImage = needsFullPreview ? nil : prior?.previewImage
        let reducedNomination = previewOnly && !allowsPreviewNetwork && !preferAnalysisPreview
        guard !photo.isExcluded, !cancelled(), !deadline.expired else { return nil }
        if !previewOnly, let prior, evidenceIsComplete(fullPreview: !prior.previewIsReduced,
            textKnown: prior.facts.textLines != nil, facesKnown: prior.facts.hasFace != nil,
            requiresFeature: requiresFeature && !prior.facts.isScreenshot, hasFeature: prior.featurePrint != nil) {
            var complete = prior
            complete.photo.isProtected = photo.isProtected
            complete.enrichmentAttempted = true
            complete.needsRetry = false
            return complete
        }
        let loaded = retainedImage == nil ? preparedPreview ?? prior?.preparedPreview ?? thumbnail(for: asset, deadline: deadline,
            allowsNetwork: allowsPreviewNetwork, nominationOnly: reducedNomination,
            maximumWait: previewTimeout, cancelled: cancelled) : nil
        guard let cgImage = retainedImage ?? loaded?.cgImage else { return nil }
        let isAnalysisQuality = retainedImage != nil ? prior?.previewIsReduced != true : loaded?.isAnalysisQuality == true
        guard previewOnly || isAnalysisQuality else { return nil }
        let metrics = needsFullPreview ? imageMetrics(cgImage) : prior?.metrics ?? imageMetrics(cgImage)
        guard !metrics.colors.isEmpty else { return nil }
        photo.quality = min(metrics.sharpness * 6, 1) * 0.55 + metrics.exposure * 0.30
            + min(Double(asset.pixelWidth) * Double(asset.pixelHeight) / 12_000_000, 1) * 0.15
        if previewOnly {
            return AnalyzedAsset(asset: asset, photo: photo, featurePrint: nil, metrics: metrics,
                fingerprint: nil, facts: CurationContextPolicy.Facts(capturedAt: asset.creationDate,
                    isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot), reviewDate: reviewDate),
                needsRetry: true, enrichmentAttempted: false, previewImage: cgImage,
                previewIsReduced: !isAnalysisQuality)
        }
        let screenshot = asset.mediaSubtypes.contains(.photoScreenshot)
        let facts: CurationContextPolicy.Facts
        if let previous = prior?.facts, previous.textLines != nil, previous.hasFace != nil {
            facts = previous
        } else {
            facts = (try? contextFacts(cgImage, capturedAt: asset.creationDate, isScreenshot: screenshot,
                                      reviewDate: reviewDate, deadline: deadline))
                ?? CurationContextPolicy.Facts(capturedAt: asset.creationDate, isScreenshot: screenshot, reviewDate: reviewDate)
        }
        let feature = screenshot ? nil : prior?.featurePrint
            ?? (requiresFeature ? (try? featurePrint(cgImage, deadline: deadline)) : nil)
        return AnalyzedAsset(asset: asset, photo: photo, featurePrint: feature,
                             metrics: metrics, fingerprint: prior?.fingerprint, facts: facts,
                             needsRetry: facts.textLines == nil || facts.hasFace == nil
                                || (requiresFeature && !screenshot && feature == nil),
                             originalState: prior?.originalState ?? .notRequested)
    }

    /// Restoring a SHA-verified identity does not need to repeat OCR and Vision.
    /// Metadata/protection and the full current file still have to match again.
    private static func analyzeOriginal(_ asset: PHAsset, protectedIdentifiers: Set<String>,
                                        reviewDate: Date?, deadline: AnalysisDeadline, previewTimeout: TimeInterval = 3) -> AnalyzedAsset? {
        let photo = metadata(for: asset, protectedIdentifiers: protectedIdentifiers)
        guard !photo.isExcluded, let image = thumbnail(for: asset, deadline: deadline, maximumWait: previewTimeout),
              let cgImage = image.cgImage else { return nil }
        let metrics = imageMetrics(cgImage)
        guard !metrics.colors.isEmpty else { return nil }
        let original = fingerprintResult(for: asset, deadline: deadline)
        return AnalyzedAsset(asset: asset, photo: photo, featurePrint: nil,
            metrics: metrics, fingerprint: original.value,
            facts: CurationContextPolicy.Facts(capturedAt: asset.creationDate,
                isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot), reviewDate: reviewDate),
            needsRetry: original.needsRetry,
            originalState: original.needsRetry ? .unavailable : .resolved)
    }

    enum ContextEnrichmentDemand: Equatable { case fullEvidence, screenTextRegions, deferUnknown }

    static func contextEnrichmentDemand(capturedAt: Date?, isScreenshot: Bool, hasReviewDate: Bool,
        requiresFeature: Bool, sharpness: Double, luminanceRange: Double, resumeDeferred: Bool,
        now: Date = Date(), calendar: Calendar = .current) -> ContextEnrichmentDemand {
        // A newly arrived compatible peer always overrides an earlier context
        // deferral and requires full OCR before approximate comparison.
        if requiresFeature || hasReviewDate || isScreenshot { return .fullEvidence }
        guard let capturedAt, capturedAt <= now else { return .deferUnknown }
        let age = calendar.dateComponents([.day], from: calendar.startOfDay(for: capturedAt),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        guard age >= 7 else { return .deferUnknown }
        if resumeDeferred { return .fullEvidence }
        if sharpness.isFinite && luminanceRange.isFinite && sharpness >= 0 && luminanceRange >= 0,
           sharpness < 0.003 && luminanceRange < 0.15 { return .fullEvidence }
        return .screenTextRegions
    }

    private static func hasTextRegions(_ cgImage: CGImage, deadline: AnalysisDeadline) throws -> Bool {
        let started = ProcessInfo.processInfo.systemUptime
        let request = VNDetectTextRectanglesRequest()
        request.reportCharacterBoxes = false
        #if targetEnvironment(simulator)
        request.usesCPUOnly = true
        #endif
        try performVision([request], image: cgImage, deadline: deadline)
        let found = !(request.results ?? []).isEmpty
        CurationTimingDiagnostics.record("textRegionNomination", ["seconds": ProcessInfo.processInfo.systemUptime - started,
            "regionsFound": found ? 1 : 0])
        return found
    }

    static func contextFacts(_ cgImage: CGImage, capturedAt: Date?, isScreenshot: Bool,
                             reviewDate: Date? = nil, deadline: AnalysisDeadline? = nil) throws -> CurationContextPolicy.Facts {
        let contextStarted = ProcessInfo.processInfo.systemUptime
        var completed = false
        defer { CurationTimingDiagnostics.record("context", ["seconds": ProcessInfo.processInfo.systemUptime - contextStarted,
            "completed": completed ? 1 : 0, "screenshot": isScreenshot ? 1 : 0]) }
        let metrics = imageMetrics(cgImage)
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.recognitionLanguages = ["ko-KR", "en-US"]
        textRequest.usesLanguageCorrection = false
        let faceRequest = VNDetectFaceRectanglesRequest()
        #if targetEnvironment(simulator)
        textRequest.usesCPUOnly = true
        faceRequest.usesCPUOnly = true
        #endif
        try performVision([textRequest, faceRequest], image: cgImage, deadline: deadline)
        let observations = (textRequest.results ?? []).sorted {
            let leftRow = Int(($0.boundingBox.midY * 100).rounded())
            let rightRow = Int(($1.boundingBox.midY * 100).rounded())
            if leftRow != rightRow { return leftRow > rightRow }
            return $0.boundingBox.minX < $1.boundingBox.minX
        }
        let recognized = observations.compactMap { $0.topCandidates(1).first }
        completed = true
        return CurationContextPolicy.Facts(capturedAt: capturedAt, isScreenshot: isScreenshot,
            textLines: recognized.map(\.string),
            confidentTextLines: recognized.filter { $0.confidence >= 0.8 }.map(\.string),
            hasFace: !(faceRequest.results ?? []).isEmpty,
            detail: metrics.sharpness, luminanceRange: metrics.luminanceRange, reviewDate: reviewDate)
    }

    private static func identicalFileReason(_ lhs: AnalyzedAsset, _ rhs: AnalyzedAsset) -> CurationReasonCode? {
        guard lhs.photo.id != rhs.photo.id, lhs.photo.width == rhs.photo.width, lhs.photo.height == rhs.photo.height,
              lhs.facts.isScreenshot == rhs.facts.isScreenshot,
              let hash = lhs.fingerprint, hash == rhs.fingerprint else { return nil }
        return lhs.facts.isScreenshot ? .duplicateScreenshot : .exactDuplicate
    }

    private static func pairReason(_ lhs: AnalyzedAsset, _ rhs: AnalyzedAsset) -> CurationReasonCode? {
        if let identical = identicalFileReason(lhs, rhs) { return identical }
        // Similar-looking screens can differ only in a code or a digit. Never approximate duplicates.
        guard !lhs.previewIsReduced, !rhs.previewIsReduced,
              !lhs.facts.isScreenshot, !rhs.facts.isScreenshot, PhotoCurationPolicy.canCompare(lhs.photo, rhs.photo),
              let leftPrint = lhs.featurePrint, let rightPrint = rhs.featurePrint else { return nil }
        // OCR failure/changed words veto an approximate match, including document photographs.
        guard let leftText = lhs.facts.textLines, let rightText = rhs.facts.textLines,
              leftText == rightText else { return nil }
        var distance: Float = 0
        do { try leftPrint.computeDistance(&distance, to: rightPrint) }
        catch { return nil }
        let difference = pixelDifference(lhs.metrics.colors, rhs.metrics.colors)
        let accepted = PhotoCurationPolicy.accepts(distance: distance, meanDifference: difference.mean,
                                                  largestTileDifference: difference.largestTile,
                                                  detail: min(lhs.metrics.sharpness, rhs.metrics.sharpness))
        return accepted ? .visuallySimilar : nil
    }

    static func visualPreviewsAreCompatible(_ lhs: ImageMetrics, _ rhs: ImageMetrics) -> Bool {
        let difference = pixelDifference(lhs.colors, rhs.colors)
        return difference.mean.isFinite && difference.largestTile.isFinite
            && difference.mean <= 0.035 && difference.largestTile <= 0.12
            && min(lhs.sharpness, rhs.sharpness) >= 0.004
    }

    static func comparisonNominationIsCompatible(_ lhs: ImageMetrics, _ rhs: ImageMetrics, reduced: Bool) -> Bool {
        guard reduced else { return visualPreviewsAreCompatible(lhs, rhs) }
        let difference = pixelDifference(lhs.colors, rhs.colors)
        // Small cached images only decide where to spend the full-quality work.
        // pairReason still uses the original strict detail/pixel/Vision/OCR checks.
        return difference.mean.isFinite && difference.largestTile.isFinite
            && difference.mean <= 0.08 && difference.largestTile <= 0.24
    }

    /// Thumbnail likeness only decides whether a full-file comparison is worth
    /// reading. It never establishes identity or authorizes deletion.
    private static func originalComparisonIdentifiers(_ analyses: [AnalyzedAsset]) -> Set<String> {
        var result = Set<String>()
        for (index, lhs) in analyses.enumerated() {
            for rhs in analyses.dropFirst(index + 1) {
                guard lhs.photo.canRemove || rhs.photo.canRemove,
                      !lhs.asset.hasAdjustments, !rhs.asset.hasAdjustments,
                      lhs.photo.width == rhs.photo.width, lhs.photo.height == rhs.photo.height,
                      Double(lhs.photo.width) * Double(lhs.photo.height) <= 32_000_000,
                      lhs.facts.isScreenshot == rhs.facts.isScreenshot,
                      originalPreviewsAreCompatible(lhs.metrics.colors, rhs.metrics.colors) else { continue }
                result.insert(lhs.photo.id)
                result.insert(rhs.photo.id)
            }
        }
        return result
    }

    static func originalPreviewsAreCompatible(_ lhs: [Double], _ rhs: [Double]) -> Bool {
        guard lhs.count == 48 * 48 * 3, rhs.count == lhs.count else { return false }
        // A cheap rejection avoids computing all 6,912 values for unrelated pairs.
        let sampleDifference = stride(from: 0, to: lhs.count, by: 216)
            .reduce(0.0) { $0 + abs(lhs[$1] - rhs[$1]) } / 32
        guard sampleDifference.isFinite, sampleDifference <= 0.02 else { return false }
        let difference = pixelDifference(lhs, rhs)
        return difference.mean <= 0.015 && difference.largestTile <= 0.06
    }

    private static func fingerprintResult(for asset: PHAsset,
                                          deadline: AnalysisDeadline = AnalysisDeadline(seconds: 6)) -> (value: String?, needsRetry: Bool) {
        // Edited photos can contain unique adjustment history; don't call those interchangeable files.
        guard !asset.hasAdjustments, Double(asset.pixelWidth) * Double(asset.pixelHeight) <= 32_000_000 else { return (nil, false) }
        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = PhotoCloudAccess.shared.allows(id: asset.localIdentifier, revision: PhotoCloudAccess.revision(for: asset))
        options.isSynchronous = false
        guard !deadline.expired else { return (nil, true) }
        let payload: (Data, CGImagePropertyOrientation)? = boundedPhotoRead(timeout: deadline.readTimeout(maximum: options.isNetworkAccessAllowed ? 30 : 3)) { complete in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, orientation, info in
                PhotoCloudAccess.shared.observe(info, asset: asset, succeeded: data?.isEmpty == false && info?[PHImageErrorKey] == nil)
                guard info?[PHImageErrorKey] == nil, info?[PHImageCancelledKey] as? Bool != true else { complete(nil); return }
                guard info?[PHImageResultIsDegradedKey] as? Bool != true else { return }
                guard let data, !data.isEmpty else { complete(nil); return }
                complete((data, orientation))
            }
        }
        guard let (data, orientation) = payload else { return (nil, true) }
        let needsRetry = false
        let hash = data.count <= 24 * 1024 * 1024
            ? "\(orientation.rawValue):" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() : nil
        return (hash, needsRetry)
    }

    static func pixelDifference(_ lhs: [Double], _ rhs: [Double]) -> (mean: Double, largestTile: Double) {
        guard lhs.count == 48 * 48 * 3, rhs.count == lhs.count else { return (.infinity, .infinity) }
        var tiles = [Double](repeating: 0, count: 64)
        for y in 0..<48 {
            for x in 0..<48 {
                let index = (y * 48 + x) * 3
                let delta = (0..<3).reduce(0.0) { $0 + abs(lhs[index + $1] - rhs[index + $1]) } / 3
                tiles[(y / 6) * 8 + x / 6] += delta
            }
        }
        return (tiles.reduce(0, +) / (48 * 48), (tiles.max() ?? 0) / 36)
    }

    static func previewRequestOptions(authorization: PHAuthorizationStatus, nominationOnly: Bool = false) -> PHImageRequestOptions? {
        guard authorization == .authorized || authorization == .limited else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = nominationOnly ? .opportunistic : .highQualityFormat
        // PhotoKit's fast resize may return a larger cached representation.
        // Avoid forcing a new exact-size decode; the same nondegraded1024px
        // quality gate below still decides whether analysis is permitted.
        options.resizeMode = .fast
        // A small PhotoKit preview is enough for Vision/OCR. Full-file hashing
        // keeps its separate asset-scoped network approval in fingerprintResult.
        options.isNetworkAccessAllowed = !nominationOnly
        options.isSynchronous = false
        return options
    }

    static func usableNominationSize(width: Int, height: Int) -> Bool {
        // Actual small PhotoKit images can nominate a 48x48 coarse comparison.
        // They cannot supply OCR, face, detail or approximate-match evidence.
        min(width, height) >= 48 && max(width, height) >= 64
    }

    enum PreviewCallbackAction: Equatable { case accept, awaitLarger, unavailable }

    static func analysisCallbackAction(degraded: Bool, failed: Bool, cancelled: Bool,
                                       hasImage: Bool) -> PreviewCallbackAction {
        // Terminal errors can accompany a degraded callback. Ignoring that
        // flag before inspecting the error needlessly waits out the deadline.
        if failed || cancelled { return .unavailable }
        if degraded { return .awaitLarger }
        return hasImage ? .accept : .unavailable
    }

    static func nominationCallbackAction(width: Int, height: Int, degraded: Bool,
                                         failed: Bool = false) -> PreviewCallbackAction {
        if failed { return .unavailable }
        if usableNominationSize(width: width, height: height) { return .accept }
        // Opportunistic PhotoKit sends a tiny cached image before the requested
        // local image. Ending on that first callback cancelled762 valid requests
        // in the first physical99 candidate. Await the later callback instead.
        return degraded ? .awaitLarger : .unavailable
    }

    private struct AnalysisPreview {
        let image: UIImage
        let isAnalysisQuality: Bool
        var cgImage: CGImage? { image.cgImage }
    }

    static func isAnalysisQualityPreview(width: Int, height: Int, originalWidth: Int, originalHeight: Int,
                                         degraded: Bool) -> Bool {
        !degraded && min(width, height) >= min(256, min(originalWidth, originalHeight))
            && max(width, height) >= min(1024, max(originalWidth, originalHeight))
    }

    static func shouldRetryLocalPreview(inCloud: Bool, failed: Bool, blocked: Bool, cancelled: Bool) -> Bool {
        !inCloud && !failed && !blocked && !cancelled
    }

    private static func thumbnail(for asset: PHAsset, deadline: AnalysisDeadline, allowsNetwork: Bool = true,
                                  nominationOnly: Bool = false,
                                  maximumWait: TimeInterval = 3,
                                  cancelled: () -> Bool = { Task.isCancelled }) -> AnalysisPreview? {
        let readStarted = ProcessInfo.processInfo.systemUptime
        let budget = deadline.remaining
        var completed = false
        var requested = false
        var accessBlocked = false
        defer { CurationTimingDiagnostics.record("preview", ["seconds": ProcessInfo.processInfo.systemUptime - readStarted,
            "budget": budget, "completed": completed ? 1 : 0, "deadlineExpired": deadline.expired ? 1 : 0,
            "networkAllowed": allowsNetwork ? 1 : 0,
            "localMiss": requested && !allowsNetwork && !completed && !accessBlocked ? 1 : 0,
            "accessBlocked": accessBlocked ? 1 : 0,
            "networkFailure": requested && allowsNetwork && !completed && !accessBlocked ? 1 : 0]) }
        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        accessBlocked = authorization != .authorized && authorization != .limited
        guard !Task.isCancelled, !cancelled(), !deadline.expired,
              let options = previewRequestOptions(authorization: authorization, nominationOnly: nominationOnly) else { return nil }
        options.isNetworkAccessAllowed = allowsNetwork && !nominationOnly
        requested = true
        let result: (AnalysisPreview?, Bool, Bool)? = boundedPhotoRead(timeout: deadline.readTimeout(maximum: allowsNetwork ? maximumWait : (nominationOnly ? 0.08 : 1)),
            cancel: { analysisImageManager.cancelImageRequest($0) }, cancelOnResult: true,
            cancelled: cancelled) { complete in
            let size: CGFloat = nominationOnly ? 384 : 1024
            return analysisImageManager.requestImage(for: asset, targetSize: CGSize(width: size, height: size),
                                                 contentMode: .aspectFit, options: options) { image, info in
                let degraded = info?[PHImageResultIsDegradedKey] as? Bool == true
                let error = info?[PHImageErrorKey] as? NSError
                if let error {
                    CurationTimingDiagnostics.record("previewError", [
                        (error.domain == PHPhotosErrorDomain ? "photos." : "other.") + String(error.code): 1,
                        "networkAllowed": options.isNetworkAccessAllowed ? 1 : 0])
                }
                CurationTimingDiagnostics.record("previewResponse", [
                    "width": Double(image?.cgImage?.width ?? 0), "height": Double(image?.cgImage?.height ?? 0),
                    "degraded": degraded ? 1 : 0, "nilImage": image == nil ? 1 : 0,
                    "cgImageMissing": image != nil && image?.cgImage == nil ? 1 : 0,
                    "cancelled": info?[PHImageCancelledKey] as? Bool == true ? 1 : 0,
                    "inCloud": info?[PHImageResultIsInCloudKey] as? Bool == true ? 1 : 0,
                    "photosError": error?.domain == PHPhotosErrorDomain ? 1 : 0,
                    "otherError": error != nil && error?.domain != PHPhotosErrorDomain ? 1 : 0,
                    "errorCode": Double(error?.code ?? 0), "nomination": nominationOnly ? 1 : 0])
                let blocked = error?.domain == PHPhotosErrorDomain
                    && (error?.code == PHPhotosError.Code.accessUserDenied.rawValue
                        || error?.code == PHPhotosError.Code.accessRestricted.rawValue)
                let mayRetry = shouldRetryLocalPreview(inCloud: info?[PHImageResultIsInCloudKey] as? Bool == true,
                    failed: error != nil, blocked: blocked, cancelled: info?[PHImageCancelledKey] as? Bool == true)
                if !nominationOnly {
                    switch analysisCallbackAction(degraded: degraded, failed: error != nil,
                        cancelled: info?[PHImageCancelledKey] as? Bool == true, hasImage: image?.cgImage != nil) {
                    case .awaitLarger: return
                    case .unavailable: complete((nil, blocked, mayRetry)); return
                    case .accept: break
                    }
                }
                if nominationOnly {
                    let width = image?.cgImage?.width ?? 0, height = image?.cgImage?.height ?? 0
                    let action = nominationCallbackAction(width: width, height: height, degraded: degraded,
                        failed: error != nil || info?[PHImageCancelledKey] as? Bool == true)
                    CurationTimingDiagnostics.record("previewCallback", ["width": Double(width), "height": Double(height),
                        "degraded": degraded ? 1 : 0, "accepted": action == .accept ? 1 : 0,
                        "awaitLarger": action == .awaitLarger ? 1 : 0, "unavailable": action == .unavailable ? 1 : 0])
                    switch action {
                    case .awaitLarger: return
                    case .unavailable: complete((nil, blocked, mayRetry)); return
                    case .accept: break
                    }
                }
                // Preview success/failure must not grant or clear original-file access.
                let preview = image.map { value in
                    AnalysisPreview(image: value, isAnalysisQuality: isAnalysisQualityPreview(
                        width: value.cgImage?.width ?? 0, height: value.cgImage?.height ?? 0,
                        originalWidth: asset.pixelWidth, originalHeight: asset.pixelHeight, degraded: degraded))
                }
                complete((preview, blocked, mayRetry))
            }
        }
        accessBlocked = accessBlocked || result?.1 == true
        completed = result?.0 != nil
        if nominationOnly, !completed, !accessBlocked, result?.2 == true,
           !Task.isCancelled, !cancelled(), !deadline.expired {
            // Retry only a non-error final undersized image, within the shared
            // per-photo allowance. An explicit iCloud/error result cannot be
            // repaired by issuing the same local high-quality request again.
            let fallback = thumbnail(for: asset, deadline: deadline, allowsNetwork: false, nominationOnly: false, cancelled: cancelled)
            completed = fallback != nil
            return fallback
        }
        return result?.0
    }

    // PhotoKit may stall while creating OR cancelling an asynchronous request.
    // Neither framework call runs on the waiting worker. Bound the number of
    // framework calls too, and skip queued starts whose caller already left.
    private static let photoReadStartQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "recoco.photo-read.start"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 8
        return queue
    }()

    private static let photoReadCancelQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "recoco.photo-read.cancel"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 4
        return queue
    }()

    // Called only by background workers. One deadline covers queueing, request
    // creation and delivery; a late result cannot become curation evidence.
    static func boundedPhotoRead<Value>(timeout: TimeInterval = 3,
        cancel: @escaping (PHImageRequestID) -> Void = { PHImageManager.default().cancelImageRequest($0) },
        cancelOnResult: Bool = false,
        cancelled: () -> Bool = { Task.isCancelled },
        request: @escaping (@escaping (Value?) -> Void) -> PHImageRequestID) -> Value? {
        guard !Task.isCancelled, !cancelled(), timeout > 0 else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let result = PhotoReadResult<Value>(cancel: cancel)
        photoReadStartQueue.addOperation {
            guard result.canStart else { return }
            let began = ProcessInfo.processInfo.systemUptime
            let id = request { result.finish($0) }
            result.register(id)
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            if elapsed > 0.1 {
                CurationTimingDiagnostics.record("slowPhotoRequestStart", ["seconds": elapsed])
            }
        }
        while !Task.isCancelled && !cancelled() && ProcessInfo.processInfo.systemUptime < deadline {
            let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
            if result.signal.wait(timeout: .now() + min(0.04, remaining)) == .success {
                let expired = ProcessInfo.processInfo.systemUptime >= deadline
                let interrupted = Task.isCancelled || cancelled() || expired
                let value = result.close(cancelRequest: cancelOnResult || interrupted)
                return interrupted ? nil : value
            }
        }
        _ = result.close(cancelRequest: true)
        return nil
    }

    /// UI reads use the same bounded, single-result boundary without blocking the main actor.
    /// Cancelling the view task also cancels the underlying PhotoKit request.
    static func boundedPhotoReadAsync<Value>(timeout: TimeInterval,
        cancel: ((PHImageRequestID) -> Void)? = nil,
        request: @escaping (@escaping (Value?) -> Void) -> PHImageRequestID) async -> Value? {
        guard !Task.isCancelled else { return nil }
        let worker = Task.detached(priority: .userInitiated) {
            if let cancel { return boundedPhotoRead(timeout: timeout, cancel: cancel, request: request) }
            return boundedPhotoRead(timeout: timeout, request: request)
        }
        return await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
    }

    private final class PhotoReadResult<Value> {
        let signal = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var finished = false
        private var closed = false
        private var value: Value?
        private var requestID: PHImageRequestID?
        private var cancellationRequested = false
        private var cancellationScheduled = false
        private let cancel: (PHImageRequestID) -> Void

        init(cancel: @escaping (PHImageRequestID) -> Void) { self.cancel = cancel }

        var canStart: Bool {
            lock.lock(); defer { lock.unlock() }
            return !closed
        }

        func register(_ id: PHImageRequestID) {
            lock.lock()
            requestID = id
            let toCancel = cancellationIdentifier()
            lock.unlock()
            scheduleCancellation(toCancel)
        }

        func finish(_ value: Value?) {
            lock.lock(); defer { lock.unlock() }
            guard !finished else { return }
            self.value = value; finished = true; signal.signal()
        }

        func close(cancelRequest: Bool) -> Value? {
            lock.lock()
            finished = true
            closed = true
            cancellationRequested = cancellationRequested || cancelRequest
            let result = value
            value = nil
            let toCancel = cancellationIdentifier()
            lock.unlock()
            scheduleCancellation(toCancel)
            return result
        }

        // Must be called with lock held. Registration may arrive after timeout
        // or even after a synchronous callback; cancel exactly once in either case.
        private func cancellationIdentifier() -> PHImageRequestID? {
            guard cancellationRequested, !cancellationScheduled,
                  let id = requestID, id != PHInvalidImageRequestID else { return nil }
            cancellationScheduled = true
            return id
        }

        private func scheduleCancellation(_ id: PHImageRequestID?) {
            guard let id else { return }
            let cancel = self.cancel
            PhotoCurationService.photoReadCancelQueue.addOperation {
                let began = ProcessInfo.processInfo.systemUptime
                cancel(id)
                let elapsed = ProcessInfo.processInfo.systemUptime - began
                if elapsed > 0.1 {
                    CurationTimingDiagnostics.record("slowPhotoRequestCancel", ["seconds": elapsed])
                }
            }
        }
    }

    private static func performVision(_ requests: [VNRequest], image: CGImage,
                                      deadline: AnalysisDeadline?) throws {
        guard !Task.isCancelled, deadline?.expired != true else { throw CancellationError() }
        // Vision requests are synchronous but cancellable. Request cancellation
        // at the shared deadline rather than checking time only after completion.
        let timer = deadline.map { budget -> DispatchSourceTimer in
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
            timer.schedule(deadline: .now() + budget.remaining)
            timer.setEventHandler { requests.forEach { $0.cancel() } }
            timer.resume()
            return timer
        }
        defer { timer?.cancel() }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform(requests)
        guard !Task.isCancelled, deadline?.expired != true else { throw CancellationError() }
    }

    static func featurePrint(_ image: CGImage, deadline: AnalysisDeadline? = nil) throws -> VNFeaturePrintObservation? {
        let featureStarted = ProcessInfo.processInfo.systemUptime
        var completed = false
        defer { CurationTimingDiagnostics.record("feature", ["seconds": ProcessInfo.processInfo.systemUptime - featureStarted,
            "completed": completed ? 1 : 0]) }
        guard featureModelPreparation.awaitCompletion(until: deadline ?? AnalysisDeadline(seconds: 6)) else {
            throw CancellationError()
        }
        let request = VNGenerateImageFeaturePrintRequest()
        // Distance scales depend on request revision. Use the same revision on iOS 16 and later.
        request.revision = VNGenerateImageFeaturePrintRequestRevision1
        #if targetEnvironment(simulator)
        request.usesCPUOnly = true
        #endif
        request.imageCropAndScaleOption = .scaleFit
        try performVision([request], image: image, deadline: deadline)
        completed = request.results?.first != nil
        return request.results?.first as? VNFeaturePrintObservation
    }

    static func candidateGroups(
        from metadata: [CandidateMetadata],
        maximumTimeSpan: TimeInterval = 30,
        calendar: Calendar = .current
    ) -> [[CandidateMetadata]] {
        let burstGroups = Dictionary(grouping: metadata.compactMap { item in
            item.burstIdentifier.map { ($0, item) }
        }, by: \.0)
            .values
            .map { $0.map(\.1).sorted { $0.creationDate < $1.creationDate } }
            .filter { $0.count >= 2 }

        let burstIdentifiers = Set(
            burstGroups.flatMap { $0.map(\.localIdentifier) }
        )
        let chronological = metadata
            .filter { !burstIdentifiers.contains($0.localIdentifier) }
            .sorted { $0.creationDate < $1.creationDate }

        var timedGroups: [[CandidateMetadata]] = []
        var currentGroup: [CandidateMetadata] = []

        func appendCurrentGroup() {
            if currentGroup.count >= 2 {
                timedGroups.append(currentGroup)
            }
            currentGroup = []
        }

        for item in chronological {
            guard let first = currentGroup.first else {
                currentGroup = [item]
                continue
            }

            let isSameDay = calendar.isDate(
                item.creationDate,
                inSameDayAs: first.creationDate
            )
            let isWithinSpan = item.creationDate.timeIntervalSince(first.creationDate)
                <= maximumTimeSpan

            if isSameDay && isWithinSpan {
                currentGroup.append(item)
            } else {
                appendCurrentGroup()
                currentGroup = [item]
            }
        }
        appendCurrentGroup()

        return (burstGroups + timedGroups).sorted {
            ($0.last?.creationDate ?? .distantPast) > ($1.last?.creationDate ?? .distantPast)
        }
    }

    static func imageMetrics(_ image: CGImage) -> ImageMetrics {
        let width = 48
        let height = 48
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        let drewImage = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drewImage else { return ImageMetrics(sharpness: 0, exposure: 0, colors: []) }

        var luminance = [Double](repeating: 0, count: width * height)
        var luminanceSum: Double = 0
        for index in 0..<(width * height) {
            let pixelIndex = index * bytesPerPixel
            let red = Double(pixels[pixelIndex]) / 255
            let green = Double(pixels[pixelIndex + 1]) / 255
            let blue = Double(pixels[pixelIndex + 2]) / 255
            let value = red * 0.2126 + green * 0.7152 + blue * 0.0722
            luminance[index] = value
            luminanceSum += value
        }

        var edgeSum: Double = 0
        var edgeCount = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let index = y * width + x
                let neighborAverage = (
                    luminance[index - 1]
                        + luminance[index + 1]
                        + luminance[index - width]
                        + luminance[index + width]
                ) / 4
                edgeSum += abs(luminance[index] - neighborAverage)
                edgeCount += 1
            }
        }

        let averageLuminance = luminanceSum / Double(width * height)
        let exposure = max(0, 1 - abs(averageLuminance - 0.5) * 2)
        let sharpness = edgeCount > 0 ? edgeSum / Double(edgeCount) : 0
        return ImageMetrics(sharpness: sharpness, exposure: exposure, colors: pixels.enumerated().filter { $0.offset % 4 != 3 }.map { Double($0.element) / 255 },
                            luminanceRange: (luminance.max() ?? 1) - (luminance.min() ?? 0))
    }

    private static func dateDescription(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

/// Explicit, local-only performance inspection for a connected test device.
/// Scalar counts/timings only: no photo identifiers, text, locations or images.
/// Nothing is written in ordinary launches or sent to a service.
enum CurationTimingDiagnostics {
    private static let streaming = ProcessInfo.processInfo.arguments.contains("-recoco-curation-timing")
    private static let probe = ProcessInfo.processInfo.arguments.contains("-recoco-curation-read-only-probe")
    static let enabled = streaming || probe
    private static let lock = NSLock()
    private static let started = ProcessInfo.processInfo.systemUptime
    private static var events: [[String: Any]] = []
    private static var workTotals: [String: Double] = [:]

    static func record(_ event: String, _ values: [String: Double]) {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        if ["preview", "previewCallback", "previewResponse", "previewError", "original", "context", "feature"].contains(event) {
            workTotals[event + ".count", default: 0] += 1
            for (key, value) in values { workTotals[event + "." + key, default: 0] += value }
            return
        }
        var totals = values
        if event == "analysisResult" || event == "restorationResult" {
            totals.merge(workTotals) { _, new in new }
            workTotals.removeAll()
        }
        events.append(["event": event, "elapsed": ProcessInfo.processInfo.systemUptime - started,
                       "values": totals])
        if events.count > 1_024 { events.removeSubrange(1..<(events.count - 1_023)) }
        // Read-only performance probes retain scalar counters in memory and
        // write once at the end, so per-event disk I/O cannot alter scheduling.
        if streaming { writeLocked() }
    }

    static func flush() {
        guard enabled else { return }
        lock.lock(); defer { lock.unlock() }
        writeLocked()
    }

    private static func writeLocked() {
        guard let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let data = try? JSONSerialization.data(withJSONObject: ["schema": 1, "events": events], options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: folder.appendingPathComponent("recoco-curation-timing.json"), options: .atomic)
    }
}
