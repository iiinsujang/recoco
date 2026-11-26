import XCTest
import Photos
import Combine
@testable import Recoco

final class CurationBatchTests: XCTestCase {
    func testFocusedReasonSearchDoesNotRetireUninspectedPairEvidence() {
        XCTAssertEqual(PhotoCurationService.completedScanCoverage(examined: ["one", "two", "gone"],
            missing: ["gone"], chosen: [], preserved: [], complete: true,
            excludingReasonGroups: [.similarCapture]), ["gone"])
        XCTAssertEqual(PhotoCurationService.completedScanCoverage(examined: ["one", "two", "gone"],
            missing: ["gone"], chosen: ["one"], preserved: ["two"], complete: true,
            excludingReasonGroups: [.similarCapture]), ["one"])
        XCTAssertEqual(PhotoCurationService.completedScanCoverage(examined: ["one", "two", "gone"],
            missing: ["gone"], chosen: [], preserved: ["two"], complete: true,
            excludingReasonGroups: []), ["one", "gone"])
    }

    private func candidate(_ id: String, reference: String? = "kept-photo",
                           reason: CurationReasonCode = .exactDuplicate) -> DecisionUnit {
        DecisionUnit(id: UUID(), type: .cleanupSingle, status: .pending,
                     candidateLocalIdentifiers: [id], recommendedLocalIdentifier: id,
                     reasonCodes: [reason], capturedDateDescription: nil, createdAt: Date(),
                     comparisonLocalIdentifier: reference)
    }

    private func variedCandidate(_ id: String, position: Int) -> DecisionUnit {
        switch position {
        case 1: return candidate(id)
        case 2: return candidate(id, reason: .visuallySimilar)
        default: return candidate(id, reference: nil, reason: .expiredScreen)
        }
    }

    func testDiversityUpgradePinsCheckedAndCurrentlyVisiblePhotos() {
        let current = [candidate("visible", reference: "keep-visible", reason: .visuallySimilar),
                       candidate("checked", reference: "keep-checked", reason: .visuallySimilar),
                       candidate("unchecked", reference: "keep-unchecked", reason: .visuallySimilar)]
        let additions = [candidate("context", reference: nil, reason: .expiredScreen),
                         candidate("exact", reference: "keep-exact")]
        let checked = PhotoCurationService.diversifiedPendingRecommendations(current,
            additions: additions, pinned: ["visible", "checked"])
        XCTAssertEqual(checked.map(\.persistenceKey), ["visible", "checked", "context"])
        let unchecked = PhotoCurationService.diversifiedPendingRecommendations(current,
            additions: additions, pinned: ["visible"])
        XCTAssertEqual(Set(unchecked.compactMap { CleanupReasonGroup($0.reasonCodes.first) }).count, 3)
        XCTAssertEqual(unchecked.first?.persistenceKey, "visible")
        XCTAssertEqual(PhotoCurationService.diversifiedPendingRecommendations(current,
            additions: additions, pinned: Set(current.map(\.persistenceKey))).map(\.persistenceKey), current.map(\.persistenceKey))
    }

    func testDiversityUpgradeRejectsComparisonConflictsAndUnprovenPairs() {
        let current = [candidate("visible", reference: "keep-visible", reason: .visuallySimilar),
                       candidate("other", reference: "keep-other", reason: .visuallySimilar)]
        let rejected = [candidate("keep-visible"), candidate("unsafe", reference: "visible"),
                        candidate("no-reference", reference: nil)]
        XCTAssertEqual(PhotoCurationService.diversifiedPendingRecommendations(current,
            additions: rejected, pinned: ["visible"]).map(\.persistenceKey), ["visible", "other"])
    }

    func testSoftDiversityFillsSmallLibraryWithoutHidingExistingSameReasonPairs() async {
        let seed = candidate("shown", reference: "keep-shown", reason: .visuallySimilar)
        var calls = 0
        let result = await PhotoCurationService.curatedBatch(excluding: [], protectedIdentifiers: [],
            initialDecisions: [seed], allowSameReasonFallback: true) { excluded, protected, remaining, groups in
            calls += 1
            XCTAssertTrue(excluded.contains("shown"))
            XCTAssertTrue(protected.contains("keep-shown"))
            XCTAssertTrue(groups.contains(.similarCapture), "Search the missing reasons before using another proven same-type pair")
            XCTAssertEqual(remaining, 2)
            return .init(decisions: [self.candidate("second", reference: "keep-2", reason: .visuallySimilar),
                                     self.candidate("third", reference: "keep-3", reason: .visuallySimilar)],
                         visitedIdentifiers: ["second", "third"], hasMore: false)
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(result.decisions.map(\.displayIdentifier), ["shown", "second", "third"])
        XCTAssertEqual(result.visitedIdentifiers, ["second", "third"])
    }

    func testSoftDiversityRequestsMissingEvidenceBeforeAcceptingBufferedCopies() async {
        var elapsed = 0.0
        var calls = 0
        var snapshots: [[String]] = []
        let result = await PhotoCurationService.curatedBatch(excluding: [], protectedIdentifiers: [],
            allowSameReasonFallback: true, diversityTimeLimit: 9, now: { Date(timeIntervalSince1970: elapsed) },
            onUpdate: { snapshots.append($0.decisions.map(\.persistenceKey)) }) { _, protected, _, groups in
                calls += 1
                switch calls {
                case 1:
                    elapsed = 0.5
                    return .init(decisions: [self.candidate("similar", reference: "keep-similar", reason: .visuallySimilar),
                        self.candidate("same-type-2", reference: "keep-2", reason: .visuallySimilar),
                        self.candidate("same-type-3", reference: "keep-3", reason: .visuallySimilar)],
                        visitedIdentifiers: [], hasMore: true, hasFreshPhotos: true, workRevision: 1)
                case 2:
                    XCTAssertEqual(groups, [.similarCapture])
                    XCTAssertEqual(snapshots, [["similar"]])
                    XCTAssertTrue(protected.isSuperset(of: ["keep-similar", "keep-2", "keep-3"]))
                    elapsed = 5
                    return .init(decisions: [self.candidate("context", reference: nil, reason: .expiredScreen)],
                        visitedIdentifiers: [], hasMore: true, hasFreshPhotos: true, workRevision: 2)
                default:
                    XCTAssertEqual(groups, [.similarCapture, .contextReview])
                    elapsed = 7
                    return .init(decisions: [self.candidate("exact", reference: "keep-exact")],
                        visitedIdentifiers: [], hasMore: false, workRevision: 3)
                }
            }
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(result.decisions.map(\.persistenceKey), ["similar", "context", "exact"])
        XCTAssertFalse(result.visitedIdentifiers.contains("same-type-2"))
        XCTAssertEqual(snapshots, [["similar"], ["similar", "context"], ["similar", "context", "exact"]])
    }

    func testFocusedSearchRetainsVerifiedAlternativesUntilDiversityBudgetEnds() async {
        let shown = candidate("shown", reference: "keep-shown", reason: .visuallySimilar)
        let alternatives = [candidate("later-one", reference: "keep-one", reason: .visuallySimilar),
                            candidate("later-two", reference: "keep-two", reason: .visuallySimilar)]
        var elapsed = 0.0
        var calls = 0
        var snapshots: [[String]] = []
        let result = await PhotoCurationService.curatedBatch(excluding: [], protectedIdentifiers: [],
            initialDecisions: [shown], allowSameReasonFallback: true, diversityTimeLimit: 9,
            now: { Date(timeIntervalSince1970: elapsed) },
            onUpdate: { snapshots.append($0.decisions.map(\.persistenceKey)) }) { _, protected, _, groups in
                calls += 1
                XCTAssertEqual(groups, [.similarCapture])
                if calls == 1 {
                    elapsed = 5
                    return .init(decisions: [], visitedIdentifiers: [], hasMore: true, hasFreshPhotos: true,
                        deferredIdentifiers: Set(alternatives.map(\.persistenceKey)),
                        deferredReferences: ["keep-one", "keep-two"], workRevision: 1,
                        deferredDecisions: alternatives)
                }
                XCTAssertTrue(snapshots.isEmpty, "Verified repeats must wait while other reasons are still being sought")
                XCTAssertTrue(protected.isSuperset(of: ["keep-one", "keep-two"]))
                elapsed = 9.1
                return .init(decisions: [], visitedIdentifiers: [], hasMore: false, workRevision: 2)
            }
        XCTAssertEqual(result.decisions.map(\.persistenceKey), ["shown", "later-one", "later-two"])
        XCTAssertEqual(snapshots, [["shown", "later-one", "later-two"]])
    }

    func testDeferredProofCannotBypassExplicitlyExcludedReasonOrReferenceProtection() async {
        let rejected = candidate("duplicate", reference: "keep", reason: .visuallySimilar)
        let result = await PhotoCurationService.curatedBatch(excluding: [], protectedIdentifiers: [],
            excludingReasonGroups: [.similarCapture], allowSameReasonFallback: true,
            diversityTimeLimit: 0) { _, _, _, _ in
                .init(decisions: [], visitedIdentifiers: [], hasMore: false,
                    deferredIdentifiers: ["duplicate"], deferredReferences: ["keep"],
                    deferredDecisions: [rejected])
            }
        XCTAssertTrue(result.decisions.isEmpty)
        XCTAssertTrue(result.visitedIdentifiers.isEmpty)
    }

    func testSoftDiversitySelectsAvailableDistinctReasonsBeforeBufferedPairs() async {
        let result = await PhotoCurationService.curatedBatch(excluding: [], protectedIdentifiers: [],
            allowSameReasonFallback: true, diversityTimeLimit: 0) { _, _, _, _ in
            .init(decisions: [self.candidate("first"), self.candidate("another-copy", reference: "keep-copy"),
                              self.candidate("similar", reference: "keep-similar", reason: .visuallySimilar),
                              self.candidate("context", reference: nil, reason: .expiredScreen)],
                  visitedIdentifiers: ["first", "another-copy", "similar", "context"], hasMore: false)
        }
        XCTAssertEqual(result.decisions.map(\.displayIdentifier), ["first", "similar", "context"])
        XCTAssertFalse(result.visitedIdentifiers.contains("another-copy"))
    }

    func testSoftDiversityPublishesFirstPhotoImmediatelyAndDrainsAfterFourSeconds() async {
        var elapsed = 0.0
        var calls = 0
        var snapshots: [[String]] = []
        let result = await PhotoCurationService.curatedBatch(excluding: [], protectedIdentifiers: [],
            allowSameReasonFallback: true, diversityTimeLimit: 4, now: { Date(timeIntervalSince1970: elapsed) },
            onUpdate: { snapshots.append($0.decisions.map(\.persistenceKey)) }) { excluded, protected, _, _ in
            calls += 1
            if calls == 1 {
                elapsed = 0.5
                return .init(decisions: [self.candidate("first"),
                    self.candidate("second", reference: "keep-2"), self.candidate("third", reference: "keep-3")],
                    visitedIdentifiers: ["first", "second", "third"], hasMore: true, hasFreshPhotos: true)
            }
            XCTAssertEqual(snapshots, [["first"]], "A first real result must not wait for the diversity budget")
            XCTAssertTrue(excluded.isSuperset(of: ["first", "second", "third"]))
            XCTAssertTrue(protected.isSuperset(of: ["kept-photo", "keep-2", "keep-3"]))
            elapsed = 4.6
            return .init(decisions: [], visitedIdentifiers: [], hasMore: true, hasFreshPhotos: true)
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(snapshots, [["first"], ["first", "second", "third"]])
        XCTAssertEqual(result.visitedIdentifiers, ["first", "second", "third"])
    }

    func testColdFirstProofDoesNotSpendMissingReasonBudgetBeforeItExists() async {
        var elapsed = 0.0
        var calls = 0
        var snapshots: [[String]] = []
        let result = await PhotoCurationService.curatedBatch(excluding: [], protectedIdentifiers: [],
            allowSameReasonFallback: true, diversityTimeLimit: 3,
            now: { Date(timeIntervalSince1970: elapsed) },
            onUpdate: { snapshots.append($0.decisions.map(\.persistenceKey)) }) { _, _, _, groups in
                calls += 1
                if calls == 1 {
                    elapsed = 6
                    return .init(decisions: [self.candidate("similar", reference: "keep-similar", reason: .visuallySimilar),
                        self.candidate("repeat-a", reference: "keep-a", reason: .visuallySimilar),
                        self.candidate("repeat-b", reference: "keep-b", reason: .visuallySimilar)],
                        visitedIdentifiers: [], hasMore: true, hasFreshPhotos: true)
                }
                XCTAssertEqual(snapshots, [["similar"]], "Cold setup cannot consume the later diversity opportunity")
                XCTAssertEqual(groups, [.similarCapture])
                elapsed = 7
                return .init(decisions: [self.candidate("context", reference: nil, reason: .expiredScreen),
                    self.candidate("exact", reference: "keep-exact")], visitedIdentifiers: [], hasMore: false)
            }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(result.decisions.map(\.persistenceKey), ["similar", "context", "exact"])
        XCTAssertEqual(snapshots, [["similar"], ["similar", "context", "exact"]])
    }

    func testSoftFallbackRechecksReferenceCollisionsAndRejectsUnsupportedCandidates() async {
        let seed = candidate("shown", reference: "keep-shown")
        let result = await PhotoCurationService.curatedBatch(excluding: ["reviewed"], protectedIdentifiers: ["saved"],
            initialDecisions: [seed], allowSameReasonFallback: true) { _, _, _, _ in
            .init(decisions: [self.candidate("keep-shown", reference: "other"),
                self.candidate("references-removed", reference: "shown"),
                self.candidate("good", reference: "keep-good"),
                self.candidate("keep-good", reference: "another"),
                self.candidate("no-reference", reference: nil),
                self.candidate("saved"), self.candidate("reviewed"),
                self.candidate("unsupported", reference: nil, reason: .dailyReflection)],
                visitedIdentifiers: [], hasMore: false)
        }
        XCTAssertEqual(result.decisions.map(\.displayIdentifier), ["shown", "good"])
        XCTAssertEqual(result.visitedIdentifiers, ["good"])
        XCTAssertFalse(result.decisions.flatMap(\.removalIdentifiers).contains("keep-good"))
    }

    func testSoftFallbackStillAllowsOnlyOneContextReview() async {
        let result = await PhotoCurationService.curatedBatch(excluding: [], protectedIdentifiers: [],
            allowSameReasonFallback: true) { _, _, _, _ in
            .init(decisions: [self.candidate("context-a", reference: nil, reason: .expiredScreen),
                              self.candidate("context-b", reference: nil, reason: .temporaryReference)],
                  visitedIdentifiers: ["context-a", "context-b"], hasMore: false)
        }
        XCTAssertEqual(result.decisions.map(\.displayIdentifier), ["context-a"])
        XCTAssertEqual(result.visitedIdentifiers, ["context-a"])
    }

    func testSameFileCopiesAcrossPhotosAndScreenshotsOccupyOneSlot() async {
        let nominations = [candidate("photo", reference: "keep-1"),
                           candidate("other-file-copy", reference: "keep-2"),
                           candidate("screenshot-copy", reference: "keep-screen", reason: .duplicateScreenshot)]
        let result = await PhotoCurationService.curatedBatch(excluding: [], protectedIdentifiers: []) { _, _, _, _ in
            .init(decisions: nominations, visitedIdentifiers: Set(nominations.map(\.persistenceKey)), hasMore: false)
        }
        XCTAssertEqual(result.decisions.map(\.persistenceKey), ["photo"])
        XCTAssertEqual(result.visitedIdentifiers, ["photo"])
        XCTAssertTrue(result.hasMore, "Skipped copies stay eligible for a future batch")
    }

    func testDistinctReasonsAfterAnEntireRunOfCopiesReachTheHomeBatch() async {
        let copy = candidate("copy")
        let other = candidate("another-copy")
        let similar = candidate("nearby", reference: "keep-nearby", reason: .visuallySimilar)
        let expiry = candidate("deadline", reference: nil, reason: .expiredScreen)
        let result = await PhotoCurationService.curatedBatch(excluding: [], protectedIdentifiers: []) { excluded, _, _, represented in
            if represented.isEmpty {
                return .init(decisions: [copy, other], visitedIdentifiers: ["copy", "another-copy"],
                             hasMore: true, hasFreshPhotos: true)
            }
            XCTAssertEqual(represented, [.identicalFile])
            XCTAssertTrue(excluded.contains("another-copy"))
            return .init(decisions: [similar, expiry], visitedIdentifiers: ["nearby", "deadline"], hasMore: false)
        }
        XCTAssertEqual(result.decisions.map(\.shortReason), [copy.shortReason, similar.shortReason, expiry.shortReason])
        XCTAssertEqual(result.visitedIdentifiers, ["copy", "nearby", "deadline"])
    }

    func testNestedSearchPreservesSkippedCopyAndReferenceForANewBatch() async {
        let copy = candidate("shown", reference: "keep-shown")
        let other = candidate("later", reference: "keep-later")
        var outerCalls = 0
        let result = await PhotoCurationService.curatedBatch(excluding: [], protectedIdentifiers: []) { excluded, protected, limit, groups in
            outerCalls += 1
            if outerCalls == 2 {
                XCTAssertTrue(excluded.contains("later"), "The outer search must not rescan a deferred copy")
                return .init(decisions: [], visitedIdentifiers: ["keep-later"], hasMore: false)
            }
            return await PhotoCurationService.curatedBatch(excluding: excluded, protectedIdentifiers: protected,
                limit: limit, excludingReasonGroups: groups) { _, _, _, _ in
                .init(decisions: [copy, other], visitedIdentifiers: ["shown", "later"], hasMore: false)
            }
        }
        XCTAssertEqual(outerCalls, 2)
        XCTAssertEqual(result.decisions.map(\.persistenceKey), ["shown"])
        XCTAssertEqual(result.visitedIdentifiers, ["shown"], "A future request must be able to compare both remaining files")
        XCTAssertTrue(result.hasMore)
    }

    func testAutomaticallyCollectsThreeCandidatesAcrossPasses() async {
        var calls = 0
        let result = await PhotoCurationService.curatedBatch(excluding: ["already-scanned"], protectedIdentifiers: ["saved-record-photo"]) { excluded, protected, remaining, _ in
            calls += 1
            XCTAssertEqual(remaining, 4 - calls)
            XCTAssertTrue(excluded.contains("already-scanned"))
            XCTAssertTrue(protected.contains("saved-record-photo"))
            if calls > 1 {
                XCTAssertTrue(excluded.contains("candidate-\(calls - 1)"))
                XCTAssertTrue(protected.contains("kept-photo"))
                XCTAssertFalse(excluded.contains("kept-photo"), "A retained photo can remain the reference for another duplicate")
            }
            return .init(decisions: [self.variedCandidate("candidate-\(calls)", position: calls)],
                         visitedIdentifiers: ["candidate-\(calls)"], hasMore: true,
                         hasFreshPhotos: true, accessiblePhotoCount: 10)
        }
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(result.decisions.map(\.displayIdentifier), ["candidate-1", "candidate-2", "candidate-3"])
        XCTAssertEqual(result.visitedIdentifiers, ["candidate-1", "candidate-2", "candidate-3"])
        XCTAssertEqual(result.accessiblePhotoCount, 10)
    }

    func testScanOrderAlternatesRecentAndOlderContiguousWindows() {
        let indices = Array(PhotoCurationService.curationScanIndices(count: 260))
        XCTAssertEqual(Array(indices[0..<64]), Array((196..<260).reversed()))
        XCTAssertEqual(Array(indices[64..<128]), Array(0..<64))
        XCTAssertEqual(Array(indices[128..<192]), Array((132..<196).reversed()))
        XCTAssertEqual(Array(indices[192..<256]), Array(64..<128))
        XCTAssertEqual(Array(indices[256..<260]), Array((128..<132).reversed()))
    }

    func testScanOrderVisitsEveryPhotoOnceAtWindowBoundaries() {
        for count in [-1, 0, 1, 63, 64, 65, 127, 128, 129, 191, 192, 193, 22_304] {
            let sequence = PhotoCurationService.curationScanIndices(count: count)
            let indices = Array(sequence)
            XCTAssertEqual(indices.count, max(0, count), "Count \(count)")
            XCTAssertEqual(indices.sorted(), Array(0..<max(0, count)), "Count \(count)")
            XCTAssertEqual(Array(sequence), indices, "Each analysis pass needs a fresh deterministic iterator")
        }
        XCTAssertEqual(Array(PhotoCurationService.curationScanIndices(count: 5, windowSize: 0)), [4, 0, 3, 1, 2])
    }

    func testScanOrderRemainsLazyForLargeLibraries() {
        let first = Array(PhotoCurationService.curationScanIndices(count: Int.max).prefix(3))
        XCTAssertEqual(first, [Int.max - 1, Int.max - 2, Int.max - 3])
    }

    func testCatalogReadsPhotoKitIdentifiersOnceAcrossAllBoundedWindows() throws {
        var readIndices: [Int] = []
        let catalog = try XCTUnwrap(PhotoCurationService.scanCatalog(count: 260) { index in
            readIndices.append(index)
            return .init(identifier: "photo-\(index)", assetIndex: index)
        })
        let expectedOrder = Array(PhotoCurationService.curationScanIndices(count: 260))
        XCTAssertEqual(readIndices, expectedOrder)
        XCTAssertEqual(catalog.map(\.assetIndex), expectedOrder)
        var visited = Set<String>()
        var resolvedIndices: [Int] = []
        while visited.count < catalog.count {
            let window = PhotoCurationService.scanWindow(in: catalog, excluding: visited,
                                                        deferred: [], reviewDates: [:])
            XCTAssertLessThanOrEqual(window.entries.count, 64)
            XCTAssertFalse(window.entries.isEmpty)
            XCTAssertFalse(window.isRetryWindow)
            XCTAssertEqual(window.remaining.count, catalog.count - visited.count)
            for entry in window.entries {
                XCTAssertEqual(entry.identifier, "photo-\(entry.assetIndex)")
                XCTAssertTrue(visited.insert(entry.identifier).inserted)
                resolvedIndices.append(entry.assetIndex)
            }
        }
        XCTAssertEqual(resolvedIndices, expectedOrder, "Snapshotting must not reorder or skip comparison neighbours")
        XCTAssertEqual(readIndices.count, 260, "Subsequent selection passes must not traverse PhotoKit again")
    }

    func testCatalogWindowPreservesDuePriorityAndDeferredRecovery() throws {
        let catalog = try XCTUnwrap(PhotoCurationService.scanCatalog(count: 260) { .init(identifier: "photo-\($0)", assetIndex: $0) })
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let dates = ["photo-100": now.addingTimeInterval(-86_400),
                     "photo-101": now.addingTimeInterval(-3 * 86_400),
                     "photo-257": now.addingTimeInterval(2 * 86_400)]
        let window = PhotoCurationService.scanWindow(in: catalog, excluding: ["photo-259"],
            deferred: ["photo-258"], reviewDates: dates, now: now)
        XCTAssertEqual(Array(window.entries.prefix(4).map(\.identifier)),
                       ["photo-101", "photo-100", "photo-257", "photo-256"])
        XCTAssertEqual(window.entries.count, 64)
        XCTAssertFalse(window.entries.contains { ["photo-259", "photo-258"].contains($0.identifier) })
        XCTAssertFalse(window.remaining.contains("photo-259"))
        XCTAssertTrue(window.remaining.contains("photo-258"), "Deferred photos must remain recoverable")

        let retry = PhotoCurationService.scanWindow(in: catalog, excluding: ["photo-259"],
            deferred: Set(catalog.map(\.identifier)), reviewDates: dates, now: now)
        XCTAssertTrue(retry.isRetryWindow)
        XCTAssertEqual(retry.entries, Array(catalog.dropFirst().prefix(64)))
        XCTAssertEqual(retry.remaining.count, 259, "Retry selection must not retire unreadable photos or their peers")
    }

    func testNewCatalogUsesCurrentScopeAndIndicesWithoutOldEntries() throws {
        let oldIDs = ["removed", "kept"]
        let old = try XCTUnwrap(PhotoCurationService.scanCatalog(count: oldIDs.count) { .init(identifier: oldIDs[$0], assetIndex: $0) })
        let currentIDs = ["new", "kept", "other-new"]
        let current = try XCTUnwrap(PhotoCurationService.scanCatalog(count: currentIDs.count) { .init(identifier: currentIDs[$0], assetIndex: $0) })
        let window = PhotoCurationService.scanWindow(in: current, excluding: [],
            deferred: Set(old.map(\.identifier)), reviewDates: [:])
        XCTAssertEqual(window.entries.map(\.identifier), ["other-new", "new"])
        XCTAssertEqual(window.entries.map { currentIDs[$0.assetIndex] }, window.entries.map(\.identifier))
        XCTAssertEqual(window.remaining, Set(currentIDs))
        XCTAssertFalse(window.remaining.contains("removed"))
    }

    func testCancelledCatalogDoesNotReturnPartialCoverage() async {
        let result = await Task {
            var reads = 0
            let catalog = PhotoCurationService.scanCatalog(count: 260) { index in
                reads += 1
                if reads == 2 { withUnsafeCurrentTask { $0?.cancel() } }
                return .init(identifier: "photo-\(index)", assetIndex: index)
            }
            return (catalog, reads)
        }.value
        XCTAssertNil(result.0, "An interrupted snapshot must not appear to be the complete accessible library")
        XCTAssertEqual(result.1, 2)
    }

    private func catalogEntry(_ index: Int, date: Date?, width: Int = 100,
                              screenshot: Bool = false, favorite: Bool = false,
                              excluded: Bool = false) -> PhotoCurationService.ScanCatalogEntry {
        .init(identifier: "photo-\(index)", assetIndex: index,
              facts: .init(capturedAt: date, width: width, height: 100,
                           isScreenshot: screenshot, isFavorite: favorite, isExcluded: excluded))
    }

    func testMetadataPriorityIsBoundedToEightPairsWithinOneCohortAndPreservesFallbackCoverage() {
        var catalog = (0..<100).map { PhotoCurationService.ScanCatalogEntry(identifier: "photo-\($0)", assetIndex: $0) }
        for group in 0..<10 {
            let date = Date(timeIntervalSince1970: Double(1_000 + group))
            for index in (10 + group * 2)...(11 + group * 2) { catalog[index] = catalogEntry(index, date: date) }
        }
        var priority: [Int] = []
        for group in (2..<10).reversed() {
            let first = 10 + group * 2
            priority.append(contentsOf: [first, first + 1])
        }
        let first = PhotoCurationService.scanWindow(in: catalog, excluding: [], deferred: [], reviewDates: [:])
        XCTAssertEqual(Array(first.entries.prefix(16).map(\.assetIndex)), priority)
        XCTAssertEqual(first.nominationCounts["exactNomineePhotos"], 16)
        XCTAssertEqual(first.entries.count, 64)

        var visited = Set(first.entries.map(\.identifier))
        var covered = first.entries.map(\.assetIndex)
        while visited.count < catalog.count {
            let next = PhotoCurationService.scanWindow(in: catalog, excluding: visited, deferred: [], reviewDates: [:])
            XCTAssertFalse(next.entries.isEmpty)
            covered += next.entries.map(\.assetIndex)
            for entry in next.entries { XCTAssertTrue(visited.insert(entry.identifier).inserted) }
        }
        XCTAssertEqual(covered.sorted(), Array(0..<100), "Metadata preference must never drop the chronological fallback")
    }

    func testSameCapturePairStaysTogetherAcrossOldWindowBoundary() {
        var catalog = (0..<130).map { PhotoCurationService.ScanCatalogEntry(identifier: "photo-\($0)", assetIndex: $0) }
        let date = Date(timeIntervalSince1970: 1_000)
        catalog[63] = catalogEntry(63, date: date)
        catalog[64] = catalogEntry(64, date: date)
        let window = PhotoCurationService.scanWindow(in: catalog, excluding: [], deferred: [], reviewDates: [:])
        XCTAssertEqual(Array(window.entries.prefix(2).map(\.assetIndex)), [63, 64])
        XCTAssertEqual(window.entries.count, 64)
        XCTAssertEqual(Array(window.entries.dropFirst(2).map(\.assetIndex)), Array(0..<62))
    }

    func testPriorityRequiresRemovablePhotoButCanUseProtectedReference() {
        let catalog = [
            catalogEntry(0, date: Date(timeIntervalSince1970: 1), favorite: true),
            catalogEntry(1, date: Date(timeIntervalSince1970: 1), favorite: true),
            catalogEntry(2, date: Date(timeIntervalSince1970: 2)),
            catalogEntry(3, date: Date(timeIntervalSince1970: 2)),
            catalogEntry(4, date: Date(timeIntervalSince1970: 3), favorite: true),
            catalogEntry(5, date: Date(timeIntervalSince1970: 3)),
            catalogEntry(6, date: Date(timeIntervalSince1970: 4)),
            catalogEntry(7, date: Date(timeIntervalSince1970: 4))
        ]
        let window = PhotoCurationService.scanWindow(in: catalog, excluding: [], deferred: [],
            protectedIdentifiers: ["photo-2", "photo-3", "photo-6"], reviewDates: [:])
        XCTAssertEqual(window.entries.map(\.assetIndex), [6, 7, 4, 5, 0, 1, 2, 3])
        let allProtected = PhotoCurationService.scanWindow(in: catalog, excluding: [], deferred: [],
            protectedIdentifiers: Set(catalog.map(\.identifier)), reviewDates: [:])
        XCTAssertEqual(allProtected.entries, catalog)
    }

    func testMissingExcludedOrMismatchedMetadataCannotCreatePriorityPair() {
        let catalog = [
            catalogEntry(0, date: nil), catalogEntry(1, date: nil),
            catalogEntry(2, date: Date(timeIntervalSince1970: 200), excluded: true),
            catalogEntry(3, date: Date(timeIntervalSince1970: 200)),
            catalogEntry(4, date: Date(timeIntervalSince1970: 300), width: 0),
            catalogEntry(5, date: Date(timeIntervalSince1970: 300), width: 0),
            catalogEntry(6, date: Date(timeIntervalSince1970: 400), screenshot: true),
            catalogEntry(7, date: Date(timeIntervalSince1970: 400)),
            catalogEntry(8, date: Date(timeIntervalSince1970: 500), width: 200),
            catalogEntry(9, date: Date(timeIntervalSince1970: 500))
        ]
        let window = PhotoCurationService.scanWindow(in: catalog, excluding: [], deferred: [], reviewDates: [:])
        XCTAssertEqual(window.entries.first?.assetIndex, 6,
                       "An old screenshot can be nominated for context, without claiming a duplicate")
        XCTAssertEqual(Set(window.entries.map(\.identifier)), Set(catalog.map(\.identifier)))
    }

    func testVisitedDeferredAndFutureReviewPhotosAreExcludedBeforePriorityGrouping() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let catalog = (0..<6).map { catalogEntry($0, date: Date(timeIntervalSince1970: Double($0 / 2) * 100)) }
        let window = PhotoCurationService.scanWindow(in: catalog, excluding: ["photo-0"], deferred: ["photo-2"],
            reviewDates: ["photo-4": now.addingTimeInterval(2 * 86_400)], now: now)
        XCTAssertEqual(Set(window.entries.map(\.assetIndex)), [1, 3, 4, 5])
        XCTAssertEqual(window.nominationCounts["exactNomineePhotos"], 0,
                       "An unavailable peer cannot promote an exact pair")
        XCTAssertEqual(window.entries.last?.assetIndex, 4,
                       "Future review dates cannot enter a priority context lane; fallback still checks their eligibility")
        XCTAssertFalse(window.remaining.contains("photo-0"))
        XCTAssertTrue(window.remaining.contains("photo-2"))
    }

    func testNearbyCaptureCandidatesBeyondFirstEmpty64AreNominatedTogether() {
        // The leading 100 photos offer no pair metadata. The actual nearby pair
        // must be inspected before spending OCR on every unrelated leading item.
        var catalog = (0..<130).map { PhotoCurationService.ScanCatalogEntry(identifier: "photo-\($0)", assetIndex: $0) }
        catalog[100] = catalogEntry(100, date: Date(timeIntervalSince1970: 1_000))
        catalog[101] = catalogEntry(101, date: Date(timeIntervalSince1970: 1_020))
        let first = PhotoCurationService.scanWindow(in: catalog, excluding: [], deferred: [], reviewDates: [:])
        XCTAssertEqual(Set(first.entries.prefix(2).map(\.assetIndex)), [100, 101])
        XCTAssertEqual(first.entries.count, 64)
        let photos = first.entries.prefix(2).map { entry in
            PhotoCurationPolicy.Photo(id: entry.identifier, date: entry.facts!.capturedAt, width: 100, height: 100)
        }
        XCTAssertTrue(PhotoCurationPolicy.selectPairs(from: photos, limit: 1) { _, _ in false }.isEmpty,
                      "Metadata priority alone must never create a recommendation")
        var visited = Set(first.entries.map(\.identifier))
        while visited.count < catalog.count {
            let next = PhotoCurationService.scanWindow(in: catalog, excluding: visited, deferred: [], reviewDates: [:])
            XCTAssertFalse(next.entries.isEmpty)
            for entry in next.entries { XCTAssertTrue(visited.insert(entry.identifier).inserted) }
        }
        XCTAssertEqual(visited.count, 130, "Fast nominations preserve complete fallback coverage")
    }

    func testNearbyPriorityKeepsProtectedReferenceButNeverProtectedOnlyPair() {
        let now = Date(timeIntervalSince1970: 2_000)
        let catalog = [catalogEntry(0, date: now.addingTimeInterval(-20), favorite: true),
                       catalogEntry(1, date: now)]
        let selected = PhotoCurationService.nearbyPriorityEntries(in: catalog, excluding: [],
            protectedIdentifiers: [], reviewDates: [:], now: now)
        XCTAssertEqual(Set(selected.map(\.assetIndex)), [0, 1])
        XCTAssertTrue(PhotoCurationService.nearbyPriorityEntries(in: catalog, excluding: [],
            protectedIdentifiers: ["photo-1"], reviewDates: [:], now: now).isEmpty)
        XCTAssertTrue(PhotoCurationService.nearbyPriorityEntries(in: catalog, excluding: ["photo-0"],
            protectedIdentifiers: [], reviewDates: [:], now: now).isEmpty)
        XCTAssertTrue(PhotoCurationService.nearbyPriorityEntries(in: catalog, excluding: [],
            protectedIdentifiers: [], reviewDates: ["photo-1": now.addingTimeInterval(86_400)], now: now).isEmpty)
    }

    func testNearbyPriorityRejectsScreenshotsDifferentSizeAndDistantCaptures() {
        let now = Date(timeIntervalSince1970: 5_000)
        let invalidPairs = [
            [catalogEntry(0, date: now, screenshot: true), catalogEntry(1, date: now.addingTimeInterval(-10), screenshot: true)],
            [catalogEntry(0, date: now), catalogEntry(1, date: now.addingTimeInterval(-10), width: 200)],
            [catalogEntry(0, date: now), catalogEntry(1, date: now.addingTimeInterval(-31))]
        ]
        for pair in invalidPairs {
            XCTAssertTrue(PhotoCurationService.nearbyPriorityEntries(in: pair, excluding: [],
                protectedIdentifiers: [], reviewDates: [:], now: now).isEmpty)
        }
    }

    func testWorkRevisionMeasuresNewWorkAndSurvivesWindowRetirement() {
        let cache = CurationAnalysisMemory<Int, String>()
        let initial = cache.workRevision
        cache.record("preview", for: "pending", revision: 1, complete: false, failed: false)
        XCTAssertGreaterThan(cache.workRevision, initial)
        cache.record(nil, for: "failed", revision: 1, complete: false)
        let afterFailure = cache.workRevision
        cache.record(nil, for: "failed", revision: 1, complete: false)
        XCTAssertEqual(cache.workRevision, afterFailure, "Repeated reports of one unavailable photo are not progress")
        cache.reset()
        XCTAssertEqual(cache.workRevision, afterFailure, "Retiring a window cannot roll back cumulative progress")
        cache.record("next-window", for: "next", revision: 1, complete: true)
        XCTAssertGreaterThan(cache.workRevision, afterFailure)
    }

    func testDeferredLocalPreviewDoesNotBlockFreshLocalWorkOrBecomeFailure() {
        let cache = CurationAnalysisMemory<Int, String>()
        let initial = cache.nextPreviewWork(among: ["slow", "fast"])
        XCTAssertEqual(initial.identifiers, ["slow", "fast"])
        XCTAssertFalse(initial.allowsNetwork)
        cache.deferPreview(for: "slow", revision: 1)
        let workAfterMiss = cache.workRevision
        cache.deferPreview(for: "slow", revision: 1)
        XCTAssertEqual(cache.workRevision, workAfterMiss)
        XCTAssertTrue(cache.entries.isEmpty)
        XCTAssertTrue(cache.failures.isEmpty)
        XCTAssertEqual(cache.nextPreviewWork(among: ["slow", "fast"]).identifiers, ["fast"])
        cache.record("fast-local", for: "fast", revision: 1, complete: true)
        let recovery = cache.nextPreviewWork(among: ["slow", "fast"])
        XCTAssertEqual(recovery.identifiers, ["slow"])
        XCTAssertTrue(recovery.allowsNetwork)
        let freshFirst = cache.nextPreviewWork(among: ["slow", "fast", "another-local"])
        XCTAssertEqual(freshFirst.identifiers, ["another-local"])
        XCTAssertFalse(freshFirst.allowsNetwork)
        cache.record("recovered-preview", for: "slow", revision: 1, complete: false, failed: false)
        XCTAssertTrue(cache.deferredPreviews.isEmpty)
        XCTAssertTrue(cache.failures.isEmpty)
        XCTAssertTrue(cache.nextPreviewWork(among: ["slow", "fast"]).identifiers.isEmpty)
    }

    func testDeferredPreviewRevisionChangeAndNetworkFailureStayDistinct() {
        let cache = CurationAnalysisMemory<Int, String>()
        cache.deferPreview(for: "changed", revision: 1)
        cache.retain(revisions: ["changed": 2])
        XCTAssertTrue(cache.deferredPreviews.isEmpty)
        XCTAssertFalse(cache.nextPreviewWork(among: ["changed"]).allowsNetwork)
        cache.deferPreview(for: "changed", revision: 2)
        cache.record(nil, for: "changed", revision: 2, complete: false)
        XCTAssertTrue(cache.deferredPreviews.isEmpty)
        XCTAssertEqual(cache.failures, ["changed": 2], "Only the later actual network-enabled read failure enters recovery")
        cache.reset()
        XCTAssertTrue(cache.deferredPreviews.isEmpty)
    }

    func testFilledSimilarCategoryPromotesOtherEvidenceSourcesFirst() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var catalog = (0..<120).map { PhotoCurationService.ScanCatalogEntry(identifier: "photo-\($0)", assetIndex: $0) }
        catalog[80] = catalogEntry(80, date: now.addingTimeInterval(-86_400))
        catalog[81] = catalogEntry(81, date: now.addingTimeInterval(-86_420))
        catalog[90] = catalogEntry(90, date: now.addingTimeInterval(-40 * 86_400), screenshot: true)
        catalog[96] = catalogEntry(96, date: now.addingTimeInterval(-90 * 86_400))
        catalog[97] = catalogEntry(97, date: now.addingTimeInterval(-90 * 86_400))
        let initial = PhotoCurationService.scanWindow(in: catalog, excluding: [], deferred: [], reviewDates: [:], now: now)
        XCTAssertTrue(Set(initial.entries.prefix(4).map(\.assetIndex)).isSuperset(of: [80, 81, 96, 97]))
        let remaining = PhotoCurationService.scanWindow(in: catalog, excluding: [], deferred: [],
            reviewDates: [:], now: now, excludingReasonGroups: [.similarCapture])
        XCTAssertTrue(remaining.entries.prefix(3).contains { $0.assetIndex == 90 })
        XCTAssertTrue(Set(remaining.entries.prefix(3).map(\.assetIndex)).isSuperset(of: [90, 96, 97]))
        XCTAssertFalse(remaining.entries.prefix(3).contains { [80, 81].contains($0.assetIndex) })
        XCTAssertEqual(remaining.nominationCounts["nearbyNomineePhotos"], 0,
                       "A filled similar category cannot take priority reads; fallback coverage remains available")
        XCTAssertEqual(remaining.remaining.count, catalog.count, "Lower priority is not permanently scanned or deleted coverage")
    }

    func testRepresentedPairsCannotConsumeContextBudgetOrReserveItsPhoto() {
        let context = candidate("context", reference: nil, reason: .temporaryReference)
        var pairCalls = 0
        let demand = CurationEvidenceDemand(excluding: [.identicalFile, .similarCapture])
        let result = demand.collect(limit: 1, pairsOnly: false) { _, _, _ in
            pairCalls += 1
            return [self.candidate("context", reference: "pair-reference")]
        } context: { reserved in
            XCTAssertTrue(reserved.isEmpty, "A suppressed pair cannot hide the context photo")
            return context
        }
        XCTAssertEqual(pairCalls, 0)
        XCTAssertEqual(result.map(\.displayIdentifier), ["context"])
        XCTAssertEqual(result.first?.reasonCodes, [.temporaryReference])
    }

    func testUnfilledPairKeepsItsReferenceProtectedBeforeContextNomination() {
        var queried: [CleanupReasonGroup] = []
        let result = CurationEvidenceDemand(excluding: [.identicalFile]).collect(limit: 2, pairsOnly: false) { group, remaining, reserved in
            queried.append(group)
            XCTAssertEqual(remaining, 2)
            XCTAssertTrue(reserved.isEmpty)
            return [self.candidate("similar", reference: "keep", reason: .visuallySimilar)]
        } context: { reserved in
            XCTAssertEqual(reserved, ["similar", "keep"])
            return self.candidate("unrelated-context", reference: nil, reason: .temporaryReference)
        }
        XCTAssertEqual(queried, [.similarCapture])
        XCTAssertEqual(result.map(\.displayIdentifier), ["similar", "unrelated-context"])
    }

    func testContextOnlyWorkDoesNotWaitForUnrequestedPairOriginals() {
        var comparisons = 0
        func promisingPair() -> Set<String> { comparisons += 1; return ["left", "right"] }
        let contextOnly = CurationEvidenceDemand(excluding: [.identicalFile, .similarCapture])
        XCTAssertTrue(contextOnly.originalIdentifiers(promisingPair).isEmpty)
        XCTAssertEqual(comparisons, 0, "Neither reads nor pending coverage should request unneeded originals")
        XCTAssertEqual(CurationEvidenceDemand(excluding: [.similarCapture]).originalIdentifiers(promisingPair), ["left", "right"])
        XCTAssertEqual(CurationEvidenceDemand(excluding: [.identicalFile]).originalIdentifiers(promisingPair), ["left", "right"])
        XCTAssertEqual(comparisons, 2, "Either outstanding pair category still requires its original comparison gate")
        for original in [PhotoCurationService.OriginalAnalysisState.notRequested, .awaitingFullBudget, .unavailable] {
            XCTAssertTrue(original.permitsCompletedPreview(originalRequired: false),
                "Already enriched partials can finish when the outstanding request only needs context")
            XCTAssertFalse(original.permitsCompletedPreview(originalRequired: true),
                "A required full-file comparison must still block unfinished originals")
        }
        XCTAssertTrue(PhotoCurationService.OriginalAnalysisState.resolved.permitsCompletedPreview(originalRequired: true))
    }

    func testLocalMissWindowYieldsToNextLocalWindowWithoutRetiringEitherPairSide() {
        let catalog = (0..<130).map { PhotoCurationService.ScanCatalogEntry(identifier: "photo-\($0)", assetIndex: $0) }
        let first = PhotoCurationService.scanWindow(in: catalog, excluding: [], deferred: [], reviewDates: [:])
        let ids = Set(first.entries.map(\.identifier))
        let misses: Set<String> = ["photo-0", "photo-1"]
        let attempted = ids.subtracting(misses)
        XCTAssertTrue(PhotoCurationService.canDeferLocalPreviewWindow(ids, attempted: attempted, localMisses: misses))
        XCTAssertFalse(PhotoCurationService.canDeferLocalPreviewWindow(ids,
            attempted: attempted.subtracting(["photo-2"]), localMisses: misses),
            "An unfinished feature, OCR or original read must finish before its window is deferred")
        let next = PhotoCurationService.scanWindow(in: catalog, excluding: [], deferred: ids, reviewDates: [:])
        XCTAssertEqual(next.entries.first?.assetIndex, 64)
        XCTAssertEqual(next.remaining.count, 130, "Local cache misses are neither visited nor failed photos")
        let laterIDs = Set(catalog.dropFirst(64).map(\.identifier))
        let retry = PhotoCurationService.scanWindow(in: catalog, excluding: laterIDs, deferred: ids, reviewDates: [:])
        XCTAssertTrue(retry.isRetryWindow)
        XCTAssertEqual(Set(retry.entries.map(\.identifier)), ids, "Recovery retains every possible comparison peer")
        let memory = CurationAnalysisMemory<Int, String>()
        for id in misses { memory.deferPreview(for: id, revision: 1) }
        let continuedRetry = PhotoCurationService.scanWindow(in: catalog, excluding: laterIDs,
            deferred: [], reviewDates: [:])
        XCTAssertFalse(continuedRetry.isRetryWindow, "A retry window becomes active across following small fetches")
        var reread = Set<String>()
        let peers = attempted.sorted()
        for offset in stride(from: 0, to: peers.count, by: 8) {
            for id in peers.dropFirst(offset).prefix(8) {
                memory.record("local-peer", for: id, revision: 1, complete: true)
                reread.insert(id)
            }
            XCTAssertFalse(PhotoCurationService.canDeferLocalPreviewWindow(ids,
                attempted: reread, localMisses: misses, recovering: misses),
                "Remembered recovery must survive several peer-reading fetches without redefer starvation")
        }
        let recovery = memory.nextPreviewWork(among: retry.entries.map(\.identifier))
        XCTAssertTrue(recovery.allowsNetwork)
        XCTAssertEqual(Set(recovery.identifiers), misses, "Remembered local misses must not repeat the same local-only attempt")
    }

    func testCloudOnlyWindowDoesNotExhaustPassesBeforeNextReadableWindow() async {
        var calls = 0
        let result = await PhotoCurationService.curatedBatch(excluding: [], protectedIdentifiers: [],
            now: { Date(timeIntervalSince1970: 0) }) { excluded, _, remaining, _ in
            calls += 1
            XCTAssertTrue(excluded.isEmpty, "Unreadable photos remain retryable, not permanently scanned")
            XCTAssertEqual(remaining, 3)
            if calls <= 8 {
                return .init(decisions: [], visitedIdentifiers: [], hasMore: true,
                             retryableFailureCount: calls * 8, hasFreshPhotos: true,
                             accessiblePhotoCount: 22_304)
            }
            return .init(decisions: [self.variedCandidate("first", position: 1), self.variedCandidate("second", position: 2), self.variedCandidate("third", position: 3)],
                         visitedIdentifiers: ["first", "second", "third"], hasMore: true,
                         retryableFailureCount: 64, hasFreshPhotos: true, accessiblePhotoCount: 22_304)
        }
        XCTAssertEqual(calls, 9)
        XCTAssertEqual(result.decisions.map(\.displayIdentifier), ["first", "second", "third"])
        XCTAssertEqual(result.retryableFailureCount, 64)
        XCTAssertEqual(result.visitedIdentifiers, ["first", "second", "third"])
    }

    func testDefaultPassLimitStillBoundsUnreadableWindows() async {
        var calls = 0
        let result = await PhotoCurationService.curatedBatch(excluding: [], protectedIdentifiers: [],
            now: { Date(timeIntervalSince1970: 0) }) { _, _, _, _ in
            calls += 1
            return .init(decisions: [], visitedIdentifiers: [], hasMore: true,
                         retryableFailureCount: calls * 8, hasFreshPhotos: true)
        }
        XCTAssertEqual(calls, 32)
        XCTAssertTrue(result.decisions.isEmpty)
        XCTAssertTrue(result.visitedIdentifiers.isEmpty)
        XCTAssertTrue(result.hasMore)
    }

    func testCancellationAfterAnUnreadableWindowRejectsLateCandidates() async {
        let entered = expectation(description: "Next readable window waits")
        let release = CurationBatchRelease()
        var calls = 0
        let task = Task {
            await PhotoCurationService.curatedBatch(excluding: [], protectedIdentifiers: [],
                now: { Date(timeIntervalSince1970: 0) }) { _, _, _, _ in
                calls += 1
                if calls <= 8 {
                    return .init(decisions: [], visitedIdentifiers: [], hasMore: true,
                                 retryableFailureCount: calls * 8, hasFreshPhotos: true)
                }
                entered.fulfill()
                await release.wait()
                return .init(decisions: [self.candidate("late")], visitedIdentifiers: ["late"], hasMore: false)
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        await release.finish()
        let result = await task.value
        XCTAssertEqual(calls, 9)
        XCTAssertTrue(result.decisions.isEmpty)
        XCTAssertTrue(result.visitedIdentifiers.isEmpty)
    }

    func testNeverRemovesAnEarlierReferenceOrUsesAnEarlierCandidateAsReference() async {
        var calls = 0
        let result = await PhotoCurationService.curatedBatch(excluding: [], protectedIdentifiers: []) { excluded, protected, _, _ in
            calls += 1
            if calls == 1 {
                return .init(decisions: [self.candidate("first", reference: "keep-first")],
                             visitedIdentifiers: ["first"], hasMore: true, hasFreshPhotos: true)
            }
            XCTAssertTrue(protected.contains("keep-first"))
            if calls == 2 {
                return .init(decisions: [self.candidate("keep-first", reference: "another"),
                                         self.candidate("bad-reference", reference: "first"),
                                         self.candidate("first", reference: "keep-first"),
                                         self.candidate("second", reference: "keep-second", reason: .visuallySimilar)],
                             visitedIdentifiers: ["keep-first", "bad-reference", "first", "second"],
                             hasMore: true, hasFreshPhotos: true)
            }
            XCTAssertTrue(excluded.contains("bad-reference"), "Rejected nominations must not repeat inside this request")
            XCTAssertTrue(protected.contains("keep-second"))
            return .init(decisions: [self.candidate("third", reference: nil, reason: .expiredScreen)],
                         visitedIdentifiers: ["third"], hasMore: false)
        }
        XCTAssertEqual(result.decisions.map(\.displayIdentifier), ["first", "second", "third"])
        XCTAssertFalse(result.visitedIdentifiers.contains("keep-first"))
        XCTAssertFalse(result.visitedIdentifiers.contains("bad-reference"))
    }

    func testFewerThanThreeRealCandidatesAreNotPaddedWithReflections() async {
        var reflection = candidate("recent-photo", reference: nil, reason: .dailyReflection)
        reflection = DecisionUnit(id: reflection.id, type: .recallMoment, status: .pending,
                                  candidateLocalIdentifiers: reflection.candidateLocalIdentifiers,
                                  recommendedLocalIdentifier: reflection.displayIdentifier,
                                  reasonCodes: [.dailyReflection], capturedDateDescription: nil, createdAt: Date())
        let result = await PhotoCurationService.curatedBatch(excluding: [], protectedIdentifiers: []) { _, _, _, _ in
            .init(decisions: [self.candidate("one"), self.candidate("two", reason: .visuallySimilar), reflection],
                  visitedIdentifiers: ["one", "two", "recent-photo"], hasMore: false, accessiblePhotoCount: 4)
        }
        XCTAssertEqual(result.decisions.map(\.displayIdentifier), ["one", "two"])
        XCTAssertFalse(result.visitedIdentifiers.contains("recent-photo"))
    }

    func testExhaustedLibraryReturnsItsActualTwoCandidates() async {
        var calls = 0
        let result = await PhotoCurationService.curatedBatch(excluding: [], protectedIdentifiers: []) { _, _, _, _ in
            calls += 1
            return .init(decisions: [self.candidate("one"), self.candidate("two", reason: .visuallySimilar)],
                         visitedIdentifiers: ["one", "two"], hasMore: false, accessiblePhotoCount: 3)
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(result.decisions.count, 2)
        XCTAssertFalse(result.hasMore)
        XCTAssertFalse(result.hasFreshPhotos)
    }

    func testContextReviewCapIsSharedAcrossPasses() async {
        var calls = 0
        let result = await PhotoCurationService.curatedBatch(excluding: [], protectedIdentifiers: []) { _, _, _, _ in
            calls += 1
            if calls == 1 {
                return .init(decisions: [self.candidate("expired-screen", reference: nil, reason: .expiredScreen)],
                             visitedIdentifiers: ["expired-screen"], hasMore: true, hasFreshPhotos: true)
            }
            return .init(decisions: [self.candidate("shopping-screen", reference: nil, reason: .shoppingScreen),
                                     self.candidate("duplicate")],
                         visitedIdentifiers: ["shopping-screen", "duplicate"], hasMore: false)
        }
        XCTAssertEqual(result.decisions.map(\.displayIdentifier), ["expired-screen", "duplicate"])
        XCTAssertFalse(result.visitedIdentifiers.contains("shopping-screen"), "A skipped context candidate remains available for another batch")
    }

    func testUnavailableOnlyPassStopsWhileRetainingVerifiedCandidateAndRetryState() async {
        var calls = 0
        let result = await PhotoCurationService.curatedBatch(excluding: [], protectedIdentifiers: []) { _, _, _, _ in
            calls += 1
            if calls == 1 {
                return .init(decisions: [self.candidate("local-photo")], visitedIdentifiers: ["local-photo"],
                             hasMore: true, hasFreshPhotos: true, accessiblePhotoCount: 5)
            }
            return .init(decisions: [], visitedIdentifiers: [], hasMore: true,
                         retryableFailureCount: 2, hasFreshPhotos: false, accessiblePhotoCount: 5)
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(result.decisions.map(\.displayIdentifier), ["local-photo"])
        XCTAssertEqual(result.retryableFailureCount, 2)
        XCTAssertTrue(result.hasMore)
        XCTAssertFalse(result.hasFreshPhotos)
    }

    func testSoftTimeBudgetReturnsOnlyCandidatesAlreadyVerified() async {
        var elapsed: TimeInterval = 0
        var calls = 0
        let result = await PhotoCurationService.curatedBatch(excluding: [], protectedIdentifiers: [],
                                                            now: { Date(timeIntervalSince1970: elapsed) }) { _, _, _, _ in
            calls += 1
            elapsed += 6
            return .init(decisions: [self.variedCandidate("candidate-\(calls)", position: calls)], visitedIdentifiers: ["candidate-\(calls)"],
                         hasMore: true, hasFreshPhotos: true)
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(result.decisions.count, 2)
        XCTAssertTrue(result.hasMore)
    }

    func testExtendedSharedBudgetCollectsThreeAcrossSlowerFetches() async {
        var elapsed: TimeInterval = 0
        var calls = 0
        let result = await PhotoCurationService.curatedBatch(excluding: [], protectedIdentifiers: [],
            maximumPasses: 3, timeLimit: 30, now: { Date(timeIntervalSince1970: elapsed) }) { _, _, remaining, _ in
                calls += 1
                XCTAssertEqual(remaining, 4 - calls)
                elapsed += 10
                return .init(decisions: [self.variedCandidate("photo-\(calls)", position: calls)],
                    visitedIdentifiers: ["photo-\(calls)"], hasMore: true, hasFreshPhotos: true)
            }
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(result.decisions.count, 3)
        XCTAssertEqual(result.visitedIdentifiers, ["photo-1", "photo-2", "photo-3"])
    }

    func testRestoredSeedsCanAlreadyBeScannedAndOnlyMissingSlotIsFetched() async {
        let seeds = [candidate("first", reference: "keep-first"), candidate("second", reference: "keep-second")]
        var calls = 0
        let result = await PhotoCurationService.curatedBatch(excluding: ["first", "second", "earlier"],
            protectedIdentifiers: ["saved-record"], initialDecisions: seeds, maximumPasses: 1) { excluded, protected, remaining, _ in
                calls += 1
                XCTAssertEqual(remaining, 1)
                XCTAssertTrue(excluded.isSuperset(of: ["first", "second", "earlier"]))
                XCTAssertTrue(protected.isSuperset(of: ["keep-first", "keep-second", "saved-record"]))
                XCTAssertFalse(excluded.contains("keep-first"))
                return .init(decisions: [self.candidate("third", reference: "keep-third", reason: .visuallySimilar)],
                    visitedIdentifiers: ["first", "second", "third", "checked"], hasMore: true,
                    hasFreshPhotos: true, accessiblePhotoCount: 100)
            }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(Array(result.decisions.prefix(2).map(\.id)), seeds.map(\.id))
        XCTAssertEqual(result.decisions.map(\.displayIdentifier), ["first", "second", "third"])
        XCTAssertEqual(result.visitedIdentifiers, ["third", "checked"], "Restoration is not new scan coverage or a completed user decision")
    }

    func testUnavailableTopUpKeepsVerifiedSeedsAndRetryStateWithoutPadding() async {
        let seeds = [candidate("first"), candidate("second")]
        let result = await PhotoCurationService.curatedBatch(excluding: [], protectedIdentifiers: [],
            initialDecisions: seeds, maximumPasses: 1) { excluded, _, remaining, _ in
                XCTAssertEqual(remaining, 1)
                XCTAssertTrue(excluded.isSuperset(of: ["first", "second"]))
                return .init(decisions: [], visitedIdentifiers: ["first", "second"], hasMore: true,
                    retryableFailureCount: 4, hasFreshPhotos: false, accessiblePhotoCount: 10)
            }
        XCTAssertEqual(result.decisions.map(\.id), seeds.map(\.id))
        XCTAssertTrue(result.visitedIdentifiers.isEmpty)
        XCTAssertTrue(result.hasMore)
        XCTAssertFalse(result.hasFreshPhotos)
        XCTAssertEqual(result.retryableFailureCount, 4)
        XCTAssertEqual(result.accessiblePhotoCount, 10)
    }

    func testSeededReferencesCandidatesAndContextCapProtectTheTopUp() async {
        let seeds = [candidate("context", reference: nil, reason: .reviewDateReached),
                     candidate("first", reference: "keep-first")]
        let result = await PhotoCurationService.curatedBatch(excluding: [], protectedIdentifiers: [],
            initialDecisions: seeds, maximumPasses: 1) { _, protected, remaining, _ in
                XCTAssertEqual(remaining, 1)
                XCTAssertTrue(protected.contains("keep-first"))
                return .init(decisions: [self.candidate("keep-first", reference: "other"),
                                         self.candidate("bad-reference", reference: "first"),
                                         self.candidate("first", reference: "keep-first"),
                                         self.candidate("extra-context", reference: nil, reason: .shoppingScreen),
                                         self.candidate("third", reference: "keep-third", reason: .visuallySimilar)],
                    visitedIdentifiers: ["keep-first", "bad-reference", "first", "extra-context", "third"],
                    hasMore: false)
            }
        XCTAssertEqual(result.decisions.map(\.displayIdentifier), ["context", "first", "third"])
        XCTAssertEqual(result.visitedIdentifiers, ["third"])
    }

    func testSeedsUseTheSameEvidenceTypeStatusAndConflictValidation() async {
        var completed = candidate("completed")
        completed.status = .completed
        let recall = DecisionUnit(id: UUID(), type: .recallMoment, status: .pending,
            candidateLocalIdentifiers: ["recall"], recommendedLocalIdentifier: "recall",
            reasonCodes: [.dailyReflection], capturedDateDescription: nil, createdAt: Date())
        let result = await PhotoCurationService.curatedBatch(excluding: ["valid"],
            protectedIdentifiers: ["protected"], initialDecisions: [
                candidate("valid", reference: "kept"), candidate("missing-reference", reference: nil),
                candidate("protected"), completed, recall, candidate("kept"),
                candidate("context", reference: nil, reason: .expiredScreen),
                candidate("extra-context", reference: nil, reason: .shoppingScreen),
                candidate("other", reference: "other-kept")
            ]) { _, _, _, _ in
                XCTFail("Three valid seeds already fill the requested set")
                return .init(decisions: [], visitedIdentifiers: [], hasMore: false)
            }
        XCTAssertEqual(result.decisions.map(\.displayIdentifier), ["valid", "context", "other"])
        XCTAssertTrue(result.visitedIdentifiers.isEmpty)
    }

    func testZeroTopUpBudgetKeepsSeedsWithoutFetching() async {
        let seed = candidate("restored")
        let result = await PhotoCurationService.curatedBatch(excluding: [], protectedIdentifiers: [],
            initialDecisions: [seed], timeLimit: 0) { _, _, _, _ in
                XCTFail("No new work is allowed outside the shared time budget")
                return .init(decisions: [], visitedIdentifiers: [], hasMore: false)
            }
        XCTAssertEqual(result.decisions.map(\.id), [seed.id])
        XCTAssertTrue(result.visitedIdentifiers.isEmpty)
    }

    func testCancellationDiscardsSeedsAndLateTopUpResult() async {
        let entered = expectation(description: "Top-up waits")
        let release = CurationBatchRelease()
        let task = Task {
            await PhotoCurationService.curatedBatch(excluding: [], protectedIdentifiers: [],
                initialDecisions: [self.candidate("seed")]) { _, _, _, _ in
                    entered.fulfill()
                    await release.wait()
                    return .init(decisions: [self.candidate("late")], visitedIdentifiers: ["late"], hasMore: false)
                }
        }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        await release.finish()
        let result = await task.value
        XCTAssertTrue(result.decisions.isEmpty)
        XCTAssertTrue(result.visitedIdentifiers.isEmpty)
    }

    func testPartialAnalysisHasABoundedPassCountWithoutRetiringPhotos() async {
        var calls = 0
        let result = await PhotoCurationService.curatedBatch(excluding: [], protectedIdentifiers: [], maximumPasses: 3) { excluded, _, _, _ in
            calls += 1
            XCTAssertTrue(excluded.isEmpty)
            return .init(decisions: [], visitedIdentifiers: [], hasMore: true, hasFreshPhotos: true)
        }
        XCTAssertEqual(calls, 3)
        XCTAssertTrue(result.decisions.isEmpty)
        XCTAssertTrue(result.visitedIdentifiers.isEmpty)
    }

    func testLimitOneDoesNotSearchForUnrequestedAdditionalPhotos() async {
        var calls = 0
        let result = await PhotoCurationService.curatedBatch(excluding: [], protectedIdentifiers: [], limit: 1) { _, _, remaining, _ in
            calls += 1
            XCTAssertEqual(remaining, 1)
            return .init(decisions: [self.candidate("only-slot")], visitedIdentifiers: ["only-slot"],
                         hasMore: true, hasFreshPhotos: true)
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(result.decisions.count, 1)
    }

    func testZeroLimitDoesNotReadAnyPhotos() async {
        let result = await PhotoCurationService.curatedBatch(excluding: [], protectedIdentifiers: [], limit: 0) { _, _, _, _ in
            XCTFail("No work is needed when today's requested slots are filled")
            return .init(decisions: [], visitedIdentifiers: [], hasMore: false)
        }
        XCTAssertTrue(result.decisions.isEmpty)
    }

    func testCancellationDiscardsPartialAndLateResults() async {
        let entered = expectation(description: "Second scan waits")
        let release = CurationBatchRelease()
        var calls = 0
        let task = Task {
            await PhotoCurationService.curatedBatch(excluding: [], protectedIdentifiers: []) { _, _, _, _ in
                calls += 1
                if calls == 1 {
                    return .init(decisions: [self.candidate("first")], visitedIdentifiers: ["first"],
                                 hasMore: true, hasFreshPhotos: true)
                }
                entered.fulfill()
                await release.wait()
                return .init(decisions: [self.candidate("late")], visitedIdentifiers: ["late"], hasMore: false)
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        await release.finish()
        let result = await task.value
        XCTAssertTrue(result.decisions.isEmpty)
        XCTAssertTrue(result.visitedIdentifiers.isEmpty)
    }
}

extension CurationBatchTests {
    func testVerifiedSubsetPublishesBeforeNextSlowPassAndKeepsReferenceProtected() async {
        let secondStarted = expectation(description: "The second pass is waiting")
        let release = CurationBatchRelease()
        var snapshots: [[String]] = []
        var calls = 0
        let task = Task {
            await PhotoCurationService.curatedBatch(excluding: [], protectedIdentifiers: [],
                onUpdate: { batch in snapshots.append(batch.decisions.map(\.persistenceKey)) }
            ) { excluded, protected, _, _ in
                calls += 1
                if calls == 1 {
                    return .init(decisions: [self.candidate("first", reference: "keep-first")],
                        visitedIdentifiers: ["first"], hasMore: true, hasFreshPhotos: true)
                }
                XCTAssertTrue(excluded.contains("first"))
                XCTAssertTrue(protected.contains("keep-first"))
                XCTAssertEqual(snapshots, [["first"]], "The user must not wait for later evidence")
                secondStarted.fulfill()
                await release.wait()
                return .init(decisions: [self.variedCandidate("second", position: 2),
                                         self.variedCandidate("third", position: 3)],
                    visitedIdentifiers: ["second", "third"], hasMore: false)
            }
        }
        await fulfillment(of: [secondStarted], timeout: 2)
        await release.finish()
        let result = await task.value
        XCTAssertEqual(snapshots, [["first"], ["first", "second", "third"]])
        XCTAssertEqual(result.decisions.map(\.persistenceKey), ["first", "second", "third"])
    }

    func testStreamingDoesNotPublishSameReasonOrRetireItsKeptCopy() async {
        var published: [PhotoCurationService.ScanBatch] = []
        let result = await PhotoCurationService.curatedBatch(excluding: [], protectedIdentifiers: [],
            maximumPasses: 1, onUpdate: { published.append($0) }
        ) { _, _, _, _ in
            .init(decisions: [self.candidate("shown", reference: "keep-shown"),
                              self.candidate("deferred", reference: "keep-deferred")],
                visitedIdentifiers: ["shown", "deferred", "keep-deferred"], hasMore: false)
        }
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published.first?.decisions.map(\.persistenceKey), ["shown"])
        XCTAssertEqual(published.first?.visitedIdentifiers, ["shown"])
        XCTAssertEqual(result.visitedIdentifiers, ["shown"])
    }

    func testCancellationAfterPublishingRejectsLaterSnapshots() async {
        let secondStarted = expectation(description: "Later pass starts")
        let release = CurationBatchRelease()
        var snapshots: [[String]] = []
        var calls = 0
        let task = Task {
            await PhotoCurationService.curatedBatch(excluding: [], protectedIdentifiers: [],
                onUpdate: { snapshots.append($0.decisions.map(\.persistenceKey)) }
            ) { _, _, _, _ in
                calls += 1
                if calls == 1 {
                    return .init(decisions: [self.candidate("already-visible")],
                        visitedIdentifiers: ["already-visible"], hasMore: true, hasFreshPhotos: true)
                }
                secondStarted.fulfill()
                await release.wait()
                return .init(decisions: [self.variedCandidate("late", position: 2)],
                    visitedIdentifiers: ["late"], hasMore: false)
            }
        }
        await fulfillment(of: [secondStarted], timeout: 2)
        task.cancel()
        await release.finish()
        let result = await task.value
        XCTAssertEqual(snapshots, [["already-visible"]])
        XCTAssertTrue(result.decisions.isEmpty, "A canceled scan cannot commit its final aggregate")
    }
}

private actor CurationBatchRelease {
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false
    func wait() async {
        if finished { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func finish() {
        finished = true
        continuation?.resume()
        continuation = nil
    }
}


extension CurationBatchTests {
    func testPreviewEvidenceSurvivesAcrossPassesWithoutBecomingScanned() {
        let cache = CurationAnalysisMemory<Int, String>()
        cache.record("same-preview", for: "first-pass", revision: 1, complete: false)
        cache.retain(revisions: ["first-pass": 1, "second-pass": 1])
        cache.record("same-preview", for: "second-pass", revision: 1, complete: false)

        let captured = Date(timeIntervalSince1970: 1_000)
        let photos = ["first-pass", "second-pass"].map {
            PhotoCurationPolicy.Photo(id: $0, date: captured, width: 100, height: 100)
        }
        let evidence = cache.analyses
        let pairs = PhotoCurationPolicy.selectPairs(from: photos, limit: 1) {
            evidence[$0.id] != nil && evidence[$0.id] == evidence[$1.id]
        }
        XCTAssertEqual(pairs.count, 1, "A later pass can compare evidence from an earlier preview")
        XCTAssertTrue(cache.entries.isEmpty, "Partial evidence must never become completed scan coverage")
        XCTAssertEqual(Set(cache.failures.keys), ["first-pass", "second-pass"])
    }

    func testUnfinishedPreviewIsNotReportedAsPhotoFailureOrCompletedCoverage() {
        let cache = CurationAnalysisMemory<Int, String>()
        cache.record("preview-awaiting-ocr", for: "photo", revision: 1, complete: false, failed: false)
        XCTAssertEqual(cache.analyses["photo"], "preview-awaiting-ocr")
        XCTAssertTrue(cache.entries.isEmpty)
        XCTAssertTrue(cache.failures.isEmpty)

        cache.record("preview-with-read-failure", for: "photo", revision: 1, complete: false)
        XCTAssertEqual(cache.failures, ["photo": 1])
        cache.record("preview-awaiting-fresh-budget", for: "photo", revision: 1, complete: false, failed: false)
        XCTAssertTrue(cache.failures.isEmpty, "A deferred operation is not a persistent photo failure")
        XCTAssertTrue(cache.entries.isEmpty)
        cache.retain(revisions: ["photo": 2])
        XCTAssertTrue(cache.analyses.isEmpty, "Pending evidence is still tied to the current asset revision")
    }

    func testRecoveredOriginalPromotesPartialAnalysisWithoutDuplicateState() {
        let cache = CurationAnalysisMemory<Int, String>()
        cache.record("preview-only", for: "photo", revision: 1, complete: false)
        cache.record("preview-and-original", for: "photo", revision: 1, complete: true)
        XCTAssertEqual(cache.analyses["photo"], "preview-and-original")
        XCTAssertEqual(Set(cache.entries.keys), ["photo"])
        XCTAssertTrue(cache.partials.isEmpty)
        XCTAssertTrue(cache.failures.isEmpty)
    }

    func testChangedOrUnavailablePhotoDiscardsItsPartialEvidence() {
        let cache = CurationAnalysisMemory<Int, String>()
        cache.record("old-preview", for: "edited", revision: 1, complete: false)
        cache.record("old-preview", for: "missing", revision: 1, complete: false)
        cache.record("current-preview", for: "unchanged", revision: 2, complete: false)
        cache.retain(revisions: ["edited": 2, "unchanged": 2])
        XCTAssertEqual(cache.analyses, ["unchanged": "current-preview"])
        XCTAssertEqual(cache.failures, ["unchanged": 2])

        cache.record(nil, for: "unchanged", revision: 2, complete: false)
        XCTAssertTrue(cache.analyses.isEmpty, "A failed new read must not reuse stale preview evidence")
        XCTAssertEqual(cache.failures, ["unchanged": 2])
    }

    func testProtectingSharedComparisonKeepsItsProofButNeverNominatesItForRemoval() {
        struct ProvenPhoto {
            var photo: PhotoCurationPolicy.Photo
            let fingerprint: String
        }
        let cache = CurationAnalysisMemory<Int, ProvenPhoto>()
        let date = Date(timeIntervalSince1970: 1_000)
        for id in ["kept-reference", "first-copy", "next-copy"] {
            let photo = PhotoCurationPolicy.Photo(id: id, date: date, width: 1024, height: 1024)
            cache.record(ProvenPhoto(photo: photo, fingerprint: "verified-identical-bytes"),
                for: id, revision: 1, complete: true)
        }
        // The first copy has been nominated. Its shared keeper is now
        // protected, while the next copy remains eligible for comparison.
        cache.retain(revisions: ["kept-reference": 1, "next-copy": 1])
        cache.transformAnalyses { value in
            var current = value
            current.photo.isProtected = current.photo.id == "kept-reference"
            return current
        }
        let facts = cache.analyses
        let pairs = PhotoCurationPolicy.selectPairs(from: facts.values.map(\.photo), limit: 3) {
            facts[$0.id]?.fingerprint == facts[$1.id]?.fingerprint
        }
        XCTAssertEqual(pairs, [.init(candidateID: "next-copy", referenceID: "kept-reference")])
        XCTAssertEqual(cache.entries.count, 2, "Protection must not restart unchanged pixel analysis")
        XCTAssertFalse(facts["kept-reference"]!.photo.canRemove)
        cache.retain(revisions: ["kept-reference": 2, "next-copy": 1])
        XCTAssertNil(cache.analyses["kept-reference"], "A real image edit still invalidates the protected partner")
        cache.retain(revisions: [:])
        XCTAssertTrue(cache.analyses.isEmpty, "Revoked access still removes every cached proof")
    }

    func testCancellationOrScopeResetClearsCompletedAndPartialEvidence() {
        let cache = CurationAnalysisMemory<Int, String>()
        cache.record("complete", for: "ready", revision: 1, complete: true)
        cache.record("partial", for: "retry", revision: 1, complete: false)
        cache.reset()
        XCTAssertTrue(cache.analyses.isEmpty)
        XCTAssertTrue(cache.entries.isEmpty)
        XCTAssertTrue(cache.partials.isEmpty)
        XCTAssertTrue(cache.failures.isEmpty)
    }

    func testPreviewNetworkingRequiresPhotoAuthorization() {
        for authorization: PHAuthorizationStatus in [.authorized, .limited] {
            let options = PhotoCurationService.previewRequestOptions(authorization: authorization)
            XCTAssertEqual(options?.isNetworkAccessAllowed, true)
            XCTAssertEqual(options?.isSynchronous, false)
            XCTAssertEqual(options?.resizeMode, .fast)
            XCTAssertEqual(options?.deliveryMode, .highQualityFormat)
        }
        for authorization: PHAuthorizationStatus in [.notDetermined, .denied, .restricted] {
            XCTAssertNil(PhotoCurationService.previewRequestOptions(authorization: authorization))
        }
    }
}

extension CurationBatchTests {
    func testMetadataDiagnosticsSeparateAgeBoundariesAndOverlappingExclusions() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = Date(timeIntervalSince1970: 1_800_000_000)
        func facts(_ days: Int, screenshot: Bool = false, favorite: Bool = false,
                   hidden: Bool = false, live: Bool = false) -> PhotoCurationService.ScanCatalogFacts {
            .init(capturedAt: calendar.date(byAdding: .day, value: -days, to: today), width: 100, height: 100,
                isScreenshot: screenshot, isFavorite: favorite, isExcluded: hidden || live,
                isHidden: hidden, isLivePhoto: live)
        }
        let values = [facts(6), facts(7, favorite: true), facts(6, screenshot: true),
            facts(7, screenshot: true), facts(29, screenshot: true), facts(30, screenshot: true),
            facts(31, hidden: true, live: true), facts(-1),
            PhotoCurationService.ScanCatalogFacts(capturedAt: nil, width: 100, height: 100)]
        let counts = PhotoCurationService.metadataDiagnosticCounts(values, now: today, calendar: calendar)
        XCTAssertEqual(counts["total"], 9)
        XCTAssertEqual(counts["favorite"], 1)
        XCTAssertEqual(counts["excludedHidden"], 1)
        XCTAssertEqual(counts["excludedLive"], 1)
        XCTAssertEqual(counts["metadataExcluded"], 1, "Overlapping exclusion flags must not double the excluded-photo count")
        XCTAssertEqual(counts["ordinaryUnder7Days"], 1)
        XCTAssertEqual(counts["ordinary7PlusDays"], 2)
        XCTAssertEqual(counts["screenshotUnder7Days"], 1)
        XCTAssertEqual(counts["screenshot7To29Days"], 2)
        XCTAssertEqual(counts["screenshot30PlusDays"], 1)
        XCTAssertEqual(counts["futureCaptureDate"], 1)
        XCTAssertEqual(counts["missingCaptureDate"], 1)
    }

    func testDeferredPreviewReceivesTurnWhileFreshLibraryNeverEnds() {
        var schedule = CurationPreviewRecoverySchedule()
        schedule.register(window: ["cloud-first", "local-peer"], missing: ["cloud-first"])
        XCTAssertNil(schedule.next(eligible: ["cloud-first"], localWorkAvailable: true))
        schedule.noteLocalProgress()
        XCTAssertNil(schedule.next(eligible: ["cloud-first"], localWorkAvailable: true))
        schedule.noteLocalProgress()
        let turn = schedule.next(eligible: ["cloud-first"], localWorkAvailable: true)
        XCTAssertEqual(turn?.identifier, "cloud-first")
        XCTAssertEqual(turn?.window, ["cloud-first", "local-peer"], "Recovery retains the comparison peer")
    }

    func testRecoveryReturnsToLocalWorkAndRotatesWindowsWithoutRepeatedFailure() throws {
        var schedule = CurationPreviewRecoverySchedule()
        schedule.register(window: ["cloud-a", "cloud-b", "reference-a"], missing: ["cloud-a", "cloud-b"])
        schedule.register(window: ["cloud-c", "reference-c"], missing: ["cloud-c"])
        let eligible: Set<String> = ["cloud-a", "cloud-b", "cloud-c"]
        var recovered: [String] = []
        for expected in ["cloud-a", "cloud-c", "cloud-b"] {
            XCTAssertNil(schedule.next(eligible: eligible, localWorkAvailable: true))
            schedule.noteLocalProgress(); schedule.noteLocalProgress()
            let turn = try XCTUnwrap(schedule.next(eligible: eligible, localWorkAvailable: true))
            XCTAssertEqual(turn.identifier, expected)
            recovered.append(turn.identifier)
            schedule.finished(turn)
            schedule.register(window: turn.window, missing: [turn.identifier])
        }
        XCTAssertEqual(recovered.count, Set(recovered).count)
        XCTAssertNil(schedule.next(eligible: eligible, localWorkAvailable: false),
                     "One failed image must not consume every following recovery slot")
    }

    func testCancelledRecoveryTurnRemainsPendingButRevokedAssetIsRemoved() throws {
        var schedule = CurationPreviewRecoverySchedule()
        schedule.register(window: ["pending", "reference"], missing: ["pending"])
        let before = try XCTUnwrap(schedule.next(eligible: ["pending"], localWorkAvailable: false))
        // No finished call when the awaiting task is cancelled.
        XCTAssertEqual(schedule.next(eligible: ["pending"], localWorkAvailable: false), before)
        XCTAssertNil(schedule.next(eligible: [], localWorkAvailable: false))
        XCTAssertNil(schedule.next(eligible: ["pending"], localWorkAvailable: false))
    }

    func testMultipleMissingCallbacksRegisterEachPreviewOnlyOnce() throws {
        var schedule = CurationPreviewRecoverySchedule()
        for _ in 0..<100 { schedule.register(window: ["one", "two"], missing: ["one", "two"]) }
        let first = try XCTUnwrap(schedule.next(eligible: ["one", "two"], localWorkAvailable: false))
        schedule.finished(first)
        let second = try XCTUnwrap(schedule.next(eligible: ["one", "two"], localWorkAvailable: false))
        XCTAssertNotEqual(first.identifier, second.identifier)
        schedule.finished(second)
        XCTAssertNil(schedule.next(eligible: ["one", "two"], localWorkAvailable: false))
    }

    func testIncrementalCatalogBoundsColdMetadataAndPreservesUnseenCoverage() {
        var cursor = PhotoCurationService.CatalogCursor(count: 22_576)
        var reads = 0
        let first = cursor.nextPage { index in
            reads += 1
            return .init(identifier: "asset-\(index)", assetIndex: index)
        }
        XCTAssertEqual(reads, 256)
        XCTAssertEqual(first.count, 256)
        XCTAssertEqual(Set(first.map(\.assetIndex)).count, 256)
        XCTAssertTrue(cursor.hasMore, "A bounded first page cannot claim the rest of the library has no candidates")
        XCTAssertEqual(cursor.totalCount, 22_576)
        XCTAssertTrue(first.contains { $0.assetIndex == 22_575 })
        XCTAssertTrue(first.contains { $0.assetIndex == 0 })
    }

    func testIncrementalCatalogEventuallyCoversEveryIndexWithoutRepeats() {
        var cursor = PhotoCurationService.CatalogCursor(count: 517)
        var indices: [Int] = []
        while cursor.hasMore {
            indices += cursor.nextPage(limit: 31) { .init(identifier: "asset-\($0)", assetIndex: $0) }.map(\.assetIndex)
        }
        XCTAssertEqual(indices.sorted(), Array(0..<517))
        XCTAssertEqual(cursor.readCount, 517)
        XCTAssertTrue(cursor.nextPage { .init(identifier: "unexpected", assetIndex: $0) }.isEmpty)
    }

    func testDiscardedCatalogPageDoesNotConsumeOriginalCursor() {
        var original = PhotoCurationService.CatalogCursor(count: 130)
        var interrupted = original
        _ = interrupted.nextPage(limit: 7) { .init(identifier: "asset-\($0)", assetIndex: $0) }
        XCTAssertEqual(original.readCount, 0, "The caller can discard cancelled or permission-invalidated metadata safely")
        let retried = original.nextPage(limit: 7) { .init(identifier: "asset-\($0)", assetIndex: $0) }
        XCTAssertEqual(retried.map(\.assetIndex), [129, 128, 127, 126, 125, 124, 123])
    }

    func testInitialWindowIncludesDifferentEvidenceSourcesBeforeFiveLocalReads() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let catalog = [catalogEntry(0, date: now), catalogEntry(1, date: now),
            catalogEntry(2, date: now.addingTimeInterval(-100)),
            catalogEntry(3, date: now.addingTimeInterval(-115)),
            catalogEntry(4, date: now.addingTimeInterval(-10 * 86_400), screenshot: true)]
        let window = PhotoCurationService.scanWindow(in: catalog, excluding: [], deferred: [], reviewDates: [:], now: now)
        XCTAssertEqual(Set(window.entries.prefix(5).map(\.assetIndex)), [0, 1, 2, 3, 4])
        XCTAssertEqual(window.entries.last?.assetIndex, 4)
        // No pixel/OCR evidence is fabricated by this metadata-only nomination.
        XCTAssertEqual(window.remaining.count, 5)
    }

    func testFastLocalNominationCannotRequestNetworkOrReplaceAnalysisQuality() {
        let quick = PhotoCurationService.previewRequestOptions(authorization: .limited, nominationOnly: true)
        XCTAssertEqual(quick?.deliveryMode, .opportunistic)
        XCTAssertEqual(quick?.resizeMode, .fast)
        XCTAssertEqual(quick?.isNetworkAccessAllowed, false)
        let full = PhotoCurationService.previewRequestOptions(authorization: .limited)
        XCTAssertEqual(full?.deliveryMode, .highQualityFormat)
        XCTAssertEqual(full?.resizeMode, .fast)
        XCTAssertNil(PhotoCurationService.previewRequestOptions(authorization: .denied, nominationOnly: true))
        XCTAssertFalse(PhotoCurationService.usableNominationSize(width: 32, height: 32))
        XCTAssertFalse(PhotoCurationService.usableNominationSize(width: 47, height: 384))
        XCTAssertFalse(PhotoCurationService.usableNominationSize(width: 63, height: 63))
        XCTAssertTrue(PhotoCurationService.usableNominationSize(width: 256, height: 128))
        XCTAssertTrue(PhotoCurationService.usableNominationSize(width: 288, height: 384))
    }

    func testSynchronousFastPhotoCallbackIsNotLostBeforeRequestIDReturns() {
        var cancelled: [PHImageRequestID] = []
        let value: String? = PhotoCurationService.boundedPhotoRead(timeout: 0.25,
            cancel: { cancelled.append($0) }) { complete in
                complete("cached-local-preview")
                return 71
            }
        XCTAssertEqual(value, "cached-local-preview")
        XCTAssertTrue(cancelled.isEmpty)
    }

    func testSmallActualPhotoCanNominateWhileInvalidPlaceholderWaits() {
        XCTAssertEqual(PhotoCurationService.nominationCallbackAction(width: 80, height: 60, degraded: true), .accept)
        XCTAssertEqual(PhotoCurationService.nominationCallbackAction(width: 0, height: 0, degraded: true), .awaitLarger)
        XCTAssertEqual(PhotoCurationService.nominationCallbackAction(width: 1024, height: 768, degraded: false), .accept)
        XCTAssertEqual(PhotoCurationService.nominationCallbackAction(width: 384, height: 256, degraded: true), .accept)
        XCTAssertEqual(PhotoCurationService.nominationCallbackAction(width: 32, height: 32, degraded: false), .unavailable)
        XCTAssertEqual(PhotoCurationService.nominationCallbackAction(width: 1024, height: 768, degraded: false, failed: true), .unavailable)
    }

    func testSmallThenLargeSynchronousCallbacksDoNotCancelLargerResult() {
        var cancellations = 0
        let result: String? = PhotoCurationService.boundedPhotoRead(timeout: 0.25, cancel: { _ in cancellations += 1 }) { complete in
            for (width, height, degraded) in [(32, 32, true), (1024, 768, false)] {
                switch PhotoCurationService.nominationCallbackAction(width: width, height: height, degraded: degraded) {
                case .accept: complete("readable-local-photo")
                case .unavailable: complete(nil)
                case .awaitLarger: break
                }
            }
            return 81
        }
        XCTAssertEqual(result, "readable-local-photo")
        XCTAssertEqual(cancellations, 0)
    }

    func testProofCacheSurvivesNewInstanceButRejectsChangedRevisionAndVersion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let cache = CurationDiskProofCache<String>(directory: directory, version: 1)
        cache.store("verified-proof", for: "private-photo-id", revision: "current-modification-and-dimensions")
        let restarted = CurationDiskProofCache<String>(directory: directory, version: 1)
        XCTAssertEqual(restarted.value(for: "private-photo-id", revision: "current-modification-and-dimensions"), "verified-proof")
        XCTAssertNil(restarted.value(for: "private-photo-id", revision: "edited-or-newly-favorite"))
        XCTAssertNil(restarted.value(for: "different-photo", revision: "current-modification-and-dimensions"))
        XCTAssertNil(CurationDiskProofCache<String>(directory: directory, version: 2)
            .value(for: "private-photo-id", revision: "current-modification-and-dimensions"))
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertFalse(files[0].lastPathComponent.contains("private-photo-id"))
    }

    func testProofCacheIsBoundedAndCorruptionFallsBackToLiveAnalysis() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let cache = CurationDiskProofCache<String>(directory: directory, version: 1, capacity: 2)
        for index in 0..<5 { cache.store("proof", for: "photo-\(index)", revision: "revision") }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 2)
        for file in files { try Data("incomplete file".utf8).write(to: file) }
        for index in 0..<5 { XCTAssertNil(cache.value(for: "photo-\(index)", revision: "revision")) }
        cache.store("must-not-persist", for: "missing-revision", revision: "")
        XCTAssertNil(cache.value(for: "missing-revision", revision: ""))
    }
}

/// Calendar rollover changes the recommendations, never the user's saved data or
/// photo authorization. These tests use a fake clock and never touch PhotoKit.
@MainActor
final class DailyRecommendationHomeTests: XCTestCase {
    private final class Clock {
        var date: Date
        init(_ date: Date) { self.date = date }
    }

    private struct Context {
        let vm: HomeViewModel
        let store: LocalActivityStore
        let defaults: UserDefaults
        let calendar: Calendar
        let clock: Clock
        let service: DailyRecommendationService
        let subscriptions: SubscriptionStore
    }

    private func context() -> Context {
        let name = "daily-recommendation-home-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let clock = Clock(calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 12))!)
        let store = LocalActivityStore(defaults: defaults, calendar: calendar, now: { clock.date })
        let subscriptions = SubscriptionStore(defaults: defaults, enabled: false)
        let service = DailyRecommendationService()
        let vm = HomeViewModel(featureAccess: .init(plan: .free, isSimilarPhotoCleanupEnabled: false),
            subscriptions: subscriptions, curationService: service, activity: store,
            authorizationStatus: { .limited }, observesPhotoLibrary: false, selectionDefaults: defaults)
        return Context(vm: vm, store: store, defaults: defaults, calendar: calendar,
                       clock: clock, service: service, subscriptions: subscriptions)
    }

    private func unit(_ id: String, reference: String? = nil, reason: CurationReasonCode = .exactDuplicate) -> DecisionUnit {
        DecisionUnit(id: UUID(), type: .cleanupSingle, status: .pending,
            candidateLocalIdentifiers: [id], recommendedLocalIdentifier: id,
            reasonCodes: [reason], capturedDateDescription: nil, createdAt: Date(),
            comparisonLocalIdentifier: reason == .expiredScreen ? nil : reference ?? "reference-\(id)")
    }

    private func seed(_ photos: [DecisionUnit], in context: Context) async {
        context.store.beginDailySession(photoIdentifiers: photos.compactMap(\.displayIdentifier),
            comparisonReferences: Dictionary(uniqueKeysWithValues: photos.map { ($0.persistenceKey, $0.comparisonLocalIdentifier!) }),
            curationReasons: Dictionary(uniqueKeysWithValues: photos.map { ($0.persistenceKey, .exactDuplicate) }))
        await context.service.setRestored(photos)
    }

    private func advanceDay(_ context: Context) {
        context.clock.date = context.calendar.date(byAdding: .day, value: 1, to: context.clock.date)!
    }

    private func renderHomePreviews(_ vm: HomeViewModel, identifiers: [String]? = nil) {
        for identifier in identifiers ?? vm.photoIdentifiers {
            let request = UUID()
            vm.updateHomePhotoPreview(identifier: identifier, generation: vm.photoPreviewGeneration,
                                      requestID: request, state: .loading)
            vm.updateHomePhotoPreview(identifier: identifier, generation: vm.photoPreviewGeneration,
                                      requestID: request, state: .ready)
        }
    }

    func testSelectedPreviewMustRenderAndRetryBeforeCleanupCanBegin() async throws {
        let context = context()
        let photo = unit("preview-retry")
        await seed([photo], in: context)
        await context.vm.onAppear()
        context.vm.toggleCleanupSelection(photo)
        let selectionKey = UserScopedStorage.key("recoco_cleanup_selection_v1")
        let originalSelection = context.defaults.stringArray(forKey: selectionKey)
        let generation = context.vm.photoPreviewGeneration
        let failedRequest = UUID()

        XCTAssertFalse(context.vm.selectedPhotosReadyForCleanup)
        XCTAssertNil(context.vm.beginSelectedCleanup(), "Analysis success alone cannot authorize an unseen picture")
        context.vm.updateHomePhotoPreview(identifier: photo.persistenceKey, generation: generation,
                                          requestID: failedRequest, state: .loading)
        XCTAssertNil(context.vm.beginSelectedCleanup(), "A loading preview remains unavailable")
        context.vm.updateHomePhotoPreview(identifier: photo.persistenceKey, generation: generation,
                                          requestID: failedRequest, state: .failed)
        XCTAssertNil(context.vm.beginSelectedCleanup(), "A failed preview keeps the whole selected batch blocked")
        XCTAssertFalse(context.vm.isCommittingSelection)
        XCTAssertEqual(context.vm.selectedCleanupCount, 1)
        XCTAssertEqual(context.defaults.stringArray(forKey: selectionKey), originalSelection)
        XCTAssertTrue(context.store.dailySessionProgress().processedDecisionKeys.isEmpty)
        XCTAssertEqual(context.store.weeklySnapshot().deletedPhotoCount, 0)

        renderHomePreviews(context.vm)
        XCTAssertTrue(context.vm.selectedPhotosReadyForCleanup)
        XCTAssertEqual(context.vm.beginSelectedCleanup()?.map(\.persistenceKey), [photo.persistenceKey])
        context.vm.endSelectedCleanup()
        XCTAssertEqual(context.vm.selectedCleanupCount, 1, "System cancellation still preserves the check")
        XCTAssertEqual(context.store.weeklySnapshot().deletedPhotoCount, 0)
    }

    func testEverySelectedPhotoNeedsItsOwnPreviewRegardlessOfCurrentCarouselPage() async {
        let context = context()
        let photos = (1...3).map { unit("preview-swipe-\($0)") }
        await seed(photos, in: context)
        await context.vm.onAppear()
        context.vm.toggleCleanupSelection(photos[0])
        context.vm.toggleCleanupSelection(photos[1])
        renderHomePreviews(context.vm, identifiers: [photos[0].persistenceKey, photos[2].persistenceKey])
        let failedRequest = UUID()
        context.vm.updateHomePhotoPreview(identifier: photos[1].persistenceKey, generation: context.vm.photoPreviewGeneration,
                                          requestID: failedRequest, state: .loading)
        context.vm.updateHomePhotoPreview(identifier: photos[1].persistenceKey, generation: context.vm.photoPreviewGeneration,
                                          requestID: failedRequest, state: .failed)

        for index in [2, 0, 1, 2] {
            context.vm.browsePhoto(at: index)
            XCTAssertNil(context.vm.beginSelectedCleanup(), "Swiping to a readable photo cannot authorize another failed selection")
            XCTAssertEqual(context.vm.selectedCleanupCount, 2)
        }
        context.vm.toggleCleanupSelection(photos[1])
        XCTAssertTrue(context.vm.selectedPhotosReadyForCleanup, "The user can remove an unreadable photo from this batch")
        XCTAssertEqual(context.vm.beginSelectedCleanup()?.map(\.persistenceKey), [photos[0].persistenceKey])
        context.vm.endSelectedCleanup()
        XCTAssertEqual(context.store.weeklySnapshot().deletedPhotoCount, 0)
    }

    func testUnrelatedPhotoChangeKeepsVisiblePreviewButVisibleEditRevokesReadiness() async {
        let context = context()
        let photo = unit("visible-change-scope")
        await seed([photo], in: context)
        await context.vm.onAppear()
        context.vm.toggleCleanupSelection(photo)
        renderHomePreviews(context.vm)
        let generation = context.vm.photoPreviewGeneration
        context.vm.photoLibraryDidChange(affectedIdentifiers: ["unrelated-downloaded-photo"])
        XCTAssertEqual(context.vm.photoPreviewGeneration, generation)
        XCTAssertTrue(context.vm.isPhotoPreviewReady(photo.persistenceKey))
        XCTAssertEqual(context.vm.selectedCleanupCount, 1)

        context.vm.photoLibraryDidChange(affectedIdentifiers: [photo.persistenceKey])
        XCTAssertNotEqual(context.vm.photoPreviewGeneration, generation)
        XCTAssertFalse(context.vm.isPhotoPreviewReady(photo.persistenceKey))
        XCTAssertNil(context.vm.beginSelectedCleanup(), "A changed visible image must render again before deletion")
        XCTAssertEqual(context.vm.selectedCleanupCount, 1)
        XCTAssertEqual(context.store.weeklySnapshot().deletedPhotoCount, 0)
    }

    func testPreviewRetryRejectsOldAndUnstartedCallbacks() async {
        let context = context()
        let photo = unit("preview-stale-request")
        await seed([photo], in: context)
        await context.vm.onAppear()
        context.vm.toggleCleanupSelection(photo)
        let generation = context.vm.photoPreviewGeneration
        let first = UUID(), retry = UUID()
        context.vm.updateHomePhotoPreview(identifier: photo.persistenceKey, generation: generation,
                                          requestID: first, state: .ready)
        XCTAssertFalse(context.vm.isPhotoPreviewReady(photo.persistenceKey), "A completion must belong to a registered request")
        context.vm.updateHomePhotoPreview(identifier: photo.persistenceKey, generation: generation,
                                          requestID: first, state: .loading)
        context.vm.updateHomePhotoPreview(identifier: photo.persistenceKey, generation: generation,
                                          requestID: retry, state: .loading)
        context.vm.updateHomePhotoPreview(identifier: photo.persistenceKey, generation: generation,
                                          requestID: first, state: .ready)
        XCTAssertNil(context.vm.beginSelectedCleanup(), "A delayed response cannot satisfy the replacement request")
        context.vm.updateHomePhotoPreview(identifier: photo.persistenceKey, generation: generation,
                                          requestID: retry, state: .failed)
        context.vm.updateHomePhotoPreview(identifier: photo.persistenceKey, generation: generation,
                                          requestID: retry, state: .ready)
        XCTAssertFalse(context.vm.isPhotoPreviewReady(photo.persistenceKey), "A finished failure cannot be changed by a late callback")

        renderHomePreviews(context.vm)
        context.vm.updateHomePhotoPreview(identifier: photo.persistenceKey, generation: generation,
                                          requestID: first, state: .failed)
        XCTAssertTrue(context.vm.isPhotoPreviewReady(photo.persistenceKey), "An old failure cannot erase a successful retry")
    }

    func testRevalidationInvalidatesOldPreviewWithoutChangingSelectionOrRecords() async throws {
        let context = context()
        let photo = unit("preview-revalidate")
        try SavedRecordStore(defaults: context.defaults).save(text: "기존 기록 유지",
            photoLocalIdentifier: "kept-memory", capturedDateDescription: nil)
        let recordsKey = UserScopedStorage.key(SavedRecordStore.storageKey)
        let records = context.defaults.data(forKey: recordsKey)
        await seed([photo], in: context)
        await context.vm.onAppear()
        context.vm.toggleCleanupSelection(photo)
        renderHomePreviews(context.vm)
        let priorGeneration = context.vm.photoPreviewGeneration

        await context.vm.onAppear()

        XCTAssertNotEqual(context.vm.photoPreviewGeneration, priorGeneration)
        XCTAssertEqual(context.vm.selectedCleanupCount, 1)
        XCTAssertNil(context.vm.beginSelectedCleanup(), "Fresh validation cannot reuse a former view's display readiness")
        let oldViewRequest = UUID()
        context.vm.updateHomePhotoPreview(identifier: photo.persistenceKey, generation: priorGeneration,
                                          requestID: oldViewRequest, state: .loading)
        context.vm.updateHomePhotoPreview(identifier: photo.persistenceKey, generation: priorGeneration,
                                          requestID: oldViewRequest, state: .ready)
        XCTAssertNil(context.vm.beginSelectedCleanup(), "The outgoing view cannot unlock the rebuilt carousel")
        XCTAssertEqual(context.defaults.data(forKey: recordsKey), records)
        renderHomePreviews(context.vm)
        XCTAssertNotNil(context.vm.beginSelectedCleanup())
        context.vm.endSelectedCleanup()
    }

    func testRelaunchRestoresChecksButRequiresNewPreviewAndIgnoresDeletedPhotoCallbacks() async throws {
        let context = context()
        let photos = [unit("preview-relaunch-1"), unit("preview-relaunch-2")]
        await seed(photos, in: context)
        await context.vm.onAppear()
        context.vm.toggleCleanupSelection(photos[0])
        renderHomePreviews(context.vm)
        let oldGeneration = context.vm.photoPreviewGeneration
        let reopened = HomeViewModel(featureAccess: .init(plan: .free, isSimilarPhotoCleanupEnabled: false),
            subscriptions: context.subscriptions, curationService: context.service, activity: context.store,
            authorizationStatus: { .limited }, observesPhotoLibrary: false, selectionDefaults: context.defaults)
        await reopened.onAppear()
        XCTAssertEqual(reopened.selectedCleanupCount, 1)
        XCTAssertNil(reopened.beginSelectedCleanup(), "Preview readiness is never persisted as permission to delete")
        let obsolete = UUID()
        reopened.updateHomePhotoPreview(identifier: photos[0].persistenceKey, generation: oldGeneration,
                                        requestID: obsolete, state: .loading)
        reopened.updateHomePhotoPreview(identifier: photos[0].persistenceKey, generation: oldGeneration,
                                        requestID: obsolete, state: .ready)
        XCTAssertNil(reopened.beginSelectedCleanup())
        renderHomePreviews(reopened)
        let selected = try XCTUnwrap(reopened.beginSelectedCleanup())
        reopened.completeSelectedCleanup(selected)
        reopened.endSelectedCleanup()
        let removedCallback = UUID()
        reopened.updateHomePhotoPreview(identifier: photos[0].persistenceKey, generation: reopened.photoPreviewGeneration,
                                        requestID: removedCallback, state: .loading)
        reopened.updateHomePhotoPreview(identifier: photos[0].persistenceKey, generation: reopened.photoPreviewGeneration,
                                        requestID: removedCallback, state: .ready)
        XCTAssertFalse(reopened.isPhotoPreviewReady(photos[0].persistenceKey))
        XCTAssertTrue(reopened.isPhotoPreviewReady(photos[1].persistenceKey), "Removing a photo preserves another currently rendered image")
        XCTAssertEqual(context.store.weeklySnapshot().deletedPhotoCount, 1)
    }

    func testSameDayRelaunchKeepsPendingPhotosAndSelectionWithoutChangingSavedRecords() async throws {
        let context = context()
        let photos = (1...3).map { unit("same-day-\($0)") }
        let recordStore = SavedRecordStore(defaults: context.defaults)
        try recordStore.save(text: "기존 기록", photoLocalIdentifier: "preserved-record-photo", capturedDateDescription: nil)
        let recordKey = UserScopedStorage.key(SavedRecordStore.storageKey)
        let recordsBefore = context.defaults.data(forKey: recordKey)
        await seed(photos, in: context)
        await context.vm.onAppear()
        context.vm.toggleCleanupSelection(photos[1])
        context.clock.date = context.clock.date.addingTimeInterval(3_600)
        let reopenedStore = LocalActivityStore(defaults: context.defaults, calendar: context.calendar, now: { context.clock.date })
        let reopened = HomeViewModel(featureAccess: .init(plan: .free, isSimilarPhotoCleanupEnabled: false),
            subscriptions: context.subscriptions, curationService: context.service, activity: reopenedStore,
            authorizationStatus: { .limited }, observesPhotoLibrary: false, selectionDefaults: context.defaults)

        await reopened.onAppear()

        XCTAssertEqual(reopened.photoIdentifiers, photos.map(\.persistenceKey))
        XCTAssertEqual(reopened.selectedCleanupUnits.map(\.persistenceKey), [photos[1].persistenceKey])
        XCTAssertEqual(reopened.permissionStatus, .limited)
        XCTAssertEqual(context.defaults.data(forKey: recordKey), recordsBefore)
        let fetches = await context.service.fetchCalls
        XCTAssertTrue(fetches.isEmpty, "Reopening the same daily set must not request unrelated replacements")
    }

    func testSameDayReadFailurePreservesSelectionUntilThePhotoRecovers() async {
        let context = context()
        let photos = (1...3).map { unit("read-recovery-\($0)") }
        await seed(photos, in: context)
        await context.vm.onAppear()
        context.vm.toggleCleanupSelection(photos[1])
        await context.service.setRestored([photos[0], photos[2]], failureCount: 1)

        await context.vm.onAppear()

        XCTAssertTrue(context.vm.selectedCleanupKeys.contains(photos[1].persistenceKey),
                      "A temporary read failure must not erase a same-day selection")
        XCTAssertEqual(context.vm.selectedCleanupCount, 0, "An unreadable photo cannot be deleted until revalidated")
        await context.service.setRestored(photos)
        await context.vm.onAppear()
        XCTAssertEqual(context.vm.selectedCleanupUnits.map(\.persistenceKey), [photos[1].persistenceKey])
    }

    func testNextDayCarriesOnlyCheckedPhotosAndPreservesRecords() async throws {
        let context = context()
        let yesterday = (1...3).map { unit("yesterday-\($0)") }
        let today = (1...3).map { unit("today-\($0)", reason: [.exactDuplicate, .visuallySimilar, .expiredScreen][$0 - 1]) }
        let records = SavedRecordStore(defaults: context.defaults)
        try records.save(text: "그대로 남길 기록", photoLocalIdentifier: "older-record-photo", capturedDateDescription: nil)
        let recordKey = UserScopedStorage.key(SavedRecordStore.storageKey)
        let before = context.defaults.data(forKey: recordKey)
        await seed(yesterday, in: context)
        await context.vm.onAppear()
        context.vm.toggleCleanupSelection(yesterday[0])
        advanceDay(context)
        await context.service.setBatch(today)

        await context.vm.onAppear()

        XCTAssertEqual(context.vm.photoIdentifiers, [yesterday[0].persistenceKey])
        XCTAssertEqual(context.vm.selectedCleanupCount, 1, "An explicit unfinished choice survives midnight")
        XCTAssertEqual(context.vm.selectedCleanupKeys, [yesterday[0].persistenceKey], "Old checkboxes must never authorize a different photo")
        XCTAssertEqual(context.store.dailySessionProgress().curatedPhotoIdentifiers, [yesterday[0].persistenceKey])
        XCTAssertEqual(context.store.weeklySnapshot().deletedPhotoCount, 0, "Replacing recommendations does not mean deleting photos")
        XCTAssertEqual(context.defaults.data(forKey: recordKey), before)
        XCTAssertEqual(context.vm.permissionStatus, .limited)
        let restored = await context.service.restoreCalls
        XCTAssertEqual(restored, [yesterday.map(\.persistenceKey), [yesterday[0].persistenceKey]])
    }

    func testColdNewDayUsesOnlyUnseenRevalidatedReserveBeforeAnyLibraryScan() async {
        let context = context()
        let yesterday = (1...3).map { unit("yesterday-\($0)") }
        await seed(yesterday, in: context)
        let reserve = [unit("fresh-one"), unit("fresh-two", reason: .visuallySimilar), unit("fresh-three", reason: .expiredScreen)]
        context.store.savePreparedRecommendations(reserve, excluding: [])
        advanceDay(context)
        await context.service.setRestored(reserve)
        await context.vm.onAppear()
        XCTAssertEqual(context.vm.photoIdentifiers, reserve.map(\.persistenceKey))
        XCTAssertEqual(context.vm.selectedCleanupCount, 0)
        let fetches = await context.service.fetchCalls
        XCTAssertTrue(fetches.isEmpty, "A prepared batch must not wait for scanning the whole library")
        XCTAssertNil(context.store.preparedRecommendations())
        XCTAssertEqual(context.store.recommendationExcludedIdentifiers(), Set((yesterday + reserve).map(\.persistenceKey)))
        XCTAssertEqual(context.store.weeklySnapshot().deletedPhotoCount, 0)
    }

    func testColdMidnightKeepsCheckedPhotoAndFillsOnlyOtherSlotsFromUnseenReserve() async {
        let context = context()
        let yesterday = (1...3).map { unit("yesterday-\($0)") }
        await seed(yesterday, in: context)
        await context.vm.onAppear()
        context.vm.toggleCleanupSelection(yesterday[0])
        let prepared = [unit("future-copy"), unit("future-similar", reason: .visuallySimilar),
                        unit("future-context", reason: .expiredScreen)]
        context.store.savePreparedRecommendations(prepared, excluding: [])
        advanceDay(context)
        await context.service.setRestored(yesterday + prepared)
        let reopened = HomeViewModel(featureAccess: .init(plan: .free, isSimilarPhotoCleanupEnabled: false),
            subscriptions: context.subscriptions, curationService: context.service, activity: context.store,
            authorizationStatus: { .limited }, observesPhotoLibrary: false, selectionDefaults: context.defaults)
        await reopened.onAppear()
        XCTAssertEqual(reopened.photoIdentifiers, [yesterday[0].persistenceKey, "future-similar", "future-context"])
        XCTAssertEqual(reopened.selectedCleanupKeys, [yesterday[0].persistenceKey])
        XCTAssertEqual(context.store.preparedRecommendations()?.photoIdentifiers, ["future-copy"])
        let fetches = await context.service.fetchCalls
        XCTAssertTrue(fetches.isEmpty)
        XCTAssertEqual(context.store.weeklySnapshot().deletedPhotoCount, 0)
    }

    func testPreparedVerifiedThreeDoNotWaitForAnUncachedFourthPhoto() async {
        let context = context()
        let ready = [unit("copy"), unit("similar", reason: .visuallySimilar), unit("context", reason: .expiredScreen)]
        context.store.savePreparedRecommendations(ready + [unit("slow-fourth")], excluding: [])
        await context.service.setCachedRestored(.init(decisions: ready, retryableFailureCount: 1,
            hasPendingAnalysis: true, retryableIdentifiers: ["slow-fourth"]))
        await context.service.setBeforeRestore { XCTFail("The optional fourth photo must not delay the ready three") }
        await context.vm.onAppear()
        XCTAssertEqual(context.vm.photoIdentifiers, ready.map(\.persistenceKey))
        XCTAssertEqual(context.store.preparedRecommendations()?.photoIdentifiers, ["slow-fourth"])
        let fetches = await context.service.fetchCalls
        XCTAssertTrue(fetches.isEmpty)
        XCTAssertEqual(context.vm.selectedCleanupCount, 0)
        XCTAssertEqual(context.store.weeklySnapshot().deletedPhotoCount, 0)
    }

    func testPreparedCachedSubsetIsVisibleBeforeFreshTopUpAndKeepsUnreadableReserve() async {
        let context = context()
        let ready = unit("ready-copy")
        let later = [unit("later-similar", reason: .visuallySimilar), unit("later-context", reason: .expiredScreen)]
        context.store.savePreparedRecommendations([ready, unit("temporarily-unreadable")], excluding: [])
        await context.service.setCachedRestored(.init(decisions: [ready], retryableFailureCount: 1,
            hasPendingAnalysis: true, retryableIdentifiers: ["temporarily-unreadable"]))
        await context.service.setBeforeRestore { XCTFail("A verified subset must be presented without a live restore wait") }
        await context.service.setBatch(later)
        await context.service.setBeforeFetch {
            await MainActor.run { XCTAssertEqual(context.vm.photoIdentifiers, [ready.persistenceKey]) }
        }
        await context.vm.onAppear()
        XCTAssertEqual(context.vm.photoIdentifiers, ([ready] + later).map(\.persistenceKey))
        XCTAssertEqual(context.store.preparedRecommendations()?.photoIdentifiers, ["temporarily-unreadable"])
        XCTAssertFalse(context.store.recommendationExcludedIdentifiers().contains("temporarily-unreadable"))
        XCTAssertEqual(context.vm.selectedCleanupCount, 0)
    }

    func testInvalidPreparedPhotosNeverAppearAndRealScanCanReplaceThem() async {
        let context = context()
        context.store.savePreparedRecommendations([unit("revoked-reserve")], excluding: [])
        await context.service.setRestored([])
        await context.service.setBatch([unit("valid-new")])
        await context.vm.onAppear()
        XCTAssertEqual(context.vm.photoIdentifiers, ["valid-new"])
        XCTAssertFalse(context.store.recommendationExcludedIdentifiers().contains("revoked-reserve"))
        XCTAssertEqual(context.store.preparedRecommendations()?.photoIdentifiers, ["revoked-reserve"],
                       "A temporary unreadable asset is not silently removed from local preparation")
    }

    func testReservePrefersThreeDistinctReasonsBeforeSameTypePairs() async {
        let context = context()
        let prepared = [unit("copy-a"), unit("copy-b"), unit("copy-c"),
                        unit("similar", reason: .visuallySimilar), unit("context-a", reason: .expiredScreen),
                        unit("context-b", reason: .expiredScreen)]
        context.store.savePreparedRecommendations(prepared, excluding: [])
        await context.service.setRestored(prepared)
        await context.vm.onAppear()
        XCTAssertEqual(context.vm.photoIdentifiers, ["copy-a", "similar", "context-a"])
        XCTAssertEqual(context.store.preparedRecommendations()?.photoIdentifiers, ["copy-b", "copy-c", "context-b"])
        XCTAssertFalse(context.store.recommendationExcludedIdentifiers().contains("context-b"))
        let fetches = await context.service.fetchCalls
        XCTAssertTrue(fetches.isEmpty)
    }

    func testPreparingNextBatchDoesNotMutateVisibleQueueSelectionOrCooldown() async {
        let context = context()
        let shown = (1...3).map { unit("shown-\($0)") }
        await seed(shown, in: context)
        await context.vm.onAppear()
        context.vm.toggleCleanupSelection(shown[1])
        let before = context.defaults.data(forKey: UserScopedStorage.key("recoco_daily_session_v1"))
        let reserve = [unit("next-one"), unit("next-two", reason: .visuallySimilar), unit("next-three", reason: .expiredScreen)]
        await context.service.setBatch(reserve)
        await context.vm.prepareNextRecommendations()
        XCTAssertEqual(context.vm.photoIdentifiers, shown.map(\.persistenceKey))
        XCTAssertEqual(context.vm.selectedCleanupKeys, [shown[1].persistenceKey])
        XCTAssertEqual(context.defaults.data(forKey: UserScopedStorage.key("recoco_daily_session_v1")), before)
        XCTAssertEqual(context.store.preparedRecommendations()?.photoIdentifiers, reserve.map(\.persistenceKey))
        XCTAssertEqual(context.store.recommendationExcludedIdentifiers(), Set(shown.map(\.persistenceKey)))
        await context.vm.prepareNextRecommendations()
        let fetches = await context.service.fetchCalls
        XCTAssertEqual(fetches.count, 1, "An unchanged home must not continuously prefetch")
    }

    func testHomeBackgroundImprovesRepeatedReasonsWithOneBoundedJobPerVisit() async {
        let context = context()
        let shown = (1...3).map { unit("shown-\($0)") }
        await seed(shown, in: context)
        await context.vm.onAppear()
        await context.service.setBatch([unit("similar", reason: .visuallySimilar), unit("context", reason: .expiredScreen)])
        await context.vm.prepareHomeRecommendations()
        await context.vm.prepareHomeRecommendations()
        XCTAssertEqual(context.vm.photoIdentifiers.first, "shown-1")
        XCTAssertEqual(Set(context.store.dailySessionProgress().curationReasons.values),
                       [.exactDuplicate, .visuallySimilar, .expiredScreen])
        XCTAssertEqual(context.vm.selectedCleanupCount, 0)
        XCTAssertEqual(context.store.weeklySnapshot().deletedPhotoCount, 0)
        let calls = await context.service.fetchCalls
        XCTAssertEqual(calls.count, 1, "A visible upgrade and a reserve search must not double the visit's work")
    }

    func testCancelingPreparationKeepsVisibleChecksAndDoesNotPublishUnseenResult() async {
        let context = context()
        let shown = (1...3).map { unit("shown-\($0)") }
        await seed(shown, in: context)
        await context.vm.onAppear()
        context.vm.toggleCleanupSelection(shown[0])
        let started = expectation(description: "reserve read started")
        let gate = CurationBatchRelease()
        await context.service.setBatch([unit("must-not-save")])
        await context.service.setBeforeFetch { started.fulfill(); await gate.wait() }
        let task = Task { await context.vm.prepareNextRecommendations() }
        await fulfillment(of: [started], timeout: 2)
        context.vm.pauseCuration(resumingAutomatically: true)
        await gate.finish()
        await task.value
        XCTAssertNil(context.store.preparedRecommendations())
        XCTAssertEqual(context.vm.photoIdentifiers, shown.map(\.persistenceKey))
        XCTAssertEqual(context.vm.selectedCleanupKeys, [shown[0].persistenceKey])
        guard case .ready = context.vm.state else { return XCTFail("Preparing tomorrow must never pause today's carousel") }
    }

    func testEmptyAndPartialReserveAccumulatesOnNaturalVisitsWithoutExposureOrOverwritingChoices() async {
        let context = context()
        let shown = (1...3).map { unit("visible-\($0)") }
        await seed(shown, in: context)
        await context.vm.onAppear()
        context.vm.toggleCleanupSelection(shown[1])
        let originalSession = context.defaults.data(forKey: UserScopedStorage.key("recoco_daily_session_v1"))
        let reserve = [unit("reserve-copy"), unit("reserve-similar", reason: .visuallySimilar),
                       unit("reserve-expired", reason: .expiredScreen)]
        await context.vm.prepareNextRecommendations()
        XCTAssertNil(context.store.preparedRecommendations())
        await context.vm.prepareNextRecommendations()
        let emptyCalls = await context.service.fetchCalls
        XCTAssertEqual(emptyCalls.count, 1, "Zero results must not spin on duplicate callbacks")

        for index in reserve.indices {
            context.vm.pauseCuration(resumingAutomatically: true)
            await context.vm.onAppear(reuseValidatedQueue: true)
            await context.service.setBatch([reserve[index]])
            await context.vm.prepareNextRecommendations()
            XCTAssertEqual(context.store.preparedRecommendations()?.photoIdentifiers,
                           Array(reserve.prefix(index + 1)).map(\.persistenceKey))
            await context.vm.prepareNextRecommendations()
            let calls = await context.service.fetchCalls
            XCTAssertEqual(calls.count, index + 2, "One bounded reserve attempt per natural Home visit")
            XCTAssertEqual(calls.last?.limit, 3 - index)
            for previous in reserve.prefix(index) {
                XCTAssertTrue(calls.last?.protected.contains(previous.persistenceKey) == true)
                XCTAssertTrue(calls.last?.protected.contains(previous.comparisonLocalIdentifier!) == true)
            }
        }
        context.vm.pauseCuration(resumingAutomatically: true)
        await context.vm.onAppear(reuseValidatedQueue: true)
        await context.vm.prepareNextRecommendations()
        let completedCalls = await context.service.fetchCalls
        XCTAssertEqual(completedCalls.count, 4, "Three prepared photos complete the preparation token")
        XCTAssertEqual(context.vm.photoIdentifiers, shown.map(\.persistenceKey))
        XCTAssertEqual(context.vm.selectedCleanupKeys, [shown[1].persistenceKey])
        XCTAssertEqual(context.defaults.data(forKey: UserScopedStorage.key("recoco_daily_session_v1")), originalSession)
        XCTAssertEqual(context.store.recommendationExcludedIdentifiers(), Set(shown.map(\.persistenceKey)),
                       "Preparing an unseen photo must not start its thirty-day exposure cooldown")
        XCTAssertEqual(context.store.weeklySnapshot().deletedPhotoCount, 0)
    }

    func testExistingQueueShowsFirstVerifiedPhotoWhileOtherTwoRestoreAutomatically() async {
        let context = context()
        let shown = (1...3).map { unit("stored-\($0)") }
        await seed(shown, in: context)
        await context.vm.onAppear()
        context.vm.toggleCleanupSelection(shown[1])
        context.vm.toggleCleanupSelection(shown[2])
        let reopened = HomeViewModel(featureAccess: .init(plan: .free, isSimilarPhotoCleanupEnabled: false),
            subscriptions: context.subscriptions, curationService: context.service, activity: context.store,
            authorizationStatus: { .limited }, observesPhotoLibrary: false, selectionDefaults: context.defaults)
        await context.service.setRestoreResults([
            .init(decisions: [shown[0]], retryableFailureCount: 2, hasPendingAnalysis: true),
            .init(decisions: shown, retryableFailureCount: 0)
        ])
        let secondStarted = expectation(description: "remaining photos restore automatically")
        let gate = CurationBatchRelease()
        var restores = 0
        await context.service.setBeforeRestore {
            restores += 1
            if restores == 2 { secondStarted.fulfill(); await gate.wait() }
        }
        let loading = Task { await reopened.onAppear() }
        await fulfillment(of: [secondStarted], timeout: 2)
        XCTAssertEqual(reopened.photoIdentifiers, [shown[0].persistenceKey], "The first real photo must not wait for the whole stored queue")
        XCTAssertEqual(reopened.selectedCleanupKeys, Set(shown.dropFirst().map(\.persistenceKey)),
                       "Pending checks must survive while their images are still being verified")
        guard case .ready = reopened.state else { await gate.finish(); await loading.value; return XCTFail("First photo is immediately ready") }
        await gate.finish()
        await loading.value
        XCTAssertEqual(reopened.photoIdentifiers, shown.map(\.persistenceKey))
        XCTAssertEqual(reopened.selectedCleanupCount, 2)
        let fetches = await context.service.fetchCalls
        XCTAssertTrue(fetches.isEmpty, "Restoring an existing set must not add a fresh scan budget")
        XCTAssertEqual(restores, 2)
    }

    func testExistingQueueStopsAutomaticRestoreForKnownPermissionLoss() async {
        let context = context()
        let shown = (1...3).map { unit("stored-\($0)") }
        await seed(shown, in: context)
        await context.service.setRestoreResults([
            .init(decisions: [shown[0]], retryableFailureCount: 1,
                  inaccessibleIdentifiers: [shown[1].persistenceKey], hasPendingAnalysis: true),
            .init(decisions: shown, retryableFailureCount: 0)
        ])
        await context.vm.onAppear()
        let restores = await context.service.restoreCalls
        XCTAssertEqual(restores.count, 1)
        XCTAssertEqual(context.vm.photoIdentifiers, [shown[0].persistenceKey])
        XCTAssertEqual(context.store.dailySessionProgress().curatedPhotoIdentifiers, shown.map(\.persistenceKey))
        XCTAssertEqual(context.vm.inaccessiblePhotoCount, 1)
    }

    func testLaterTransientRestoreFailureRetainsEarlierPhotoOnlyAtSameAssetRevision() async {
        for changed in [false, true] {
            let context = context()
            let shown = (1...3).map { unit("stored-\($0)") }
            await seed(shown, in: context)
            let revisions = Dictionary(uniqueKeysWithValues: shown.flatMap {
                [($0.persistenceKey, "revision-1"), ($0.comparisonLocalIdentifier!, "reference-1")]
            })
            var laterRevisions = revisions
            if changed { laterRevisions[shown[0].comparisonLocalIdentifier!] = "reference-edited" }
            await context.service.setRestoreResults([
                .init(decisions: [shown[0]], retryableFailureCount: 2, hasPendingAnalysis: true,
                      retryableIdentifiers: Set(shown.dropFirst().map(\.persistenceKey)), assetRevisions: revisions),
                .init(decisions: Array(shown.dropFirst()), retryableFailureCount: 1,
                      retryableIdentifiers: [shown[0].persistenceKey], assetRevisions: laterRevisions)
            ])
            await context.vm.onAppear()
            XCTAssertEqual(context.vm.photoIdentifiers, (changed ? Array(shown.dropFirst()) : shown).map(\.persistenceKey))
            XCTAssertEqual(context.store.dailySessionProgress().curatedPhotoIdentifiers, shown.map(\.persistenceKey),
                           "A failed current read must not erase persistent pending photos")
        }
    }

    func testExistingQueueHasAtMostThreeAutomaticRestoreSlices() async {
        let context = context()
        let shown = (1...3).map { unit("stored-\($0)") }
        await seed(shown, in: context)
        await context.service.setRestoreResults(Array(repeating:
            .init(decisions: [], retryableFailureCount: 3, hasPendingAnalysis: true), count: 4))
        await context.vm.onAppear()
        let restores = await context.service.restoreCalls
        let fetches = await context.service.fetchCalls
        XCTAssertEqual(restores.count, 3)
        XCTAssertTrue(fetches.isEmpty)
        XCTAssertEqual(context.store.dailySessionProgress().curatedPhotoIdentifiers, shown.map(\.persistenceKey))
        XCTAssertFalse(context.vm.canPauseCuration)
        guard case .noCandidate = context.vm.state else { return XCTFail("A bounded restore must end in an actionable recovery state") }
    }

    func testCooldownBlocksCandidateButKeepsItAvailableAsComparisonEvidence() async {
        let context = context()
        let yesterday = unit("recently-recommended")
        await seed([yesterday], in: context)
        advanceDay(context)
        let newPhoto = unit("new-duplicate", reference: yesterday.persistenceKey)
        // Even an incorrectly nominated recent photo must be rejected by the collector.
        await context.service.setBatch([yesterday, newPhoto])

        await context.vm.onAppear()

        XCTAssertEqual(context.vm.photoIdentifiers, [newPhoto.persistenceKey])
        XCTAssertEqual(context.store.dailySessionProgress().comparisonReferences[newPhoto.persistenceKey], yesterday.persistenceKey)
        let calls = await context.service.fetchCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(calls.first?.protected.contains(yesterday.persistenceKey) == true)
        XCTAssertFalse(calls.first?.excluded.contains(yesterday.persistenceKey) == true,
                       "Cooldown is candidate protection; removing comparison evidence could hide valid fresh duplicates")
        XCTAssertEqual(context.vm.totalDecisionCount, 1, "No evidence-free padding to promise exactly three")
    }

    func testInitialScanCrossingMidnightCannotPublishOrPersistStaleCandidates() async {
        let context = context()
        let entered = expectation(description: "yesterday's scan is waiting")
        let release = DailyRecommendationGate()
        await context.service.setBatch([unit("stale-result")])
        await context.service.setBeforeFetch { entered.fulfill(); await release.wait() }
        let pending = Task { await context.vm.onAppear() }
        await fulfillment(of: [entered], timeout: 2)
        advanceDay(context)
        let freshDisplayed = expectation(description: "new-day scan becomes ready")
        let observation = context.vm.$state.sink { state in
            if case .ready(let photo) = state, photo.persistenceKey == "fresh-result" { freshDisplayed.fulfill() }
        }
        defer { observation.cancel() }
        // The first request captured its response before waiting. Any automatic
        // new-day retry receives a genuinely new result and does not repeat the fixture.
        await context.service.setBeforeFetch(nil)
        await context.service.setBatch([unit("fresh-result")])
        await release.finish()
        await pending.value
        await fulfillment(of: [freshDisplayed], timeout: 2)

        XCTAssertFalse(context.vm.photoIdentifiers.contains("stale-result"))
        XCTAssertFalse(context.store.dailySessionProgress().curatedPhotoIdentifiers.contains("stale-result"))
        XCTAssertFalse(context.store.scannedPhotoIdentifiers().contains("stale-result"))
        XCTAssertFalse(context.store.recommendationExcludedIdentifiers().contains("stale-result"),
                       "A result never shown must not start a 30-day cooldown")
        XCTAssertEqual(context.vm.photoIdentifiers, ["fresh-result"], "The new day must remain retryable")
    }

    func testMidnightCannotReplaceOpenDeletionConfirmationAndCancellationKeepsItsSelection() async throws {
        let context = context()
        let photos = (1...3).map { unit("confirmation-cancel-\($0)") }
        try SavedRecordStore(defaults: context.defaults).save(text: "취소해도 유지할 기록",
            photoLocalIdentifier: "cancel-preserved-record", capturedDateDescription: nil)
        let recordsKey = UserScopedStorage.key(SavedRecordStore.storageKey)
        let recordsBefore = context.defaults.data(forKey: recordsKey)
        await seed(photos, in: context)
        await context.vm.onAppear()
        context.vm.toggleCleanupSelection(photos[1])
        renderHomePreviews(context.vm)
        let snapshot = try XCTUnwrap(context.vm.beginSelectedCleanup())
        let dailyKey = UserScopedStorage.key("recoco_daily_session_v1")
        let pendingBefore = context.defaults.data(forKey: dailyKey)
        advanceDay(context)

        await context.vm.refreshForNewDay()

        XCTAssertTrue(context.vm.isCommittingSelection)
        XCTAssertEqual(context.vm.photoIdentifiers, photos.map(\.persistenceKey))
        XCTAssertEqual(context.vm.selectedCleanupUnits.map(\.persistenceKey), snapshot.map(\.persistenceKey))
        XCTAssertEqual(context.defaults.data(forKey: dailyKey), pendingBefore,
                       "The day notification cannot rotate the active confirmation's session")
        XCTAssertEqual(context.defaults.data(forKey: recordsKey), recordsBefore)
        let callsWhileConfirming = await context.service.fetchCalls
        XCTAssertTrue(callsWhileConfirming.isEmpty)

        let freshReady = expectation(description: "cancellation carries the same checked photo into the new day")
        // Progressive restoration and final queue publication can both emit
        // ready for the same preserved card. Observe the first matching state,
        // not a promise that the publisher emits that state exactly once.
        let observation = context.vm.$state.filter { state in
            if case .ready(let photo) = state { return photo.persistenceKey == photos[1].persistenceKey }
            return false
        }.prefix(1).sink { _ in freshReady.fulfill() }
        defer { observation.cancel() }
        // Cancel means the success callback is never called.
        context.vm.endSelectedCleanup()
        await fulfillment(of: [freshReady], timeout: 2)

        XCTAssertFalse(context.vm.isCommittingSelection)
        XCTAssertEqual(context.vm.photoIdentifiers, [photos[1].persistenceKey])
        XCTAssertEqual(context.vm.selectedCleanupKeys, [photos[1].persistenceKey],
                       "Canceling a deletion must preserve the exact selected photo across midnight")
        XCTAssertEqual(context.vm.selectedCleanupCount, 1)
        XCTAssertEqual(context.store.dailySessionProgress().curatedPhotoIdentifiers, [photos[1].persistenceKey])
        XCTAssertEqual(context.store.weeklySnapshot().deletedPhotoCount, 0)
        XCTAssertTrue(context.store.cleanupDailyCounts().isEmpty)
        XCTAssertEqual(context.defaults.data(forKey: recordsKey), recordsBefore)
    }

    func testMidnightUnconfirmedDeletionKeepsRecoveryVisibleUntilExplicitRecheck() async throws {
        let context = context()
        let photos = (1...3).map { unit("confirmation-failure-\($0)") }
        try SavedRecordStore(defaults: context.defaults).save(text: "실패 후에도 유지할 기존 기록",
            photoLocalIdentifier: "failure-preserved-record", capturedDateDescription: nil)
        let recordsKey = UserScopedStorage.key(SavedRecordStore.storageKey)
        let recordsBefore = context.defaults.data(forKey: recordsKey)
        await seed(photos, in: context)
        await context.vm.onAppear()
        context.vm.toggleCleanupSelection(photos[1])
        renderHomePreviews(context.vm)
        let snapshot = try XCTUnwrap(context.vm.beginSelectedCleanup())
        let dailyKey = UserScopedStorage.key("recoco_daily_session_v1")
        let sessionBefore = context.defaults.data(forKey: dailyKey)
        advanceDay(context)
        context.vm.reportCleanupFailure(NSError(domain: "DailyRecommendationTest.Unconfirmed", code: 1))
        XCTAssertEqual(context.vm.cleanupRecovery, .unconfirmed)
        let recoveryCleared = expectation(description: "automatic day refresh must not erase an unconfirmed result")
        recoveryCleared.isInverted = true
        let observation = context.vm.$cleanupRecovery.sink { recovery in
            if recovery != .unconfirmed { recoveryCleared.fulfill() }
        }

        context.vm.endSelectedCleanup()
        await fulfillment(of: [recoveryCleared], timeout: 0.1)
        observation.cancel()

        XCTAssertFalse(context.vm.isCommittingSelection)
        XCTAssertEqual(context.vm.cleanupRecovery, .unconfirmed)
        XCTAssertEqual(context.vm.photoIdentifiers, photos.map(\.persistenceKey))
        XCTAssertEqual(context.vm.selectedCleanupUnits.map(\.persistenceKey), snapshot.map(\.persistenceKey))
        XCTAssertNil(context.vm.beginSelectedCleanup(), "Do not allow another deletion before the unknown outcome is checked")
        XCTAssertEqual(context.defaults.data(forKey: dailyKey), sessionBefore)
        XCTAssertEqual(context.defaults.data(forKey: recordsKey), recordsBefore)
        XCTAssertEqual(context.store.weeklySnapshot().deletedPhotoCount, 0)
        let fetches = await context.service.fetchCalls
        XCTAssertTrue(fetches.isEmpty, "An unresolved deletion must not be hidden by a new automatic recommendation")
    }

    func testMidnightConfirmedDeletionPreservesEachDaysCountsAndCompletionFeedback() async throws {
        let context = context()
        let photos = (1...3).map { unit("confirmation-success-\($0)") }
        try SavedRecordStore(defaults: context.defaults).save(text: "비워도 유지할 기존 기록",
            photoLocalIdentifier: "success-preserved-record", capturedDateDescription: nil)
        let recordsKey = UserScopedStorage.key(SavedRecordStore.storageKey)
        let recordsBefore = context.defaults.data(forKey: recordsKey)
        let firstDay = context.calendar.startOfDay(for: context.clock.date)
        await seed(photos, in: context)
        await context.vm.onAppear()
        context.vm.toggleCleanupSelection(photos[0])
        renderHomePreviews(context.vm)
        let firstSnapshot = try XCTUnwrap(context.vm.beginSelectedCleanup())
        context.vm.completeSelectedCleanup(firstSnapshot)
        context.vm.endSelectedCleanup()
        XCTAssertEqual(context.store.cleanupDailyCounts()[firstDay], 1)
        context.vm.toggleCleanupSelection(photos[1])
        context.vm.toggleCleanupSelection(photos[2])
        let finalSnapshot = try XCTUnwrap(context.vm.beginSelectedCleanup())
        advanceDay(context)
        let secondDay = context.calendar.startOfDay(for: context.clock.date)

        await context.vm.refreshForNewDay()

        XCTAssertEqual(context.vm.photoIdentifiers, [photos[1].persistenceKey, photos[2].persistenceKey])
        XCTAssertEqual(context.vm.selectedCleanupCount, 2)
        let completed = expectation(description: "successful transaction gets completion feedback")
        let replaced = expectation(description: "day refresh must not erase immediate completion feedback")
        replaced.isInverted = true
        var hasCompleted = false
        let observation = context.vm.$state.sink { state in
            if case .completed = state {
                if !hasCompleted { hasCompleted = true; completed.fulfill() }
            } else if hasCompleted { replaced.fulfill() }
        }
        context.vm.completeSelectedCleanup(finalSnapshot)
        context.vm.endSelectedCleanup()
        await fulfillment(of: [completed, replaced], timeout: 0.15)
        observation.cancel()

        guard case .completed(let summary) = context.vm.state else { return XCTFail("Keep the success screen until the next navigation") }
        XCTAssertEqual(summary.deletedCount, 2)
        XCTAssertEqual(context.store.cleanupDailyCounts(), [firstDay: 1, secondDay: 2])
        XCTAssertEqual(context.store.todaySummary()?.deletedPhotoCount, 2)
        XCTAssertEqual(context.store.weeklySnapshot().deletedPhotoCount, 3)
        XCTAssertEqual(context.defaults.data(forKey: recordsKey), recordsBefore)
        XCTAssertFalse(context.vm.isCommittingSelection)
        XCTAssertEqual(context.vm.selectedCleanupCount, 0)

        await context.vm.onAppear()

        guard case .noCandidate = context.vm.state else { return XCTFail("A later Home visit must not replay the completed transaction") }
        XCTAssertEqual(context.store.cleanupDailyCounts(), [firstDay: 1, secondDay: 2])
        XCTAssertEqual(context.store.weeklySnapshot().deletedPhotoCount, 3)
        XCTAssertEqual(context.defaults.data(forKey: recordsKey), recordsBefore)
        let fetches = await context.service.fetchCalls
        XCTAssertTrue(fetches.isEmpty, "An already-completed new day does not silently request another batch")
    }

    func testYesterdayPausedScanDoesNotBlockNextDaysAutomaticRecommendations() async {
        let context = context()
        let entered = expectation(description: "scan before leaving app")
        let release = DailyRecommendationGate()
        await context.service.setBatch([unit("cancelled-result")])
        await context.service.setBeforeFetch { entered.fulfill(); await release.wait() }
        let pending = Task { await context.vm.onAppear() }
        await fulfillment(of: [entered], timeout: 2)
        context.vm.pauseCuration()
        await release.finish()
        await pending.value
        advanceDay(context)
        await context.service.setBeforeFetch(nil)
        await context.service.setBatch([unit("next-day-result")])

        await context.vm.onAppear()

        XCTAssertEqual(context.vm.photoIdentifiers, ["next-day-result"])
        XCTAssertFalse(context.store.recommendationExcludedIdentifiers().contains("cancelled-result"))
        XCTAssertEqual(context.vm.selectedCleanupCount, 0)
    }
}

private actor DailyRecommendationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false
    func wait() async {
        if finished { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func finish() { finished = true; continuation?.resume(); continuation = nil }
}

private actor DailyRecommendationService: PhotoCurationServing {
    struct FetchCall {
        let excluded: Set<String>
        let protected: Set<String>
        let limit: Int
    }
    var fetchCalls: [FetchCall] = []
    var restoreCalls: [[String]] = []
    var batch = PhotoCurationService.ScanBatch(decisions: [], visitedIdentifiers: [], hasMore: false)
    var restored: [DecisionUnit] = []
    var restoredFailureCount = 0
    var restoreResults: [PhotoCurationService.RestoredDecisions] = []
    var cachedRestored: PhotoCurationService.RestoredDecisions?
    var beforeFetch: (() async -> Void)?
    var beforeRestore: (() async -> Void)?
    func setBatch(_ photos: [DecisionUnit]) {
        batch = .init(decisions: photos, visitedIdentifiers: Set(photos.map(\.persistenceKey)), hasMore: false)
    }
    func setRestored(_ photos: [DecisionUnit], failureCount: Int = 0) {
        restored = photos; restoredFailureCount = failureCount
    }
    func setBeforeFetch(_ action: (() async -> Void)?) { beforeFetch = action }
    func setBeforeRestore(_ action: (() async -> Void)?) { beforeRestore = action }
    func setRestoreResults(_ results: [PhotoCurationService.RestoredDecisions]) { restoreResults = results }
    func setCachedRestored(_ result: PhotoCurationService.RestoredDecisions?) { cachedRestored = result }
    func restoreCachedDecisions(localIdentifiers: [String], references: [String: String], reasons: [String: CurationReasonCode],
                               protectedIdentifiers: Set<String>, reviewDates: [String: Date]) async -> PhotoCurationService.RestoredDecisions? {
        cachedRestored
    }
    func resetScan() async {}
    nonisolated func hasUnscannedPhotos(excluding: Set<String>) async -> Bool { false }
    func fetchNextBatch(excluding: Set<String>, protectedIdentifiers: Set<String>, reviewDates: [String: Date],
                        limit: Int, firstResult: Bool, excludingReasonGroups: Set<CleanupReasonGroup>,
                        onProgress: (@Sendable (PhotoCurationService.ScanProgress) -> Void)?) async -> PhotoCurationService.ScanBatch {
        fetchCalls.append(FetchCall(excluded: excluding, protected: protectedIdentifiers, limit: limit))
        let result = batch
        await beforeFetch?()
        return result
    }
    func restoreDecisions(localIdentifiers: [String], references: [String: String], reasons: [String: CurationReasonCode],
                          protectedIdentifiers: Set<String>, reviewDates: [String: Date]) async -> PhotoCurationService.RestoredDecisions {
        restoreCalls.append(localIdentifiers)
        let result = restoreResults.isEmpty ? nil : restoreResults.removeFirst()
        await beforeRestore?()
        if let result { return result }
        return .init(decisions: restored.filter { localIdentifiers.contains($0.persistenceKey) }, retryableFailureCount: restoredFailureCount)
    }
    func fetchSimilarPhotoDecision(scanLimit: Int, protectedIdentifiers: Set<String>, reviewDates: [String: Date]) async -> DecisionUnit? { nil }
}

@MainActor
final class StreamingHomeRecommendationTests: XCTestCase {
    private func unit(_ id: String, reason: CurationReasonCode = .exactDuplicate) -> DecisionUnit {
        DecisionUnit(id: UUID(), type: .cleanupSingle, status: .pending,
            candidateLocalIdentifiers: [id], recommendedLocalIdentifier: id,
            reasonCodes: [reason], capturedDateDescription: nil, createdAt: Date(),
            comparisonLocalIdentifier: reason == .expiredScreen ? nil : "reference-\(id)")
    }

    private func context(_ service: StreamingHomeService) -> (HomeViewModel, LocalActivityStore, UserDefaults) {
        let name = "streaming-home-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let store = LocalActivityStore(defaults: defaults)
        let vm = HomeViewModel(featureAccess: .init(plan: .free, isSimilarPhotoCleanupEnabled: false),
            subscriptions: SubscriptionStore(defaults: defaults, enabled: false),
            curationService: service, activity: store, authorizationStatus: { .authorized },
            observesPhotoLibrary: false, selectionDefaults: defaults)
        return (vm, store, defaults)
    }

    private func render(_ vm: HomeViewModel, id: String) {
        let request = UUID()
        vm.updateHomePhotoPreview(identifier: id, generation: vm.photoPreviewGeneration, requestID: request, state: .loading)
        vm.updateHomePhotoPreview(identifier: id, generation: vm.photoPreviewGeneration, requestID: request, state: .ready)
    }

    func testFirstVerifiedPhotosAreVisibleAndSavedBeforeLaterPassFinishes() async throws {
        let first = unit("stream-first"), second = unit("stream-second", reason: .visuallySimilar)
        let third = unit("stream-third", reason: .expiredScreen)
        let release = CurationBatchRelease()
        let entered = expectation(description: "later pass blocked")
        let service = StreamingHomeService(batches: [
            .init(decisions: [first, second], visitedIdentifiers: ["stream-first", "stream-second"], hasMore: true, hasFreshPhotos: true),
            .init(decisions: [third], visitedIdentifiers: ["stream-third"], hasMore: false)
        ], waitAt: 2, wait: { entered.fulfill(); await release.wait() })
        let (vm, store, defaults) = context(service)
        try SavedRecordStore(defaults: defaults).save(text: "기존 기록", photoLocalIdentifier: "old-record", capturedDateDescription: nil)
        let recordKey = UserScopedStorage.key(SavedRecordStore.storageKey)
        let before = defaults.data(forKey: recordKey)
        let task = Task { await vm.onAppear() }
        await fulfillment(of: [entered], timeout: 2)
        guard case .ready = vm.state else { await release.finish(); await task.value; return XCTFail("Verified photos must appear before the third photo finishes") }
        XCTAssertEqual(vm.photoIdentifiers, ["stream-first", "stream-second"])
        XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, vm.photoIdentifiers)
        XCTAssertNotNil(defaults.data(forKey: UserScopedStorage.key("recoco_curation_authorization_v1")))
        vm.browsePhoto(at: 1)
        vm.toggleCleanupSelection(second)
        await release.finish()
        await task.value
        XCTAssertEqual(vm.photoIdentifiers, ["stream-first", "stream-second", "stream-third"])
        XCTAssertEqual(vm.currentDecisionIndex, 1)
        XCTAssertEqual(vm.selectedCleanupKeys, ["stream-second"])
        XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, vm.photoIdentifiers)
        XCTAssertEqual(defaults.data(forKey: recordKey), before)
        XCTAssertEqual(store.weeklySnapshot().deletedPhotoCount, 0)
    }

    func testCleanupIntentCancelsLateAppendButKeepsAlreadyPublishedQueueAndSelection() async {
        let first = unit("committed-stream-first"), second = unit("canceled-late", reason: .visuallySimilar)
        let release = CurationBatchRelease()
        let entered = expectation(description: "later pass blocked for cleanup")
        let service = StreamingHomeService(batches: [
            .init(decisions: [first], visitedIdentifiers: [first.persistenceKey], hasMore: true, hasFreshPhotos: true),
            .init(decisions: [second], visitedIdentifiers: [second.persistenceKey], hasMore: false)
        ], waitAt: 2, wait: { entered.fulfill(); await release.wait() })
        let (vm, store, _) = context(service)
        let task = Task { await vm.onAppear() }
        await fulfillment(of: [entered], timeout: 2)
        vm.toggleCleanupSelection(first)
        render(vm, id: first.persistenceKey)
        XCTAssertEqual(vm.beginSelectedCleanup()?.map(\.persistenceKey), [first.persistenceKey])
        await release.finish()
        await task.value
        vm.endSelectedCleanup()
        XCTAssertEqual(vm.photoIdentifiers, [first.persistenceKey])
        XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, [first.persistenceKey])
        XCTAssertEqual(vm.selectedCleanupKeys, [first.persistenceKey])
        XCTAssertFalse(store.recommendationExcludedIdentifiers().contains(second.persistenceKey))
        XCTAssertEqual(store.weeklySnapshot().deletedPhotoCount, 0)
    }

    func testChangedSessionBeforeFirstSnapshotRejectsLateRecommendationAndCoverage() async {
        let stale = unit("stale-before-first-snapshot")
        let release = CurationBatchRelease()
        let entered = expectation(description: "first scan waits while session changes")
        let service = StreamingHomeService(batches: [
            .init(decisions: [stale], visitedIdentifiers: [stale.persistenceKey], hasMore: false)
        ], waitAt: 1, wait: { entered.fulfill(); await release.wait() })
        let (vm, store, _) = context(service)
        let task = Task { await vm.onAppear() }
        await fulfillment(of: [entered], timeout: 2)
        store.beginDailySession(photoIdentifiers: ["newer-session-photo"],
            comparisonReferences: ["newer-session-photo": "newer-reference"],
            curationReasons: ["newer-session-photo": .exactDuplicate])
        await release.finish()
        await task.value
        XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, ["newer-session-photo"])
        XCTAssertFalse(vm.photoIdentifiers.contains(stale.persistenceKey))
        XCTAssertFalse(store.scannedPhotoIdentifiers().contains(stale.persistenceKey))
        XCTAssertFalse(store.recommendationExcludedIdentifiers().contains(stale.persistenceKey))
        XCTAssertEqual(store.weeklySnapshot().deletedPhotoCount, 0)
    }

    func testUnchangedTabReentryKeepsVisiblePreviewWithoutStartingAnotherAnalysis() async {
        let photo = unit("stable-tab-photo")
        let service = StreamingHomeService(batches: [.init(decisions: [photo], visitedIdentifiers: [photo.persistenceKey], hasMore: false)])
        let (vm, _, _) = context(service)
        await vm.onAppear()
        render(vm, id: photo.persistenceKey)
        let generation = vm.photoPreviewGeneration
        await vm.onAppear(reuseValidatedQueue: true)
        XCTAssertEqual(vm.photoPreviewGeneration, generation)
        XCTAssertTrue(vm.isPhotoPreviewReady(photo.persistenceKey))
        let calls = await service.counts()
        XCTAssertEqual(calls.fetch, 1)
        XCTAssertEqual(calls.restore, 0)

        vm.photoLibraryDidChange()
        await vm.onAppear(reuseValidatedQueue: true)
        let changedCalls = await service.counts()
        XCTAssertEqual(changedCalls.restore, 1, "Photo library changes still require validation")
    }

    func testLifecycleInterruptionResumesButExplicitPauseWaitsForUser() async {
        for automatically in [true, false] {
            let photo = unit("resume-\(automatically)")
            let release = CurationBatchRelease()
            let entered = expectation(description: "initial pass \(automatically)")
            let batch = PhotoCurationService.ScanBatch(decisions: [photo], visitedIdentifiers: [photo.persistenceKey], hasMore: false)
            let service = StreamingHomeService(batches: [batch, batch], waitAt: 1,
                wait: { entered.fulfill(); await release.wait() })
            let (vm, store, _) = context(service)
            let task = Task { await vm.onAppear() }
            await fulfillment(of: [entered], timeout: 2)
            vm.pauseCuration(resumingAutomatically: automatically)
            await release.finish()
            await task.value
            XCTAssertTrue(store.dailySessionProgress().curatedPhotoIdentifiers.isEmpty)
            await vm.onAppear(reuseValidatedQueue: true)
            if automatically {
                guard case .ready = vm.state else { return XCTFail("Returning from an interruption should continue automatically") }
                XCTAssertEqual(vm.photoIdentifiers, [photo.persistenceKey])
            } else {
                guard case .scanPaused = vm.state else { return XCTFail("A deliberate pause remains paused") }
                XCTAssertTrue(vm.photoIdentifiers.isEmpty)
            }
            let calls = await service.counts()
            XCTAssertEqual(calls.fetch, automatically ? 2 : 1)
        }
    }

    func testUnrelatedUnreadablePhotoDoesNotRestartAValidatedQueueOnTabReentry() async {
        let photo = unit("validated-with-unrelated-failure")
        let service = StreamingHomeService(batches: [
            .init(decisions: [photo], visitedIdentifiers: [photo.persistenceKey],
                  hasMore: true, retryableFailureCount: 1, hasFreshPhotos: false)
        ])
        let (vm, store, _) = context(service)
        await vm.onAppear()
        render(vm, id: photo.persistenceKey)
        vm.toggleCleanupSelection(photo)
        let generation = vm.photoPreviewGeneration
        let before = await service.counts()
        XCTAssertTrue(vm.hasScanIssue, "This failure concerns a different photo, not the verified visible queue")

        await vm.onAppear(reuseValidatedQueue: true)

        let after = await service.counts()
        XCTAssertEqual(after.fetch, before.fetch)
        XCTAssertEqual(after.restore, 0)
        XCTAssertEqual(vm.photoPreviewGeneration, generation)
        XCTAssertTrue(vm.isPhotoPreviewReady(photo.persistenceKey))
        XCTAssertEqual(vm.selectedCleanupKeys, [photo.persistenceKey])
        XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, [photo.persistenceKey])
        XCTAssertEqual(store.weeklySnapshot().deletedPhotoCount, 0)
    }

    func testShortFreshQueueContinuesAfterInitialBudgetWithoutNavigationOrReloadingVisiblePhotos() async {
        let first = unit("tab-first"), second = unit("tab-second", reason: .visuallySimilar)
        let third = unit("tab-third", reason: .expiredScreen)
        let unfinished = PhotoCurationService.ScanBatch(decisions: [], visitedIdentifiers: [], hasMore: true, hasFreshPhotos: true)
        let release = CurationBatchRelease()
        let entered = expectation(description: "same Home visit automatically continues unfinished search")
        let service = StreamingHomeService(batches: [
            .init(decisions: [first, second], visitedIdentifiers: [first.persistenceKey, second.persistenceKey], hasMore: true, hasFreshPhotos: true)
        ] + Array(repeating: unfinished, count: 95) + [
            .init(decisions: [third], visitedIdentifiers: [third.persistenceKey], hasMore: false)
        ], waitAt: 97, wait: { entered.fulfill(); await release.wait() })
        let (vm, store, _) = context(service)
        let initialDone = expectation(description: "first foreground budget finishes")
        var initialFinished = false
        let initial = Task { await vm.onAppear(); initialFinished = true; initialDone.fulfill() }
        await fulfillment(of: [initialDone], timeout: 2)
        guard initialFinished else {
            initial.cancel(); await release.finish(); await initial.value
            return XCTFail("A bounded initial request must return before the nonblocking continuation finishes")
        }
        vm.browsePhoto(at: 1)
        vm.toggleCleanupSelection(second)
        render(vm, id: first.persistenceKey)
        render(vm, id: second.persistenceKey)
        let generation = vm.photoPreviewGeneration

        await fulfillment(of: [entered], timeout: 2)
        guard case .ready = vm.state else {
            await release.finish()
            return XCTFail("Automatic continuation must keep the ready carousel during continued analysis")
        }
        XCTAssertEqual(vm.photoPreviewGeneration, generation)
        XCTAssertTrue(vm.isPhotoPreviewReady(second.persistenceKey))
        XCTAssertEqual(vm.currentDecisionIndex, 1)
        XCTAssertEqual(vm.selectedCleanupKeys, [second.persistenceKey])
        let filled = expectation(description: "third photo appends without another Home callback")
        var didFill = false
        let observation = vm.$state.sink { state in
            if case .ready = state, vm.photoIdentifiers.count == 3, !didFill {
                didFill = true; filled.fulfill()
            }
        }
        defer { observation.cancel() }
        await release.finish()
        await fulfillment(of: [filled], timeout: 2)

        XCTAssertEqual(vm.photoIdentifiers, [first.persistenceKey, second.persistenceKey, third.persistenceKey])
        XCTAssertEqual(vm.photoPreviewGeneration, generation)
        XCTAssertEqual(vm.currentDecisionIndex, 1)
        XCTAssertEqual(vm.selectedCleanupKeys, [second.persistenceKey])
        XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, vm.photoIdentifiers)
        let counts = await service.counts()
        XCTAssertEqual(counts.restore, 0, "Already verified photos must not be read again during continuation")
        XCTAssertEqual(store.weeklySnapshot().deletedPhotoCount, 0)
        vm.pauseCuration(resumingAutomatically: true)
    }

    func testUnchangedShortQueueGetsOnlyOneExtraAutomaticAttempt() async {
        let first = unit("bounded-tab-first")
        let unfinished = PhotoCurationService.ScanBatch(decisions: [], visitedIdentifiers: [], hasMore: true, hasFreshPhotos: true)
        let release = CurationBatchRelease()
        let entered = expectation(description: "one automatic follow-up begins")
        let service = StreamingHomeService(batches: [
            .init(decisions: [first], visitedIdentifiers: [first.persistenceKey], hasMore: true, hasFreshPhotos: true)
        ] + Array(repeating: unfinished, count: 400), waitAt: 97,
            wait: { entered.fulfill(); await release.wait() })
        let (vm, _, _) = context(service)
        await vm.onAppear()
        render(vm, id: first.persistenceKey)
        let generation = vm.photoPreviewGeneration
        await fulfillment(of: [entered], timeout: 2)
        let stopped = expectation(description: "unchanged work stops after one follow-up slice")
        var didStop = false
        let observation = vm.$state.dropFirst().sink { state in
            if case .ready = state, !didStop { didStop = true; stopped.fulfill() }
        }
        defer { observation.cancel() }
        await release.finish()
        await fulfillment(of: [stopped], timeout: 2)
        await Task.yield()
        await vm.onAppear(reuseValidatedQueue: true)
        let afterDuplicateCallback = await service.counts()
        XCTAssertEqual(afterDuplicateCallback.fetch, 128, "Initial three slices plus one unchanged slice; no endless retry")
        vm.pauseCuration(resumingAutomatically: true)
        await vm.onAppear(reuseValidatedQueue: true)
        let afterContinuation = await service.counts()
        XCTAssertGreaterThan(afterContinuation.fetch, afterDuplicateCallback.fetch,
                             "A real new Home visit gets a fresh bounded opportunity")
        XCTAssertEqual(afterContinuation.restore, 0)
        vm.pauseCuration(resumingAutomatically: true)
        XCTAssertEqual(vm.photoPreviewGeneration, generation)
        XCTAssertTrue(vm.isPhotoPreviewReady(first.persistenceKey))
    }

    func testNonblockingFollowUpCannotAppendAfterTabExitPermissionChangeOrCleanupConfirmation() async {
        for interruption in ["tab", "permission", "confirmation"] {
            let first = unit("kept-\(interruption)")
            let late = unit("late-\(interruption)", reason: .visuallySimilar)
            let unfinished = PhotoCurationService.ScanBatch(decisions: [], visitedIdentifiers: [],
                hasMore: true, hasFreshPhotos: true)
            let gate = CurationBatchRelease()
            let entered = expectation(description: "nonblocking continuation \(interruption)")
            let service = StreamingHomeService(batches: [
                .init(decisions: [first], visitedIdentifiers: [first.persistenceKey], hasMore: true, hasFreshPhotos: true)
            ] + Array(repeating: unfinished, count: 95) + [
                .init(decisions: [late], visitedIdentifiers: [late.persistenceKey], hasMore: false)
            ], waitAt: 97, wait: { entered.fulfill(); await gate.wait() })
            let (vm, store, _) = context(service)
            await vm.onAppear()
            await fulfillment(of: [entered], timeout: 2)
            render(vm, id: first.persistenceKey)
            vm.toggleCleanupSelection(first)
            let unchanged = expectation(description: "late result must not publish after \(interruption)")
            unchanged.isInverted = true
            let observation = vm.$state.sink { _ in
                if vm.photoIdentifiers.contains(late.persistenceKey) { unchanged.fulfill() }
            }
            if interruption == "tab" { vm.pauseCuration(resumingAutomatically: true) }
            else if interruption == "permission" { vm.photoLibraryDidChange() }
            else { XCTAssertEqual(vm.beginSelectedCleanup()?.map(\.persistenceKey), [first.persistenceKey]) }
            await gate.finish()
            await fulfillment(of: [unchanged], timeout: 0.1)
            observation.cancel()
            XCTAssertEqual(vm.photoIdentifiers, [first.persistenceKey])
            XCTAssertEqual(vm.selectedCleanupKeys, [first.persistenceKey])
            XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, [first.persistenceKey])
            XCTAssertFalse(store.recommendationExcludedIdentifiers().contains(late.persistenceKey))
            XCTAssertEqual(store.weeklySnapshot().deletedPhotoCount, 0)
            vm.pauseCuration(resumingAutomatically: true)
        }
    }
}

private actor StreamingHomeService: PhotoCurationServing {
    let batches: [PhotoCurationService.ScanBatch]
    let waitAt: Int?
    let wait: (() async -> Void)?
    var fetchCount = 0
    var restoreCount = 0
    init(batches: [PhotoCurationService.ScanBatch], waitAt: Int? = nil, wait: (() async -> Void)? = nil) {
        self.batches = batches; self.waitAt = waitAt; self.wait = wait
    }
    func counts() -> (fetch: Int, restore: Int) { (fetchCount, restoreCount) }
    func resetScan() async {}
    func hasUnscannedPhotos(excluding: Set<String>) async -> Bool { false }
    func fetchNextBatch(excluding: Set<String>, protectedIdentifiers: Set<String>, reviewDates: [String: Date],
                        limit: Int, firstResult: Bool, excludingReasonGroups: Set<CleanupReasonGroup>,
                        onProgress: (@Sendable (PhotoCurationService.ScanProgress) -> Void)?) async -> PhotoCurationService.ScanBatch {
        fetchCount += 1
        let number = fetchCount
        if number == waitAt { await wait?() }
        guard batches.indices.contains(number - 1) else { return .init(decisions: [], visitedIdentifiers: [], hasMore: false) }
        return batches[number - 1]
    }
    func restoreDecisions(localIdentifiers: [String], references: [String: String], reasons: [String: CurationReasonCode],
                          protectedIdentifiers: Set<String>, reviewDates: [String: Date]) async -> PhotoCurationService.RestoredDecisions {
        restoreCount += 1
        return .init(decisions: batches.flatMap(\.decisions).filter { localIdentifiers.contains($0.persistenceKey) }, retryableFailureCount: 0)
    }
    func fetchSimilarPhotoDecision(scanLimit: Int, protectedIdentifiers: Set<String>, reviewDates: [String: Date]) async -> DecisionUnit? { nil }
}

// The original-file shortcut is only a read filter, never identity evidence.
extension CurationBatchTests {
    func testOriginalReadPrefilterRejectsUnrelatedOrIncompletePreviews() {
        let photo = Array(repeating: 0.35, count: 48 * 48 * 3)
        XCTAssertTrue(PhotoCurationService.originalPreviewsAreCompatible(photo, photo))
        XCTAssertTrue(PhotoCurationService.originalPreviewsAreCompatible(photo,
            Array(repeating: 0.351, count: photo.count)))
        XCTAssertFalse(PhotoCurationService.originalPreviewsAreCompatible(photo,
            Array(repeating: 0.8, count: photo.count)))
        XCTAssertFalse(PhotoCurationService.originalPreviewsAreCompatible([], []))
        XCTAssertFalse(PhotoCurationService.originalPreviewsAreCompatible(photo, Array(photo.dropLast())))
        var localChange = photo
        for y in 0..<6 {
            for x in 0..<6 {
                for channel in 0..<3 { localChange[(y * 48 + x) * 3 + channel] = 0.95 }
            }
        }
        XCTAssertFalse(PhotoCurationService.originalPreviewsAreCompatible(photo, localChange),
            "A small changed tile must not trigger a whole-file read just because the overall color is similar")
    }

    func testExhaustedPhotoReadBudgetDoesNotStartARequest() {
        var requested = false
        var cancelled = false
        let result: String? = PhotoCurationService.boundedPhotoRead(timeout: 0,
            cancel: { _ in cancelled = true }, request: { _ in
                requested = true
                return 99
            })
        XCTAssertNil(result)
        XCTAssertFalse(requested)
        XCTAssertFalse(cancelled)
    }

    func testOriginalAndPreviewReadsShareTheRemainingBudget() {
        let expired = PhotoCurationService.AnalysisDeadline(seconds: -1)
        XCTAssertTrue(expired.expired)
        XCTAssertEqual(expired.readTimeout(maximum: 30), 0)
        let short = PhotoCurationService.AnalysisDeadline(seconds: 0.2)
        XCTAssertLessThanOrEqual(short.readTimeout(maximum: 30), 0.2,
            "An approved original download must not restart a separate thirty-second timeout")
        XCTAssertGreaterThan(short.readTimeout(maximum: 30), 0)
    }
}

final class MetadataNominationFairnessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ id: String, days: Int, seconds: TimeInterval = 0,
                       screenshot: Bool = false, favorite: Bool = false, excluded: Bool = false,
                       width: Int = 100) -> PhotoCurationService.ScanCatalogEntry {
        let date = Calendar.current.date(byAdding: .day, value: -days, to: now)!.addingTimeInterval(seconds)
        return .init(identifier: id, assetIndex: id.utf8.reduce(0) { $0 + Int($1) },
            facts: .init(capturedAt: date, width: width, height: 100,
                         isScreenshot: screenshot, isFavorite: favorite, isExcluded: excluded))
    }

    func testFirstWindowUsesBoundedPairAndScreenOpportunitiesBeforeUnrelatedFiller() {
        var catalog: [PhotoCurationService.ScanCatalogEntry] = []
        for pair in 0..<16 {
            catalog += [entry("pair-\(pair)-a", days: 10, seconds: Double(-pair * 100)),
                        entry("pair-\(pair)-b", days: 10, seconds: Double(-pair * 100 - 10))]
        }
        catalog += (0..<16).map { entry("screen-\($0)", days: 40 + $0, screenshot: true) }
        catalog += (0..<100).map { entry("unrelated-\($0)", days: 1 + $0, width: 1000 + $0) }
        let window = PhotoCurationService.scanWindow(in: catalog, excluding: [], deferred: [], reviewDates: [:], now: now)
        XCTAssertEqual(window.nominationCounts["nearbyNomineePhotos"], 32)
        XCTAssertEqual(window.nominationCounts["contextNomineePhotos"], 16)
        XCTAssertEqual(window.entries.filter { $0.identifier.hasPrefix("pair-") }.count, 32)
        XCTAssertEqual(window.entries.filter { $0.identifier.hasPrefix("screen-") }.count, 16)
        XCTAssertLessThanOrEqual(window.entries.count, 64)
        XCTAssertEqual(window.remaining, Set(catalog.map(\.identifier)), "A broader nomination is not evidence or scanned coverage")
    }

    func testMissingContextReasonGetsScreensBeforeMoreOrdinaryPairCandidates() {
        var catalog = (0..<50).map { entry("screen-\($0)", days: 40 + $0, screenshot: true) }
        for pair in 0..<10 {
            catalog += [entry("pair-\(pair)-a", days: 1, seconds: Double(-pair * 100)),
                        entry("pair-\(pair)-b", days: 1, seconds: Double(-pair * 100))]
        }
        let window = PhotoCurationService.scanWindow(in: catalog, excluding: [], deferred: [],
            reviewDates: [:], now: now, excludingReasonGroups: [.similarCapture])
        XCTAssertTrue(window.entries.prefix(2).allSatisfy { $0.facts?.isScreenshot == true })
        XCTAssertEqual(window.nominationCounts["contextNomineePhotos"], 32)
        XCTAssertLessThanOrEqual(window.entries.count, 64)
        XCTAssertGreaterThanOrEqual(window.entries.filter { $0.facts?.isScreenshot == true }.count, 32)
        XCTAssertEqual(window.remaining, Set(catalog.map(\.identifier)), "A scheduling change is not deletion evidence or completed coverage")
    }

    func testCompletedContextChecksYieldToNewScreensWithoutLosingPairEligibility() {
        let catalog = [entry("old-a", days: 30, screenshot: true), entry("old-b", days: 30, screenshot: true)]
            + (0..<20).map { entry("unexamined-\($0)", days: 40 + $0, screenshot: true) }
        let window = PhotoCurationService.scanWindow(in: catalog, excluding: [], deferred: [],
            reviewDates: [:], now: now, excludingReasonGroups: [.similarCapture], contextExamined: ["old-a", "old-b"])
        XCTAssertTrue(window.entries.prefix(2).allSatisfy { $0.identifier.hasPrefix("unexamined-") })
        XCTAssertEqual(window.nominationCounts["contextNomineePhotos"], 20)
        XCTAssertEqual(window.nominationCounts["exactNomineePhotos"], 2,
                       "Negative OCR evidence says nothing about identical file evidence")
        XCTAssertTrue(Set(window.entries.map(\.identifier)).isSuperset(of: ["old-a", "old-b"]))
        XCTAssertEqual(window.remaining, Set(catalog.map(\.identifier)))
    }

    func testExactPairsIncludeOlderCohortsBeforeNinthRecentPairWithoutSplittingPeers() {
        var catalog: [PhotoCurationService.ScanCatalogEntry] = []
        for pair in 0..<12 {
            catalog += [entry("new-\(pair)-a", days: 1, seconds: Double(-pair * 100)),
                        entry("new-\(pair)-b", days: 1, seconds: Double(-pair * 100))]
        }
        for (name, days) in [("week", 10), ("month", 40), ("old", 200)] {
            catalog += [entry("\(name)-a", days: days), entry("\(name)-b", days: days)]
        }
        let window = PhotoCurationService.scanWindow(in: catalog, excluding: [], deferred: [], reviewDates: [:], now: now)
        XCTAssertEqual(Array(window.entries.prefix(8).map(\.identifier)),
                       ["new-0-a", "new-0-b", "week-a", "week-b", "month-a", "month-b", "old-a", "old-b"])
        XCTAssertEqual(window.nominationCounts["exactNomineePhotos"], 16)
        XCTAssertEqual(window.remaining, Set(catalog.map(\.identifier)), "Nomination never consumes scan coverage")
        XCTAssertEqual(Set(window.entries.map(\.identifier)).count, window.entries.count)
    }

    func testNearbyPairsStayAdjacentAndSampleEveryAgeBeforeRecentPairsDominate() {
        var catalog: [PhotoCurationService.ScanCatalogEntry] = []
        for pair in 0..<12 {
            catalog += [entry("new-\(pair)-a", days: 1, seconds: Double(-pair * 100)),
                        entry("new-\(pair)-b", days: 1, seconds: Double(-pair * 100 - 10))]
        }
        for (name, days) in [("week", 10), ("month", 40), ("old", 200)] {
            catalog += [entry("\(name)-a", days: days, favorite: true), entry("\(name)-b", days: days, seconds: -10)]
        }
        let result = PhotoCurationService.nearbyPriorityEntries(in: catalog, excluding: [],
            protectedIdentifiers: [], reviewDates: [:], now: now)
        XCTAssertEqual(Array(result.prefix(8).map(\.identifier)),
                       ["new-0-a", "new-0-b", "week-a", "week-b", "month-a", "month-b", "old-a", "old-b"])
        XCTAssertEqual(result.count, 16)
        XCTAssertEqual(Set(result.map(\.identifier)).count, 16)
        for pair in stride(from: 0, to: result.count, by: 2) {
            XCTAssertLessThanOrEqual(abs(result[pair].facts!.capturedAt!.timeIntervalSince(result[pair + 1].facts!.capturedAt!)), 30)
        }
    }

    func testContextNominationsIncludeThirtyDayScreensAndOnlyOneRecentExpiryOpportunity() {
        var catalog = (0..<12).map { entry("recent-\($0)", days: 1, seconds: Double(-$0), screenshot: true) }
        catalog += (0..<12).map { entry("week-\($0)", days: 10, seconds: Double(-$0), screenshot: true) }
        catalog += [entry("month-a", days: 40, screenshot: true), entry("month-b", days: 41, screenshot: true),
                    entry("old-a", days: 200, screenshot: true), entry("old-b", days: 201, screenshot: true)]
        let result = PhotoCurationService.contextPriorityEntries(in: catalog, excluding: [],
            protectedIdentifiers: [], reviewDates: [:], now: now)
        XCTAssertEqual(Array(result.prefix(4).map(\.identifier)), ["month-a", "week-0", "old-a", "recent-0"])
        XCTAssertEqual(result.count, 8)
        XCTAssertEqual(result.filter { $0.identifier.hasPrefix("recent-") }.count, 1)
        XCTAssertEqual(Set(result.map(\.identifier)).count, 8)
    }

    func testLargeContextCohortSpreadsItsFirstBudgetAcrossCaptureHistory() {
        let catalog = (0..<100).map { entry("old-\($0)", days: 200 + $0 * 5, screenshot: true) }
        let first = PhotoCurationService.contextPriorityEntries(in: catalog, excluding: [],
            protectedIdentifiers: [], reviewDates: [:], now: now, limit: 8)
        XCTAssertEqual(first.count, 8)
        XCTAssertEqual(Array(first.prefix(3).map(\.identifier)), ["old-0", "old-99", "old-50"],
                       "A large six-month-plus cohort must not repeatedly consume its budget on one neighboring capture period")
        let seen = Set(first.map(\.identifier))
        let next = PhotoCurationService.contextPriorityEntries(in: catalog, excluding: seen,
            protectedIdentifiers: [], reviewDates: [:], now: now, limit: 8)
        XCTAssertEqual(next.count, 8)
        XCTAssertTrue(seen.isDisjoint(with: next.map(\.identifier)))
        XCTAssertEqual(Set(next.map(\.identifier)).count, 8)
    }

    func testContextAgeBoundariesUseElapsedCalendarDaysIncludingLateCaptureTime() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        func boundary(_ id: String, days: Int) -> PhotoCurationService.ScanCatalogEntry {
            var value = entry(id, days: days, screenshot: true)
            value.facts = .init(capturedAt: calendar.date(byAdding: .day, value: -days, to: today)!.addingTimeInterval(22 * 3600),
                width: 100, height: 100, isScreenshot: true)
            return value
        }
        let catalog = [boundary("seven", days: 7), boundary("thirty", days: 30),
                       boundary("one-eighty", days: 180), boundary("recent", days: 1)]
        let result = PhotoCurationService.contextPriorityEntries(in: catalog, excluding: [],
            protectedIdentifiers: [], reviewDates: [:], now: now)
        XCTAssertEqual(result.map(\.identifier), ["thirty", "seven", "one-eighty", "recent"])
        let ordinary = catalog.map { value -> PhotoCurationService.ScanCatalogEntry in
            var copy = value; copy.facts!.isScreenshot = false; return copy
        }
        let olderOnly = PhotoCurationService.contextPriorityEntries(in: ordinary, excluding: [],
            protectedIdentifiers: [], reviewDates: [:], now: now, screenshots: false)
        XCTAssertEqual(olderOnly.map(\.identifier), ["thirty", "seven", "one-eighty"])
    }

    func testContextNominationNeverPromotesExcludedProtectedFutureOrUnknownMetadata() {
        let catalog = [entry("good", days: 40, screenshot: true), entry("visited", days: 40, screenshot: true),
            entry("protected", days: 40, screenshot: true), entry("favorite", days: 40, screenshot: true, favorite: true),
            entry("hidden", days: 40, screenshot: true, excluded: true), entry("future-review", days: 40, screenshot: true),
            entry("future-capture", days: -1, screenshot: true), entry("no-size", days: 40, screenshot: true, width: 0),
            .init(identifier: "unknown", assetIndex: 100), entry("good", days: 40, screenshot: true)]
        let result = PhotoCurationService.contextPriorityEntries(in: catalog, excluding: ["visited"],
            protectedIdentifiers: ["protected"], reviewDates: ["future-review": now.addingTimeInterval(86_400)], now: now)
        XCTAssertEqual(result.map(\.identifier), ["good"])
        XCTAssertTrue(PhotoCurationService.contextPriorityEntries(in: catalog, excluding: [],
            protectedIdentifiers: [], reviewDates: [:], now: now, limit: 0).isEmpty)
    }

    func testFairFillerDoesNotLoseCoverageOrReviveDeferredIdentifiers() {
        var catalog: [PhotoCurationService.ScanCatalogEntry] = []
        for days in [1, 10, 40, 200] {
            catalog += (0..<80).map { entry("age-\(days)-\($0)", days: days, seconds: Double(-$0 * 100)) }
        }
        let deferred: Set<String> = ["age-40-0"]
        let first = PhotoCurationService.scanWindow(in: catalog, excluding: [], deferred: deferred,
            reviewDates: [:], now: now)
        XCTAssertEqual(first.entries.count, 64)
        for days in [1, 10, 40, 200] {
            XCTAssertTrue(first.entries.contains { $0.identifier.hasPrefix("age-\(days)-") })
        }
        XCTAssertTrue(first.remaining.contains("age-40-0"))
        XCTAssertFalse(first.entries.contains { $0.identifier == "age-40-0" })
        var visited = Set(first.entries.map(\.identifier))
        while visited.count < catalog.count - deferred.count {
            let next = PhotoCurationService.scanWindow(in: catalog, excluding: visited, deferred: deferred,
                reviewDates: [:], now: now)
            XCTAssertFalse(next.entries.isEmpty)
            guard !next.entries.isEmpty else { return }
            for item in next.entries { XCTAssertTrue(visited.insert(item.identifier).inserted) }
        }
        XCTAssertEqual(visited.union(deferred), Set(catalog.map(\.identifier)))
        let recovery = PhotoCurationService.scanWindow(in: catalog, excluding: visited, deferred: deferred,
            reviewDates: [:], now: now)
        XCTAssertTrue(recovery.isRetryWindow)
        XCTAssertEqual(recovery.entries.map(\.identifier), ["age-40-0"])
    }
}


final class CurationDeferredEvidenceTests: XCTestCase {
    func testMissingReasonSearchGivesContextAndOriginalsSeparateFirstTurns() {
        var schedule = CurationMissingReasonSchedule()
        let turns = (0..<8).map { _ in schedule.prioritizesContext(excluding: [.similarCapture]) }
        XCTAssertEqual(turns, [true, false, true, false, true, false, true, false],
                       "A complete OCR budget must not starve every file-identity comparison")
        XCTAssertTrue(schedule.prioritizesContext(excluding: [.similarCapture, .identicalFile]))
        XCTAssertFalse(schedule.prioritizesContext(excluding: [.similarCapture, .contextReview]))
        XCTAssertFalse(schedule.prioritizesContext(excluding: []), "The first candidate keeps the local-file fast path")
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testSmallRealPreviewNominatesButCannotStandInForFullEvidence() {
        XCTAssertTrue(PhotoCurationService.usableNominationSize(width: 80, height: 60))
        XCTAssertFalse(PhotoCurationService.isAnalysisQualityPreview(width: 80, height: 60,
            originalWidth: 4032, originalHeight: 3024, degraded: true))
        XCTAssertFalse(PhotoCurationService.isAnalysisQualityPreview(width: 1024, height: 768,
            originalWidth: 4032, originalHeight: 3024, degraded: true))
        XCTAssertFalse(PhotoCurationService.isAnalysisQualityPreview(width: 384, height: 288,
            originalWidth: 4032, originalHeight: 3024, degraded: false))
        XCTAssertTrue(PhotoCurationService.isAnalysisQualityPreview(width: 1024, height: 768,
            originalWidth: 4032, originalHeight: 3024, degraded: false))
        XCTAssertTrue(PhotoCurationService.isAnalysisQualityPreview(width: 320, height: 240,
            originalWidth: 320, originalHeight: 240, degraded: false))
    }

    func testExplicitCloudOrPhotoErrorDoesNotRepeatSameLocalRead() {
        XCTAssertFalse(PhotoCurationService.shouldRetryLocalPreview(inCloud: true, failed: false, blocked: false, cancelled: false))
        XCTAssertFalse(PhotoCurationService.shouldRetryLocalPreview(inCloud: false, failed: true, blocked: false, cancelled: false))
        XCTAssertFalse(PhotoCurationService.shouldRetryLocalPreview(inCloud: false, failed: false, blocked: true, cancelled: false))
        XCTAssertFalse(PhotoCurationService.shouldRetryLocalPreview(inCloud: false, failed: false, blocked: false, cancelled: true))
        XCTAssertTrue(PhotoCurationService.shouldRetryLocalPreview(inCloud: false, failed: false, blocked: false, cancelled: false))
    }

    func testAcceptingSmallCallbackCancelsUnneededLargerRequestExactlyOnce() {
        var cancelled: [PHImageRequestID] = []
        let cancellation = expectation(description: "unneeded larger request cancelled")
        let result: Int? = PhotoCurationService.boundedPhotoRead(timeout: 0.1,
            cancel: { cancelled.append($0); cancellation.fulfill() }, cancelOnResult: true) { complete in
                complete(80); complete(1024); return 91
            }
        XCTAssertEqual(result, 80)
        wait(for: [cancellation], timeout: 1)
        XCTAssertEqual(cancelled, [91])
    }

    func testContextDeferralRemainsUnknownAndLaterCompatiblePeerForcesFullEvidence() {
        let young = now.addingTimeInterval(-2 * 86_400)
        XCTAssertEqual(PhotoCurationService.contextEnrichmentDemand(capturedAt: young, isScreenshot: false,
            hasReviewDate: false, requiresFeature: false, sharpness: 0.03, luminanceRange: 0.5,
            resumeDeferred: false, now: now), .deferUnknown)
        let unknownFacts = CurationContextPolicy.Facts(capturedAt: young)
        XCTAssertNil(unknownFacts.textLines)
        XCTAssertNil(CurationContextPolicy.evidence(for: unknownFacts, now: now))
        XCTAssertEqual(PhotoCurationService.contextEnrichmentDemand(capturedAt: young, isScreenshot: false,
            hasReviewDate: false, requiresFeature: true, sharpness: 0.03, luminanceRange: 0.5,
            resumeDeferred: false, now: now), .fullEvidence)
    }

    func testOlderUnpairedOrdinaryPhotoUsesScreeningThenCanResumeRealOCR() {
        let older = now.addingTimeInterval(-30 * 86_400)
        XCTAssertEqual(PhotoCurationService.contextEnrichmentDemand(capturedAt: older, isScreenshot: false,
            hasReviewDate: false, requiresFeature: false, sharpness: 0.03, luminanceRange: 0.5,
            resumeDeferred: false, now: now), .screenTextRegions)
        XCTAssertEqual(PhotoCurationService.contextEnrichmentDemand(capturedAt: older, isScreenshot: false,
            hasReviewDate: false, requiresFeature: false, sharpness: 0.03, luminanceRange: 0.5,
            resumeDeferred: true, now: now), .fullEvidence)
        XCTAssertEqual(PhotoCurationService.contextEnrichmentDemand(capturedAt: older, isScreenshot: false,
            hasReviewDate: false, requiresFeature: false, sharpness: 0.0008, luminanceRange: 0.06,
            resumeDeferred: false, now: now), .fullEvidence)
        XCTAssertEqual(PhotoCurationService.contextEnrichmentDemand(capturedAt: older, isScreenshot: true,
            hasReviewDate: false, requiresFeature: false, sharpness: 0.03, luminanceRange: 0.5,
            resumeDeferred: false, now: now), .fullEvidence)
    }

    func testParkedPartialWindowsRotateWithoutMarkingCoverageOrLosingColdMemory() throws {
        let a = CurationAnalysisMemory<Int, String>()
        a.record("partial-proof", for: "candidate", revision: 1, complete: false, failed: false)
        a.record("peer-proof", for: "reference", revision: 1, complete: true)
        var parked = CurationParkedWindows<CurationAnalysisMemory<Int, String>>()
        parked.park(identifiers: ["candidate", "reference"], value: a, freshTurn: true)
        let eligible: Set<String> = ["candidate", "reference", "fresh"]
        XCTAssertNil(parked.take(eligible: eligible, freshAvailable: true))
        parked.park(identifiers: ["fresh"], value: CurationAnalysisMemory(), freshTurn: true)
        let resumed = try XCTUnwrap(parked.take(eligible: eligible, freshAvailable: true))
        XCTAssertEqual(resumed.identifiers, ["candidate", "reference"])
        XCTAssertEqual(resumed.value.partials["candidate"]?.analysis, "partial-proof")
        XCTAssertEqual(resumed.value.entries["reference"]?.analysis, "peer-proof")
        XCTAssertTrue(resumed.value.failures.isEmpty)
        // The cache is in memory even with persistent disk proofs disabled.
        // Revisions and access are rechecked before any resumed proof is used.
        resumed.value.retain(revisions: ["candidate": 2])
        XCTAssertTrue(resumed.value.analyses.isEmpty)
    }

    func testProductiveParkedWindowImmediatelyKeepsOtherVerifiedPairAvailable() throws {
        var parked = CurationParkedWindows<CurationAnalysisMemory<Int, String>>()
        let facts = CurationAnalysisMemory<Int, String>()
        for id in ["first", "first-reference", "second", "second-reference"] {
            facts.record("verified-" + id, for: id, revision: 1, complete: true)
        }
        // The first candidate was published; its reference remains protected
        // and the other complete pair remains available on the next call.
        parked.park(identifiers: ["first-reference", "second", "second-reference"],
            value: facts, freshTurn: false, productive: true)
        let next = try XCTUnwrap(parked.take(eligible: ["first-reference", "second", "second-reference", "fresh"],
            freshAvailable: true))
        XCTAssertEqual(next.identifiers, ["first-reference", "second", "second-reference"])
        next.value.retain(revisions: ["first-reference": 1, "second": 1, "second-reference": 1])
        XCTAssertNil(next.value.analyses["first"])
        XCTAssertEqual(next.value.analyses["second"], "verified-second")
        XCTAssertEqual(next.value.analyses["second-reference"], "verified-second-reference")
    }

    func testParkedWindowsBoundMemoryAndResumeWhenNoFreshRowsRemain() throws {
        var parked = CurationParkedWindows<Int>(capacity: 3)
        for index in 0..<5 { parked.park(identifiers: ["\(index)", "peer\(index)"], value: index, freshTurn: false) }
        XCTAssertEqual(parked.windows.count, 3)
        let eligible: Set<String> = ["2", "peer2", "3", "peer3", "4", "peer4"]
        let resumed = try XCTUnwrap(parked.take(eligible: eligible, freshAvailable: false))
        XCTAssertEqual(resumed.value, 2)
        XCTAssertNil(parked.take(eligible: [], freshAvailable: false))
        XCTAssertTrue(parked.windows.isEmpty)
    }

    func testEvictedUnknownWindowResumesAfterTwoResidentTurnsWithoutFalseExhaustion() throws {
        var parked = CurationParkedWindows<CurationAnalysisMemory<Int, String>>(capacity: 3)
        for index in 0..<4 {
            let value = CurationAnalysisMemory<Int, String>()
            value.record("partial", for: "candidate\(index)", revision: 1, complete: false, failed: false)
            parked.park(identifiers: ["candidate\(index)", "reference\(index)"], value: value, freshTurn: false)
        }
        XCTAssertEqual(parked.windows.count, 3)
        XCTAssertEqual(parked.evictedIdentifiers, [["candidate0", "reference0"]])
        let eligible = Set((0..<4).flatMap { ["candidate\($0)", "reference\($0)"] })
        for index in 1..<3 {
            let resident = try XCTUnwrap(parked.take(eligible: eligible, freshAvailable: false,
                restoring: { XCTFail("The first two resident turns retain their memory cache"); return CurationAnalysisMemory() }))
            XCTAssertEqual(resident.identifiers, ["candidate\(index)", "reference\(index)"])
        }
        XCTAssertEqual(parked.windows.count, 1)
        XCTAssertTrue(parked.hasPendingWork, "Evicted unknown context must not make hasFresh false")
        var recreated = 0
        let evicted = try XCTUnwrap(parked.take(eligible: eligible, freshAvailable: false, restoring: {
            recreated += 1; return CurationAnalysisMemory()
        }))
        XCTAssertEqual(evicted.identifiers, ["candidate0", "reference0"])
        XCTAssertTrue(evicted.value.analyses.isEmpty, "No stale proof or image survives metadata-only eviction")
        XCTAssertEqual(recreated, 1)
        XCTAssertEqual(parked.take(eligible: eligible, freshAvailable: false)?.identifiers, ["candidate3", "reference3"])
        XCTAssertFalse(parked.hasPendingWork)
    }

    func testEvictedQueueDeduplicatesAndDropsFullyRevokedWindows() {
        var parked = CurationParkedWindows<Int>(capacity: 1)
        parked.park(identifiers: ["a", "peer-a"], value: 1, freshTurn: false)
        parked.park(identifiers: ["b", "peer-b"], value: 2, freshTurn: false)
        parked.park(identifiers: ["a", "peer-a"], value: 3, freshTurn: false)
        XCTAssertEqual(parked.evictedIdentifiers, [["b", "peer-b"]])
        XCTAssertEqual(parked.take(eligible: ["a", "peer-a"], freshAvailable: false)?.value, 3)
        XCTAssertFalse(parked.hasPendingWork)
    }

    func testCacheRotationAndCancellationDoNotManufactureOrRegressProgress() {
        var progress = CurationWorkProgress()
        progress.record(before: 32, after: 40)
        XCTAssertEqual(progress.value, 8)
        progress.record(before: 0, after: 8)
        XCTAssertEqual(progress.value, 16, "A new window has its own revision counter")
        progress.record(before: 40, after: 40)
        XCTAssertEqual(progress.value, 16, "A parked retry with no new work is not progress")
        progress.record(before: 8, after: 9, consumed: 1)
        XCTAssertEqual(progress.value, 18)
        var parked = CurationParkedWindows<Int>()
        parked.park(identifiers: ["a", "peer"], value: 9, freshTurn: false)
        let cancelledTurn = parked.take(eligible: ["a", "peer"], freshAvailable: false)!
        parked.park(identifiers: cancelledTurn.identifiers, value: cancelledTurn.value, freshTurn: false)
        XCTAssertEqual(parked.windows.count, 1)
        XCTAssertEqual(parked.freshTurns, 0)
        XCTAssertEqual(progress.value, 18)
    }
}


final class CurationEnrichmentFairnessTests: XCTestCase {
    func testUnfinishedOCRDoesNotBlockUntouchedLocalPeers() {
        let memory = CurationAnalysisMemory<Int, CurationAnalysisWorkState>()
        memory.record(CurationAnalysisWorkState(), for: "timed-out-context", revision: 1, complete: false, failed: false)
        memory.noteEnrichmentAttempt(for: "timed-out-context", revision: 1)
        let local = memory.nextPreviewWork(among: ["timed-out-context", "new-peer", "parking"], hasPendingEnrichment: true)
        XCTAssertEqual(local.identifiers, ["new-peer", "parking"])
        XCTAssertFalse(local.allowsNetwork)
    }

    func testTimedOutPairAndContextRotateBehindUntouchedEvidenceThenRetryFairly() {
        let memory = CurationAnalysisMemory<Int, String>()
        let ids = ["slow-pair", "second-peer", "parking", "ordinary"]
        memory.noteEnrichmentAttempt(for: "slow-pair", revision: 1)
        XCTAssertEqual(memory.enrichmentOrder(among: ids, priority: ["slow-pair", "second-peer"]),
                       ["second-peer", "parking", "ordinary", "slow-pair"])
        memory.noteEnrichmentAttempt(for: "second-peer", revision: 1)
        memory.noteEnrichmentAttempt(for: "parking", revision: 1)
        memory.noteEnrichmentAttempt(for: "ordinary", revision: 1)
        XCTAssertEqual(memory.enrichmentOrder(among: ids, priority: ["slow-pair", "second-peer"]), ids)
        memory.noteEnrichmentAttempt(for: "slow-pair", revision: 1)
        XCTAssertEqual(memory.enrichmentOrder(among: ids, priority: ["slow-pair", "second-peer"]),
                       ["second-peer", "parking", "ordinary", "slow-pair"])
        memory.retain(revisions: ["slow-pair": 2, "second-peer": 1, "parking": 1, "ordinary": 1])
        XCTAssertEqual(memory.enrichmentOrder(among: ids, priority: ["slow-pair", "second-peer"]).first, "slow-pair")
    }

    func testRepeatedUnknownHQReadDoesNotManufactureEvidenceProgressButRealOCRDoes() {
        let memory = CurationAnalysisMemory<Int, CurationAnalysisWorkState>()
        var state = CurationAnalysisWorkState()
        memory.record(state, for: "photo", revision: 1, complete: false, failed: false)
        state.fullPreview = true
        memory.record(state, for: "photo", revision: 1, complete: false, failed: false,
            advancesWork: memory.analyses["photo"] != state)
        let afterFirstHQ = memory.workRevision
        for _ in 0..<3 {
            memory.noteEnrichmentAttempt(for: "photo", revision: 1)
            memory.record(state, for: "photo", revision: 1, complete: false, failed: false,
                advancesWork: memory.analyses["photo"] != state)
        }
        XCTAssertEqual(memory.workRevision, afterFirstHQ)
        XCTAssertNil(memory.analyses["photo"]?.textLines)
        XCTAssertTrue(memory.entries.isEmpty)
        XCTAssertTrue(memory.failures.isEmpty)
        state.textLines = ["PARKING LEVEL 2"]
        state.confidentTextLines = state.textLines!
        state.hasFace = false
        state.enrichmentAttempted = true
        state.needsRetry = false
        memory.record(state, for: "photo", revision: 1, complete: true, failed: false,
            advancesWork: memory.analyses["photo"] != state)
        XCTAssertGreaterThan(memory.workRevision, afterFirstHQ)
        XCTAssertNotNil(memory.entries["photo"])
    }
}


final class CurationEvictedWindowFairnessTests: XCTestCase {
    func testRepeatedResidentTimeoutsCannotStarveEvictedCoherentPeerWindow() throws {
        var parked = CurationParkedWindows<CurationAnalysisMemory<Int, CurationAnalysisWorkState>>(capacity: 3)
        for index in 0..<4 {
            let memory = CurationAnalysisMemory<Int, CurationAnalysisWorkState>()
            memory.record(CurationAnalysisWorkState(fullPreview: true), for: "candidate\(index)", revision: 1,
                complete: false, failed: false)
            parked.park(identifiers: ["candidate\(index)", "reference\(index)"], value: memory, freshTurn: false)
        }
        let eligible = Set((0..<4).flatMap { ["candidate\($0)", "reference\($0)"] })
        var progress = CurationWorkProgress()
        for index in 1..<3 {
            let resident = try XCTUnwrap(parked.take(eligible: eligible, freshAvailable: false,
                restoring: { XCTFail("Metadata restoration must occur on the third turn"); return CurationAnalysisMemory() }))
            XCTAssertEqual(resident.identifiers, ["candidate\(index)", "reference\(index)"])
            let before = resident.value.workRevision
            resident.value.noteEnrichmentAttempt(for: "candidate\(index)", revision: 1)
            let sameUnknown = try XCTUnwrap(resident.value.analyses["candidate\(index)"])
            resident.value.record(sameUnknown, for: "candidate\(index)", revision: 1, complete: false,
                failed: false, advancesWork: false)
            progress.record(before: before, after: resident.value.workRevision)
            parked.park(identifiers: resident.identifiers, value: resident.value, freshTurn: false)
            XCTAssertEqual(parked.windows.count, 3)
        }
        let restored = try XCTUnwrap(parked.take(eligible: eligible, freshAvailable: false,
            restoring: { CurationAnalysisMemory() }))
        XCTAssertEqual(restored.identifiers, ["candidate0", "reference0"])
        XCTAssertTrue(restored.value.analyses.isEmpty)
        XCTAssertEqual(progress.value, 0, "Retry turns do not manufacture completed evidence")
    }

    func testProductiveContinuationPrecedesDueMetadataTurnThenOldestMetadataResumes() throws {
        var parked = CurationParkedWindows<Int>(capacity: 3)
        for index in 0..<4 { parked.park(identifiers: ["\(index)", "peer\(index)"], value: index, freshTurn: false) }
        let eligible = Set((0..<4).flatMap { ["\($0)", "peer\($0)"] })
        for _ in 0..<2 {
            let resident = try XCTUnwrap(parked.take(eligible: eligible, freshAvailable: false, restoring: { -1 }))
            parked.park(identifiers: resident.identifiers, value: resident.value, freshTurn: false)
        }
        parked.park(identifiers: ["2", "peer2"], value: 2, freshTurn: false, productive: true)
        XCTAssertEqual(parked.take(eligible: eligible, freshAvailable: false, restoring: { -1 })?.value, 2)
        XCTAssertEqual(parked.take(eligible: eligible, freshAvailable: false, restoring: { -1 })?.identifiers, ["0", "peer0"])
    }
}


final class CurationPreviewAndParkedFairnessTests: XCTestCase {
    func testDrainingProductiveWindowConsumesItsOnePriorityTurn() {
        var parked = CurationParkedWindows<Int>()
        var recovery = CurationPreviewRecoverySchedule()
        parked.park(identifiers: ["pair-a", "pair-b"], value: 1, freshTurn: false, productive: true)
        let ready = parked.selectWork(eligible: ["pair-a", "pair-b", "fresh"], freshAvailable: true,
            recoveryEligible: [], recoverySchedule: &recovery, ready: { $0 == 1 })
        XCTAssertNotNil(ready.parked)
        parked.park(identifiers: ["pair-a", "pair-b"], value: 2, freshTurn: false)
        let next = parked.selectWork(eligible: ["pair-a", "pair-b", "fresh"], freshAvailable: true,
            recoveryEligible: [], recoverySchedule: &recovery)
        XCTAssertNil(next.parked, "A drained negative remainder must not retain the previous result's priority")
        XCTAssertNil(next.recovery)
        XCTAssertTrue(parked.hasPendingWork, "Unknown comparisons stay available for later retry")
    }

    func testFinishedReadIsConsumedBeforeStartingAnotherCloudRetry() throws {
        var parked = CurationParkedWindows<Int>()
        let ids: Set<String> = ["unready", "ready", "cloud"]
        parked.park(identifiers: ["unready"], value: 1, freshTurn: false)
        parked.park(identifiers: ["ready"], value: 2, freshTurn: false)
        var recovery = CurationPreviewRecoverySchedule()
        recovery.register(window: ["cloud"], missing: ["cloud"])
        recovery.noteLocalProgress(); recovery.noteLocalProgress()
        let result = parked.selectWork(eligible: ids, freshAvailable: true,
            recoveryEligible: ids, recoverySchedule: &recovery, ready: { $0 == 2 })
        XCTAssertEqual(result.parked?.identifiers, ["ready"])
        XCTAssertNil(result.recovery)
        let next = parked.selectWork(eligible: ids, freshAvailable: true,
            recoveryEligible: ids, recoverySchedule: &recovery)
        XCTAssertEqual(next.recovery?.identifier, "cloud", "Using completed work must not discard pending recovery")
    }

    func testNewReasonGetsFreshTurnWithoutLosingProductiveFactsOrDueRecovery() throws {
        var parked = CurationParkedWindows<Int>()
        let ids: Set<String> = ["old-peer", "cloud-peer", "fresh-screen"]
        parked.park(identifiers: ["old-peer", "cloud-peer"], value: 7, freshTurn: false, productive: true)
        var recovery = CurationPreviewRecoverySchedule()
        recovery.register(window: ["old-peer", "cloud-peer"], missing: ["cloud-peer"])
        recovery.noteLocalProgress(); recovery.noteLocalProgress()
        let fresh = parked.selectWork(eligible: ids, freshAvailable: true,
            recoveryEligible: ids, recoverySchedule: &recovery, preferFreshReason: true)
        XCTAssertNil(fresh.parked)
        XCTAssertNil(fresh.recovery)
        XCTAssertEqual(parked.windows.first?.value, 7)
        let resumed = parked.selectWork(eligible: ids, freshAvailable: false,
            recoveryEligible: ids, recoverySchedule: &recovery, preferFreshReason: true)
        XCTAssertEqual(resumed.parked?.value, 7, "A small library still resumes its available proof")
        let due = parked.selectWork(eligible: ids, freshAvailable: false,
            recoveryEligible: ids, recoverySchedule: &recovery)
        XCTAssertEqual(due.recovery?.identifier, "cloud-peer")
    }

    func testVisibleHomeTriesFreshWindowsBeforeBoundedCloudRetryWithoutLosingIt() throws {
        var parked = CurationParkedWindows<Int>()
        var recovery = CurationPreviewRecoverySchedule()
        let ids = Set((0..<4).flatMap { ["local-\($0)", "missing-\($0)"] })
        for index in 0..<3 {
            let window = ["local-\(index)", "missing-\(index)"]
            parked.park(identifiers: window, value: index, freshTurn: true)
            recovery.register(window: window, missing: ["missing-\(index)"])
            recovery.noteLocalProgress()
            let next = parked.selectWork(eligible: ids, freshAvailable: true,
                recoveryEligible: ids, recoverySchedule: &recovery, freshPassesBeforeRetry: 4)
            XCTAssertNil(next.parked)
            XCTAssertNil(next.recovery, "An unresolved read must not preempt the next fresh candidate window")
        }
        // An exhausted small library must not wait for nonexistent fresh work.
        let immediate = parked.selectWork(eligible: ids, freshAvailable: false,
            recoveryEligible: ids, recoverySchedule: &recovery, freshPassesBeforeRetry: 4)
        XCTAssertEqual(immediate.recovery?.identifier, "missing-0")
        // Selecting is non-destructive; a cancelled turn remains due.
        recovery.noteLocalProgress()
        let due = parked.selectWork(eligible: ids, freshAvailable: true,
            recoveryEligible: ids, recoverySchedule: &recovery, freshPassesBeforeRetry: 4)
        XCTAssertEqual(due.recovery, immediate.recovery)
        XCTAssertTrue(parked.hasPendingWork)
        XCTAssertEqual(recovery.localPasses, 4)
    }

    func testDuePreviewRecoveryIsNotBlockedBySolePendingOCRWindow() throws {
        let memory = CurationAnalysisMemory<Int, String>()
        memory.record("unverified-peer", for: "local-peer", revision: 1, complete: false, failed: false)
        memory.deferPreview(for: "missing-peer", revision: 1)
        var parked = CurationParkedWindows<CurationAnalysisMemory<Int, String>>()
        let ids = ["local-peer", "missing-peer", "context"]
        parked.park(identifiers: ids, value: memory, freshTurn: false)
        var recovery = CurationPreviewRecoverySchedule()
        recovery.register(window: ids, missing: ["missing-peer"])
        recovery.noteLocalProgress(); recovery.noteLocalProgress()
        let selected = parked.selectWork(eligible: Set(ids), freshAvailable: false,
            recoveryEligible: ["missing-peer"], recoverySchedule: &recovery,
            restoring: { XCTFail("The resident cache should survive"); return CurationAnalysisMemory() })
        XCTAssertNil(selected.parked)
        let turn = try XCTUnwrap(selected.recovery)
        XCTAssertEqual(turn.identifier, "missing-peer")
        XCTAssertEqual(turn.window, ids)
        let retained = try XCTUnwrap(parked.takeMatching(turn.window))
        XCTAssertEqual(retained.partials["local-peer"]?.analysis, "unverified-peer")
        recovery.finished(turn)
        recovery.register(window: ids, missing: ["missing-peer"])
        XCTAssertNil(recovery.next(eligible: ["missing-peer"], localWorkAvailable: false),
                     "The same failed asset gets one interleaved attempt per session")
    }

    func testProductiveContinuationBypassesDueRecoveryOnlyOnceEvenIfProductiveAgain() throws {
        let ids = ["local-peer", "missing-peer", "second-pair"]
        var parked = CurationParkedWindows<Int>()
        parked.park(identifiers: ids, value: 7, freshTurn: false, productive: true)
        var recovery = CurationPreviewRecoverySchedule()
        recovery.register(window: ids, missing: ["missing-peer"])
        recovery.noteLocalProgress(); recovery.noteLocalProgress()
        let first = parked.selectWork(eligible: Set(ids), freshAvailable: true,
            recoveryEligible: ["missing-peer"], recoverySchedule: &recovery, restoring: { 0 })
        XCTAssertEqual(first.parked?.value, 7)
        XCTAssertNil(first.recovery)
        parked.park(identifiers: ids, value: 8, freshTurn: false, productive: true)
        let second = parked.selectWork(eligible: Set(ids), freshAvailable: true,
            recoveryEligible: ["missing-peer"], recoverySchedule: &recovery, restoring: { 0 })
        XCTAssertNil(second.parked)
        XCTAssertEqual(second.recovery?.identifier, "missing-peer")
        // Cancellation before finished() must leave the same bounded turn due.
        let retry = parked.selectWork(eligible: Set(ids), freshAvailable: true,
            recoveryEligible: ["missing-peer"], recoverySchedule: &recovery, restoring: { 0 })
        XCTAssertEqual(retry.recovery, second.recovery)
        XCTAssertEqual(parked.windows.count, 1)
    }
}


final class CurationConcurrentPreparationTests: XCTestCase {
    func testPreparationCanSupplyThreePairsWhileGivingContextItsFirstWave() {
        typealias Pair = PhotoCurationService.PairPreparationCandidate
        let pairs = (0..<3).map { Pair(identifiers: ["a\($0)", "b\($0)"],
            attemptOrders: [nil, nil], visualDifference: Double($0) * 0.01) }
        let plan = PhotoCurationService.fullPreparationIdentifiers(pairs: pairs,
            context: ["screen-a", "screen-b", "screen-c", "screen-d"])
        XCTAssertEqual(Array(plan.prefix(4)), ["a0", "b0", "screen-a", "screen-b"])
        XCTAssertTrue(Set(pairs.flatMap(\.identifiers)).isSubset(of: plan))
        XCTAssertEqual(plan.count, 8)
        XCTAssertEqual(Set(plan).count, 8)
    }

    func testNegativeFirstPairLeavesAnotherCompletePairAndContextInPreparedWindow() {
        typealias Pair = PhotoCurationService.PairPreparationCandidate
        let first = Pair(identifiers: ["first-a", "first-b"], attemptOrders: [nil, nil], visualDifference: 0.01)
        let alternative = Pair(identifiers: ["other-a", "other-b"], attemptOrders: [nil, nil], visualDifference: 0.02)
        let plan = PhotoCurationService.fullPreparationIdentifiers(pairs: [alternative, first],
            context: ["screen-a", "screen-b", "screen-c", "screen-d", "later"])
        XCTAssertEqual(Array(plan.prefix(2)), first.identifiers)
        XCTAssertTrue(Set(alternative.identifiers).isSubset(of: plan), "A first negative comparison must not force another serial read")
        XCTAssertTrue(Set(["screen-a", "screen-b", "screen-c", "screen-d"]).isSubset(of: plan))
        XCTAssertEqual(plan.count, 8)
    }

    func testPreparedLookaheadBoundsMemoryAndDoesNotSplitPairOrRepeatPhoto() {
        typealias Pair = PhotoCurationService.PairPreparationCandidate
        let pairs = (0..<8).map { Pair(identifiers: ["a\($0)", "b\($0)"],
            attemptOrders: [nil, nil], visualDifference: Double($0)) }
        let full = PhotoCurationService.fullPreparationIdentifiers(pairs: pairs, context: ["a0", "screen", "screen"], limit: 100)
        XCTAssertLessThanOrEqual(full.count, 12)
        XCTAssertEqual(Set(full).count, full.count)
        let short = PhotoCurationService.fullPreparationIdentifiers(pairs: pairs, context: [], limit: 1)
        XCTAssertTrue(short.isEmpty, "A lone comparison member cannot produce pair evidence")
        XCTAssertTrue(PhotoCurationService.fullPreparationIdentifiers(pairs: pairs, context: ["screen"], limit: 0).isEmpty)
    }

    func testWiderLookaheadKeepsTwoContextReadsWhileTryingMoreCompletePairs() {
        typealias Pair = PhotoCurationService.PairPreparationCandidate
        let pairs = (0..<5).map { Pair(identifiers: ["a\($0)", "b\($0)"],
            attemptOrders: [nil, nil], visualDifference: Double($0) * 0.01) }
        let plan = PhotoCurationService.fullPreparationIdentifiers(pairs: pairs,
            context: ["screen-a", "screen-b", "screen-c"], limit: 12)
        XCTAssertEqual(Array(plan.prefix(4)), ["a0", "b0", "screen-a", "screen-b"])
        XCTAssertTrue(Set(pairs.flatMap(\.identifiers)).isSubset(of: plan))
        XCTAssertEqual(plan.count, 12)
    }

    func testPreparedLookaheadReusesReadyPartnerForEveryMissingPeer() {
        typealias Pair = PhotoCurationService.PairPreparationCandidate
        let pairs = [
            Pair(identifiers: ["ready-reference", "new-a"], attemptOrders: [1, nil], visualDifference: 0.01),
            Pair(identifiers: ["ready-reference", "new-b"], attemptOrders: [1, nil], visualDifference: 0.02)
        ]
        let plan = PhotoCurationService.fullPreparationIdentifiers(pairs: pairs, context: [],
            alreadyPrepared: ["ready-reference"], limit: 2)
        XCTAssertEqual(plan, ["new-a", "new-b"], "A ready partner must not hide or reread either missing comparison member")
        let sharedNewPartner = PhotoCurationService.fullPreparationIdentifiers(pairs: pairs, context: [], limit: 3)
        XCTAssertEqual(sharedNewPartner, ["ready-reference", "new-a", "new-b"], "One prepared image can complete another nominated pair")
    }

    func testPromisingUntouchedPairPrecedesLooseNominationWithoutStarvingRetries() {
        typealias Pair = PhotoCurationService.PairPreparationCandidate
        let loose = Pair(identifiers: ["loose-a", "loose-b"], attemptOrders: [nil, nil], visualDifference: 0.07)
        let close = Pair(identifiers: ["close-a", "close-b"], attemptOrders: [nil, nil], visualDifference: 0.01)
        let invalid = Pair(identifiers: ["invalid-a", "invalid-b"], attemptOrders: [nil, nil], visualDifference: .nan)
        XCTAssertEqual(PhotoCurationService.preferredPreparationPair([loose, close, invalid]), close.identifiers)
        let attempted = Pair(identifiers: close.identifiers, attemptOrders: [10, 11], visualDifference: 0.01)
        XCTAssertEqual(PhotoCurationService.preferredPreparationPair([attempted, loose]), loose.identifiers)
        let earlierRetry = Pair(identifiers: loose.identifiers, attemptOrders: [1, 2], visualDifference: 0.07)
        XCTAssertEqual(PhotoCurationService.preferredPreparationPair([attempted, earlierRetry]), earlierRetry.identifiers)
        XCTAssertTrue(PhotoCurationService.preferredPreparationPair([invalid]).isEmpty)
    }

    func testCompleteLocalPairPrecedesCloudThumbnailsWithoutInventingEvidence() {
        typealias Pair = PhotoCurationService.PairPreparationCandidate
        let cloud = Pair(identifiers: ["cloud-a", "cloud-b"], attemptOrders: [nil, nil],
            visualDifference: 0.001, localPreviewCount: 0)
        let mixed = Pair(identifiers: ["local-a", "cloud-c"], attemptOrders: [nil, nil],
            visualDifference: 0.002, localPreviewCount: 1)
        let local = Pair(identifiers: ["local-b", "local-c"], attemptOrders: [nil, nil],
            visualDifference: 0.02, localPreviewCount: 2)
        XCTAssertEqual(PhotoCurationService.preferredPreparationPair([cloud, mixed, local]), local.identifiers)
        XCTAssertEqual(PhotoCurationService.preferredPreparationPair([cloud, mixed]), mixed.identifiers)
        XCTAssertEqual(PhotoCurationService.preferredPreparationPair([cloud]), cloud.identifiers,
            "Unavailable local previews change read order only; cloud recovery remains possible")
    }

    func testAvailabilityOnlyChangeKeepsEvidenceButContentAndSafetyMetadataInvalidateIt() {
        let before = CurationLibraryAssetRevision()
        XCTAssertFalse(before.requiresRefresh(after: before, contentChanged: false))
        XCTAssertTrue(before.requiresRefresh(after: before, contentChanged: true))
        XCTAssertTrue(before.requiresRefresh(after: nil, contentChanged: false))
        let changes: [(inout CurationLibraryAssetRevision) -> Void] = [
            { $0.favorite = true }, { $0.hidden = true }, { $0.adjusted = true },
            { $0.modifiedAt = Date(timeIntervalSince1970: 1) },
            { $0.capturedAt = Date(timeIntervalSince1970: 1) },
            { $0.width = 1024 }, { $0.height = 1024 }, { $0.subtypes = 1 },
            { $0.burstIdentifier = "changed-burst" }, { $0.latitude = 37 }, { $0.longitude = 127 }
        ]
        for change in changes {
            var after = before; change(&after)
            XCTAssertTrue(before.requiresRefresh(after: after, contentChanged: false))
        }
    }

    func testWorkerCountBurstDoesNotFloodHomePresentation() {
        let gate = CurationProgressPresentationGate()
        var accepted = 0
        for checked in 0...64 {
            if gate.accepts(.init(phase: .reading, checkedCount: checked,
                windowCount: 64, accessiblePhotoCount: 22_000)) { accepted += 1 }
        }
        XCTAssertEqual(accepted, 1)
        XCTAssertTrue(gate.accepts(.init(phase: .comparing, checkedCount: 64,
            windowCount: 64, accessiblePhotoCount: 22_000)))
        XCTAssertTrue(gate.accepts(.init(phase: .comparing, checkedCount: 64,
            windowCount: 64, accessiblePhotoCount: 22_001)))
    }

    func testUnrelatedLibraryNotificationDoesNotInvalidatePhotosButRealChangesDo() {
        XCTAssertFalse(CurationLibraryChangePolicy.requiresRefresh(relevantFetch: false,
            incremental: false, inserted: 0, removed: 0, changed: 0, moved: false))
        XCTAssertFalse(CurationLibraryChangePolicy.requiresRefresh(relevantFetch: true,
            incremental: true, inserted: 0, removed: 0, changed: 0, moved: false))
        for counts in [(1, 0, 0), (0, 1, 0), (0, 0, 1)] {
            XCTAssertTrue(CurationLibraryChangePolicy.requiresRefresh(relevantFetch: true,
                incremental: true, inserted: counts.0, removed: counts.1, changed: counts.2, moved: false))
        }
        XCTAssertTrue(CurationLibraryChangePolicy.requiresRefresh(relevantFetch: true,
            incremental: false, inserted: 0, removed: 0, changed: 0, moved: false))
        XCTAssertTrue(CurationLibraryChangePolicy.requiresRefresh(relevantFetch: true,
            incremental: true, inserted: 0, removed: 0, changed: 0, moved: true))
    }

    private final class Counter {
        private let lock = NSLock()
        private var active = 0
        private(set) var peak = 0
        private(set) var starts = 0
        func enter() { lock.lock(); active += 1; starts += 1; peak = max(peak, active); lock.unlock() }
        func leave() { lock.lock(); active -= 1; lock.unlock() }
        func snapshot() -> (peak: Int, starts: Int) { lock.lock(); defer { lock.unlock() }; return (peak, starts) }
    }

    func testLocalPreparationBoundsConcurrencyAndKeepsInputIdentity() {
        let counter = Counter()
        let deadline = PhotoCurationService.AnalysisDeadline(seconds: 2)
        let batch = CurationConcurrentPreparation<Int>(count: 16, concurrency: 8, deadline: deadline,
            itemTimeout: 0.08) { index, _, cancellation in
            counter.enter(); defer { counter.leave() }
            Thread.sleep(forTimeInterval: 0.01)
            return cancellation.isCancelled ? nil : index * 10
        }
        let result = batch.wait(until: deadline, forAll: true)
        batch.cancel()
        XCTAssertEqual(result.completed, Set(0..<16))
        XCTAssertEqual(result.values, Dictionary(uniqueKeysWithValues: (0..<16).map { ($0, $0 * 10) }))
        XCTAssertLessThanOrEqual(counter.snapshot().peak, 4)
        XCTAssertEqual(counter.snapshot().starts, 16)
    }

    func testSlowCloudReadsDoNotBlockLaterReadyEvidenceAndCPUStaysBounded() {
        let releaseCloud = DispatchSemaphore(value: 0)
        let cpu = CurationWorkGate(limit: 4)
        let counter = Counter()
        let deadline = PhotoCurationService.AnalysisDeadline(seconds: 2)
        let batch = CurationConcurrentPreparation<Int>(count: 12, concurrency: 12, maximumConcurrency: 12,
            deadline: deadline, itemTimeout: 2) { index, itemDeadline, cancellation in
            if index < 4 { _ = releaseCloud.wait(timeout: .now() + 1.5) }
            return cpu.perform(until: itemDeadline, cancelled: { cancellation.isCancelled }) {
                counter.enter(); defer { counter.leave() }
                Thread.sleep(forTimeInterval: 0.01)
                return index
            }
        }
        defer { batch.cancel(); for _ in 0..<4 { releaseCloud.signal() } }
        for index in 4..<12 {
            XCTAssertEqual(batch.wait(until: .init(seconds: 0.5), forAnyOf: [index]).values[index], index,
                "A later ready photo must be analyzed before the first four cloud reads finish")
        }
        XCTAssertTrue(Set(batch.snapshot().values.keys).isDisjoint(with: Set(0..<4)))
        XCTAssertLessThanOrEqual(counter.snapshot().peak, 4)
    }

    func testAnalysisPermitWaitHonorsCancellationAndDeadline() {
        let gate = CurationWorkGate(limit: 1)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let _: Int? = gate.perform(until: .init(seconds: 2), cancelled: { false }) {
                entered.signal(); _ = release.wait(timeout: .now() + 1); return 1
            }
            done.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        let blocked: Int? = gate.perform(until: .init(seconds: 0.04), cancelled: { false }) {
            XCTFail("A timed out waiter must not run analysis"); return 2
        }
        XCTAssertNil(blocked)
        let cancelled: Int? = gate.perform(until: .init(seconds: 1), cancelled: { true }) {
            XCTFail("A canceled waiter must not run analysis"); return 3
        }
        XCTAssertNil(cancelled)
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(gate.perform(until: .init(seconds: 1), cancelled: { false }) { 4 }, 4)
    }

    func testCanceledPreparationRejectsLateCompletion() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let returned = DispatchSemaphore(value: 0)
        let batch = CurationConcurrentPreparation<Int>(count: 1,
            deadline: .init(seconds: 2), itemTimeout: 1) { _, _, _ in
            entered.signal()
            _ = release.wait(timeout: .now() + 1)
            returned.signal()
            return 42
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        batch.cancel(); release.signal()
        XCTAssertEqual(returned.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(batch.snapshot().values.isEmpty)
        XCTAssertTrue(batch.snapshot().completed.isEmpty)
    }

    func testReadyFullPreviewIsUsedBeforeEarlierPendingPhoto() {
        let releaseFirst = DispatchSemaphore(value: 0)
        let batch = CurationConcurrentPreparation<Int>(count: 2,
            deadline: .init(seconds: 2), itemTimeout: 1) { index, _, _ in
            if index == 0 { _ = releaseFirst.wait(timeout: .now() + 1) }
            return index
        }
        let ready = batch.wait(until: .init(seconds: 0.5), forAll: false)
        XCTAssertNil(ready.values[0])
        XCTAssertEqual(ready.values[1], 1)
        let names = ["pending-first", "ready-second"]
        let readyNames = Set(ready.values.keys.map { names[$0] })
        XCTAssertEqual(PhotoCurationService.preparedEnrichmentIndex(in: names, ready: readyNames), 1)
        batch.cancel(); releaseFirst.signal()
    }

    func testWaitingForNextImageDoesNotReuseAnAlreadyConsumedReadyResult() {
        let releaseSecond = DispatchSemaphore(value: 0)
        let secondStarted = DispatchSemaphore(value: 0)
        let batch = CurationConcurrentPreparation<Int>(count: 2,
            deadline: .init(seconds: 2), itemTimeout: 1) { index, _, _ in
            if index == 1 {
                secondStarted.signal()
                _ = releaseSecond.wait(timeout: .now() + 1)
            }
            return index
        }
        XCTAssertEqual(secondStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(batch.wait(until: .init(seconds: 0.5), forAnyOf: [0]).values[0], 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { releaseSecond.signal() }
        let next = batch.wait(until: .init(seconds: 0.5), forAnyOf: [1])
        XCTAssertEqual(next.values[1], 1, "Consumed result 0 must not end the wait for image 1")
        batch.cancel()
    }

    func testFailedPreparedReadCompletesAsUnknownWithoutWaitingForUnrelatedWork() {
        let release = DispatchSemaphore(value: 0)
        let batch = CurationConcurrentPreparation<Int>(count: 2,
            deadline: .init(seconds: 2), itemTimeout: 1) { index, _, _ in
            if index == 0 { return nil }
            _ = release.wait(timeout: .now() + 1)
            return 42
        }
        let failed = batch.wait(until: .init(seconds: 0.5), forAnyOf: [0])
        XCTAssertTrue(failed.completed.contains(0))
        XCTAssertNil(failed.values[0])
        XCTAssertFalse(failed.completed.contains(1))
        batch.cancel(); release.signal()
    }

    func testWholeCandidateWindowCanPrepareBeforeSlowEvidenceWork() {
        let counter = Counter()
        let deadline = PhotoCurationService.AnalysisDeadline(seconds: 2)
        let batch = CurationConcurrentPreparation<Int>(count: 64, deadline: deadline,
            itemTimeout: 0.08) { index, _, _ in
            counter.enter(); defer { counter.leave() }
            Thread.sleep(forTimeInterval: 0.002)
            return index >= 32 ? index : nil
        }
        let result = batch.wait(until: deadline, forAll: true)
        batch.cancel()
        XCTAssertEqual(result.completed.count, 64)
        XCTAssertEqual(Set(result.values.keys), Set(32..<64), "Later local candidates must get a turn")
        XCTAssertLessThanOrEqual(counter.snapshot().peak, 4)
    }

    func testRetainedPreparedResourcesAreReleasedWhenAccessOrRevisionChanges() {
        final class PreparedResource {}
        let memory = CurationAnalysisMemory<Int, PreparedResource>()
        weak var prepared: PreparedResource?
        do {
            let value = PreparedResource()
            prepared = value
            memory.record(value, for: "photo", revision: 1, complete: false, failed: false)
        }
        XCTAssertNotNil(prepared)
        memory.retain(revisions: ["photo": 2])
        XCTAssertNil(prepared, "Changed photo evidence must release its retained image")
        do {
            let value = PreparedResource()
            prepared = value
            memory.record(value, for: "photo", revision: 2, complete: false, failed: false)
        }
        memory.retain(revisions: [:])
        XCTAssertNil(prepared, "Revoked photo access must release its retained image")
        do {
            let value = PreparedResource()
            prepared = value
            memory.record(value, for: "photo", revision: 2, complete: false, failed: false)
        }
        memory.reset()
        XCTAssertNil(prepared)
    }

    func testOnlyCompleteFullQualityEvidenceMaySkipImageReload() {
        XCTAssertTrue(PhotoCurationService.evidenceIsComplete(fullPreview: true, textKnown: true,
            facesKnown: true, requiresFeature: true, hasFeature: true))
        XCTAssertFalse(PhotoCurationService.evidenceIsComplete(fullPreview: false, textKnown: true,
            facesKnown: true, requiresFeature: true, hasFeature: true))
        XCTAssertFalse(PhotoCurationService.evidenceIsComplete(fullPreview: true, textKnown: false,
            facesKnown: true, requiresFeature: true, hasFeature: true))
        XCTAssertFalse(PhotoCurationService.evidenceIsComplete(fullPreview: true, textKnown: true,
            facesKnown: true, requiresFeature: true, hasFeature: false))
        XCTAssertTrue(PhotoCurationService.evidenceIsComplete(fullPreview: true, textKnown: true,
            facesKnown: true, requiresFeature: false, hasFeature: false))
    }

    func testModelPreparationStartsOnceAndRealWorkJoinsItsSingleOwner() {
        let counter = Counter()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let once = CurationOncePreparation()
        once.start { _, _ in
            counter.enter(); defer { counter.leave() }
            entered.signal(); _ = release.wait(timeout: .now() + 1)
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        once.start { _, _ in XCTFail("A second preparation must not start") }
        release.signal()
        XCTAssertTrue(once.awaitCompletion(until: .init(seconds: 1)))
        XCTAssertEqual(counter.snapshot().starts, 1)
    }

    func testModelWaiterDeadlineDoesNotCancelSharedPreparationButExplicitStopDoes() {
        let entered = DispatchSemaphore(value: 0)
        let cancelled = DispatchSemaphore(value: 0)
        let once = CurationOncePreparation()
        once.start { _, cancellation in
            cancellation.setHandler { cancelled.signal() }
            entered.signal()
            while !cancellation.isCancelled { Thread.sleep(forTimeInterval: 0.005) }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(once.awaitCompletion(until: .init(seconds: 0.01)))
        XCTAssertEqual(cancelled.wait(timeout: .now() + 0.02), .timedOut)
        once.cancel()
        XCTAssertEqual(cancelled.wait(timeout: .now() + 1), .success)
    }

    func testPreparedReadSurvivesShortSliceAndIsConsumedWithoutAnotherRead() {
        let release = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let pool = CurationConcurrentPreparation<String>(count: 1, deadline: .init(seconds: 1), itemTimeout: 1) { _, _, cancellation in
            entered.signal(); _ = release.wait(timeout: .now() + 1)
            return cancellation.isCancelled ? nil : "verified"
        }
        let memory = CurationAnalysisMemory<Int, String>()
        memory.preparation = CurationWindowPreparation(identifiers: ["photo"], revisions: ["photo": 1],
            inputs: ["pending"], pool: pool)
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(pool.wait(until: .init(seconds: 0.01), forAll: true).values.isEmpty)
        memory.retain(revisions: ["photo": 1])
        release.signal()
        XCTAssertEqual(pool.wait(until: .init(seconds: 1), forAll: true).values[0], "verified")
        XCTAssertTrue(memory.preparation?.hasReadyResult == true)
        pool.discardValues(at: [0])
        XCTAssertFalse(memory.preparation?.hasReadyResult == true)
        XCTAssertTrue(memory.preparation?.isFinished == true)
    }

    func testRevisionChangeCancelsPreparedReadBeforeItCanPublishStaleValue() {
        let release = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let cancelled = DispatchSemaphore(value: 0)
        let pool = CurationConcurrentPreparation<String>(count: 1, deadline: .init(seconds: 1), itemTimeout: 1) { _, _, cancellation in
            cancellation.setHandler { cancelled.signal(); release.signal() }
            entered.signal(); _ = release.wait(timeout: .now() + 1)
            return "old-proof"
        }
        let memory = CurationAnalysisMemory<Int, String>()
        memory.preparation = CurationWindowPreparation(identifiers: ["photo"], revisions: ["photo": 1],
            inputs: ["pending"], pool: pool)
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        memory.retain(revisions: ["photo": 2])
        XCTAssertEqual(cancelled.wait(timeout: .now() + 1), .success)
        XCTAssertNil(memory.preparation)
        XCTAssertTrue(pool.snapshot().values.isEmpty)
    }
}
final class CurationReadDeadlineRegressionTests: XCTestCase {
    func testDegradedTerminalErrorFinishesWithoutWaitingForReadDeadline() {
        let began = ProcessInfo.processInfo.systemUptime
        let result: String? = PhotoCurationService.boundedPhotoRead(timeout: 1,
            cancel: { _ in }, request: { complete in
                let action = PhotoCurationService.analysisCallbackAction(degraded: true,
                    failed: true, cancelled: false, hasImage: false)
                if action == .unavailable { complete(nil) }
                return 80
            })
        XCTAssertNil(result)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 0.5,
            "A terminal PhotoKit error must not occupy the whole first-photo read allowance")
    }

    func testDegradedImageStillWaitsForRealAnalysisImage() {
        let result: String? = PhotoCurationService.boundedPhotoRead(timeout: 1,
            cancel: { _ in }, request: { complete in
                if PhotoCurationService.analysisCallbackAction(degraded: true,
                    failed: false, cancelled: false, hasImage: true) == .accept { complete("coarse") }
                if PhotoCurationService.analysisCallbackAction(degraded: false,
                    failed: false, cancelled: false, hasImage: true) == .accept { complete("full") }
                return 81
            })
        XCTAssertEqual(result, "full", "Faster error handling cannot make a coarse image analysis evidence")
    }

    func testSlowRequestCreationIsIncludedInDeadlineAndLateIdentifierIsCancelled() {
        let cancelled = expectation(description: "late PhotoKit request is cancelled")
        let started = ProcessInfo.processInfo.systemUptime
        let result: Int? = PhotoCurationService.boundedPhotoRead(timeout: 0.05, cancel: { id in
            XCTAssertEqual(id, 941); cancelled.fulfill()
        }) { complete in
            Thread.sleep(forTimeInterval: 0.5)
            complete(7)
            return 941
        }
        XCTAssertNil(result, "A result delivered after the deadline must not become evidence")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.3)
        wait(for: [cancelled], timeout: 2)
    }

    func testSlowCancellationDoesNotDelayReadyPreviewOrFollowingRead() {
        let cancelled = expectation(description: "slow cancellation eventually finishes")
        let started = ProcessInfo.processInfo.systemUptime
        let result: Int? = PhotoCurationService.boundedPhotoRead(timeout: 0.05, cancel: { id in
            XCTAssertEqual(id, 942)
            Thread.sleep(forTimeInterval: 0.5)
            cancelled.fulfill()
        }, cancelOnResult: true) { complete in complete(8); return 942 }
        XCTAssertEqual(result, 8)
        let next: Int? = PhotoCurationService.boundedPhotoRead(timeout: 0.1,
            cancel: { _ in }) { complete in complete(9); return 943 }
        XCTAssertEqual(next, 9)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.3)
        wait(for: [cancelled], timeout: 2)
    }
}

final class CurationContextNominationCacheTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func proof(complete: Bool = true, lines: [String] = ["주차 위치"])
        -> PhotoCurationService.ContextProofNomination {
        .init(textLines: lines, confidentTextLines: lines, hasFace: false,
              detail: 0.1, luminanceRange: 0.5, contextComplete: complete)
    }

    private var captured: Date { now.addingTimeInterval(-40 * 86_400) }
    private var revision: String { "1|\(captured.timeIntervalSince1970)|100|100|4|false|false|false" }
    private var entry: PhotoCurationService.ScanCatalogEntry {
        .init(identifier: "known-context", assetIndex: 200,
              facts: .init(capturedAt: captured, width: 100, height: 100, isScreenshot: true))
    }

    func testProjectionReadsOnlyRequestedFieldsAndRejectsWrongSchema() throws {
        struct Full: Codable { let contextComplete: Bool; let ignoredImageMetrics: [Double] }
        struct Small: Decodable { let contextComplete: Bool }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let cache = CurationDiskProofCache<Full>(directory: directory, version: 1)
        cache.store(Full(contextComplete: true, ignoredImageMetrics: Array(repeating: 0.5, count: 6912)),
                    for: "private-id", revision: "current")
        let values = cache.projectedValues(as: Small.self)
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first?.revision, "current")
        XCTAssertEqual(values.first?.value.contextComplete, true)
        XCTAssertTrue(CurationDiskProofCache<Full>(directory: directory, version: 2)
            .projectedValues(as: Small.self).isEmpty)
    }

    func testVerifiedContextGetsFirstNominationWithoutCreatingDecision() {
        let hints = PhotoCurationService.cachedContextNominationIdentifiers(in: [entry],
            proofs: [(revision, proof())], now: now)
        XCTAssertEqual(hints, [entry.identifier])
        let ordinary = (0..<100).map { index in
            PhotoCurationService.ScanCatalogEntry(identifier: "ordinary-\(index)", assetIndex: index,
                facts: .init(capturedAt: now.addingTimeInterval(Double(-index * 100)), width: 200, height: 200))
        }
        let window = PhotoCurationService.scanWindow(in: ordinary + [entry], excluding: [], deferred: [],
            reviewDates: [:], now: now, cachedContextIdentifiers: hints)
        XCTAssertEqual(window.entries.first?.identifier, entry.identifier)
        XCTAssertEqual(window.nominationCounts["cachedContextNomineePhotos"], 1)
        XCTAssertEqual(window.entries.count, 64)
    }

    func testIncompleteProtectedOrUnmatchedCachedEvidenceCannotNominate() {
        for value in [proof(complete: false), proof(lines: ["영수증 주차 위치"]), proof(lines: [])] {
            XCTAssertTrue(PhotoCurationService.cachedContextNominationIdentifiers(in: [entry],
                proofs: [(revision, value)], now: now).isEmpty)
        }
        XCTAssertTrue(PhotoCurationService.cachedContextNominationIdentifiers(in: [entry],
            proofs: [("invalid-revision", proof())], now: now).isEmpty)
        var changed = entry.facts!; changed.isFavorite = true
        let favorite = PhotoCurationService.ScanCatalogEntry(identifier: entry.identifier, assetIndex: 200, facts: changed)
        XCTAssertTrue(PhotoCurationService.cachedContextNominationIdentifiers(in: [favorite],
            proofs: [(revision, proof())], now: now).isEmpty)
    }

    func testHintCannotBypassCurrentProtectionReviewDateOrEvidenceExclusion() {
        func window(protected: Set<String> = [], dates: [String: Date] = [:],
                    groups: Set<CleanupReasonGroup> = [], visited: Set<String> = []) -> PhotoCurationService.ScanWindow {
            PhotoCurationService.scanWindow(in: [entry], excluding: visited, deferred: [],
                protectedIdentifiers: protected, reviewDates: dates, now: now,
                excludingReasonGroups: groups, cachedContextIdentifiers: [entry.identifier])
        }
        XCTAssertEqual(window(protected: [entry.identifier]).nominationCounts["cachedContextNomineePhotos"], 0)
        XCTAssertEqual(window(dates: [entry.identifier: now.addingTimeInterval(86_400)])
            .nominationCounts["cachedContextNomineePhotos"], 0)
        XCTAssertEqual(window(groups: [.contextReview]).nominationCounts["cachedContextNomineePhotos"], 0)
        XCTAssertTrue(window(visited: [entry.identifier]).entries.isEmpty)
    }
}

final class CurationActiveProofRetentionTests: XCTestCase {
    func testBackgroundAnalysisDoesNotEvictDisplayedCandidateOrItsComparison() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let cache = CurationDiskProofCache<String>(directory: directory, version: 1, capacity: 3)
        cache.store("candidate proof", for: "displayed", revision: "unchanged")
        cache.store("comparison proof", for: "comparison", revision: "unchanged")
        cache.retainIdentifiers(["displayed", "comparison"])
        for index in 0..<12 {
            cache.store("unshown analysis", for: "background-\(index)", revision: "unchanged")
        }
        let restarted = CurationDiskProofCache<String>(directory: directory, version: 1, capacity: 3)
        XCTAssertEqual(restarted.value(for: "displayed", revision: "unchanged"), "candidate proof")
        XCTAssertEqual(restarted.value(for: "comparison", revision: "unchanged"), "comparison proof")
        XCTAssertNil(restarted.value(for: "displayed", revision: "edited"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil).filter { $0.pathExtension == "proof" }.count, 3)
    }

    func testChangingRetainedSetAllowsOldQueueEvictionAndStillBoundsTheCache() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let cache = CurationDiskProofCache<String>(directory: directory, version: 1, capacity: 2)
        cache.store("old", for: "old-photo", revision: "same")
        cache.retainIdentifiers(["old-photo"])
        for index in 0..<5 { cache.store("new", for: "new-\(index)", revision: "same") }
        XCTAssertEqual(cache.value(for: "old-photo", revision: "same"), "old")
        cache.retainIdentifiers(["new-4"])
        for index in 0..<5 { cache.store("later", for: "later-\(index)", revision: "same") }
        XCTAssertNil(cache.value(for: "old-photo", revision: "same"))
        XCTAssertEqual(cache.value(for: "new-4", revision: "same"), "new")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil).filter { $0.pathExtension == "proof" }.count, 2)
    }
}
