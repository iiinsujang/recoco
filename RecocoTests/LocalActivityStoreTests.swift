import XCTest
import UIKit
import Photos
import Vision
import UserNotifications
import AuthenticationServices
@testable import Recoco

final class LocalActivityStoreTests: XCTestCase {
    private func preparedPhoto(_ id: String, reference: String? = nil,
                               reason: CurationReasonCode = .exactDuplicate) -> DecisionUnit {
        DecisionUnit(id: UUID(), type: .cleanupSingle, status: .pending,
            candidateLocalIdentifiers: [id], recommendedLocalIdentifier: id,
            reasonCodes: [reason], capturedDateDescription: nil, createdAt: Date(),
            comparisonLocalIdentifier: reason == .expiredScreen ? nil : reference ?? "kept-\(id)")
    }

    @MainActor
    func testUnseenPreparedPhotosSurviveNextDayWithoutExposureOrActivity() throws {
        let context = makeContext()
        let photos = [preparedPhoto("one"), preparedPhoto("two", reason: .visuallySimilar),
                      preparedPhoto("three", reason: .expiredScreen)]
        context.store.savePreparedRecommendations(photos, excluding: [])
        XCTAssertTrue(context.store.dailySessionProgress().curatedPhotoIdentifiers.isEmpty)
        XCTAssertTrue(context.store.recommendationExcludedIdentifiers().isEmpty)
        XCTAssertTrue(context.store.scannedPhotoIdentifiers().isEmpty)
        XCTAssertEqual(context.store.weeklySnapshot().deletedPhotoCount, 0)

        context.date.value = context.calendar.date(byAdding: .day, value: 1, to: context.date.value)!
        let reopened = LocalActivityStore(defaults: context.defaults, calendar: context.calendar, now: { context.date.value })
        XCTAssertEqual(reopened.preparedRecommendations()?.photoIdentifiers, ["one", "two", "three"])
        XCTAssertTrue(reopened.recommendationExcludedIdentifiers().isEmpty)
        reopened.removePreparedRecommendations(["one"])
        XCTAssertEqual(reopened.preparedRecommendations()?.photoIdentifiers, ["two", "three"])
        XCTAssertNil(reopened.preparedRecommendations()?.comparisonReferences["one"])
        XCTAssertTrue(reopened.recommendationExcludedIdentifiers().isEmpty)
    }

    @MainActor
    func testPreparedPhotosAreBoundedExpireAndKeepReferenceSafe() throws {
        let context = makeContext()
        context.store.savePreparedRecommendations([preparedPhoto("first", reference: "keep-first")], excluding: [])
        context.store.savePreparedRecommendations([preparedPhoto("keep-first"), preparedPhoto("points-to-first", reference: "first")]
            + (1...8).map { preparedPhoto("future-\($0)") }, excluding: ["future-3"])
        let prepared = try XCTUnwrap(context.store.preparedRecommendations())
        XCTAssertEqual(prepared.photoIdentifiers.count, 6)
        XCTAssertFalse(prepared.photoIdentifiers.contains("keep-first"))
        XCTAssertFalse(prepared.photoIdentifiers.contains("points-to-first"))
        XCTAssertFalse(prepared.photoIdentifiers.contains("future-3"))
        context.date.value = context.calendar.date(byAdding: .day, value: 7, to: context.date.value)!
        XCTAssertNil(context.store.preparedRecommendations())
        XCTAssertTrue(context.store.recommendationExcludedIdentifiers().isEmpty)
    }

    @MainActor
    func testMidnightCarriesOnlyCheckedPendingPhotosWithoutRenewingExposureOrMovingOldActions() throws {
        let context = makeContext()
        let originalDate = context.date.value
        context.store.beginDailySession(photoIdentifiers: ["done", "checked", "unchecked"],
            comparisonReferences: ["checked": "keep-checked"],
            curationReasons: ["done": .exactDuplicate, "checked": .visuallySimilar, "unchecked": .expiredScreen])
        context.store.recordDailyDecision(decisionKey: "done", deletedPhotoCount: 1, savedRecord: false)
        context.date.value = context.calendar.date(byAdding: .day, value: 1, to: originalDate)!
        context.store.carrySelectedRecommendationsToCurrentDay(["done", "checked", "not-in-queue"])
        let session = context.store.dailySessionProgress()
        XCTAssertEqual(session.curatedPhotoIdentifiers, ["checked"])
        XCTAssertEqual(session.comparisonReferences, ["checked": "keep-checked"])
        XCTAssertEqual(session.curationReasons, ["checked": .visuallySimilar])
        XCTAssertTrue(session.processedDecisionKeys.isEmpty)
        XCTAssertEqual(session.deletedPhotoCount, 0)
        XCTAssertEqual(context.store.weeklySnapshot().deletedPhotoCount, 1)
        XCTAssertNil(context.store.todaySummary())
        let historyData = try XCTUnwrap(context.defaults.data(forKey: UserScopedStorage.key("recoco_recommendation_history_v1")))
        let history = try JSONDecoder().decode([String: Date].self, from: historyData)
        XCTAssertEqual(history["checked"], originalDate)
        context.store.carrySelectedRecommendationsToCurrentDay(["checked"])
        XCTAssertEqual(context.store.weeklySnapshot().deletedPhotoCount, 1, "Repeated foreground entry must not replay yesterday's deletion")
    }

    @MainActor
    func testAppendingRecommendationPreservesExistingSessionAndCounts() throws {
        let context = makeContext()
        let store = context.store
        store.beginDailySession(photoIdentifiers: ["done", "pending"],
            comparisonReferences: ["done": "kept-done", "pending": "kept-pending"],
            curationReasons: ["done": .exactDuplicate, "pending": .visuallySimilar])
        store.recordDailyDecision(decisionKey: "done", deletedPhotoCount: 1, savedRecord: true)
        let token = try XCTUnwrap(store.recommendationAppendToken())
        let key = UserScopedStorage.key("recoco_daily_session_v1")
        var before = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(context.defaults.data(forKey: key))) as? [String: Any])
        let activityBefore = store.weeklySnapshot()

        XCTAssertTrue(store.appendRecommendations(photoIdentifiers: ["added"], comparisonReferences: ["added": "kept-added"],
            curationReasons: ["added": .exactDuplicate], matching: token))

        let session = store.dailySessionProgress()
        XCTAssertEqual(session.curatedPhotoIdentifiers, ["done", "pending", "added"])
        XCTAssertEqual(session.processedDecisionKeys, ["done"])
        XCTAssertEqual(session.deletedPhotoCount, 1)
        XCTAssertEqual(session.savedRecordCount, 1)
        XCTAssertEqual(session.comparisonReferences, ["done": "kept-done", "pending": "kept-pending", "added": "kept-added"])
        XCTAssertEqual(store.weeklySnapshot().savedRecordCount, activityBefore.savedRecordCount)
        XCTAssertEqual(store.weeklySnapshot().deletedPhotoCount, activityBefore.deletedPhotoCount)
        var after = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(context.defaults.data(forKey: key))) as? [String: Any])
        for changed in ["curatedPhotoIdentifiers", "comparisonReferences", "curationReasons"] {
            before.removeValue(forKey: changed); after.removeValue(forKey: changed)
        }
        XCTAssertEqual(before as NSDictionary, after as NSDictionary, "Session identity, date and all counters must be unchanged")
        XCTAssertFalse(store.matchesRecommendationAppendToken(token))
    }

    @MainActor
    func testDiversityReplacementPreservesCompletedCountsAndRejectsStaleOrPinnedChanges() throws {
        let context = makeContext()
        let store = context.store
        store.beginDailySession(photoIdentifiers: ["done", "checked", "other"],
            comparisonReferences: ["done": "keep-done", "checked": "kept-checked", "other": "kept-other"],
            curationReasons: ["done": .exactDuplicate, "checked": .visuallySimilar, "other": .visuallySimilar])
        store.recordDailyDecision(decisionKey: "done", deletedPhotoCount: 1, savedRecord: true)
        let token = try XCTUnwrap(store.recommendationAppendToken())
        let checked = preparedPhoto("checked", reason: .visuallySimilar)
        let other = preparedPhoto("other", reason: .visuallySimilar)
        let new = preparedPhoto("context", reason: .expiredScreen)
        XCTAssertFalse(store.diversifyPendingRecommendations([other, new], preserving: ["checked"], matching: token))
        XCTAssertTrue(store.diversifyPendingRecommendations([checked, new], preserving: ["checked"], matching: token))
        XCTAssertFalse(store.diversifyPendingRecommendations([checked, new], preserving: [], matching: token))
        let session = store.dailySessionProgress()
        XCTAssertEqual(session.curatedPhotoIdentifiers, ["done", "checked", "context"])
        XCTAssertEqual(session.processedDecisionKeys, ["done"])
        XCTAssertEqual(session.deletedPhotoCount, 1)
        XCTAssertEqual(session.savedRecordCount, 1)
        XCTAssertEqual(session.comparisonReferences["checked"], "kept-checked")
        XCTAssertEqual(session.curationReasons["checked"], .visuallySimilar)
        XCTAssertTrue(store.recommendationExcludedIdentifiers().isSuperset(of: ["done", "checked", "other", "context"]))
        XCTAssertEqual(store.weeklySnapshot().deletedPhotoCount, 1)
    }

    @MainActor
    func testAppendingRejectsChangedDaySessionProcessedChoiceOrQueue() throws {
        for change in ["day", "session", "processed", "queue"] {
            let context = makeContext()
            let store = context.store
            store.beginDailySession(photoIdentifiers: ["first", "second"],
                curationReasons: ["first": .exactDuplicate, "second": .exactDuplicate])
            let token = try XCTUnwrap(store.recommendationAppendToken())
            let key = UserScopedStorage.key("recoco_daily_session_v1")
            switch change {
            case "day": context.date.value = context.date.value.addingTimeInterval(86400)
            case "session":
                store.recordCompletion(deletedPhotoCount: 0, savedRecordCount: 0)
                store.beginDailySession(photoIdentifiers: ["replacement"])
            case "processed": store.recordDailyDecision(decisionKey: "first", deletedPhotoCount: 0, savedRecord: false)
            default:
                var value = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(context.defaults.data(forKey: key))) as? [String: Any])
                value["curatedPhotoIdentifiers"] = ["second", "first"]
                context.defaults.set(try JSONSerialization.data(withJSONObject: value), forKey: key)
            }
            let before = context.defaults.data(forKey: key)
            XCTAssertFalse(store.appendRecommendations(photoIdentifiers: ["late"], comparisonReferences: ["late": "kept"],
                curationReasons: ["late": .exactDuplicate], matching: token), change)
            XCTAssertEqual(context.defaults.data(forKey: key), before, change)
        }
    }

    @MainActor
    func testAppendingRejectsConflictingReferenceAndExcessQuantity() throws {
        let context = makeContext()
        let store = context.store
        store.beginDailySession(photoIdentifiers: ["one", "two"], comparisonReferences: ["one": "kept-one"],
            curationReasons: ["one": .exactDuplicate, "two": .exactDuplicate])
        let token = try XCTUnwrap(store.recommendationAppendToken())
        XCTAssertFalse(store.appendRecommendations(photoIdentifiers: ["kept-one"], comparisonReferences: ["kept-one": "kept-other"],
            curationReasons: ["kept-one": .exactDuplicate], matching: token))
        XCTAssertFalse(store.appendRecommendations(photoIdentifiers: ["three"], comparisonReferences: ["three": "one"],
            curationReasons: ["three": .exactDuplicate], matching: token))
        XCTAssertFalse(store.appendRecommendations(photoIdentifiers: ["three", "four"], comparisonReferences: [:],
            curationReasons: ["three": .reviewDateReached, "four": .reviewDateReached], matching: token))
        XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, ["one", "two"])
    }

    @MainActor
    func testReviewedPhotosSurviveCompletionRelaunchAndScanScopeReset() {
        let context = makeContext()
        context.store.beginDailySession(photoIdentifiers: ["reviewed-a", "reviewed-b"])
        context.store.recordDailyDecision(decisionKey: "reviewed-a", deletedPhotoCount: 0, savedRecord: true)
        context.store.recordDailyDecision(decisionKey: "reviewed-b", deletedPhotoCount: 0, savedRecord: false)
        context.store.recordScannedPhotos(["reviewed-a", "only-scanned"])
        context.store.recordCompletion(deletedPhotoCount: 0, savedRecordCount: 1)
        context.store.resetScannedPhotos()

        let reopened = LocalActivityStore(defaults: context.defaults, calendar: context.calendar, now: { context.date.value })

        XCTAssertTrue(reopened.dailySessionProgress().curatedPhotoIdentifiers.isEmpty)
        XCTAssertTrue(reopened.scannedPhotoIdentifiers().isEmpty)
        XCTAssertEqual(reopened.reviewedPhotoIdentifiers(), ["reviewed-a", "reviewed-b"])
        XCTAssertFalse(reopened.reviewedPhotoIdentifiers().contains("only-scanned"))
        XCTAssertEqual(reopened.todaySummary()?.savedRecordCount, 1)
        XCTAssertEqual(reopened.todaySummary()?.deletedPhotoCount, 0)
    }

    @MainActor
    func testReviewedPhotosResetOnNextCalendarDayWhileNominationsStayInCooldown() throws {
        let context = makeContext()
        context.store.beginDailySession(photoIdentifiers: ["yesterday-reviewed", "still-pending"])
        context.store.recordDailyDecision(decisionKey: "yesterday-reviewed", deletedPhotoCount: 0, savedRecord: false)
        XCTAssertEqual(context.store.reviewedPhotoIdentifiers(), ["yesterday-reviewed"])
        context.date.value = try XCTUnwrap(context.calendar.date(byAdding: .day, value: 1, to: context.date.value))

        XCTAssertTrue(context.store.reviewedPhotoIdentifiers().isEmpty)
        XCTAssertTrue(context.store.dailySessionProgress().curatedPhotoIdentifiers.isEmpty)
        XCTAssertEqual(context.store.recommendationExcludedIdentifiers(), ["yesterday-reviewed", "still-pending"])
        context.store.recordDailyDecision(decisionKey: "still-pending", deletedPhotoCount: 0, savedRecord: false)
        XCTAssertEqual(context.store.reviewedPhotoIdentifiers(), ["still-pending"])
    }

    @MainActor
    func testCurrentSessionChoicesRemainReviewedWhenSeparateHistoryIsMissing() {
        let context = makeContext()
        context.store.beginDailySession(photoIdentifiers: ["legacy-reviewed"])
        context.store.recordDailyDecision(decisionKey: "legacy-reviewed", deletedPhotoCount: 0, savedRecord: false)
        context.defaults.removeObject(forKey: UserScopedStorage.key("recoco_reviewed_photos_v1"))

        XCTAssertEqual(context.store.reviewedPhotoIdentifiers(), ["legacy-reviewed"])
        context.store.recordCompletion(deletedPhotoCount: 0, savedRecordCount: 0)
        XCTAssertTrue(context.store.dailySessionProgress().processedDecisionKeys.isEmpty)
        XCTAssertEqual(context.store.reviewedPhotoIdentifiers(), ["legacy-reviewed"])
    }

    @MainActor
    func testPhotoScopeRefreshClearsOnlyScanCoverage() {
        let context = makeContext()
        let store = context.store
        let protection = CurationProtectionStore(defaults: context.defaults)
        store.beginDailySession(photoIdentifiers: ["finished", "pending"],
                                comparisonReferences: ["pending": "reference"])
        store.recordDailyDecision(decisionKey: "finished", deletedPhotoCount: 1, savedRecord: true)
        protection.protect(["reference"])
        store.recordScannedPhotos(["earlier-photo", "finished"])
        XCTAssertFalse(store.scannedPhotoIdentifiers().isEmpty)

        store.resetScannedPhotos()

        XCTAssertTrue(store.scannedPhotoIdentifiers().isEmpty)
        let session = store.dailySessionProgress()
        XCTAssertEqual(session.curatedPhotoIdentifiers, ["finished", "pending"])
        XCTAssertEqual(session.processedDecisionKeys, ["finished"])
        XCTAssertEqual(session.comparisonReferences, ["pending": "reference"])
        XCTAssertEqual(session.deletedPhotoCount, 1)
        XCTAssertEqual(session.savedRecordCount, 1)
        XCTAssertEqual(protection.identifiers(), ["reference"])
    }

    func testCarouselCompletionPreservesUnvisitedPhotosAndRejectsDuplicateCallbacks() {
        let decisions = (1...3).map { index in
            DecisionUnit(id: UUID(), type: .cleanupSingle, status: .pending,
                         candidateLocalIdentifiers: ["photo-\(index)"],
                         recommendedLocalIdentifier: "photo-\(index)",
                         reasonCodes: [], capturedDateDescription: nil, createdAt: Date())
        }
        var queue = HomeDecisionQueue(decisions: decisions)
        queue.select(1)
        XCTAssertEqual(queue.decisions.count, 3)
        XCTAssertEqual(queue.selectedIndex, 1)
        XCTAssertEqual(queue.remove(key: "photo-2")?.displayIdentifier, "photo-2")
        XCTAssertEqual(queue.decisions.compactMap(\.displayIdentifier), ["photo-1", "photo-3"])
        XCTAssertEqual(queue.selectedIndex, 1)
        XCTAssertNil(queue.remove(key: "photo-2"))
        queue.select(-1)
        queue.select(8)
        XCTAssertEqual(queue.selectedIndex, 1)
        queue.remove(key: "photo-1")
        XCTAssertEqual(queue.decisions[queue.selectedIndex].displayIdentifier, "photo-3")
        queue.remove(key: "photo-3")
        XCTAssertTrue(queue.decisions.isEmpty)
        XCTAssertEqual(queue.selectedIndex, 0)
    }

    @MainActor
    func testDuplicateDecisionIsCountedOnlyOnce() {
        let context = makeContext()
        let store = context.store

        store.beginDailySession(photoIdentifiers: ["photo-1"])
        store.recordDailyDecision(
            decisionKey: "photo-1",
            deletedPhotoCount: 1,
            savedRecord: true
        )
        store.recordDailyDecision(
            decisionKey: "photo-1",
            deletedPhotoCount: 1,
            savedRecord: true
        )

        let progress = store.dailySessionProgress()
        XCTAssertEqual(progress.processedDecisionKeys, Set(["photo-1"]))
        XCTAssertEqual(progress.deletedPhotoCount, 1)
        XCTAssertEqual(progress.savedRecordCount, 1)
    }

    @MainActor
    func testDailySessionRestoresAcrossStoreInstances() {
        let context = makeContext()
        context.store.beginDailySession(photoIdentifiers: ["photo-1", "photo-2"])
        context.store.recordDailyDecision(
            decisionKey: "photo-1",
            deletedPhotoCount: 1,
            savedRecord: false
        )

        let restored = LocalActivityStore(
            defaults: context.defaults,
            calendar: context.calendar,
            now: { context.date.value }
        ).dailySessionProgress()

        XCTAssertEqual(restored.curatedPhotoIdentifiers, ["photo-1", "photo-2"])
        XCTAssertEqual(restored.processedDecisionKeys, Set(["photo-1"]))
        XCTAssertEqual(restored.deletedPhotoCount, 1)
    }

    @MainActor
    func testUnreviewedPhotosRetireAfterDayChangesWithoutInventingActivity() throws {
        let context = makeContext()
        context.store.beginDailySession(photoIdentifiers: ["photo-1"])

        context.date.value = try XCTUnwrap(
            context.calendar.date(byAdding: .day, value: 1, to: context.date.value)
        )

        let refreshed = context.store.dailySessionProgress()
        XCTAssertTrue(refreshed.curatedPhotoIdentifiers.isEmpty)
        XCTAssertTrue(refreshed.processedDecisionKeys.isEmpty)
        XCTAssertEqual(refreshed.deletedPhotoCount, 0)
        XCTAssertEqual(refreshed.savedRecordCount, 0)
        XCTAssertEqual(context.store.recommendationExcludedIdentifiers(), ["photo-1"])
        XCTAssertEqual(context.store.weeklySnapshot().completedDays, 0)
        XCTAssertNil(context.store.todaySummary())
    }

    @MainActor
    func testCompletionMovesSessionIntoTodayAndWeeklySummary() {
        let context = makeContext()
        context.store.beginDailySession(photoIdentifiers: ["photo-1"])
        context.store.recordDailyDecision(
            decisionKey: "photo-1",
            deletedPhotoCount: 1,
            savedRecord: true
        )
        context.store.recordCompletion(deletedPhotoCount: 1, savedRecordCount: 1)

        let today = context.store.todaySummary()
        XCTAssertEqual(today?.deletedPhotoCount, 1)
        XCTAssertEqual(today?.savedRecordCount, 1)

        let week = context.store.weeklySnapshot(referenceDate: context.date.value)
        XCTAssertEqual(week.completedDays, 1)
        XCTAssertEqual(week.deletedPhotoCount, 1)
        XCTAssertEqual(week.savedRecordCount, 1)
        XCTAssertEqual(week.dailyDeletedCounts.reduce(0, +), 1)
        XCTAssertTrue(context.store.dailySessionProgress().curatedPhotoIdentifiers.isEmpty)
    }

    @MainActor
    func testSavedRecordsAreReturnedNewestFirst() throws {
        let context = makeContext()
        let recordStore = SavedRecordStore(
            defaults: context.defaults,
            now: { context.date.value }
        )
        try recordStore.save(
            text: "첫 번째 기억",
            photoLocalIdentifier: "photo-1",
            capturedDateDescription: "2026. 7. 18."
        )
        context.date.value = context.date.value.addingTimeInterval(60)
        try recordStore.save(
            text: "두 번째 기억",
            photoLocalIdentifier: "photo-2",
            capturedDateDescription: nil
        )

        let records = recordStore.records()
        XCTAssertEqual(records.map(\.text), ["두 번째 기억", "첫 번째 기억"])
        XCTAssertEqual(records.last?.photoLocalIdentifier, "photo-1")
    }

    @MainActor
    func testSavedRecordsRetainEveryItemAcrossStoreRecreation() throws {
        let context = makeContext()
        let recordStore = SavedRecordStore(
            defaults: context.defaults,
            now: { context.date.value }
        )

        for index in 0..<100 {
            context.date.value = context.date.value.addingTimeInterval(60)
            try recordStore.save(
                text: "기억 \(index)",
                photoLocalIdentifier: "photo-\(index)",
                capturedDateDescription: nil
            )
        }

        let records = SavedRecordStore(defaults: context.defaults).records()
        XCTAssertEqual(records.count, 100)
        XCTAssertEqual(records.first?.text, "기억 99")
        XCTAssertEqual(records.last?.text, "기억 0")
    }

    @MainActor
    func testWeeklySnapshotExcludesPreviousWeek() throws {
        let context = makeContext()
        context.store.recordCompletion(deletedPhotoCount: 2, savedRecordCount: 1)

        context.date.value = try XCTUnwrap(
            context.calendar.date(byAdding: .day, value: 7, to: context.date.value)
        )

        let nextWeek = context.store.weeklySnapshot(referenceDate: context.date.value)
        XCTAssertEqual(nextWeek.completedDays, 0)
        XCTAssertEqual(nextWeek.deletedPhotoCount, 0)
        XCTAssertEqual(nextWeek.savedRecordCount, 0)
    }

    @MainActor
    func testMultilingualMemoriesPreserveTextAndPhotoIdentityAcrossReload() throws {
        let context = makeContext()
        let store = SavedRecordStore(defaults: context.defaults)
        let samples = [
            "바다에서 함께한 오후 🌊", "海辺で過ごした静かな午後。",
            "A quiet afternoon by the sea.", "Lembrança da avó — coração ☀️",
            "Ein schöner Tag am Meer.", "رحلة هادئة إلى البحر — 2026 / 바다",
            "परिवार के साथ एक शांत दिन।", "Un souvenir d’été 👨‍👩‍👧‍👦",
            "Ọjọ́ ayọ̀ lẹ́gbẹ̀ẹ́ òkun", "Una tarde tranquila, México."
        ]
        var identifiers: [UUID] = []
        for (index, text) in samples.enumerated() {
            let saved = try store.save(text: text, photoLocalIdentifier: "culture-\(index)", capturedDateDescription: nil)
            identifiers.append(saved.id)
        }
        let restored = SavedRecordStore(defaults: context.defaults).records()
        XCTAssertEqual(restored.count, samples.count)
        for (index, id) in identifiers.enumerated() {
            let record = try XCTUnwrap(restored.first { $0.id == id })
            XCTAssertEqual(record.text, samples[index])
            XCTAssertEqual(record.photoLocalIdentifier, "culture-\(index)")
        }
    }

    func testSimilarPhotoCandidatesStayWithinThirtySecondWindow() {
        let baseDate = Date(timeIntervalSince1970: 1_783_465_200)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let metadata = [
            PhotoCurationService.CandidateMetadata(
                localIdentifier: "photo-1",
                creationDate: baseDate,
                burstIdentifier: nil
            ),
            PhotoCurationService.CandidateMetadata(
                localIdentifier: "photo-2",
                creationDate: baseDate.addingTimeInterval(12),
                burstIdentifier: nil
            ),
            PhotoCurationService.CandidateMetadata(
                localIdentifier: "photo-3",
                creationDate: baseDate.addingTimeInterval(45),
                burstIdentifier: nil
            )
        ]

        let groups = PhotoCurationService.candidateGroups(
            from: metadata,
            maximumTimeSpan: 30,
            calendar: calendar
        )

        XCTAssertEqual(groups.map { $0.map(\.localIdentifier) }, [["photo-1", "photo-2"]])
    }

    func testSimilarPhotoCleanupRequiresFeatureFlagAndPremiumPlan() {
        XCTAssertFalse(FeatureAccess(
            plan: .free,
            isSimilarPhotoCleanupEnabled: true
        ).canUseSimilarPhotoCleanup)
        XCTAssertFalse(FeatureAccess(
            plan: .premium,
            isSimilarPhotoCleanupEnabled: false
        ).canUseSimilarPhotoCleanup)
        XCTAssertTrue(FeatureAccess(
            plan: .premium,
            isSimilarPhotoCleanupEnabled: true
        ).canUseSimilarPhotoCleanup)
    }

    func testHomeProgressKeepsOriginalThreePhotoPositionAfterResume() {
        let resumed = HomeDecisionProgress(
            completedBeforeLoad: 1,
            pendingCount: 2,
            currentPendingIndex: 0
        )
        let finalPhoto = HomeDecisionProgress(
            completedBeforeLoad: 1,
            pendingCount: 2,
            currentPendingIndex: 1
        )

        XCTAssertEqual(resumed.currentNumber, 2)
        XCTAssertEqual(resumed.totalCount, 3)
        XCTAssertEqual(finalPhoto.currentNumber, 3)
        XCTAssertEqual(finalPhoto.totalCount, 3)
    }

    @MainActor
    func testDeniedPhotoAccessRoutesReturningUserToRecoverableHome() {
        let router = AppRouter()

        router.resolveInitialRoute(
            isLoggedIn: true,
            hasCompletedOnboarding: true,
            photoAuthStatus: .denied
        )

        XCTAssertEqual(router.route, .main)
    }

    @MainActor
    func testUndecidedPhotoAccessRoutesReturningUserToPermissionEducation() {
        let router = AppRouter()

        router.resolveInitialRoute(
            isLoggedIn: true,
            hasCompletedOnboarding: true,
            photoAuthStatus: .notDetermined
        )

        XCTAssertEqual(router.route, .photoPermission)
    }

    @MainActor
    func testIndependentMemoryPreservesCleanupProgressAndDoesNotEndItsBatch() {
        let context = makeContext()
        context.store.beginDailySession(photoIdentifiers: ["one", "two", "three"])
        context.store.recordDailyDecision(decisionKey: "one", deletedPhotoCount: 1, savedRecord: false)
        context.store.recordIndependentMemory()
        let restored = LocalActivityStore(defaults: context.defaults, calendar: context.calendar, now: { context.date.value })
        XCTAssertEqual(restored.dailySessionProgress().curatedPhotoIdentifiers, ["one", "two", "three"])
        XCTAssertEqual(restored.dailySessionProgress().processedDecisionKeys, ["one"])
        XCTAssertEqual(restored.dailySessionProgress().deletedPhotoCount, 1)
        XCTAssertEqual(restored.todaySummary()?.savedRecordCount, 1)
        XCTAssertFalse(restored.hasCompletedCleanupToday())
    }

    @MainActor
    func testIndependentMemoryDeduplicatesSavedIDAcrossRelaunchAndKeepsLegacyActivities() {
        let context = makeContext()
        let recordID = UUID()
        context.store.recordIndependentMemory() // Existing events have no saved-record identity.
        context.store.recordIndependentMemory(recordID: recordID)
        let restored = LocalActivityStore(defaults: context.defaults, calendar: context.calendar,
                                           now: { context.date.value })
        restored.recordIndependentMemory(recordID: recordID)
        XCTAssertEqual(restored.weeklySnapshot().savedRecordCount, 2)
        restored.recordIndependentMemory(recordID: UUID())
        XCTAssertEqual(restored.weeklySnapshot().savedRecordCount, 3)
        XCTAssertEqual(restored.weeklySnapshot().dailySavedCounts.reduce(0, +), 3)
        XCTAssertFalse(restored.hasCompletedCleanupToday())
    }

    @MainActor
    func testSecondBatchResumesAndAggregatesOnlyOneActiveDay() {
        let context = makeContext()
        context.store.recordCompletion(deletedPhotoCount: 2, savedRecordCount: 1)
        context.store.beginDailySession(photoIdentifiers: ["four", "five"])
        context.store.recordDailyDecision(decisionKey: "four", deletedPhotoCount: 1, savedRecord: false)
        let restored = LocalActivityStore(defaults: context.defaults, calendar: context.calendar, now: { context.date.value })
        XCTAssertTrue(restored.hasCompletedCleanupToday())
        XCTAssertEqual(restored.dailySessionProgress().curatedPhotoIdentifiers, ["four", "five"])
        restored.recordCompletion(deletedPhotoCount: 1, savedRecordCount: 0)
        XCTAssertEqual(restored.todaySummary()?.deletedPhotoCount, 3)
        XCTAssertEqual(restored.weeklySnapshot().completedDays, 1)
        XCTAssertEqual(restored.weeklySnapshot().savedRecordCount, 1)
        XCTAssertTrue(restored.dailySessionProgress().curatedPhotoIdentifiers.isEmpty)
    }

    @MainActor
    func testAdditionalScanAdvancesAndResetsTheFollowingDay() {
        let context = makeContext()
        XCTAssertEqual(context.store.advanceCurationScan(), 64)
        XCTAssertEqual(context.store.advanceCurationScan(), 128)
        context.date.value = context.date.value.addingTimeInterval(86400)
        XCTAssertEqual(context.store.advanceCurationScan(), 64)
    }

    func testUncertainAndUnknownReasonsRequireReview() {
        for reason in [CurationReasonCode.shoppingScreen, .expiredScreen, .visuallySimilar, .reviewDateReached, .lowDetail] {
            XCTAssertTrue(CurationEvidence(reason: reason, photoDescription: "사진", detail: "확인").requiresReview)
        }
        for reason in [CurationReasonCode.exactDuplicate, .duplicateScreenshot] {
            XCTAssertFalse(CurationEvidence(reason: reason, photoDescription: "사진", detail: "확인").requiresReview)
        }
    }

    @MainActor
    func testUnreadableRecordsCannotBeOverwrittenOrExcludedFromDeletionProtection() throws {
        let context = makeContext()
        let original = Data("unreadable saved records".utf8)
        context.defaults.set(original, forKey: SavedRecordStore.storageKey)
        let records = SavedRecordStore(defaults: context.defaults)
        XCTAssertThrowsError(try records.save(text: "새 기록", photoLocalIdentifier: "new", capturedDateDescription: nil))
        XCTAssertThrowsError(try CurationProtectionStore(defaults: context.defaults).validatedIdentifiers())
        XCTAssertEqual(context.defaults.data(forKey: SavedRecordStore.storageKey), original)
    }

    @MainActor
    func testSameRecordIDCanBeRetriedAfterRestartWithoutDuplicatingOrOverwriting() throws {
        let context = makeContext()
        let id = UUID()
        let original = try SavedRecordStore(defaults: context.defaults).save(
            id: id, text: "원래 기록", photoLocalIdentifier: "photo", capturedDateDescription: nil)
        let restored = SavedRecordStore(defaults: context.defaults)
        XCTAssertEqual(try restored.save(id: id, text: "원래 기록", photoLocalIdentifier: "photo", capturedDateDescription: nil), original)
        XCTAssertThrowsError(try restored.save(id: id, text: "다른 내용", photoLocalIdentifier: "photo", capturedDateDescription: nil))
        XCTAssertEqual(restored.records(), [original])
    }

    @MainActor
    func testInterruptedCompletionIsNotCountedTwiceAfterRestart() throws {
        let context = makeContext()
        context.store.beginDailySession(photoIdentifiers: ["one"])
        context.store.recordDailyDecision(decisionKey: "one", deletedPhotoCount: 1, savedRecord: false)
        let pendingSession = try XCTUnwrap(context.defaults.data(forKey: "recoco_daily_session_v1"))
        context.store.recordCompletion(deletedPhotoCount: 1, savedRecordCount: 0)
        // Termination after committing the event but before clearing the daily session.
        context.defaults.set(pendingSession, forKey: "recoco_daily_session_v1")
        let restored = LocalActivityStore(defaults: context.defaults, calendar: context.calendar, now: { context.date.value })
        restored.recordCompletion(deletedPhotoCount: 1, savedRecordCount: 0)
        XCTAssertEqual(restored.weeklySnapshot().deletedPhotoCount, 1)
        XCTAssertTrue(restored.dailySessionProgress().curatedPhotoIdentifiers.isEmpty)
    }

    @MainActor
    func testIncompleteBatchCountsSurviveMidnightAndRemainAttributedToOriginalDay() {
        let context = makeContext()
        context.store.beginDailySession(photoIdentifiers: ["one", "two"])
        context.store.recordDailyDecision(decisionKey: "one", deletedPhotoCount: 1, savedRecord: false)
        XCTAssertEqual(context.store.weeklySnapshot().deletedPhotoCount, 1)
        context.date.value = context.date.value.addingTimeInterval(86400)
        XCTAssertTrue(context.store.dailySessionProgress().curatedPhotoIdentifiers.isEmpty)
        XCTAssertTrue(context.store.dailySessionProgress().processedDecisionKeys.isEmpty)
        XCTAssertNil(context.store.todaySummary())
        XCTAssertEqual(context.store.weeklySnapshot().deletedPhotoCount, 1)
        XCTAssertEqual(context.store.weeklySnapshot().completedDays, 1)
        context.store.recordDailyDecision(decisionKey: "two", deletedPhotoCount: 1, savedRecord: false)
        context.store.recordCompletion(deletedPhotoCount: 1, savedRecordCount: 0)
        XCTAssertEqual(context.store.todaySummary()?.deletedPhotoCount, 1)
        XCTAssertEqual(context.store.todaySummary()?.reviewedPhotoCount, 1)
        XCTAssertEqual(context.store.weeklySnapshot().deletedPhotoCount, 2)
        XCTAssertEqual(context.store.weeklySnapshot().completedDays, 2)
    }

    @MainActor
    func testKeepingAllPhotosHasACompletionCountWithoutInventingDeletions() {
        let context = makeContext()
        context.store.beginDailySession(photoIdentifiers: ["one", "two", "three"])
        for id in ["one", "two", "three"] {
            context.store.recordDailyDecision(decisionKey: id, deletedPhotoCount: 0, savedRecord: false)
        }
        context.store.recordCompletion(deletedPhotoCount: 0, savedRecordCount: 0)
        let restored = LocalActivityStore(defaults: context.defaults, calendar: context.calendar, now: { context.date.value })
        XCTAssertEqual(restored.todaySummary()?.reviewedPhotoCount, 3)
        XCTAssertEqual(restored.todaySummary()?.deletedPhotoCount, 0)
        XCTAssertEqual(restored.todaySummary()?.savedRecordCount, 0)
    }

    @MainActor
    func testOvernightRolloverRetiresPendingEvidenceAndCommitsKeepsOnce() {
        let context = makeContext()
        context.store.beginDailySession(photoIdentifiers: ["kept", "pending"],
            comparisonReferences: ["kept": "ref-1", "pending": "ref-2"],
            curationReasons: ["kept": .exactDuplicate, "pending": .exactDuplicate])
        context.store.recordDailyDecision(decisionKey: "kept", deletedPhotoCount: 0, savedRecord: false)
        context.date.value = context.date.value.addingTimeInterval(86400)
        let next = context.store.dailySessionProgress()
        XCTAssertTrue(next.curatedPhotoIdentifiers.isEmpty)
        XCTAssertTrue(next.comparisonReferences.isEmpty)
        XCTAssertTrue(next.curationReasons.isEmpty)
        XCTAssertNil(next.curationVersion)
        XCTAssertEqual(context.store.recommendationExcludedIdentifiers(), ["kept", "pending"])
        _ = context.store.dailySessionProgress()
        XCTAssertEqual(context.store.weeklySnapshot().completedDays, 1)
        XCTAssertNil(context.store.todaySummary())
    }

    @MainActor
    func testInterruptedMidnightRolloverRetiresPendingPhotosWithoutRecounting() throws {
        let context = makeContext()
        context.store.beginDailySession(photoIdentifiers: ["done", "pending"])
        context.store.recordDailyDecision(decisionKey: "done", deletedPhotoCount: 1, savedRecord: false)
        let beforeRollover = try XCTUnwrap(context.defaults.data(forKey: "recoco_daily_session_v1"))
        context.date.value = context.date.value.addingTimeInterval(86400)
        _ = context.store.dailySessionProgress()
        // The old event was saved, but the old queue was not cleared before termination.
        context.defaults.set(beforeRollover, forKey: "recoco_daily_session_v1")
        let restored = LocalActivityStore(defaults: context.defaults, calendar: context.calendar, now: { context.date.value })
        XCTAssertTrue(restored.dailySessionProgress().curatedPhotoIdentifiers.isEmpty)
        XCTAssertEqual(restored.weeklySnapshot().deletedPhotoCount, 1)
        XCTAssertNil(restored.todaySummary())
        restored.recordDailyDecision(decisionKey: "pending", deletedPhotoCount: 1, savedRecord: false)
        restored.recordCompletion(deletedPhotoCount: 1, savedRecordCount: 0)
        XCTAssertEqual(restored.todaySummary()?.deletedPhotoCount, 1)
        XCTAssertEqual(restored.weeklySnapshot().deletedPhotoCount, 2)
    }

    @MainActor
    func testSeparateCleanupDoesNotEraseDailySession() {
        let context = makeContext()
        context.store.beginDailySession(photoIdentifiers: ["one", "two"])
        context.store.recordDailyDecision(decisionKey: "one", deletedPhotoCount: 1, savedRecord: false)
        context.store.recordCompletion(deletedPhotoCount: 2, savedRecordCount: 0, completesDailySession: false)
        XCTAssertEqual(context.store.dailySessionProgress().processedDecisionKeys, ["one"])
        XCTAssertEqual(context.store.weeklySnapshot().deletedPhotoCount, 3)
    }

    @MainActor
    func testDeletionCancellationAndFailureNeverAdvanceProgress() async {
        let context = makeContext()
        let unit = deletionUnit()
        context.store.beginDailySession(photoIdentifiers: unit.removalIdentifiers)
        for error in [NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.Code.userCancelled.rawValue),
                      NSError(domain: "test.permission.changed", code: 1)] {
            let controller = PhotoDeletionController(validate: { _ in true }, commit: { _ in throw error })
            do {
                try await controller.delete(unit) { count in
                    context.store.recordDailyDecision(decisionKey: unit.persistenceKey, deletedPhotoCount: count, savedRecord: false)
                    XCTFail("Cancellation or failure must not report success")
                }
            } catch { }
            XCTAssertFalse(controller.isDeleting)
            XCTAssertTrue(context.store.dailySessionProgress().processedDecisionKeys.isEmpty)
            XCTAssertEqual(context.store.weeklySnapshot().deletedPhotoCount, 0)
        }
    }

    @MainActor
    func testChangedEvidencePreventsCallingPhotoDeletion() async {
        let controller = PhotoDeletionController(validate: { _ in false }, commit: { _ in XCTFail("Must not delete") })
        do {
            try await controller.delete(deletionUnit()) { _ in XCTFail("Must not complete") }
            XCTFail("Changed evidence must stop the operation")
        } catch { }
        XCTAssertFalse(controller.isDeleting)
    }

    @MainActor
    func testConcurrentDeleteTapsProduceOneConfirmedResultThatSurvivesReload() async {
        let context = makeContext()
        let unit = deletionUnit()
        context.store.beginDailySession(photoIdentifiers: unit.removalIdentifiers)
        let started = expectation(description: "Validation started")
        var resume: CheckedContinuation<Bool, Never>?
        var commitCount = 0
        let controller = PhotoDeletionController(validate: { _ in
            await withCheckedContinuation { resume = $0; started.fulfill() }
        }, commit: { _ in commitCount += 1 })
        let first = Task { @MainActor in
            try await controller.delete(unit) { count in
                context.store.recordDailyDecision(decisionKey: unit.persistenceKey, deletedPhotoCount: count, savedRecord: false)
            }
        }
        await fulfillment(of: [started], timeout: 2)
        do {
            let second = try await controller.delete(unit) { _ in XCTFail("Duplicate tap must not complete") }
            XCTAssertFalse(second)
            resume?.resume(returning: true)
            let succeeded = try await first.value
            XCTAssertTrue(succeeded)
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(commitCount, 1)
        let restored = LocalActivityStore(defaults: context.defaults, calendar: context.calendar, now: { context.date.value })
        XCTAssertEqual(restored.dailySessionProgress().deletedPhotoCount, 1)
        XCTAssertEqual(restored.dailySessionProgress().processedDecisionKeys, [unit.persistenceKey])
    }

    private func deletionUnit() -> DecisionUnit {
        DecisionUnit(id: UUID(), type: .cleanupSingle, status: .pending, candidateLocalIdentifiers: ["one"],
                     recommendedLocalIdentifier: "one", reasonCodes: [.exactDuplicate],
                     capturedDateDescription: nil, createdAt: Date(), comparisonLocalIdentifier: "kept")
    }

    @MainActor
    func testDeleteMemoryPersistsAndDoesNotRemovePhotoProtectionOrActivity() throws {
        let context = makeContext()
        let store = SavedRecordStore(defaults: context.defaults)
        let one = try store.save(text: "하나", photoLocalIdentifier: "one", capturedDateDescription: nil)
        let two = try store.save(text: "둘", photoLocalIdentifier: "two", capturedDateDescription: nil)
        context.store.recordIndependentMemory()
        XCTAssertTrue(try store.delete(id: one.id))
        XCTAssertFalse(try store.delete(id: one.id))
        XCTAssertEqual(SavedRecordStore(defaults: context.defaults).records().map(\.id), [two.id])
        XCTAssertTrue(try CurationProtectionStore(defaults: context.defaults).validatedIdentifiers().contains("one"))
        XCTAssertEqual(context.store.weeklySnapshot().savedRecordCount, 1)
        XCTAssertEqual(context.store.weeklySnapshot().deletedPhotoCount, 0)
    }

    @MainActor
    func testCorruptStorageCannotBeOverwrittenByRecordDeletion() {
        let context = makeContext()
        let original = Data("broken records".utf8)
        context.defaults.set(original, forKey: SavedRecordStore.storageKey)
        XCTAssertThrowsError(try SavedRecordStore(defaults: context.defaults).delete(id: UUID()))
        XCTAssertEqual(context.defaults.data(forKey: SavedRecordStore.storageKey), original)
    }

    @MainActor
    func testScanProgressMergesAcrossRequestsAndRestartsThenResetsNextDay() {
        let context = makeContext()
        context.store.recordScannedPhotos(["a", "b"])
        context.store.recordScannedPhotos(["b", "c"])
        let restored = LocalActivityStore(defaults: context.defaults, calendar: context.calendar, now: { context.date.value })
        XCTAssertEqual(restored.scannedPhotoIdentifiers(), ["a", "b", "c"])
        context.date.value = context.date.value.addingTimeInterval(86400)
        XCTAssertTrue(restored.scannedPhotoIdentifiers().isEmpty)
    }

    @MainActor
    func testLegacyIncompleteScanProgressIsRetriedWithoutLosingActivityOrProtection() {
        let context = makeContext()
        let key = UserScopedStorage.key("recoco_scanned_photos_v1")
        context.store.recordCompletion(deletedPhotoCount: 2, savedRecordCount: 1)
        CurationProtectionStore(defaults: context.defaults).protect(["kept"])
        context.store.recordScannedPhotos(["prematurely-visited"])
        var legacy = context.defaults.dictionary(forKey: key)!
        legacy.removeValue(forKey: "version")
        context.defaults.set(legacy, forKey: key)
        XCTAssertTrue(context.store.scannedPhotoIdentifiers().isEmpty)
        context.store.recordScannedPhotos(["fully-compared"])
        XCTAssertEqual(context.store.scannedPhotoIdentifiers(), ["fully-compared"])
        XCTAssertEqual(context.store.weeklySnapshot().deletedPhotoCount, 2)
        XCTAssertEqual(context.store.weeklySnapshot().savedRecordCount, 1)
        XCTAssertTrue(CurationProtectionStore(defaults: context.defaults).identifiers().contains("kept"))
        var previous = context.defaults.dictionary(forKey: key)!
        previous["version"] = PhotoCurationService.curationVersion - 1
        context.defaults.set(previous, forKey: key)
        XCTAssertTrue(context.store.scannedPhotoIdentifiers().isEmpty)
    }

    @MainActor
    func testReportWeekAlwaysStartsMondayAndExcludesNextMonday() {
        let context = makeContext()
        // Gregorian calendar defaults to Sunday; report is explicitly Monday–Sunday.
        func date(_ day: Int, hour: Int = 0) -> Date {
            context.calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
        }
        context.date.value = date(18, hour: 23) // Sunday
        context.store.recordCompletion(deletedPhotoCount: 2, savedRecordCount: 0)
        context.date.value = date(19) // Exactly next Monday, not part of the previous week
        context.store.recordIndependentMemory()
        let previous = context.store.weeklySnapshot(referenceDate: date(18))
        XCTAssertEqual(previous.deletedPhotoCount, 2)
        XCTAssertEqual(previous.savedRecordCount, 0)
        XCTAssertEqual(previous.dailyDeletedCounts, [0, 0, 0, 0, 0, 0, 2])
        let current = context.store.weeklySnapshot()
        XCTAssertEqual(current.deletedPhotoCount, 0)
        XCTAssertEqual(current.savedRecordCount, 1)
        XCTAssertEqual(current.dailySavedCounts, [1, 0, 0, 0, 0, 0, 0])
    }

    func testReportWeekUsesCalendarDaysAcrossDSTAndYearBoundary() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        for (month, day, hours) in [(3, 8, 167), (11, 1, 169)] {
            let date = calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
            let week = ReportingWeek.interval(containing: date, calendar: calendar)
            XCTAssertEqual(calendar.component(.weekday, from: week.start), 2)
            XCTAssertEqual(calendar.component(.hour, from: week.end), 0)
            XCTAssertEqual(week.duration / 3600, Double(hours))
        }
        let date = calendar.date(from: DateComponents(year: 2027, month: 1, day: 1))!
        XCTAssertEqual(ReportingWeek.label(containing: date, calendar: calendar, locale: Locale(identifier: "ko_KR")), "2026. 12. 28. – 2027. 1. 3. · 월–일")
    }

    @MainActor
    func testRecordDeletionChangesInventoryButNotSaveActivityAndKeepDoesNotAddChartCount() throws {
        let context = makeContext()
        let records = SavedRecordStore(defaults: context.defaults, now: { context.date.value })
        let record = try records.save(text: "남긴 기억", photoLocalIdentifier: nil, capturedDateDescription: nil)
        context.store.recordIndependentMemory()
        context.store.beginDailySession(photoIdentifiers: ["kept"])
        context.store.recordDailyDecision(decisionKey: "kept", deletedPhotoCount: 0, savedRecord: false)
        context.store.recordCompletion(deletedPhotoCount: 0, savedRecordCount: 0)
        try records.delete(id: record.id)
        XCTAssertEqual(try records.readRecords().count, 0)
        let report = context.store.weeklySnapshot()
        XCTAssertEqual(report.savedRecordCount, 1)
        XCTAssertEqual(report.deletedPhotoCount, 0)
        XCTAssertEqual(report.dailySavedCounts.reduce(0, +), 1)
        XCTAssertEqual(report.dailyDeletedCounts.reduce(0, +), 0)
    }

    @MainActor
    func testDailyDeletionBatchPersistsAllSelectedPhotosAndPreservesRecordCounts() throws {
        let context = makeContext()
        let store = context.store
        store.beginDailySession(photoIdentifiers: ["recorded", "first", "second", "left"])
        store.recordDailyDecision(decisionKey: "recorded", deletedPhotoCount: 0, savedRecord: true)
        let savedRecords = Data("existing record content remains untouched".utf8)
        let recordKey = UserScopedStorage.key(SavedRecordStore.storageKey)
        context.defaults.set(savedRecords, forKey: recordKey)

        store.recordDailyDeletions([(key: "first", count: 1), (key: "second", count: 1)])
        let data = try XCTUnwrap(context.defaults.data(forKey: UserScopedStorage.key("recoco_daily_session_v1")))
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(stored["processedDecisionKeys"] as? [String] ?? []), ["recorded", "first", "second"])
        XCTAssertEqual(stored["deletedPhotoCount"] as? Int, 2)
        XCTAssertEqual(stored["savedRecordCount"] as? Int, 1)
        let reopened = LocalActivityStore(defaults: context.defaults, calendar: context.calendar, now: { context.date.value })
        let pending = reopened.dailySessionProgress()
        XCTAssertEqual(pending.processedDecisionKeys, ["recorded", "first", "second"])
        XCTAssertEqual(pending.deletedPhotoCount, 2)
        XCTAssertEqual(pending.savedRecordCount, 1)
        XCTAssertTrue(pending.curatedPhotoIdentifiers.contains("left"))
        XCTAssertFalse(pending.processedDecisionKeys.contains("left"))
        XCTAssertEqual(context.defaults.data(forKey: recordKey), savedRecords)
    }

    @MainActor
    func testDailyDeletionBatchDeduplicatesAndIgnoresNonpositiveCounts() throws {
        let context = makeContext()
        let store = context.store
        store.beginDailySession(photoIdentifiers: ["first", "second", "left"])
        store.recordDailyDeletions([(key: "first", count: 1), (key: "first", count: 9),
                                    (key: "second", count: 1), (key: "left", count: 0),
                                    (key: "left", count: -1)])
        let key = UserScopedStorage.key("recoco_daily_session_v1")
        let beforeRepeat = try XCTUnwrap(context.defaults.data(forKey: key))
        store.recordDailyDeletions([(key: "second", count: 1), (key: "first", count: 1)])
        XCTAssertEqual(context.defaults.data(forKey: key), beforeRepeat)
        XCTAssertEqual(store.dailySessionProgress().processedDecisionKeys, ["first", "second"])
        XCTAssertEqual(store.dailySessionProgress().deletedPhotoCount, 2)
        XCTAssertEqual(store.weeklySnapshot().deletedPhotoCount, 2)
        XCTAssertEqual(store.reviewedPhotoIdentifiers(), ["first", "second"])
    }

    @MainActor
    func testCleanupCalendarIncludesPendingBatchWithoutDoubleCountingCompletion() {
        let context = makeContext()
        let store = context.store
        let today = context.calendar.startOfDay(for: context.date.value)
        store.beginDailySession(photoIdentifiers: ["first", "second", "kept"])
        store.recordDailyDeletions([(key: "first", count: 1), (key: "second", count: 1)])
        XCTAssertEqual(store.cleanupDailyCounts(), [today: 2])
        store.recordDailyDecision(decisionKey: "kept", deletedPhotoCount: 0, savedRecord: false)
        store.recordCompletion(deletedPhotoCount: 2, savedRecordCount: 0)
        XCTAssertEqual(store.cleanupDailyCounts(), [today: 2])
        let reopened = LocalActivityStore(defaults: context.defaults, calendar: context.calendar, now: { context.date.value })
        XCTAssertEqual(reopened.cleanupDailyCounts(), [today: 2])
        XCTAssertEqual(reopened.todaySummary()?.deletedPhotoCount, 2)
    }

    @MainActor
    func testCleanupCalendarExcludesKeepsRecordSavesAndFutureActivity() throws {
        let context = makeContext()
        let store = context.store
        let firstDate = context.date.value
        let firstDay = context.calendar.startOfDay(for: firstDate)
        store.beginDailySession(photoIdentifiers: ["kept", "recorded"])
        store.recordDailyDecision(decisionKey: "kept", deletedPhotoCount: 0, savedRecord: false)
        store.recordDailyDecision(decisionKey: "recorded", deletedPhotoCount: 0, savedRecord: true)
        store.recordCompletion(deletedPhotoCount: 0, savedRecordCount: 1)
        store.recordIndependentMemory(recordID: UUID())
        XCTAssertTrue(store.cleanupDailyCounts().isEmpty)

        context.date.value = try XCTUnwrap(context.calendar.date(byAdding: .day, value: 1, to: firstDate))
        let secondDay = context.calendar.startOfDay(for: context.date.value)
        store.beginDailySession(photoIdentifiers: ["second-day-photo"])
        store.recordDailyDeletions([(key: "second-day-photo", count: 1)])
        store.recordCompletion(deletedPhotoCount: 1, savedRecordCount: 0)
        let eventsKey = UserScopedStorage.key("recoco_activity_events_v1")
        let beforeRead = context.defaults.data(forKey: eventsKey)
        XCTAssertEqual(store.cleanupDailyCounts(), [secondDay: 1])
        XCTAssertNil(store.cleanupDailyCounts()[firstDay])
        XCTAssertTrue(store.cleanupDailyCounts(referenceDate: firstDate).isEmpty)
        XCTAssertEqual(context.defaults.data(forKey: eventsKey), beforeRead, "Calendar projection must never rewrite existing activity")
        XCTAssertEqual(store.weeklySnapshot().savedRecordCount, 2)
    }

    @MainActor
    func testDeletionBatchCrossingMidnightKeepsEachDaysCount() throws {
        let context = makeContext()
        let store = context.store
        let firstDay = context.calendar.startOfDay(for: context.date.value)
        store.beginDailySession(photoIdentifiers: ["first", "second", "third"])
        store.recordDailyDeletions([(key: "first", count: 1), (key: "second", count: 1)])
        context.date.value = try XCTUnwrap(context.calendar.date(byAdding: .day, value: 1, to: context.date.value))
        let secondDay = context.calendar.startOfDay(for: context.date.value)
        store.recordDailyDeletions([(key: "third", count: 1)])
        store.recordCompletion(deletedPhotoCount: 1, savedRecordCount: 0)
        XCTAssertEqual(store.cleanupDailyCounts(), [firstDay: 2, secondDay: 1])
        XCTAssertEqual(store.todaySummary()?.deletedPhotoCount, 1)
        XCTAssertEqual(store.weeklySnapshot().deletedPhotoCount, 3)
    }

    @MainActor
    func testMonthlyCleanupCountsCalendarMonthAndExcludesFutureActivity() throws {
        let context = makeContext()
        let store = context.store
        func date(_ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
            context.calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
        }
        for (when, count, key) in [(date(7, 31), 5, "previous-month"),
                                   (date(8, 1), 2, "first-day"),
                                   (date(8, 31), 3, "last-day"),
                                   (date(9, 1, 0), 7, "next-month")] {
            context.date.value = when
            store.beginDailySession(photoIdentifiers: [key])
            store.recordDailyDeletions([(key: key, count: count)])
            store.recordCompletion(deletedPhotoCount: count, savedRecordCount: 0)
        }
        let eventsKey = UserScopedStorage.key("recoco_activity_events_v1")
        let beforeRead = context.defaults.data(forKey: eventsKey)
        XCTAssertEqual(store.monthlyDeletedPhotoCount(referenceDate: date(8, 1)), 2,
                       "Later activity in the same month must not appear before it happened")
        XCTAssertEqual(store.monthlyDeletedPhotoCount(referenceDate: date(8, 31, 23)), 5,
                       "Month boundaries use calendar dates, not a rolling 30-day window or the current week")
        XCTAssertEqual(store.monthlyDeletedPhotoCount(referenceDate: date(9, 1, 0)), 7)
        XCTAssertEqual(context.defaults.data(forKey: eventsKey), beforeRead,
                       "Changing the report period must not rewrite saved activity")
    }

    @MainActor
    func testMonthlyCleanupResetsAtNewYearAndCountsPendingBatchOnlyOnce() throws {
        let context = makeContext()
        let store = context.store
        context.date.value = try XCTUnwrap(context.calendar.date(from:
            DateComponents(year: 2026, month: 12, day: 31, hour: 23, minute: 59)))
        store.beginDailySession(photoIdentifiers: ["old-year"])
        store.recordDailyDeletions([(key: "old-year", count: 4)])
        store.recordCompletion(deletedPhotoCount: 4, savedRecordCount: 0)

        context.date.value = try XCTUnwrap(context.calendar.date(from:
            DateComponents(year: 2027, month: 1, day: 1, hour: 0, minute: 1)))
        store.beginDailySession(photoIdentifiers: ["first", "second", "kept"])
        store.recordDailyDeletions([(key: "first", count: 1), (key: "second", count: 1)])
        XCTAssertEqual(store.monthlyDeletedPhotoCount(), 2)
        store.recordDailyDecision(decisionKey: "kept", deletedPhotoCount: 0, savedRecord: true)
        store.recordCompletion(deletedPhotoCount: 2, savedRecordCount: 1)
        store.recordIndependentMemory(recordID: UUID())
        XCTAssertEqual(store.monthlyDeletedPhotoCount(), 2,
                       "Saved memories and completion must not add to the cleanup total")
        let reopened = LocalActivityStore(defaults: context.defaults, calendar: context.calendar,
                                         now: { context.date.value })
        XCTAssertEqual(reopened.monthlyDeletedPhotoCount(), 2)
        XCTAssertEqual(reopened.weeklySnapshot().savedRecordCount, 2)
    }

    @MainActor
    func testRecommendationCooldownSurvivesCompletionRelaunchAndScopeReset() throws {
        let context = makeContext()
        let store = context.store
        store.beginDailySession(photoIdentifiers: ["first", "second"],
            comparisonReferences: ["first": "comparison"], curationReasons: ["first": .exactDuplicate, "second": .shoppingScreen])
        let token = try XCTUnwrap(store.recommendationAppendToken())
        XCTAssertTrue(store.appendRecommendations(photoIdentifiers: ["third"], comparisonReferences: [:],
            curationReasons: ["third": .expiredScreen], matching: token))
        store.recordDailyDecision(decisionKey: "first", deletedPhotoCount: 1, savedRecord: false)
        store.recordCompletion(deletedPhotoCount: 1, savedRecordCount: 0)
        store.resetScannedPhotos()
        let reopened = LocalActivityStore(defaults: context.defaults, calendar: context.calendar, now: { context.date.value })
        XCTAssertEqual(reopened.recommendationExcludedIdentifiers(), ["first", "second", "third"])
        XCTAssertFalse(reopened.recommendationExcludedIdentifiers().contains("comparison"),
                       "Cooldown protects nominated candidates; comparison references must remain usable")
        XCTAssertTrue(reopened.dailySessionProgress().curatedPhotoIdentifiers.isEmpty)
        XCTAssertEqual(reopened.todaySummary()?.deletedPhotoCount, 1)
    }

    @MainActor
    func testSameDayRecommendationRestorationDoesNotRestartCooldown() throws {
        let context = makeContext()
        let originalDate = context.date.value
        context.store.beginDailySession(photoIdentifiers: ["one", "two", "three"])
        let historyKey = UserScopedStorage.key("recoco_recommendation_history_v1")
        let originalHistory = try XCTUnwrap(context.defaults.data(forKey: historyKey))
        let originalDayKey = context.store.recommendationDayKey
        context.date.value = originalDate.addingTimeInterval(120)
        context.store.beginDailySession(photoIdentifiers: ["replacement"])
        let reopened = LocalActivityStore(defaults: context.defaults, calendar: context.calendar, now: { context.date.value })
        XCTAssertEqual(reopened.dailySessionProgress().curatedPhotoIdentifiers, ["one", "two", "three"])
        XCTAssertEqual(reopened.recommendationDayKey, originalDayKey)
        XCTAssertEqual(context.defaults.data(forKey: historyKey), originalHistory)

        context.date.value = try XCTUnwrap(context.calendar.date(byAdding: .day, value: 29,
            to: context.calendar.startOfDay(for: originalDate))).addingTimeInterval(86399)
        XCTAssertEqual(reopened.recommendationExcludedIdentifiers(), ["one", "two", "three"])
        context.date.value = try XCTUnwrap(context.calendar.date(byAdding: .day, value: 30,
            to: context.calendar.startOfDay(for: originalDate)))
        XCTAssertTrue(reopened.recommendationExcludedIdentifiers().isEmpty)
        XCTAssertNotEqual(reopened.recommendationDayKey, originalDayKey)
    }

    @MainActor
    func testARecommendationAfterCooldownStartsANewThirtyDayInterval() throws {
        let context = makeContext()
        let first = context.calendar.startOfDay(for: context.date.value)
        context.store.beginDailySession(photoIdentifiers: ["returning"])
        context.date.value = try XCTUnwrap(context.calendar.date(byAdding: .day, value: 30, to: first))
        XCTAssertTrue(context.store.recommendationExcludedIdentifiers().isEmpty)
        context.store.beginDailySession(photoIdentifiers: ["returning"])
        XCTAssertEqual(context.store.recommendationExcludedIdentifiers(), ["returning"])
        context.date.value = try XCTUnwrap(context.calendar.date(byAdding: .day, value: 59, to: first))
        XCTAssertEqual(context.store.recommendationExcludedIdentifiers(), ["returning"])
        context.date.value = try XCTUnwrap(context.calendar.date(byAdding: .day, value: 60, to: first))
        XCTAssertTrue(context.store.recommendationExcludedIdentifiers().isEmpty)
    }

    @MainActor
    func testRecommendationCooldownExpiresAtThirtyCalendarDaysAcrossDST() throws {
        let context = makeContext()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        for (month, day) in [(2, 20), (10, 20)] {
            context.date.value = try XCTUnwrap(calendar.date(from:
                DateComponents(year: 2026, month: month, day: day, hour: 23, minute: 59)))
            let store = LocalActivityStore(defaults: context.defaults, calendar: calendar, now: { context.date.value })
            let candidate = "dst-\(month)"
            store.beginDailySession(photoIdentifiers: [candidate])
            let eligible = try XCTUnwrap(calendar.date(byAdding: .day, value: 30,
                to: calendar.startOfDay(for: context.date.value)))
            context.date.value = eligible.addingTimeInterval(-1)
            XCTAssertTrue(store.recommendationExcludedIdentifiers().contains(candidate))
            context.date.value = eligible
            XCTAssertFalse(store.recommendationExcludedIdentifiers().contains(candidate))
        }
    }

    @MainActor
    func testLegacySessionNominationsMigrateUsingOriginalDateWithoutChangingRecords() throws {
        let context = makeContext()
        let originalDate = context.date.value
        let components = context.calendar.dateComponents([.year, .month, .day], from: originalDate)
        let legacy: [String: Any] = [
            "dayKey": "\(components.year!)-\(components.month!)-\(components.day!)",
            "curatedPhotoIdentifiers": ["legacy-pending", "legacy-done"],
            "processedDecisionKeys": ["legacy-done"], "deletedPhotoCount": 1, "savedRecordCount": 0
        ]
        context.defaults.set(try JSONSerialization.data(withJSONObject: legacy),
            forKey: UserScopedStorage.key("recoco_daily_session_v1"))
        let record = SavedMemoryRecord(id: UUID(), createdAt: originalDate, text: "기존 기록",
            photoLocalIdentifier: "record-photo", capturedDateDescription: nil)
        let recordsData = try JSONEncoder().encode([record])
        context.defaults.set(recordsData, forKey: UserScopedStorage.key(SavedRecordStore.storageKey))
        context.defaults.set(["kept"], forKey: UserScopedStorage.key("recoco_protected_photos_v1"))
        context.date.value = try XCTUnwrap(context.calendar.date(byAdding: .day, value: 1, to: originalDate))

        XCTAssertEqual(context.store.recommendationExcludedIdentifiers(), ["legacy-pending", "legacy-done"])
        XCTAssertTrue(context.store.dailySessionProgress().curatedPhotoIdentifiers.isEmpty)
        XCTAssertEqual(context.defaults.data(forKey: UserScopedStorage.key(SavedRecordStore.storageKey)), recordsData)
        XCTAssertEqual(CurationProtectionStore(defaults: context.defaults).identifiers(), ["kept", "record-photo"])
        XCTAssertEqual(context.store.weeklySnapshot(referenceDate: originalDate).deletedPhotoCount, 1)
        context.date.value = try XCTUnwrap(context.calendar.date(byAdding: .day, value: 30,
            to: context.calendar.startOfDay(for: originalDate)))
        XCTAssertTrue(context.store.recommendationExcludedIdentifiers().isEmpty,
                      "Upgrade must not extend an old nomination by another 30 days")
    }

    @MainActor
    func testReadOnlyRelaunchAndRejectedAppendDoNotExtendRecommendationDates() throws {
        let context = makeContext()
        context.store.beginDailySession(photoIdentifiers: ["first"], curationReasons: ["first": .exactDuplicate])
        let token = try XCTUnwrap(context.store.recommendationAppendToken())
        let historyKey = UserScopedStorage.key("recoco_recommendation_history_v1")
        let before = try XCTUnwrap(context.defaults.data(forKey: historyKey))
        context.date.value = context.date.value.addingTimeInterval(60)
        _ = context.store.dailySessionProgress()
        _ = context.store.recommendationExcludedIdentifiers()
        XCTAssertFalse(context.store.appendRecommendations(photoIdentifiers: ["first"], comparisonReferences: [:],
            curationReasons: ["first": .exactDuplicate], matching: token))
        XCTAssertEqual(context.defaults.data(forKey: historyKey), before)
    }

    @MainActor
    private func makeContext() -> TestContext {
        let suiteName = "LocalActivityStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = MutableDate(
            value: Date(timeIntervalSince1970: 1_783_465_200)
        )
        let store = LocalActivityStore(
            defaults: defaults,
            calendar: calendar,
            now: { date.value }
        )
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return TestContext(
            store: store,
            defaults: defaults,
            calendar: calendar,
            date: date
        )
    }
}

private struct TestContext {
    let store: LocalActivityStore
    let defaults: UserDefaults
    let calendar: Calendar
    let date: MutableDate
}

private final class MutableDate {
    var value: Date

    init(value: Date) {
        self.value = value
    }
}

final class PhotoSelectionCopyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_756_800)

    func testActiveSelectionReasonsDescribeTheirObservableBasis() {
        let headlines: [(CurationReasonCode, String)] = [
            (.dailyReflection, "다시 살펴볼 사진을 골랐어요."),
            (.anniversaryReflection, "지난해 이맘때 찍은 사진이에요."),
            (.exactDuplicate, "같은 사진이 한 장 더 있어요."),
            (.duplicateScreenshot, "같은 스크린샷이 한 장 더 있어요."),
            (.expiredScreen, "화면에서 읽은 기한이 지났어요."),
            (.temporaryReference, "위치·이용 안내 문구가 담겨 있어요."),
            (.shoppingScreen, "구매·배송 관련 문구가 보여요."),
            (.lowDetail, "윤곽과 밝기 차이가 작은 사진이에요."),
            (.reviewDateReached, "직접 정한 확인 날짜가 되었어요."),
            (.visuallySimilar, "가까운 시간에 찍은 비슷한 사진이 있어요.")
        ]
        for (reason, headline) in headlines {
            XCTAssertEqual(reason.displayText, headline, reason.rawValue)
        }
    }

    func testDailyReflectionWithoutSelectionProvenanceUsesNeutralHeadline() {
        let evidence = CurationEvidence(reason: .dailyReflection, photoDescription: "사진", detail: "선정 근거")
        let unit = DecisionUnit(id: UUID(), type: .recallMoment, status: .pending,
            candidateLocalIdentifiers: ["photo"], recommendedLocalIdentifier: "photo",
            reasonCodes: [.dailyReflection], capturedDateDescription: nil, createdAt: now)

        XCTAssertEqual(evidence.summary, "다시 살펴볼 사진을 골랐어요.")
        XCTAssertEqual(unit.shortReason, "다시 살펴볼 사진을 골랐어요.")
    }

    func testReflectionSelectionSummaryOverridesOnlyHeadlineAndIgnoresEmptyText() {
        for reason in [CurationReasonCode.dailyReflection, .anniversaryReflection] {
            var evidence = CurationEvidence(reason: reason, photoDescription: "사진", detail: "상세한 선정 근거",
                selectionSummary: "  최근 사진부터 골랐어요.\n")
            XCTAssertEqual(evidence.summary, "최근 사진부터 골랐어요.")
            XCTAssertEqual(evidence.detail, "상세한 선정 근거")
            for empty in ["", " \n "] {
                evidence.selectionSummary = empty
                XCTAssertEqual(evidence.summary, reason.displayText)
            }
        }
    }

    func testCleanupEvidenceCannotReplaceItsHeadlineWithSelectionSummary() {
        for reason in [CurationReasonCode.exactDuplicate, .duplicateScreenshot, .expiredScreen,
                       .temporaryReference, .shoppingScreen, .lowDetail, .reviewDateReached, .visuallySimilar] {
            let evidence = CurationEvidence(reason: reason, photoDescription: "사진", detail: "선정 근거",
                selectionSummary: "최근 사진부터 골랐어요.")
            XCTAssertEqual(evidence.summary, reason.displayText, reason.rawValue)
        }
    }

    func testLegacyEvidenceDecodesWithoutSelectionSummary() throws {
        let legacy = Data(#"{"reason":"dailyReflection","photoDescription":"사진","detail":"이전 선정 근거"}"#.utf8)
        let evidence = try JSONDecoder().decode(CurationEvidence.self, from: legacy)

        XCTAssertNil(evidence.selectionSummary)
        XCTAssertEqual(evidence.summary, "다시 살펴볼 사진을 골랐어요.")
        XCTAssertEqual(evidence.detail, "이전 선정 근거")
    }

    func testEvidenceHeadlineWinsConflictingCodesWithoutChangingDeletionCandidates() {
        var unit = DecisionUnit(id: UUID(), type: .cleanupSingle, status: .pending,
            candidateLocalIdentifiers: ["photo"], recommendedLocalIdentifier: "photo",
            reasonCodes: [.exactDuplicate], capturedDateDescription: nil, createdAt: now)
        let originalCandidates = unit.removalIdentifiers
        unit.evidence = CurationEvidence(reason: .expiredScreen, photoDescription: "기한이 표시된 화면", detail: "읽은 날짜를 확인해주세요.")

        XCTAssertEqual(unit.shortReason, "화면에서 읽은 기한이 지났어요.")
        XCTAssertEqual(unit.selectionDetail, "읽은 날짜를 확인해주세요.")
        XCTAssertEqual(unit.removalIdentifiers, originalCandidates)

        unit.evidence = CurationEvidence(reason: .dailyReflection, photoDescription: "사진", detail: "선정 근거",
            selectionSummary: "최근 사진부터 골랐어요.")
        XCTAssertEqual(unit.shortReason, "최근 사진부터 골랐어요.")
        XCTAssertTrue(unit.removalIdentifiers.isEmpty, "A reflection remains excluded from recommended cleanup")
    }

    func testRecencySelectionDescribesOrderingEvenWhenTheAvailablePhotoIsOld() throws {
        for yearsAgo in [0, 5] {
            let capturedAt = try XCTUnwrap(Calendar.current.date(byAdding: .year, value: -yearsAgo, to: now))
            let evidence = PhotoCurationService.reflectionEvidence(reason: .dailyReflection, capturedAt: capturedAt, now: now)

            XCTAssertEqual(evidence.summary, "최근 사진부터 골랐어요.")
            XCTAssertEqual(evidence.detail, "허용한 사진 중 최근 사진부터 골랐어요.")
        }
    }

    func testMissingCaptureDateDoesNotClaimRecencySelection() {
        let evidence = PhotoCurationService.reflectionEvidence(reason: .dailyReflection, capturedAt: nil, now: now)

        XCTAssertEqual(evidence.summary, "다시 살펴볼 사진을 골랐어요.")
        XCTAssertEqual(evidence.detail, "허용한 사진 중 다시 살펴보도록 골랐어요.")
    }

    func testAnniversarySelectionUsesVerifiedDateAndStaleAnniversaryFallsBackNeutrally() throws {
        let capturedAt = try XCTUnwrap(Calendar.current.date(byAdding: .year, value: -1, to: now))
        let anniversary = PhotoCurationService.reflectionEvidence(reason: .anniversaryReflection, capturedAt: capturedAt, now: now)
        XCTAssertEqual(anniversary.reason, .anniversaryReflection)
        XCTAssertEqual(anniversary.summary, "지난해 이맘때 찍은 사진이에요.")
        XCTAssertEqual(anniversary.detail, "지난해 같은 날짜에서 앞뒤 7일 안에 찍은 사진이에요.")

        let later = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 8, to: now))
        let stale = PhotoCurationService.reflectionEvidence(reason: .anniversaryReflection, capturedAt: capturedAt, now: later)
        XCTAssertEqual(stale.reason, .dailyReflection)
        XCTAssertEqual(stale.summary, "다시 살펴볼 사진을 골랐어요.")
        XCTAssertEqual(stale.detail, "허용한 사진 중 다시 살펴보도록 골랐어요.")
    }
}

final class PhotoAnniversaryPolicyTests: XCTestCase {
    private func calendar(_ timeZone: String = "UTC") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12, in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func testAnniversaryWindowIncludesSevenDaysOnEachSideAndExcludesNextMidnight() throws {
        let calendar = calendar()
        let now = date(2026, 10, 23, in: calendar)
        let window = try XCTUnwrap(PhotoAnniversaryPolicy.window(relativeTo: now, calendar: calendar))
        XCTAssertEqual(window.start, date(2025, 10, 16, hour: 0, in: calendar))
        XCTAssertEqual(window.end, date(2025, 10, 31, hour: 0, in: calendar))
        XCTAssertTrue(PhotoAnniversaryPolicy.matches(window.start, relativeTo: now, calendar: calendar))
        XCTAssertTrue(PhotoAnniversaryPolicy.matches(window.end.addingTimeInterval(-1), relativeTo: now, calendar: calendar))
        XCTAssertFalse(PhotoAnniversaryPolicy.matches(window.start.addingTimeInterval(-1), relativeTo: now, calendar: calendar))
        XCTAssertFalse(PhotoAnniversaryPolicy.matches(window.end, relativeTo: now, calendar: calendar))
        XCTAssertFalse(PhotoAnniversaryPolicy.matches(nil, relativeTo: now, calendar: calendar))
        XCTAssertFalse(PhotoAnniversaryPolicy.matches(date(2026, 10, 23, in: calendar), relativeTo: now, calendar: calendar))
        XCTAssertFalse(PhotoAnniversaryPolicy.matches(date(2024, 10, 23, in: calendar), relativeTo: now, calendar: calendar))
    }

    func testAnniversaryWindowAtNewYearDoesNotReachTwoYearsAgo() throws {
        let calendar = calendar()
        let now = date(2026, 1, 3, in: calendar)
        let window = try XCTUnwrap(PhotoAnniversaryPolicy.window(relativeTo: now, calendar: calendar))
        XCTAssertEqual(window.start, date(2025, 1, 1, hour: 0, in: calendar))
        XCTAssertEqual(window.end, date(2025, 1, 11, hour: 0, in: calendar))
        XCTAssertFalse(PhotoAnniversaryPolicy.matches(date(2024, 12, 31, in: calendar), relativeTo: now, calendar: calendar))
        XCTAssertTrue(PhotoAnniversaryPolicy.matches(date(2025, 1, 1, in: calendar), relativeTo: now, calendar: calendar))
    }

    func testAnniversaryWindowAtYearEndDoesNotReachTheCurrentYear() throws {
        let calendar = calendar()
        let now = date(2026, 12, 29, in: calendar)
        let window = try XCTUnwrap(PhotoAnniversaryPolicy.window(relativeTo: now, calendar: calendar))
        XCTAssertEqual(window.start, date(2025, 12, 22, hour: 0, in: calendar))
        XCTAssertEqual(window.end, date(2026, 1, 1, hour: 0, in: calendar))
        XCTAssertTrue(PhotoAnniversaryPolicy.matches(date(2025, 12, 31, in: calendar), relativeTo: now, calendar: calendar))
        XCTAssertFalse(PhotoAnniversaryPolicy.matches(window.end, relativeTo: now, calendar: calendar))
    }

    func testLeapDayUsesValidPreviousYearDateAndPreviousLeapDayCanMatch() throws {
        let calendar = calendar()
        let leapToday = date(2024, 2, 29, in: calendar)
        let window = try XCTUnwrap(PhotoAnniversaryPolicy.window(relativeTo: leapToday, calendar: calendar))
        XCTAssertEqual(window.start, date(2023, 2, 21, hour: 0, in: calendar))
        XCTAssertEqual(window.end, date(2023, 3, 8, hour: 0, in: calendar))
        XCTAssertTrue(PhotoAnniversaryPolicy.matches(date(2023, 2, 28, in: calendar), relativeTo: leapToday, calendar: calendar))
        XCTAssertTrue(PhotoAnniversaryPolicy.matches(date(2024, 2, 29, in: calendar),
            relativeTo: date(2025, 2, 28, in: calendar), calendar: calendar))
    }

    func testAnniversaryYearAndDayBoundariesFollowTheProvidedTimeZone() throws {
        let seoul = calendar("Asia/Seoul")
        let losAngeles = calendar("America/Los_Angeles")
        let now = date(2026, 1, 1, hour: 0, in: seoul).addingTimeInterval(30 * 60)
        let seoulWindow = try XCTUnwrap(PhotoAnniversaryPolicy.window(relativeTo: now, calendar: seoul))
        let laWindow = try XCTUnwrap(PhotoAnniversaryPolicy.window(relativeTo: now, calendar: losAngeles))
        XCTAssertEqual(seoulWindow.start, date(2025, 1, 1, hour: 0, in: seoul))
        XCTAssertEqual(laWindow.start, date(2024, 12, 24, hour: 0, in: losAngeles))
        XCTAssertEqual(laWindow.end, date(2025, 1, 1, hour: 0, in: losAngeles))
        let captured = date(2025, 1, 2, in: seoul)
        XCTAssertTrue(PhotoAnniversaryPolicy.matches(captured, relativeTo: now, calendar: seoul))
        XCTAssertFalse(PhotoAnniversaryPolicy.matches(captured, relativeTo: now, calendar: losAngeles))
        let october = date(2026, 10, 23, in: seoul)
        let localMidnight = date(2025, 10, 16, hour: 0, in: seoul)
        XCTAssertTrue(PhotoAnniversaryPolicy.matches(localMidnight, relativeTo: october, calendar: seoul))
        XCTAssertFalse(PhotoAnniversaryPolicy.matches(localMidnight.addingTimeInterval(-1), relativeTo: october, calendar: seoul))
    }

    func testAnniversaryWindowUsesCalendarDaysAcrossDaylightSavingChange() throws {
        let calendar = calendar("America/Los_Angeles")
        let now = date(2025, 3, 10, in: calendar)
        let window = try XCTUnwrap(PhotoAnniversaryPolicy.window(relativeTo: now, calendar: calendar))
        XCTAssertEqual(window.start, date(2024, 3, 3, hour: 0, in: calendar))
        XCTAssertEqual(window.end, date(2024, 3, 18, hour: 0, in: calendar))
        XCTAssertEqual(window.duration, 15 * 24 * 60 * 60 - 60 * 60)
        XCTAssertTrue(PhotoAnniversaryPolicy.matches(window.end.addingTimeInterval(-1), relativeTo: now, calendar: calendar))
        XCTAssertFalse(PhotoAnniversaryPolicy.matches(window.end, relativeTo: now, calendar: calendar))
    }
}

final class PhotoContextFormatterTests: XCTestCase {
    private var capturedAt: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar.date(from: DateComponents(year: 2025, month: 10, day: 23, hour: 0, minute: 30))!
    }

    func testCaptureDateUsesItsCalendarDayInTheSpecifiedTimeZone() {
        XCTAssertEqual(PhotoContextFormatter.dateText(capturedAt, timeZone: TimeZone(identifier: "Asia/Seoul")!, locale: Locale(identifier: "ko_KR")), "2025년 10월 23일")
        XCTAssertEqual(PhotoContextFormatter.dateText(capturedAt, timeZone: TimeZone(secondsFromGMT: 0)!, locale: Locale(identifier: "ko_KR")), "2025년 10월 22일")
        XCTAssertEqual(PhotoContextFormatter.dateText(capturedAt, timeZone: TimeZone(secondsFromGMT: 0)!, locale: Locale(identifier: "en_US")), "October 22, 2025")
        XCTAssertEqual(PhotoContextFormatter.dateText(capturedAt, timeZone: TimeZone(secondsFromGMT: 0)!, locale: Locale(identifier: "th_TH@calendar=buddhist")), "22 ตุลาคม 2568")
        XCTAssertNil(PhotoContextFormatter.dateText(nil))
    }

    func testPlaceUsesAvailableRegionWithoutDuplicatingItsName() {
        XCTAssertEqual(PhotoContextFormatter.placeText(locality: "서울", subLocality: "마포구",
            subAdministrativeArea: nil, administrativeArea: "서울특별시", country: "대한민국"), "서울 마포구")
        XCTAssertEqual(PhotoContextFormatter.placeText(locality: "서울 마포구", subLocality: "마포구",
            subAdministrativeArea: nil, administrativeArea: nil, country: nil), "서울 마포구")
        XCTAssertEqual(PhotoContextFormatter.placeText(locality: "서울", subLocality: "서울 마포구",
            subAdministrativeArea: nil, administrativeArea: nil, country: nil), "서울 마포구")
        XCTAssertEqual(PhotoContextFormatter.placeText(locality: nil, subLocality: nil,
            subAdministrativeArea: "해운대구", administrativeArea: "부산", country: "대한민국"), "부산 해운대구")
        XCTAssertNil(PhotoContextFormatter.placeText(locality: nil, subLocality: nil,
            subAdministrativeArea: nil, administrativeArea: nil, country: "대한민국"))
        XCTAssertNil(PhotoContextFormatter.placeText(locality: " ", subLocality: "\n",
            subAdministrativeArea: nil, administrativeArea: nil, country: nil))
    }

    func testCaptionOmitsMissingDateOrPlaceWithoutEmptySeparators() {
        let timeZone = TimeZone(identifier: "Asia/Seoul")!
        XCTAssertEqual(PhotoContextFormatter.caption(capturedAt: capturedAt, place: "서울 마포구", timeZone: timeZone, locale: Locale(identifier: "ko_KR")),
                       "2025년 10월 23일 · " + String(localized: "\("서울 마포구") 인근"))
        XCTAssertEqual(PhotoContextFormatter.caption(capturedAt: capturedAt, place: nil, timeZone: timeZone, locale: Locale(identifier: "ko_KR")), "2025년 10월 23일")
        XCTAssertEqual(PhotoContextFormatter.caption(capturedAt: nil, place: "부산 해운대구", timeZone: timeZone, locale: Locale(identifier: "ko_KR")), String(localized: "\("부산 해운대구") 인근"))
        XCTAssertNil(PhotoContextFormatter.caption(capturedAt: nil, place: nil, timeZone: timeZone, locale: Locale(identifier: "ko_KR")))
        XCTAssertNil(PhotoContextFormatter.caption(capturedAt: nil, place: " \n", timeZone: timeZone, locale: Locale(identifier: "ko_KR")))
    }
}

final class PhotoCurationAccuracyTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_783_465_200)

    private func photo(_ id: String, seconds: Double = 0, favorite: Bool = false, protected: Bool = false, quality: Double = 0) -> PhotoCurationPolicy.Photo {
        PhotoCurationPolicy.Photo(id: id, date: date.addingTimeInterval(seconds), width: 1000, height: 1000,
                                  isFavorite: favorite, isProtected: protected, quality: quality)
    }

    func testTimeAloneNeverProducesDeletionCandidates() {
        let photos = [photo("a"), photo("b", seconds: 1), photo("c", seconds: 2)]
        XCTAssertTrue(PhotoCurationPolicy.selectPairs(from: photos, limit: 3) { _, _ in false }.isEmpty)
    }

    func testFavoritesAndRecordedOrKeptPhotosAreNeverRemovalCandidates() {
        let photos = [photo("favorite", favorite: true), photo("memory", protected: true), photo("candidate", quality: 1)]
        let pairs = PhotoCurationPolicy.selectPairs(from: photos, limit: 3) { _, _ in true }
        XCTAssertEqual(pairs.map(\.candidateID), ["candidate"])
        XCTAssertEqual(pairs.first?.referenceID, "favorite")
        XCTAssertTrue(PhotoCurationPolicy.selectPairs(from: Array(photos.prefix(2)), limit: 3) { _, _ in true }.isEmpty)
    }

    func testAReferenceCanNeverAlsoBeSuggestedForDeletion() {
        let photos = (0..<12).map { photo("photo-\($0)", quality: Double($0)) }
        let pairs = PhotoCurationPolicy.selectPairs(from: photos, limit: 3) { _, _ in true }
        XCTAssertEqual(pairs.count, 3)
        XCTAssertTrue(Set(pairs.map(\.candidateID)).isDisjoint(with: pairs.map(\.referenceID)))
        XCTAssertEqual(Set(pairs.map(\.referenceID)), ["photo-11"])
    }

    func testTransitiveSimilarityDoesNotDeleteAnUnmatchedPhoto() {
        let photos = [photo("a", quality: 3), photo("b", quality: 2), photo("c", quality: 1)]
        let pairs = PhotoCurationPolicy.selectPairs(from: photos, limit: 3) { lhs, rhs in
            Set([lhs.id, rhs.id]) != Set(["a", "c"])
        }
        XCTAssertEqual(pairs, [.init(candidateID: "b", referenceID: "a")])
    }

    func testMissingDatesDifferentDimensionsAndDistantPhotosAreRejected() {
        let base = photo("base")
        let missing = PhotoCurationPolicy.Photo(id: "missing", date: nil, width: 1000, height: 1000)
        let cropped = PhotoCurationPolicy.Photo(id: "cropped", date: date, width: 500, height: 1000)
        XCTAssertFalse(PhotoCurationPolicy.canCompare(base, missing))
        XCTAssertFalse(PhotoCurationPolicy.canCompare(base, cropped))
        XCTAssertFalse(PhotoCurationPolicy.canCompare(base, photo("late", seconds: 31)))
        XCTAssertFalse(PhotoCurationPolicy.canCompare(base, base))
        XCTAssertTrue(PhotoCurationPolicy.canCompare(base, photo("near", seconds: 30)))
    }

    func testNoPaddingToThreeAndZeroLimitReturnsNoCandidates() {
        let photos = [photo("a"), photo("b")]
        XCTAssertEqual(PhotoCurationPolicy.selectPairs(from: photos, limit: 3) { _, _ in true }.count, 1)
        XCTAssertTrue(PhotoCurationPolicy.selectPairs(from: photos, limit: 0) { _, _ in true }.isEmpty)
        XCTAssertTrue(PhotoCurationPolicy.selectPairs(from: [photo("a")], limit: 3) { _, _ in true }.isEmpty)
    }

    func testMissingOrInvalidAnalysisAndFlatImagesFailClosed() {
        for distance: Float? in [nil, .nan, .infinity, -1, 10] {
            XCTAssertFalse(PhotoCurationPolicy.accepts(distance: distance, meanDifference: 0, largestTileDifference: 0, detail: 0.1))
        }
        XCTAssertFalse(PhotoCurationPolicy.accepts(distance: 0, meanDifference: 0, largestTileDifference: 0, detail: 0))
        XCTAssertFalse(PhotoCurationPolicy.accepts(distance: 0, meanDifference: .nan, largestTileDifference: 0, detail: 0.1))
    }

    func testLocalImageChangesFailEvenWhenGlobalAverageAndVisionPass() {
        let original = [Double](repeating: 0.5, count: 48 * 48 * 3)
        var changed = original
        for y in 0..<6 {
            for x in 0..<6 {
                for channel in 0..<3 { changed[(y * 48 + x) * 3 + channel] = 1 }
            }
        }
        let difference = PhotoCurationService.pixelDifference(original, changed)
        XCTAssertLessThan(difference.mean, 0.035)
        XCTAssertGreaterThan(difference.largestTile, 0.12)
        XCTAssertFalse(PhotoCurationPolicy.accepts(distance: 0, meanDifference: difference.mean,
                                                  largestTileDifference: difference.largestTile, detail: 0.1))
    }

    func testSmallCompressionDifferencesCanPassButLargeChangesCannot() {
        let original = [Double](repeating: 0.5, count: 48 * 48 * 3)
        let near = PhotoCurationService.pixelDifference(original, original.map { $0 + 0.01 })
        XCTAssertTrue(PhotoCurationPolicy.accepts(distance: 1, meanDifference: near.mean, largestTileDifference: near.largestTile, detail: 0.1))
        let far = PhotoCurationService.pixelDifference(original, original.map { $0 + 0.2 })
        XCTAssertFalse(PhotoCurationPolicy.accepts(distance: 1, meanDifference: far.mean, largestTileDifference: far.largestTile, detail: 0.1))
        let invalid = PhotoCurationService.pixelDifference([], [])
        XCTAssertFalse(PhotoCurationPolicy.accepts(distance: 0, meanDifference: invalid.mean, largestTileDifference: invalid.largestTile, detail: 0.1))
    }

    @MainActor
    func testComparisonReferencesPersistAndLegacySessionCanBeReplacedWithoutLosingCounts() throws {
        let suite = "curation-references-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.dateComponents([.year, .month, .day], from: date)
        let legacy: [String: Any] = ["dayKey": "\(today.year!)-\(today.month!)-\(today.day!)",
                                   "curatedPhotoIdentifiers": ["old"], "processedDecisionKeys": ["already-done"],
                                   "deletedPhotoCount": 1, "savedRecordCount": 0]
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: UserScopedStorage.key("recoco_daily_session_v1"))
        let store = LocalActivityStore(defaults: defaults, calendar: calendar, now: { self.date })
        XCTAssertNil(store.dailySessionProgress().curationVersion)
        store.beginDailySession(photoIdentifiers: ["candidate"], comparisonReferences: ["candidate": "reference"])
        let restored = LocalActivityStore(defaults: defaults, calendar: calendar, now: { self.date }).dailySessionProgress()
        XCTAssertEqual(restored.comparisonReferences, ["candidate": "reference"])
        XCTAssertEqual(restored.curatedPhotoIdentifiers, ["candidate"])
        XCTAssertEqual(restored.curationVersion, PhotoCurationService.curationVersion)
        XCTAssertEqual(restored.deletedPhotoCount, 1)
        XCTAssertEqual(restored.processedDecisionKeys, ["already-done"])
    }

    @MainActor
    func testProtectionPersistsAcrossInstancesBeyondFormerTwentyRecordLimit() throws {
        let suite = "curation-protection-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        CurationProtectionStore(defaults: defaults).protect(["kept"])
        let store = SavedRecordStore(defaults: defaults)
        for i in 0..<25 {
            try store.save(text: "기억", photoLocalIdentifier: "record-\(i)", capturedDateDescription: nil)
        }
        XCTAssertEqual(store.records().count, 25)
        let protected = CurationProtectionStore(defaults: defaults).identifiers()
        XCTAssertEqual(protected.count, 26)
        XCTAssertTrue(protected.contains("record-0"))
        XCTAssertTrue(protected.contains("kept"))
    }

    private func fixtureImage(inverted: Bool = false) throws -> CGImage {
        var bytes = [UInt8]()
        for y in 0..<96 {
            for x in 0..<96 {
                let value: UInt8 = (x / 12 + y / 12) % 2 == 0 ? 30 : 220
                bytes.append(contentsOf: [inverted ? 255 - value : value, UInt8((x * 7) % 256), UInt8((y * 11) % 256), 255])
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: 96, height: 96, bitsPerComponent: 8, bitsPerPixel: 32,
                                     bytesPerRow: 96 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    func testPixelPipelineOnActualImageBuffers() throws {
        let original = PhotoCurationService.imageMetrics(try fixtureImage())
        let copy = PhotoCurationService.imageMetrics(try fixtureImage())
        let changed = PhotoCurationService.imageMetrics(try fixtureImage(inverted: true))
        let sameDifference = PhotoCurationService.pixelDifference(original.colors, copy.colors)
        XCTAssertTrue(PhotoCurationPolicy.accepts(distance: 0, meanDifference: sameDifference.mean,
                                                 largestTileDifference: sameDifference.largestTile, detail: original.sharpness))
        let different = PhotoCurationService.pixelDifference(original.colors, changed.colors)
        XCTAssertFalse(PhotoCurationPolicy.accepts(distance: 0, meanDifference: different.mean,
                                                  largestTileDifference: different.largestTile, detail: original.sharpness))
    }

    func testVisionFeaturePrintIdentityOnSupportedHardware() throws {
        let original = try fixtureImage()
        let copy = try fixtureImage()
        let originalPrint = try XCTUnwrap(try PhotoCurationService.featurePrint(original))
        let copyPrint = try XCTUnwrap(try PhotoCurationService.featurePrint(copy))
        XCTAssertEqual(originalPrint.requestRevision, VNGenerateImageFeaturePrintRequestRevision1)
        var distance: Float = 0
        try originalPrint.computeDistance(&distance, to: copyPrint)
        #if targetEnvironment(simulator)
        // This simulator's CPU backend returns the same ~19.73799 for identical inputs.
        // Do not relax the production threshold to make an unsupported backend pass.
        try XCTSkipIf(abs(distance - 19.737993) < 0.001,
                      "Simulator Vision revision 1 CPU output is invalid for identical images; run this test on a physical iPhone.")
        #endif
        XCTAssertEqual(distance, 0, accuracy: 0.001)
    }

    func testMissingComparisonEvidenceCannotAuthorizeDeletion() async {
        let unit = DecisionUnit(id: UUID(), type: .cleanupSingle, status: .pending,
                                candidateLocalIdentifiers: ["candidate"], recommendedLocalIdentifier: "candidate",
                                selectedLocalIdentifier: nil, reasonCodes: [], capturedDateDescription: nil, createdAt: date)
        let allowed = await PhotoCurationService().canDelete(unit, protectedIdentifiers: [])
        XCTAssertFalse(allowed)
    }
}

final class CurationContextTests: XCTestCase {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(secondsFromGMT: 0)!
        return result
    }
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: 29))! }
    private func facts(_ text: [String], daysAgo: Int = 40, screenshot: Bool = true) -> CurationContextPolicy.Facts {
        CurationContextPolicy.Facts(capturedAt: calendar.date(byAdding: .day, value: -daysAgo, to: now),
                                   isScreenshot: screenshot, textLines: text, confidentTextLines: text,
                                   hasFace: false, detail: 0.01, luminanceRange: 0.4)
    }
    private func evidence(_ facts: CurationContextPolicy.Facts) -> CurationEvidence? {
        CurationContextPolicy.evidence(for: facts, now: now, calendar: calendar)
    }

    func testOldPhotoOrEmptyScreenshotIsNotADiscardReason() {
        XCTAssertNil(evidence(facts([], daysAgo: 200, screenshot: false)))
        XCTAssertNil(evidence(facts([], daysAgo: 200)))
        XCTAssertNil(evidence(facts(["기억하고 싶은 문장"], daysAgo: 200)))
    }

    func testExplicitExpiredDateAndFullRangeUseTheActualEndDate() {
        let result = evidence(facts(["사용기한 2026.08.31"]))
        XCTAssertEqual(result?.reason, .expiredScreen)
        XCTAssertEqual(result?.observedDate, calendar.date(from: DateComponents(year: 2026, month: 8, day: 31)))
        XCTAssertTrue(result?.requiresReview == true)
        let range = evidence(facts(["행사기간 2026.08.01 ~ 2026.08.31"]))
        XCTAssertEqual(range?.observedDate, result?.observedDate)
        let nextLine = evidence(facts(["유효기간", "2026년 8월 31일"]))
        XCTAssertEqual(nextLine?.observedDate, result?.observedDate)
    }

    func testGregorianExpiryInPhotoIsIndependentOfDisplayCalendar() throws {
        var thai = Calendar(identifier: .buddhist)
        thai.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Bangkok"))
        XCTAssertNil(CurationContextPolicy.evidence(for: facts(["valid until 2027-01-01"]),
                                                   now: now, calendar: thai))
        let past = CurationContextPolicy.evidence(for: facts(["valid until 2025-01-01"]),
                                                  now: now, calendar: thai)
        var gregorian = calendar
        gregorian.timeZone = thai.timeZone
        XCTAssertEqual(past?.observedDate, gregorian.date(from: DateComponents(year: 2025, month: 1, day: 1)))
    }

    func testFutureTodayAmbiguousAndInvalidDatesDoNotBecomeExpiredScreens() {
        for text in ["사용기한 2026.12.31", "사용기한 2026.09.29", "사용기한 08.31",
                     "사용기한 2026.02.30", "행사기간 2026.01.01 ~ 12.31", "행사기간 2026.01.01-12.31",
                     "행사기간 2026.01.01 ~ 2026.12.31", "생년월일 2020.01.01", "사용기한 아래 표시 제조일 2026.08.31"] {
            XCTAssertNil(evidence(facts([text])), text)
        }
        XCTAssertNil(evidence(facts(["장바구니 결제하기", "사용기한 2026.12.31"])))
    }

    func testReceiptsBookingsIdentityAndMedicalWordsVetoContextualSuggestions() {
        for marker in ["영수증", "예약확정", "여권", "진단서", "입장권", "결제완료", "인증번호"] {
            XCTAssertNil(evidence(facts(["사용기한 2026.08.31", marker])), marker)
            XCTAssertNil(evidence(facts(["장바구니 결제하기", marker])), marker)
        }
    }

    func testTemporaryReferenceRequiresSpecificCombinedCluesAndElapsedTime() {
        XCTAssertEqual(evidence(facts(["주차 위치 지하 2층"], daysAgo: 7, screenshot: false))?.reason, .temporaryReference)
        XCTAssertEqual(evidence(facts(["와이파이 비밀번호"], daysAgo: 8))?.reason, .temporaryReference)
        XCTAssertNil(evidence(facts(["주차 위치"], daysAgo: 6)))
        XCTAssertNil(evidence(facts(["주차"], daysAgo: 100)))
    }

    func testShoppingScreensNeedMultipleCluesThirtyDaysAndScreenshotMetadata() {
        XCTAssertEqual(evidence(facts(["장바구니", "결제하기"], daysAgo: 30))?.reason, .shoppingScreen)
        XCTAssertEqual(evidence(facts(["배송조회 배송완료"], daysAgo: 40))?.reason, .shoppingScreen)
        XCTAssertNil(evidence(facts(["장바구니 결제하기"], daysAgo: 29)))
        XCTAssertNil(evidence(facts(["장바구니 결제하기"], screenshot: false)))
        XCTAssertNil(evidence(facts(["가격 10,000원"], daysAgo: 90)))
    }

    func testFailedOrLowConfidenceOCRCannotCreateContextualReason() {
        var sample = facts(["사용기한 2026.08.31"])
        sample.confidentTextLines = []
        XCTAssertNil(evidence(sample))
        sample.textLines = nil
        sample.confidentTextLines = ["사용기한 2026.08.31"]
        XCTAssertNil(evidence(sample))
    }

    func testLowDetailIsOnlyAReviewAndNeedsNoTextOrFacesAndLowContrast() {
        var sample = facts([], screenshot: false)
        sample.detail = 0.0002
        sample.luminanceRange = 0.02
        XCTAssertEqual(evidence(sample)?.reason, .lowDetail)
        XCTAssertTrue(evidence(sample)?.requiresReview == true)
        sample.hasFace = true
        XCTAssertNil(evidence(sample))
        sample.hasFace = nil
        XCTAssertNil(evidence(sample))
        sample.hasFace = false
        sample.textLines = ["메모"]
        XCTAssertNil(evidence(sample))
        sample.textLines = []
        sample.luminanceRange = 0.5
        XCTAssertNil(evidence(sample))
        sample.luminanceRange = 0.02
        sample.detail = .nan
        XCTAssertNil(evidence(sample))
    }

    func testUserReviewDateWinsOverGuessesAndNeverFiresEarly() {
        var sample = facts(["영수증"], daysAgo: 1)
        sample.reviewDate = calendar.date(byAdding: .day, value: 1, to: now)
        XCTAssertNil(evidence(sample))
        sample.reviewDate = now
        XCTAssertEqual(evidence(sample)?.reason, .reviewDateReached)
        XCTAssertEqual(evidence(sample)?.observedDate, now)
    }

    func testExactPairSelectionCanCrossDatesWhileProtectingRetainedCopy() {
        let favorite = PhotoCurationPolicy.Photo(id: "a", date: now, width: 100, height: 100, isFavorite: true)
        let duplicate = PhotoCurationPolicy.Photo(id: "b", date: now.addingTimeInterval(-86400), width: 100, height: 100)
        let extra = PhotoCurationPolicy.Photo(id: "c", date: now.addingTimeInterval(-172800), width: 100, height: 100)
        XCTAssertTrue(PhotoCurationPolicy.selectPairs(from: [favorite, duplicate], limit: 3) { _, _ in true }.isEmpty)
        let result = PhotoCurationPolicy.selectPairs(from: [favorite, duplicate, extra], limit: 3,
                                                   requiresNearbyCapture: false) { _, _ in true }
        XCTAssertEqual(Set(result.map(\.referenceID)), ["a"])
        XCTAssertEqual(Set(result.map(\.candidateID)), ["b", "c"])
    }

    @MainActor
    func testReviewDatesAndNonComparisonReasonsPersistWithoutLosingProgress() throws {
        let suite = "curation-context-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        CurationReviewStore(defaults: defaults).set(now, for: "later")
        XCTAssertEqual(CurationReviewStore(defaults: defaults).dates()["later"], now)
        let store = LocalActivityStore(defaults: defaults, calendar: calendar, now: { self.now })
        store.beginDailySession(photoIdentifiers: ["screen"], curationReasons: ["screen": .expiredScreen])
        let restored = LocalActivityStore(defaults: defaults, calendar: calendar, now: { self.now }).dailySessionProgress()
        XCTAssertEqual(restored.curationReasons, ["screen": .expiredScreen])
        XCTAssertTrue(restored.comparisonReferences.isEmpty)
        CurationReviewStore(defaults: defaults).set(nil, for: "later")
        XCTAssertTrue(CurationReviewStore(defaults: defaults).dates().isEmpty)
    }

    func testMissingAssetCannotAuthorizeContextualDeletion() async {
        let unit = DecisionUnit(id: UUID(), type: .cleanupSingle, status: .pending,
                                candidateLocalIdentifiers: ["not-a-photo"], recommendedLocalIdentifier: "not-a-photo",
                                reasonCodes: [.expiredScreen], capturedDateDescription: nil, createdAt: now,
                                evidence: CurationEvidence(reason: .expiredScreen, photoDescription: "기한이 지난 화면", detail: "예시"))
        let allowed = await PhotoCurationService().canDelete(unit, protectedIdentifiers: [])
        XCTAssertFalse(allowed)
    }
}

final class CurationOCRIntegrationTests: XCTestCase {
    func testConcurrentEvidenceKeepsDifferentScreenTextAndPolicyResultsSeparate() throws {
        let captions = ["EXPIRES 2026.08.31", "EXPIRES 2027.08.31"]
        let images = try captions.map { caption -> CGImage in
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(size: CGSize(width: 1000, height: 600), format: format).image { context in
                UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1000, height: 600))
                (caption as NSString).draw(at: CGPoint(x: 65, y: 180), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 55, weight: .medium), .foregroundColor: UIColor.black
                ])
            }
            return try XCTUnwrap(image.cgImage)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 29)))
        let serial = try images.map {
            try PhotoCurationService.contextFacts($0, capturedAt: now.addingTimeInterval(-86400), isScreenshot: true)
        }
        let deadline = PhotoCurationService.AnalysisDeadline(seconds: 30)
        let pool = CurationConcurrentPreparation<CurationContextPolicy.Facts>(count: images.count,
            concurrency: 2, deadline: deadline, itemTimeout: 20) { index, budget, cancellation in
            guard !cancellation.isCancelled else { return nil }
            return try? PhotoCurationService.contextFacts(images[index],
                capturedAt: now.addingTimeInterval(-86400), isScreenshot: true, deadline: budget)
        }
        let result = pool.wait(until: deadline, forAll: true)
        pool.cancel()
        XCTAssertEqual(result.values.count, 2)
        for index in images.indices {
            let facts = try XCTUnwrap(result.values[index])
            XCTAssertEqual(facts.textLines, serial[index].textLines)
            XCTAssertEqual(facts.confidentTextLines, serial[index].confidentTextLines)
            XCTAssertEqual(facts.hasFace, serial[index].hasFace)
        }
        XCTAssertEqual(CurationContextPolicy.evidence(for: try XCTUnwrap(result.values[0]),
            now: now, calendar: calendar)?.reason, .expiredScreen)
        XCTAssertNil(CurationContextPolicy.evidence(for: try XCTUnwrap(result.values[1]), now: now, calendar: calendar))
    }

    func testActualImageTextRecognitionFeedsExpiredScreenPolicy() throws {
        for caption in ["EXPIRES 2026.08.31", "사용기한 2026.08.31"] {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(size: CGSize(width: 1000, height: 600), format: format).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 1000, height: 600))
                (caption as NSString).draw(at: CGPoint(x: 65, y: 180), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 55, weight: .medium), .foregroundColor: UIColor.black
                ])
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 29)))
            let facts = try PhotoCurationService.contextFacts(try XCTUnwrap(image.cgImage),
                                                            capturedAt: now.addingTimeInterval(-86400), isScreenshot: true)
            XCTAssertFalse(facts.confidentTextLines.isEmpty, caption)
            XCTAssertEqual(CurationContextPolicy.evidence(for: facts, now: now, calendar: calendar)?.reason, .expiredScreen, caption)
        }
    }
}

final class MedicalDocumentCurationTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return value
    }
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 12))!
    }
    private func facts(_ lines: [String]) -> CurationContextPolicy.Facts {
        CurationContextPolicy.Facts(capturedAt: now.addingTimeInterval(-45 * 86400),
            isScreenshot: true, textLines: lines, confidentTextLines: lines,
            hasFace: false, detail: 0.02, luminanceRange: 0.8)
    }
    private func evidence(_ sample: CurationContextPolicy.Facts) -> CurationEvidence? {
        CurationContextPolicy.evidence(for: sample, now: now, calendar: calendar)
    }

    func testEnglishMedicalDocumentsVetoExpiryAndShoppingSuggestions() {
        for marker in ["PRESCRIPTION", "Prescription No. DEMO-101", "diagnosis",
                       "MEDICAL RECORD", "Medical report", "Lab results", "Laboratory results"] {
            XCTAssertNil(evidence(facts([marker, "Valid until 2026-09-30"])), marker)
            XCTAssertNil(evidence(facts([marker, "cart", "checkout"])), marker)
        }
    }

    func testMedicalProtectionSurvivesOCRLineBreaksAndLowConfidence() {
        XCTAssertNil(evidence(facts(["MeDiCaL", "  ReCoRd  ", "Expires 2026-09-30"])))
        var sample = facts(["PRESCRIPTION", "Valid until 2026-09-30"])
        // A weakly recognized medical marker can veto a guess; it cannot justify deletion.
        sample.confidentTextLines = ["Valid until 2026-09-30"]
        XCTAssertNil(evidence(sample))
    }

    func testOrdinaryExpiredCouponsStillRequestReview() {
        for marker in ["COUPON", "Coffee subscription coupon", "Product description"] {
            let result = evidence(facts([marker, "Valid until 2026-09-30"]))
            XCTAssertEqual(result?.reason, .expiredScreen, marker)
            XCTAssertEqual(result?.observedDate,
                           calendar.date(from: DateComponents(year: 2026, month: 9, day: 30)), marker)
            XCTAssertTrue(result?.requiresReview == true, marker)
        }
    }

    func testExplicitUserReviewDateRemainsAReviewForMedicalDocuments() {
        var sample = facts(["PRESCRIPTION", "Valid until 2026-09-30"])
        sample.reviewDate = calendar.date(byAdding: .day, value: 1, to: now)
        XCTAssertNil(evidence(sample))
        sample.reviewDate = now
        let result = evidence(sample)
        XCTAssertEqual(result?.reason, .reviewDateReached)
        XCTAssertTrue(result?.requiresReview == true)
    }
}

final class FirstRecommendationTests: XCTestCase {
    private func candidate() -> DecisionUnit {
        DecisionUnit(id: UUID(), type: .cleanupSingle, status: .pending,
            candidateLocalIdentifiers: ["verified"], recommendedLocalIdentifier: "verified",
            reasonCodes: [.exactDuplicate], capturedDateDescription: nil, createdAt: Date())
    }

    func testFirstVerifiedResultReturnsWithoutFillingThreeSlots() async {
        var calls = 0
        let unit = candidate()
        let result = await PhotoCurationService.firstAvailableBatch(excluding: ["already-seen"]) { visited in
            calls += 1
            XCTAssertTrue(visited.contains("already-seen"))
            if calls == 1 {
                return .init(decisions: [], visitedIdentifiers: ["fully-compared"], hasMore: true, hasFreshPhotos: true)
            }
            XCTAssertTrue(visited.contains("fully-compared"))
            return .init(decisions: [unit], visitedIdentifiers: ["verified"], hasMore: true, hasFreshPhotos: true)
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(result.decisions.map(\.persistenceKey), ["verified"])
        XCTAssertEqual(result.visitedIdentifiers, ["fully-compared", "verified"])
    }

    func testPartialWindowsAreNotRetiredAndAutomaticSearchIsBounded() async {
        var calls = 0
        let result = await PhotoCurationService.firstAvailableBatch(excluding: []) { visited in
            calls += 1
            XCTAssertTrue(visited.isEmpty)
            return .init(decisions: [], visitedIdentifiers: [], hasMore: true, hasFreshPhotos: true)
        }
        XCTAssertEqual(calls, 8)
        XCTAssertTrue(result.hasMore)
        XCTAssertTrue(result.visitedIdentifiers.isEmpty)
    }

    func testUnavailableOnlyWindowStopsInsteadOfRetryingForever() async {
        var calls = 0
        let result = await PhotoCurationService.firstAvailableBatch(excluding: []) { _ in
            calls += 1
            return .init(decisions: [], visitedIdentifiers: [], hasMore: true,
                         retryableFailureCount: 4, hasFreshPhotos: false, accessiblePhotoCount: 4)
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(result.retryableFailureCount, 4)
        XCTAssertEqual(result.accessiblePhotoCount, 4)
        XCTAssertTrue(result.visitedIdentifiers.isEmpty)
    }

    func testEmptyLibraryIsDistinctFromUnfinishedSearch() async {
        var calls = 0
        let result = await PhotoCurationService.firstAvailableBatch(excluding: []) { _ in
            calls += 1
            return .init(decisions: [], visitedIdentifiers: [], hasMore: false, accessiblePhotoCount: 0)
        }
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(result.hasMore)
        XCTAssertEqual(result.accessiblePhotoCount, 0)
        XCTAssertEqual(result.retryableFailureCount, 0)
    }

    func testSoftTimeBudgetStopsBetweenPasses() async {
        var elapsed: TimeInterval = 0
        var calls = 0
        _ = await PhotoCurationService.firstAvailableBatch(excluding: [], now: { Date(timeIntervalSince1970: elapsed) }) { _ in
            calls += 1
            elapsed += 6
            return .init(decisions: [], visitedIdentifiers: [], hasMore: true, hasFreshPhotos: true)
        }
        XCTAssertEqual(calls, 2)
    }

    func testCancellationDiscardsLateDecisionsAndVisitedIdentifiers() async {
        let entered = expectation(description: "scan entered")
        let release = AsyncScanRelease()
        let unit = candidate()
        let task = Task {
            await PhotoCurationService.firstAvailableBatch(excluding: []) { _ in
                entered.fulfill()
                await release.wait()
                return .init(decisions: [unit], visitedIdentifiers: ["verified"], hasMore: false)
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

private actor AsyncScanRelease {
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false
    func wait() async {
        if finished { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func finish() { finished = true; continuation?.resume(); continuation = nil }
}


@MainActor
final class HomeCurationSearchTests: XCTestCase {
    private func unit(_ id: String, _ reason: CurationReasonCode = .exactDuplicate) -> DecisionUnit {
        DecisionUnit(id: UUID(), type: .cleanupSingle, status: .pending,
            candidateLocalIdentifiers: [id], recommendedLocalIdentifier: id,
            reasonCodes: [reason], capturedDateDescription: nil, createdAt: Date(),
            comparisonLocalIdentifier: reason == .expiredScreen ? nil : "kept")
    }

    func testContinuesEmptyFreshWindowsAndCombinesOnlyCompletedCoverage() async {
        var calls = 0
        let result = await HomeCurationSearch.curated(excluding: ["old"]) { excluded, _, _, _ in
            calls += 1
            if calls == 1 {
                XCTAssertEqual(excluded, ["old"])
                return .init(decisions: [], visitedIdentifiers: ["checked"], hasMore: true,
                    retryableFailureCount: 2, hasFreshPhotos: true, accessiblePhotoCount: 20)
            }
            XCTAssertEqual(excluded, ["old", "checked"])
            return .init(decisions: [self.unit("one"), self.unit("two", .visuallySimilar), self.unit("three", .expiredScreen)],
                visitedIdentifiers: ["one", "two", "three"], hasMore: false,
                retryableFailureCount: 1, accessiblePhotoCount: 20)
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(result?.decisions.count, 3)
        XCTAssertEqual(result?.visitedIdentifiers, ["checked", "one", "two", "three"])
        XCTAssertEqual(result?.retryableFailureCount, 1)
        XCTAssertEqual(result?.accessiblePhotoCount, 20)
    }

    func testTwoCandidatesContinueToThreeWithRemainingLimitAndProtectedReference() async {
        var calls = 0
        let result = await HomeCurationSearch.curated(excluding: ["old"], protectedIdentifiers: ["saved"]) { excluded, protected, remaining, _ in
            calls += 1
            if calls == 1 {
                XCTAssertEqual(remaining, 3)
                XCTAssertEqual(protected, ["saved"])
                return .init(decisions: [self.unit("one"), self.unit("two", .visuallySimilar)], visitedIdentifiers: ["one", "two"],
                    hasMore: true, hasFreshPhotos: true)
            }
            XCTAssertEqual(remaining, 1)
            XCTAssertEqual(excluded, ["old", "one", "two"])
            XCTAssertEqual(protected, ["saved", "kept"])
            return .init(decisions: [self.unit("three", .expiredScreen)], visitedIdentifiers: ["three"], hasMore: true, hasFreshPhotos: true)
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(result?.decisions.compactMap(\.displayIdentifier), ["one", "two", "three"])
    }

    func testPartialRealRecommendationRemainsWhenPhotosAreExhaustedOrUnavailable() async {
        for count in 1...2 {
            for hasMore in [true, false] {
                var calls = 0
                let result = await HomeCurationSearch.curated(excluding: []) { _, _, _, _ in
                    calls += 1
                    return .init(decisions: (0..<count).map { self.unit("photo-\($0)", $0 == 0 ? .exactDuplicate : .visuallySimilar) },
                        visitedIdentifiers: [], hasMore: hasMore, hasFreshPhotos: !hasMore)
                }
                XCTAssertEqual(calls, 1)
                XCTAssertEqual(result?.decisions.count, count)
            }
        }
    }

    func testPartialSetIsKeptWhenContinuationBudgetEnds() async {
        var elapsed: TimeInterval = 0
        var calls = 0
        let result = await HomeCurationSearch.curated(excluding: [], now: { Date(timeIntervalSince1970: elapsed) }) { _, _, _, _ in
            calls += 1; elapsed = 30
            return .init(decisions: [self.unit("one"), self.unit("two", .visuallySimilar)], visitedIdentifiers: [],
                hasMore: true, hasFreshPhotos: true)
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(result?.decisions.compactMap(\.displayIdentifier), ["one", "two"])
    }

    func testOuterCollectionRejectsCandidateReferenceCollisionBetweenPasses() async {
        var calls = 0
        let result = await HomeCurationSearch.curated(excluding: []) { _, _, _, _ in
            calls += 1
            if calls == 1 {
                return .init(decisions: [self.unit("one")], visitedIdentifiers: ["one"], hasMore: true, hasFreshPhotos: true)
            }
            var conflict = self.unit("two", .visuallySimilar)
            conflict.comparisonLocalIdentifier = "one"
            return .init(decisions: [self.unit("kept"), conflict, self.unit("three", .expiredScreen)],
                visitedIdentifiers: ["kept", "two", "three"], hasMore: false)
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(result?.decisions.compactMap(\.displayIdentifier), ["one", "three"])
        XCTAssertFalse(result?.visitedIdentifiers.contains("two") ?? true)
        XCTAssertFalse(result?.visitedIdentifiers.contains("kept") ?? true)
    }

    func testExhaustedOrOnlyRetryablePhotosDoNotLoop() async {
        for batch in [
            PhotoCurationService.ScanBatch(decisions: [], visitedIdentifiers: [], hasMore: true,
                retryableFailureCount: 4, hasFreshPhotos: false),
            PhotoCurationService.ScanBatch(decisions: [], visitedIdentifiers: [], hasMore: false, hasFreshPhotos: true)
        ] {
            var calls = 0
            let result = await HomeCurationSearch.curated(excluding: []) { _, _, _, _ in calls += 1; return batch }
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(result?.retryableFailureCount, batch.retryableFailureCount)
        }
    }

    func testEmptyFreshSearchIsBoundedByThirtyTwoShortRequests() async {
        var calls = 0
        let result = await HomeCurationSearch.curated(excluding: [], now: { Date(timeIntervalSince1970: 0) }) { _, _, _, _ in
            calls += 1
            return .init(decisions: [], visitedIdentifiers: ["checked-\(calls)"], hasMore: true, hasFreshPhotos: true)
        }
        XCTAssertEqual(calls, 32)
        XCTAssertEqual(result?.visitedIdentifiers, Set((1...32).map { "checked-\($0)" }))
        XCTAssertEqual(result?.hasFreshPhotos, true)
    }

    func testDeadlinePreventsAnotherFetchButKeepsCompletedCoverage() async {
        var elapsed: TimeInterval = 0
        var calls = 0
        let result = await HomeCurationSearch.curated(excluding: [], now: { Date(timeIntervalSince1970: elapsed) }) { _, _, _, _ in
            calls += 1; elapsed = 30
            return .init(decisions: [], visitedIdentifiers: ["checked"], hasMore: true, hasFreshPhotos: true)
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(result?.visitedIdentifiers, ["checked"])
    }

    func testInvalidatedRequestDoesNotReturnCoverageOrContinue() async {
        var allowed = true
        var calls = 0
        let result = await HomeCurationSearch.curated(excluding: [], canContinue: { allowed }) { _, _, _, _ in
            calls += 1; allowed = false
            return .init(decisions: [], visitedIdentifiers: ["checked"], hasMore: true, hasFreshPhotos: true)
        }
        XCTAssertEqual(calls, 1)
        XCTAssertNil(result)
    }

    func testForegroundContinuesAfterFirstSliceDeadlineWithoutPublishingAnEmptyConclusion() async {
        var elapsed: TimeInterval = 0
        var calls = 0
        var publications: [Int] = []
        let result = await HomeCurationSearch.curatedContinuing(excluding: ["old"],
            now: { Date(timeIntervalSince1970: elapsed) },
            onUpdate: { publications.append($0.decisions.count) }) { excluded, _, _, _ in
                // Cross one four-second slice, not the whole twelve-second visit.
                calls += 1; elapsed += 5
                if calls == 1 {
                    return .init(decisions: [], visitedIdentifiers: ["checked-first-window"],
                        hasMore: true, hasFreshPhotos: true, workRevision: 1)
                }
                XCTAssertTrue(excluded.contains("checked-first-window"))
                return .init(decisions: [self.unit("one"), self.unit("two", .visuallySimilar), self.unit("three", .expiredScreen)],
                    visitedIdentifiers: ["one", "two", "three"], hasMore: false, workRevision: 2)
            }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(publications, [3])
        XCTAssertEqual(result?.decisions.count, 3)
        XCTAssertEqual(result?.visitedIdentifiers, ["checked-first-window", "one", "two", "three"])
    }

    func testForegroundDoesNotFillRepeatedReasonsAtAnInternalSliceBoundary() async {
        var elapsed = 0.0
        var calls = 0
        var published: [[String]] = []
        let result = await HomeCurationSearch.curatedContinuing(excluding: [], diversityTimeLimit: 9,
            now: { Date(timeIntervalSince1970: elapsed) },
            onUpdate: { published.append($0.decisions.map(\.persistenceKey)) }) { _, _, _, groups in
                calls += 1
                if calls == 1 {
                    elapsed = 4.1
                    return .init(decisions: [self.unit("similar-a", .visuallySimilar), self.unit("similar-b", .visuallySimilar),
                        self.unit("similar-c", .visuallySimilar)], visitedIdentifiers: [],
                        hasMore: true, hasFreshPhotos: true, workRevision: 1)
                }
                XCTAssertEqual(published, [["similar-a"]], "A four-second slice must not end the shared diversity search")
                XCTAssertTrue(groups.contains(.similarCapture))
                elapsed = 7
                return .init(decisions: [self.unit("exact"), self.unit("context", .expiredScreen)],
                    visitedIdentifiers: [], hasMore: false, workRevision: 2)
            }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(result?.decisions.map(\.persistenceKey), ["similar-a", "exact", "context"])
    }

    func testForegroundKeepsVerifiedThreeUsableAfterShortMissingReasonSearch() async {
        var elapsed = 0.0
        var calls = 0
        var published: [[String]] = []
        let result = await HomeCurationSearch.curatedContinuing(excluding: [],
            now: { Date(timeIntervalSince1970: elapsed) },
            onUpdate: { published.append($0.decisions.map(\.persistenceKey)) }) { _, protected, _, groups in
                calls += 1
                if calls == 1 {
                    elapsed = 1
                    return .init(decisions: [self.unit("similar-a", .visuallySimilar), self.unit("similar-b", .visuallySimilar),
                        self.unit("similar-c", .visuallySimilar)], visitedIdentifiers: [],
                        hasMore: true, hasFreshPhotos: true, workRevision: 1)
                }
                XCTAssertTrue(groups.contains(.similarCapture), "Missing reasons get an actual search turn first")
                XCTAssertTrue(protected.contains("kept"))
                XCTAssertEqual(published, [["similar-a"]])
                // The first proof arrived at1s. Its three-second opportunity
                // for missing reasons starts there, after cold setup.
                elapsed = 4.1
                return .init(decisions: [], visitedIdentifiers: [], hasMore: true, hasFreshPhotos: true, workRevision: 2)
            }
        XCTAssertEqual(calls, 2, "A usable three-photo set must not wait nine seconds for missing evidence")
        XCTAssertEqual(result?.decisions.map(\.persistenceKey), ["similar-a", "similar-b", "similar-c"])
        XCTAssertEqual(result?.decisions.map(\.reasonCodes), Array(repeating: [.visuallySimilar], count: 3))
        XCTAssertEqual(published, [["similar-a"], ["similar-a", "similar-b", "similar-c"]])
    }

    func testForegroundSlicesProtectSeedAndDeferredReferencesWhileStreamingAdditions() async {
        var elapsed: TimeInterval = 0
        var calls = 0
        var publications: [[String]] = []
        let result = await HomeCurationSearch.curatedContinuing(excluding: [],
            now: { Date(timeIntervalSince1970: elapsed) },
            onUpdate: { publications.append($0.decisions.compactMap(\.displayIdentifier)) }) { excluded, protected, remaining, _ in
                calls += 1; elapsed += 5
                if calls == 1 {
                    return .init(decisions: [self.unit("one")], visitedIdentifiers: ["one"],
                        hasMore: true, hasFreshPhotos: true,
                        deferredIdentifiers: ["deferred"], deferredReferences: ["keep-deferred"], workRevision: 1)
                }
                XCTAssertEqual(remaining, 2)
                XCTAssertTrue(excluded.isSuperset(of: ["one", "deferred"]))
                XCTAssertTrue(protected.isSuperset(of: ["kept", "keep-deferred"]))
                return .init(decisions: [self.unit("two", .visuallySimilar), self.unit("three", .expiredScreen)],
                    visitedIdentifiers: ["two", "three"], hasMore: false, workRevision: 2)
            }
        XCTAssertEqual(publications, [["one"], ["one", "two", "three"]])
        XCTAssertEqual(result?.decisions.compactMap(\.displayIdentifier), ["one", "two", "three"])
        XCTAssertFalse(result?.visitedIdentifiers.contains("deferred") ?? true)
        XCTAssertFalse(result?.visitedIdentifiers.contains("keep-deferred") ?? true)
    }

    func testForegroundStopsAfterUnchangedWorkRevisionInsteadOfRetryingThreeIdenticalSlices() async {
        var calls = 0
        let result = await HomeCurationSearch.curatedContinuing(excluding: [], maximumAttempts: 1) { _, _, _, _ in
            calls += 1
            return .init(decisions: [], visitedIdentifiers: [], hasMore: true, hasFreshPhotos: true, workRevision: 7)
        }
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(result?.hasFreshPhotos == true)
        XCTAssertTrue(result?.decisions.isEmpty == true)
    }

    func testForegroundDoesNotRestartDiversityWaitOnNextSliceAndKeepsSeedReference() async {
        var elapsed: TimeInterval = 0
        var calls = 0
        var publications: [[String]] = []
        let seed = unit("already-visible")
        let result = await HomeCurationSearch.curatedContinuing(excluding: ["old"],
            initialDecisions: [seed], diversityTimeLimit: 4, timeLimit: 4,
            now: { Date(timeIntervalSince1970: elapsed) },
            onUpdate: { publications.append($0.decisions.compactMap(\.displayIdentifier)) }) { excluded, protected, remaining, _ in
                calls += 1
                XCTAssertEqual(remaining, 2)
                XCTAssertTrue(excluded.isSuperset(of: ["old", "already-visible"]))
                XCTAssertTrue(protected.contains("kept"), "The seed's comparison remains safe during fallback")
                if calls == 1 {
                    elapsed = 5
                    return .init(decisions: [], visitedIdentifiers: ["first-window"],
                        hasMore: true, hasFreshPhotos: true, workRevision: 1)
                }
                XCTAssertTrue(excluded.contains("first-window"))
                elapsed += 0.1
                guard calls == 2 else {
                    return .init(decisions: [], visitedIdentifiers: [], hasMore: false, workRevision: 3)
                }
                return .init(decisions: [self.unit("second"), self.unit("third")],
                    visitedIdentifiers: ["second", "third"], hasMore: true, hasFreshPhotos: true, workRevision: 2)
            }
        XCTAssertEqual(calls, 2, "Known safe candidates should fill the set without another diversity fetch")
        XCTAssertEqual(elapsed, 5.1, accuracy: 0.001)
        XCTAssertEqual(result?.decisions.compactMap(\.displayIdentifier), ["already-visible", "second", "third"])
        XCTAssertEqual(result?.decisions.map(\.reasonCodes), Array(repeating: [.exactDuplicate], count: 3),
            "Repeated reasons remain truthful; fallback does not rewrite the evidence")
        XCTAssertEqual(publications.last, ["already-visible", "second", "third"])
        XCTAssertTrue(publications.allSatisfy { $0.first == "already-visible" })
        XCTAssertFalse(result?.visitedIdentifiers.contains("kept") ?? true)
    }

    func testRejectedNominationDoesNotTurnSourceExhaustionIntoPendingWork() async {
        var calls = 0
        let result = await HomeCurationSearch.curatedContinuing(excluding: [], protectedIdentifiers: ["protected"]) { _, _, _, _ in
            calls += 1
            return .init(decisions: [self.unit("protected")], visitedIdentifiers: ["protected"],
                hasMore: false, hasFreshPhotos: false, workRevision: 1)
        }
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(result?.decisions.isEmpty == true)
        XCTAssertFalse(result?.hasMore ?? true)
        XCTAssertFalse(result?.hasFreshPhotos ?? true)
        XCTAssertFalse(result?.visitedIdentifiers.contains("protected") ?? true)
    }

    func testForegroundContinuationIsBoundedAndRejectsLateInvalidatedSlice() async {
        var calls = 0
        let bounded = await HomeCurationSearch.curatedContinuing(excluding: [], maximumAttempts: 1) { _, _, _, _ in
            calls += 1
            return .init(decisions: [], visitedIdentifiers: ["checked-\(calls)"],
                hasMore: true, hasFreshPhotos: true, workRevision: UInt64(calls))
        }
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(bounded?.visitedIdentifiers.count, 3)

        var valid = true
        var delivered: [String] = []
        var elapsed: TimeInterval = 0
        calls = 0
        let invalidated = await HomeCurationSearch.curatedContinuing(excluding: [],
            now: { Date(timeIntervalSince1970: elapsed) },
            onUpdate: { delivered = $0.decisions.compactMap(\.displayIdentifier) }, canContinue: { valid }) { _, _, _, _ in
                calls += 1; elapsed += 5
                if calls == 1 {
                    return .init(decisions: [self.unit("visible")], visitedIdentifiers: ["visible"],
                        hasMore: true, hasFreshPhotos: true, workRevision: 1)
                }
                valid = false
                return .init(decisions: [self.unit("late", .visuallySimilar)], visitedIdentifiers: ["late"],
                    hasMore: false, workRevision: 2)
            }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(delivered, ["visible"])
        XCTAssertNil(invalidated)
    }
}

@MainActor
final class PhotoRecoveryTests: XCTestCase {
    private final class Access { var status: PHAuthorizationStatus = .authorized }
    private func renderHomePreviews(_ vm: HomeViewModel) {
        for identifier in vm.photoIdentifiers {
            let request = UUID()
            vm.updateHomePhotoPreview(identifier: identifier, generation: vm.photoPreviewGeneration,
                                      requestID: request, state: .loading)
            vm.updateHomePhotoPreview(identifier: identifier, generation: vm.photoPreviewGeneration,
                                      requestID: request, state: .ready)
        }
    }
    private func unit(_ id: String, _ reason: CurationReasonCode = .exactDuplicate) -> DecisionUnit {
        DecisionUnit(id: UUID(), type: .cleanupSingle, status: .pending,
            candidateLocalIdentifiers: [id], recommendedLocalIdentifier: id,
            reasonCodes: [reason], capturedDateDescription: nil, createdAt: Date(),
            comparisonLocalIdentifier: reason == .expiredScreen ? nil : "kept-\(id)")
    }
    private func variedUnit(_ id: String, position: Int) -> DecisionUnit {
        unit(id, [.exactDuplicate, .visuallySimilar, .expiredScreen][position - 1])
    }

    private func reflection(_ id: String, reason: CurationReasonCode = .dailyReflection) -> DecisionUnit {
        DecisionUnit(id: UUID(), type: .recallMoment, status: .pending,
            candidateLocalIdentifiers: [id], recommendedLocalIdentifier: id,
            reasonCodes: [reason], capturedDateDescription: nil, createdAt: Date(),
            evidence: CurationEvidence(reason: reason,
                photoDescription: "오늘 다시 만난 사진", detail: "이 사진엔 어떤 기억이 있나요?"))
    }
    private func context(enabled: Bool = true, hasUnscanned: Bool = false, cloudPhotoCount: Int = 0) -> (HomeViewModel, LocalActivityStore, SubscriptionStore, RecoveryService, Access, UserDefaults) {
        let name = "photo-recovery-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let activity = LocalActivityStore(defaults: defaults)
        let subscription = SubscriptionStore(defaults: defaults, enabled: enabled)
        let service = RecoveryService(hasUnscanned: hasUnscanned, cloudPhotoCount: cloudPhotoCount)
        let access = Access()
        let vm = HomeViewModel(featureAccess: .init(plan: .free, isSimilarPhotoCleanupEnabled: false),
            subscriptions: subscription, curationService: service, activity: activity,
            authorizationStatus: { access.status }, observesPhotoLibrary: false, selectionDefaults: defaults)
        return (vm, activity, subscription, service, access, defaults)
    }

    func testBatchSelectionCompletesOnlySelectedPhotosAndIgnoresRepeatedSuccess() async throws {
        let (vm, store, _, service, _, defaults) = context(enabled: false)
        let photos = (1...3).map { unit("batch-selected-\($0)") }
        let records = SavedRecordStore(defaults: defaults)
        let existing = try records.save(text: "기존 기록 보존", photoLocalIdentifier: "older-batch-photo", capturedDateDescription: nil)
        let originalRecords = defaults.data(forKey: UserScopedStorage.key(SavedRecordStore.storageKey))
        store.beginDailySession(photoIdentifiers: photos.compactMap(\.displayIdentifier),
            curationReasons: Dictionary(uniqueKeysWithValues: photos.map { ($0.persistenceKey, .exactDuplicate) }))
        await service.setRestored(.init(decisions: photos, retryableFailureCount: 0))
        await vm.onAppear()

        XCTAssertNil(vm.beginSelectedCleanup(), "An empty selection cannot start a transaction")
        vm.toggleCleanupSelection(photos[0])
        vm.toggleCleanupSelection(photos[2])
        XCTAssertEqual(vm.selectedCleanupCount, 2)
        renderHomePreviews(vm)
        let snapshot = try XCTUnwrap(vm.beginSelectedCleanup())
        XCTAssertEqual(snapshot.map(\.persistenceKey), [photos[0].persistenceKey, photos[2].persistenceKey])
        XCTAssertTrue(vm.isCommittingSelection)
        XCTAssertNil(vm.cleanupResultMessage, "Selection and the pending system prompt are not a successful deletion")
        XCTAssertNil(vm.beginSelectedCleanup(), "Rapid repeated taps cannot start another batch")
        vm.toggleCleanupSelection(photos[1])
        XCTAssertEqual(vm.selectedCleanupCount, 2, "Selection is frozen while the system confirmation is open")

        vm.completeSelectedCleanup(snapshot)
        vm.endSelectedCleanup()
        XCTAssertFalse(vm.isCommittingSelection)
        XCTAssertEqual(vm.photoIdentifiers, [photos[1].persistenceKey])
        XCTAssertEqual(vm.selectedCleanupCount, 0)
        XCTAssertTrue(vm.selectedCleanupKeys.isEmpty)
        XCTAssertEqual(vm.cleanupResultMessage, "사진 2장을 비웠어요. 선택하지 않은 1장은 그대로예요.")
        vm.browsePhoto(at: vm.currentDecisionIndex)
        XCTAssertNotNil(vm.cleanupResultMessage, "The carousel's index normalization must not dismiss the result")
        XCTAssertEqual(store.dailySessionProgress().processedDecisionKeys, Set(snapshot.map(\.persistenceKey)))
        XCTAssertEqual(store.weeklySnapshot().deletedPhotoCount, 2)
        guard case .ready(let remaining) = vm.state else { return XCTFail("The unselected photo remains in the carousel") }
        XCTAssertEqual(remaining.persistenceKey, photos[1].persistenceKey)
        vm.completeSelectedCleanup(snapshot)
        XCTAssertEqual(vm.photoIdentifiers, [photos[1].persistenceKey])
        XCTAssertEqual(store.weeklySnapshot().deletedPhotoCount, 2)
        XCTAssertEqual(vm.cleanupResultMessage, "사진 2장을 비웠어요. 선택하지 않은 1장은 그대로예요.")

        vm.finishReviewing()
        XCTAssertNil(vm.cleanupResultMessage)
        guard case .completed(let summary) = vm.state else { return XCTFail("Finishing the last unselected photo completes the session") }
        XCTAssertEqual(summary.deletedCount, 2)
        XCTAssertEqual(summary.reviewedCount, 3)
        vm.completeSelectedCleanup(snapshot)
        XCTAssertEqual(store.weeklySnapshot().deletedPhotoCount, 2, "A late callback cannot create a second daily deletion")
        XCTAssertEqual(store.todaySummary()?.deletedPhotoCount, 2)
        XCTAssertEqual(records.records().map(\.id), [existing.id])
        XCTAssertEqual(defaults.data(forKey: UserScopedStorage.key(SavedRecordStore.storageKey)), originalRecords)
    }

    func testPartialCleanupFeedbackLastsUntilBrowsingOrChangingSelection() async throws {
        let (vm, store, _, service, _, _) = context(enabled: false)
        let photos = (1...3).map { unit("batch-feedback-\($0)") }
        store.beginDailySession(photoIdentifiers: photos.compactMap(\.displayIdentifier),
            curationReasons: Dictionary(uniqueKeysWithValues: photos.map { ($0.persistenceKey, .exactDuplicate) }))
        await service.setRestored(.init(decisions: photos, retryableFailureCount: 0))
        await vm.onAppear()

        vm.toggleCleanupSelection(photos[0])
        renderHomePreviews(vm)
        let first = try XCTUnwrap(vm.beginSelectedCleanup())
        vm.completeSelectedCleanup(first)
        vm.endSelectedCleanup()
        XCTAssertEqual(vm.cleanupResultMessage, "사진 1장을 비웠어요. 선택하지 않은 2장은 그대로예요.")
        vm.browsePhoto(at: 99)
        XCTAssertNotNil(vm.cleanupResultMessage, "An invalid index must not count as browsing")

        vm.browsePhoto(at: 1)
        XCTAssertNil(vm.cleanupResultMessage)
        XCTAssertEqual(vm.photoIdentifiers, [photos[1].persistenceKey, photos[2].persistenceKey])
        XCTAssertTrue(vm.selectedCleanupKeys.isEmpty, "Browsing only dismisses feedback")
        vm.toggleCleanupSelection(photos[2])
        let second = try XCTUnwrap(vm.beginSelectedCleanup())
        vm.completeSelectedCleanup(second)
        vm.endSelectedCleanup()
        XCTAssertEqual(vm.cleanupResultMessage, "사진 1장을 비웠어요. 선택하지 않은 1장은 그대로예요.")

        vm.toggleCleanupSelection(photos[1])
        XCTAssertNil(vm.cleanupResultMessage)
        XCTAssertEqual(vm.selectedCleanupCount, 1)
        XCTAssertEqual(store.weeklySnapshot().deletedPhotoCount, 2,
                       "Beginning a new selection cannot count as deleting the remaining photo")
    }

    func testFullCleanupUsesCompletionWithoutPartialFeedback() async throws {
        let (vm, store, _, service, _, _) = context(enabled: false)
        let photos = (1...3).map { unit("batch-full-feedback-\($0)") }
        store.beginDailySession(photoIdentifiers: photos.compactMap(\.displayIdentifier),
            curationReasons: Dictionary(uniqueKeysWithValues: photos.map { ($0.persistenceKey, .exactDuplicate) }))
        await service.setRestored(.init(decisions: photos, retryableFailureCount: 0))
        await vm.onAppear()
        photos.forEach(vm.toggleCleanupSelection)
        renderHomePreviews(vm)
        let selected = try XCTUnwrap(vm.beginSelectedCleanup())
        XCTAssertNil(vm.cleanupResultMessage)
        vm.completeSelectedCleanup(selected)
        vm.endSelectedCleanup()

        guard case .completed(let summary) = vm.state else { return XCTFail("All three deletions keep the existing completion flow") }
        XCTAssertEqual(summary.deletedCount, 3)
        XCTAssertNil(vm.cleanupResultMessage)
        XCTAssertTrue(vm.photoIdentifiers.isEmpty)
        XCTAssertEqual(store.weeklySnapshot().deletedPhotoCount, 3)
    }

    func testCancelledBatchLeavesSelectionAndPendingPhotosUnchanged() async throws {
        let (vm, store, _, service, _, _) = context(enabled: false)
        let photos = (1...3).map { unit("batch-cancel-\($0)") }
        store.beginDailySession(photoIdentifiers: photos.compactMap(\.displayIdentifier),
            curationReasons: Dictionary(uniqueKeysWithValues: photos.map { ($0.persistenceKey, .exactDuplicate) }))
        await service.setRestored(.init(decisions: photos, retryableFailureCount: 0))
        await vm.onAppear()
        vm.toggleCleanupSelection(photos[0])
        vm.toggleCleanupSelection(photos[1])
        renderHomePreviews(vm)
        let firstAttempt = try XCTUnwrap(vm.beginSelectedCleanup())
        vm.endSelectedCleanup()

        XCTAssertNil(vm.cleanupResultMessage, "Cancellation must never produce successful cleanup feedback")
        XCTAssertEqual(vm.selectedCleanupCount, 2)
        XCTAssertEqual(vm.photoIdentifiers, photos.compactMap(\.displayIdentifier))
        XCTAssertTrue(store.dailySessionProgress().processedDecisionKeys.isEmpty)
        XCTAssertEqual(store.weeklySnapshot().deletedPhotoCount, 0)
        XCTAssertEqual(vm.beginSelectedCleanup()?.map(\.persistenceKey), firstAttempt.map(\.persistenceKey))
        vm.endSelectedCleanup()
    }

    func testChangedCleanupKeepsSelectionAndCountsUntilExplicitRecheck() async throws {
        let (vm, store, _, service, _, defaults) = context(enabled: false)
        let photos = (1...3).map { unit("batch-recheck-\($0)") }
        store.beginDailySession(photoIdentifiers: photos.compactMap(\.displayIdentifier),
            curationReasons: Dictionary(uniqueKeysWithValues: photos.map { ($0.persistenceKey, .exactDuplicate) }))
        await service.setRestored(.init(decisions: photos, retryableFailureCount: 0))
        await vm.onAppear()
        vm.toggleCleanupSelection(photos[0])
        vm.toggleCleanupSelection(photos[2])
        let selection = defaults.stringArray(forKey: UserScopedStorage.key("recoco_cleanup_selection_v1"))
        renderHomePreviews(vm)
        let snapshots = try XCTUnwrap(vm.beginSelectedCleanup())
        vm.reportCleanupFailure(PhotoDeletionController.DeletionError.changedPhotos)
        vm.endSelectedCleanup()

        XCTAssertEqual(vm.cleanupRecovery, .changedPhotos)
        XCTAssertNil(vm.cleanupResultMessage, "Failed validation must never produce successful cleanup feedback")
        XCTAssertFalse(vm.showToast, "Recovery must not disappear with a transient toast")
        XCTAssertEqual(vm.selectedCleanupCount, 2)
        XCTAssertEqual(defaults.stringArray(forKey: UserScopedStorage.key("recoco_cleanup_selection_v1")), selection)
        XCTAssertTrue(store.dailySessionProgress().processedDecisionKeys.isEmpty)
        XCTAssertEqual(store.weeklySnapshot().deletedPhotoCount, 0)
        XCTAssertNil(vm.beginSelectedCleanup(), "Stale evidence must be checked before another delete request")

        await vm.recheckCleanupPhotos()
        XCTAssertNil(vm.cleanupRecovery)
        XCTAssertEqual(vm.selectedCleanupCount, 2)
        renderHomePreviews(vm)
        XCTAssertEqual(vm.beginSelectedCleanup()?.map(\.persistenceKey), snapshots.map(\.persistenceKey))
        vm.endSelectedCleanup()
        XCTAssertEqual(store.weeklySnapshot().deletedPhotoCount, 0)
    }

    func testUnknownCleanupFailureDoesNotClaimPhotosWereKeptOrAutoRetry() async throws {
        let (vm, store, _, service, _, _) = context(enabled: false)
        let photo = unit("batch-unconfirmed")
        store.beginDailySession(photoIdentifiers: [photo.persistenceKey], curationReasons: [photo.persistenceKey: .exactDuplicate])
        await service.setRestored(.init(decisions: [photo], retryableFailureCount: 0))
        await vm.onAppear()
        vm.toggleCleanupSelection(photo)
        renderHomePreviews(vm)
        XCTAssertNotNil(vm.beginSelectedCleanup())
        vm.reportCleanupFailure(NSError(domain: "test.ambiguous-transaction", code: 1))
        vm.endSelectedCleanup()

        XCTAssertEqual(vm.cleanupRecovery, .unconfirmed)
        XCTAssertNil(vm.cleanupResultMessage, "An unconfirmed transaction cannot claim a successful deletion")
        XCTAssertTrue(vm.cleanupRecovery?.title.contains("완료 여부") == true)
        XCTAssertFalse(vm.cleanupRecovery?.message.contains("사진은 그대로") == true)
        XCTAssertEqual(vm.selectedCleanupCount, 1)
        XCTAssertNil(vm.beginSelectedCleanup())
        XCTAssertTrue(store.dailySessionProgress().processedDecisionKeys.isEmpty)
        XCTAssertEqual(store.weeklySnapshot().deletedPhotoCount, 0)
    }

    func testCleanupAccessFailureOffersCorrectRecoveryWithoutChangingSelection() async {
        let (vm, _, _, _, access, _) = context(enabled: false)
        vm.reportCleanupFailure(NSError(domain: PHPhotosErrorDomain,
            code: PHPhotosError.Code.accessUserDenied.rawValue))
        XCTAssertEqual(vm.cleanupRecovery, .accessDenied)
        vm.reportCleanupFailure(NSError(domain: PHPhotosErrorDomain,
            code: PHPhotosError.Code.accessRestricted.rawValue))
        XCTAssertEqual(vm.cleanupRecovery, .accessRestricted)
        access.status = .denied
        vm.reportCleanupFailure(PhotoDeletionController.DeletionError.changedPhotos)
        XCTAssertEqual(vm.cleanupRecovery, .accessDenied, "Current permission takes precedence over generic changed evidence")
        access.status = .restricted
        vm.reportCleanupFailure(NSError(domain: "test", code: 0))
        XCTAssertEqual(vm.cleanupRecovery, .accessRestricted)
    }

    func testSelectedCleanupRestoresByStablePhotoKeyAcrossRelaunch() async throws {
        let (vm, store, subscriptions, service, access, defaults) = context(enabled: false)
        let photos = (1...3).map { unit("batch-relaunch-\($0)") }
        store.beginDailySession(photoIdentifiers: photos.compactMap(\.displayIdentifier),
            curationReasons: Dictionary(uniqueKeysWithValues: photos.map { ($0.persistenceKey, .exactDuplicate) }))
        await service.setRestored(.init(decisions: photos, retryableFailureCount: 0))
        await vm.onAppear()
        vm.toggleCleanupSelection(photos[1])
        vm.toggleCleanupSelection(photos[2])
        let recreated = photos.map { unit($0.persistenceKey) }
        XCTAssertNotEqual(recreated[1].id, photos[1].id)
        await service.setRestored(.init(decisions: recreated, retryableFailureCount: 0))
        let reopenedStore = LocalActivityStore(defaults: defaults)
        let reopened = HomeViewModel(subscriptions: subscriptions, curationService: service, activity: reopenedStore,
            authorizationStatus: { access.status }, observesPhotoLibrary: false, selectionDefaults: defaults)
        await reopened.onAppear()

        XCTAssertEqual(reopened.selectedCleanupCount, 2)
        XCTAssertEqual(reopened.selectedCleanupUnits.map(\.persistenceKey), [photos[1].persistenceKey, photos[2].persistenceKey])
        XCTAssertTrue(reopenedStore.dailySessionProgress().processedDecisionKeys.isEmpty)
        XCTAssertEqual(reopenedStore.weeklySnapshot().deletedPhotoCount, 0)
        reopened.focusSelectedPhoto(recreated[2])
        XCTAssertEqual(reopened.currentDecisionIndex, 2)
        reopened.toggleCleanupSelection(recreated[2])
        XCTAssertEqual(reopened.selectedCleanupCount, 1)
        XCTAssertEqual(reopened.selectedCleanupUnits.first?.persistenceKey, photos[1].persistenceKey)
    }

    func testBatchSuccessKeepsUnreadableRestoredPhotoPending() async throws {
        let (vm, store, _, service, _, _) = context(enabled: false)
        let photos = (1...3).map { unit("batch-unreadable-\($0)") }
        store.beginDailySession(photoIdentifiers: photos.compactMap(\.displayIdentifier),
            curationReasons: Dictionary(uniqueKeysWithValues: photos.map { ($0.persistenceKey, .exactDuplicate) }))
        await service.setRestored(.init(decisions: Array(photos.prefix(2)), retryableFailureCount: 1))
        await vm.onAppear()
        vm.toggleCleanupSelection(photos[0])
        vm.toggleCleanupSelection(photos[1])
        renderHomePreviews(vm)
        let snapshot = try XCTUnwrap(vm.beginSelectedCleanup())
        vm.completeSelectedCleanup(snapshot)
        vm.endSelectedCleanup()

        guard case .noCandidate = vm.state else { return XCTFail("An unreadable pending photo prevents a completed-session claim") }
        XCTAssertTrue(vm.hasScanIssue)
        XCTAssertTrue(vm.hasDeletedPhotosInSession)
        XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, photos.compactMap(\.displayIdentifier))
        XCTAssertEqual(store.dailySessionProgress().processedDecisionKeys, Set(snapshot.map(\.persistenceKey)))
        XCTAssertEqual(store.weeklySnapshot().deletedPhotoCount, 2)
        await service.setRestored(.init(decisions: [photos[2]], retryableFailureCount: 0))
        await vm.retryCuration()
        guard case .ready(let recovered) = vm.state else { return XCTFail("The unreadable third photo must remain recoverable") }
        XCTAssertEqual(recovered.persistenceKey, photos[2].persistenceKey)
        XCTAssertEqual(store.weeklySnapshot().deletedPhotoCount, 2)
    }

    func testSavedMiddleDecisionContinuesToNextPhotoAndRestoresRemainingQueueOnce() async throws {
        let (vm, store, subscriptions, service, access, defaults) = context(enabled: false)
        let photos = [reflection("continue-first"), reflection("continue-middle"), reflection("continue-last")]
        let records = SavedRecordStore(defaults: defaults)
        let existing = try records.save(text: "이미 남겨둔 기록", photoLocalIdentifier: "older-photo", capturedDateDescription: nil)
        store.beginDailySession(photoIdentifiers: photos.compactMap(\.displayIdentifier),
            curationReasons: Dictionary(uniqueKeysWithValues: photos.map { ($0.persistenceKey, .dailyReflection) }))
        await service.setRestored(.init(decisions: photos, retryableFailureCount: 0))
        await vm.onAppear()
        vm.currentDecisionIndex = 1

        let saved = try records.save(text: "지금 남긴 기록", photoLocalIdentifier: photos[1].displayIdentifier, capturedDateDescription: nil)
        XCTAssertTrue(vm.markTodayCompleted(unit: photos[1], deletedCount: 0, savedRecord: true, protectPhoto: false))
        guard case .ready(let next) = vm.state else { return XCTFail("A middle save must continue without a completion screen") }
        XCTAssertEqual(next.persistenceKey, photos[2].persistenceKey)
        XCTAssertEqual(vm.photoIdentifiers, [photos[0].persistenceKey, photos[2].persistenceKey])
        XCTAssertEqual(store.dailySessionProgress().processedDecisionKeys, [photos[1].persistenceKey])
        XCTAssertEqual(store.weeklySnapshot().savedRecordCount, 1)

        XCTAssertFalse(vm.markTodayCompleted(unit: photos[1], deletedCount: 0, savedRecord: true, protectPhoto: false),
                       "Repeated success must not announce or account for a second completion")
        XCTAssertEqual(store.weeklySnapshot().savedRecordCount, 1)
        let recordsAfterSave = defaults.data(forKey: UserScopedStorage.key(SavedRecordStore.storageKey))
        await service.setRestored(.init(decisions: [photos[0], photos[2]], retryableFailureCount: 0))
        let reopenedStore = LocalActivityStore(defaults: defaults)
        let reopened = HomeViewModel(subscriptions: subscriptions, curationService: service, activity: reopenedStore,
            authorizationStatus: { access.status }, observesPhotoLibrary: false)

        await reopened.onAppear()

        guard case .ready = reopened.state else { return XCTFail("Relaunch must restore the unfinished carousel") }
        XCTAssertEqual(reopened.photoIdentifiers, [photos[0].persistenceKey, photos[2].persistenceKey])
        XCTAssertEqual(reopenedStore.dailySessionProgress().processedDecisionKeys, [photos[1].persistenceKey])
        XCTAssertEqual(reopened.weeklyProgress.savedRecordCount, 1)
        XCTAssertEqual(Set(records.records().map(\.id)), Set([existing.id, saved.id]))
        XCTAssertEqual(defaults.data(forKey: UserScopedStorage.key(SavedRecordStore.storageKey)), recordsAfterSave)
        let fetches = await service.fetchLimits
        XCTAssertTrue(fetches.isEmpty, "Continuing and relaunching must not request a replacement batch")
    }

    func testOutOfOrderDecisionsShowCompletionOnlyWhenEveryPhotoIsHandled() async {
        let (vm, store, _, service, _, _) = context(enabled: false)
        let photos = (1...3).map { reflection("out-of-order-\($0)") }
        store.beginDailySession(photoIdentifiers: photos.compactMap(\.displayIdentifier),
            curationReasons: Dictionary(uniqueKeysWithValues: photos.map { ($0.persistenceKey, .dailyReflection) }))
        await service.setRestored(.init(decisions: photos, retryableFailureCount: 0))
        await vm.onAppear()
        vm.currentDecisionIndex = 2

        XCTAssertTrue(vm.markTodayCompleted(unit: photos[2], deletedCount: 1, savedRecord: false, protectPhoto: false))
        guard case .ready(let previous) = vm.state else { return XCTFail("The last carousel position is not the final unhandled photo") }
        XCTAssertEqual(previous.persistenceKey, photos[1].persistenceKey)
        XCTAssertEqual(vm.photoIdentifiers, [photos[0].persistenceKey, photos[1].persistenceKey])
        XCTAssertTrue(vm.hasDeletedPhotosInSession, "Recovery instructions must remain available after returning to the carousel")

        XCTAssertTrue(vm.markTodayCompleted(unit: photos[1], deletedCount: 0, savedRecord: true, protectPhoto: false))
        guard case .ready(let first) = vm.state else { return XCTFail("The unvisited first photo must remain available") }
        XCTAssertEqual(first.persistenceKey, photos[0].persistenceKey)
        XCTAssertTrue(vm.markTodayCompleted(unit: photos[0], deletedCount: 0, savedRecord: false, protectPhoto: false))
        guard case .completed(let summary) = vm.state else { return XCTFail("Only the final handled photo completes the session") }
        XCTAssertEqual(summary.reviewedCount, 3)
        XCTAssertEqual(summary.deletedCount, 1)
        XCTAssertEqual(summary.savedRecordCount, 1)
        XCTAssertTrue(vm.photoIdentifiers.isEmpty)

        XCTAssertFalse(vm.markTodayCompleted(unit: photos[0], deletedCount: 1, savedRecord: true, protectPhoto: false))
        XCTAssertEqual(store.todaySummary()?.deletedPhotoCount, 1)
        XCTAssertEqual(store.todaySummary()?.savedRecordCount, 1)
        guard case .completed(let unchangedSummary) = vm.state else { return XCTFail("A stale callback must not change the finished route") }
        XCTAssertEqual(unchangedSummary.reviewedCount, 3)
    }

    func testLastReadableSuccessKeepsUnreadablePhotoPendingUntilRecovery() async {
        let (vm, store, subscriptions, service, _, _) = context()
        let available = reflection("continue-readable")
        let unavailable = reflection("continue-unreadable")
        store.beginDailySession(photoIdentifiers: [available.persistenceKey, unavailable.persistenceKey],
            curationReasons: [available.persistenceKey: .dailyReflection, unavailable.persistenceKey: .dailyReflection])
        await service.setRestored(.init(decisions: [available], retryableFailureCount: 1))
        await vm.onAppear()

        XCTAssertTrue(vm.markTodayCompleted(unit: available, deletedCount: 1, savedRecord: false, protectPhoto: false))
        guard case .noCandidate = vm.state else { return XCTFail("A success is not full completion while another photo cannot be read") }
        XCTAssertTrue(vm.hasScanIssue)
        XCTAssertTrue(vm.hasDeletedPhotosInSession)
        XCTAssertFalse(subscriptions.firstExperienceCompleted)
        XCTAssertEqual(store.dailySessionProgress().processedDecisionKeys, [available.persistenceKey])
        XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, [available.persistenceKey, unavailable.persistenceKey])
        XCTAssertFalse(vm.markTodayCompleted(unit: available, deletedCount: 1, savedRecord: false, protectPhoto: false))
        XCTAssertEqual(store.weeklySnapshot().deletedPhotoCount, 1)

        await service.setRestored(.init(decisions: [unavailable], retryableFailureCount: 0))
        await vm.retryCuration()
        guard case .ready(let recovered) = vm.state else { return XCTFail("Recovery must expose the remaining photo directly") }
        XCTAssertEqual(recovered.persistenceKey, unavailable.persistenceKey)
        XCTAssertTrue(vm.hasDeletedPhotosInSession, "The committed deletion's recovery guide survives photo-read recovery")
        XCTAssertTrue(vm.markTodayCompleted(unit: recovered, deletedCount: 0, savedRecord: false, protectPhoto: false))
        guard case .completed(let summary) = vm.state else { return XCTFail("The session finishes only after the recovered photo is handled") }
        XCTAssertEqual(summary.reviewedCount, 2)
        XCTAssertEqual(summary.deletedCount, 1)
    }

    func testNoCleanupCandidatesNeverPadsWithRecentPhotosAndPreservesRecords() async throws {
        let (vm, store, _, service, _, defaults) = context()
        let records = SavedRecordStore(defaults: defaults)
        try records.save(text: "이미 남긴 기억", photoLocalIdentifier: "saved-photo", capturedDateDescription: nil)
        let originalBytes = defaults.data(forKey: UserScopedStorage.key(SavedRecordStore.storageKey))
        let before = store.weeklySnapshot()
        let ordinaryPhotos = (1...3).map { reflection("reflection-\($0)") }
        await service.setBatch(.init(decisions: [], visitedIdentifiers: ["checked"], hasMore: false, accessiblePhotoCount: 7))
        await service.setReflections(ordinaryPhotos)

        await vm.onAppear()

        guard case .noCandidate = vm.state else { return XCTFail("Readable recent photos are not deletion evidence") }
        XCTAssertTrue(vm.photoIdentifiers.isEmpty)
        XCTAssertEqual(vm.totalDecisionCount, 0)
        XCTAssertTrue(vm.lastScanFoundNoCandidates)
        let calls = await service.reflectionCalls
        XCTAssertTrue(calls.isEmpty, "Automatic cleanup must not invoke the reflection filler")
        XCTAssertTrue(store.dailySessionProgress().curationReasons.isEmpty)
        XCTAssertEqual(defaults.data(forKey: UserScopedStorage.key(SavedRecordStore.storageKey)), originalBytes)
        XCTAssertEqual(store.weeklySnapshot().savedRecordCount, before.savedRecordCount)
        XCTAssertEqual(store.weeklySnapshot().deletedPhotoCount, before.deletedPhotoCount)
    }

    func testAdditionalBatchKeepsOneVerifiedCandidateWithoutPaddingOrLosingPriorChoices() async throws {
        let (vm, store, _, service, _, defaults) = context()
        store.beginDailySession(photoIdentifiers: ["already-processed"])
        store.recordDailyDecision(decisionKey: "already-processed", deletedPhotoCount: 1, savedRecord: true)
        store.clearPendingRecommendations()
        let records = SavedRecordStore(defaults: defaults)
        try records.save(text: "보존할 기록", photoLocalIdentifier: "record-photo", capturedDateDescription: nil)
        let originalBytes = defaults.data(forKey: UserScopedStorage.key(SavedRecordStore.storageKey))
        let before = store.weeklySnapshot()
        var cleanup = unit("cleanup")
        cleanup.comparisonLocalIdentifier = "comparison-reference"
        await service.setBatch(.init(decisions: [cleanup], visitedIdentifiers: ["cleanup", "comparison-reference"], hasMore: false))
        await service.setReflections([reflection("reflection-a"), reflection("reflection-b")])

        await vm.loadMoreDecisions()

        XCTAssertEqual(vm.photoIdentifiers, ["cleanup"])
        XCTAssertEqual(vm.totalDecisionCount, 1, "Show the available count instead of inventing three")
        let calls = await service.reflectionCalls
        XCTAssertTrue(calls.isEmpty)
        let session = store.dailySessionProgress()
        XCTAssertEqual(session.comparisonReferences, ["cleanup": "comparison-reference"])
        XCTAssertEqual(session.processedDecisionKeys, ["already-processed"])
        XCTAssertEqual(session.deletedPhotoCount, 1)
        XCTAssertEqual(session.savedRecordCount, 1)
        XCTAssertEqual(defaults.data(forKey: UserScopedStorage.key(SavedRecordStore.storageKey)), originalBytes)
        XCTAssertEqual(store.weeklySnapshot().savedRecordCount, before.savedRecordCount)
        XCTAssertEqual(store.weeklySnapshot().deletedPhotoCount, before.deletedPhotoCount)
    }

    func testOneOrTwoVerifiedCandidatesUseActualCountWithoutReflectionPadding() async {
        for count in [1, 2] {
            let (vm, store, _, service, access, _) = context(enabled: false)
            access.status = .limited
            let candidates = (1...count).map { variedUnit("verified-\(count)-\($0)", position: $0) }
            await service.setBatch(.init(decisions: candidates,
                visitedIdentifiers: Set(candidates.compactMap(\.displayIdentifier)), hasMore: false, accessiblePhotoCount: count + 1))
            await service.setReflections([reflection("readable-but-no-evidence")])

            await vm.onAppear()

            guard case .ready = vm.state else { return XCTFail("Verified candidates remain useful when fewer than three exist") }
            XCTAssertEqual(vm.photoIdentifiers, candidates.compactMap(\.displayIdentifier))
            XCTAssertEqual(vm.totalDecisionCount, count)
            XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, candidates.compactMap(\.displayIdentifier))
            let calls = await service.reflectionCalls
            XCTAssertTrue(calls.isEmpty)
            for photo in candidates {
                XCTAssertTrue(vm.markTodayCompleted(unit: photo, deletedCount: 0, savedRecord: false, protectPhoto: false))
            }
            guard case .completed(let summary) = vm.state else { return XCTFail("Only the actual available set should finish") }
            XCTAssertEqual(summary.reviewedCount, count)
            XCTAssertEqual(summary.deletedCount, 0)
        }
    }

    func testHomeRejectsReflectionReturnedInsideCleanupBatch() async {
        let (vm, store, _, service, _, _) = context()
        await service.setBatch(.init(decisions: [reflection("recent-photo")], visitedIdentifiers: ["recent-photo"], hasMore: false))
        await vm.onAppear()
        XCTAssertTrue(vm.photoIdentifiers.isEmpty)
        XCTAssertTrue(store.dailySessionProgress().curatedPhotoIdentifiers.isEmpty)
        guard case .noCandidate = vm.state else { return XCTFail("A recent photo must not become a cleanup candidate") }
    }

    func testLegacyRecentPhotoQueueIsRescannedWithoutChangingRecordsOrProcessedCounts() async throws {
        XCTAssertGreaterThan(PhotoCurationService.curationVersion, 5)
        for completedCount in [0, 1] {
            let (vm, store, _, service, _, defaults) = context(enabled: false)
            let records = SavedRecordStore(defaults: defaults)
            let saved = try records.save(text: "변경 없이 남아 있을 기록", photoLocalIdentifier: "recorded-photo", capturedDateDescription: nil)
            store.recordIndependentMemory(recordID: saved.id)
            store.beginDailySession(photoIdentifiers: ["old-recent-a", "old-recent-b"],
                curationReasons: ["old-recent-a": .dailyReflection, "old-recent-b": .dailyReflection])
            if completedCount == 1 {
                store.recordDailyDecision(decisionKey: "already-processed", deletedPhotoCount: 1, savedRecord: false)
            }
            let key = UserScopedStorage.key("recoco_daily_session_v1")
            let encoded = try XCTUnwrap(defaults.data(forKey: key))
            var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            legacy["curationVersion"] = 5
            defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: key)
            let beforeSession = store.dailySessionProgress()
            let beforeActivity = store.weeklySnapshot()
            let recordBytes = defaults.data(forKey: UserScopedStorage.key(SavedRecordStore.storageKey))
            let protectedBytes = defaults.object(forKey: UserScopedStorage.key("recoco_protected_photos_v1")) as? [String]
            let fresh = (1...3).map { variedUnit("evidence-\(completedCount)-\($0)", position: $0) }
            await service.setBatch(.init(decisions: fresh,
                visitedIdentifiers: Set(fresh.map(\.persistenceKey)), hasMore: false, accessiblePhotoCount: 8))
            // A stale fallback must not win merely because it was persisted before the upgrade.
            await service.setReflections([reflection("old-recent-a"), reflection("old-recent-b")])

            await vm.onAppear()

            guard case .ready(let current) = vm.state else { return XCTFail("The upgrade should search automatically for real cleanup evidence") }
            XCTAssertFalse(current.reasonCodes.contains(where: \.isReflection))
            XCTAssertEqual(vm.photoIdentifiers, Array(fresh.prefix(3 - completedCount)).compactMap(\.displayIdentifier))
            XCTAssertEqual(vm.totalDecisionCount, 3)
            let after = store.dailySessionProgress()
            XCTAssertEqual(after.curationVersion, PhotoCurationService.curationVersion)
            XCTAssertEqual(after.processedDecisionKeys, beforeSession.processedDecisionKeys)
            XCTAssertEqual(after.deletedPhotoCount, beforeSession.deletedPhotoCount)
            XCTAssertEqual(after.savedRecordCount, beforeSession.savedRecordCount)
            XCTAssertFalse(after.curationReasons.values.contains(where: \.isReflection))
            XCTAssertEqual(store.weeklySnapshot().deletedPhotoCount, beforeActivity.deletedPhotoCount)
            XCTAssertEqual(store.weeklySnapshot().savedRecordCount, beforeActivity.savedRecordCount)
            XCTAssertEqual(defaults.data(forKey: UserScopedStorage.key(SavedRecordStore.storageKey)), recordBytes)
            XCTAssertEqual(defaults.object(forKey: UserScopedStorage.key("recoco_protected_photos_v1")) as? [String], protectedBytes)
            let searches = await service.fetchLimits
            let restores = await service.restoreIdentifiers
            let reflectionCalls = await service.reflectionCalls
            XCTAssertEqual(searches, [3 - completedCount])
            XCTAssertTrue(restores.isEmpty, "Version-five recent-photo queues must be searched again rather than replayed")
            XCTAssertTrue(reflectionCalls.isEmpty)
        }
    }

    func testCompletedCleanupBatchIsNotOfferedAgainWhenRequestingMore() async {
        let (vm, store, _, service, _, _) = context(enabled: false)
        let photos = (1...3).map { variedUnit("reviewed-cleanup-\($0)", position: $0) }
        await service.setBatch(.init(decisions: photos, visitedIdentifiers: Set(photos.map(\.persistenceKey)), hasMore: false))
        await vm.onAppear()
        for photo in photos {
            vm.markTodayCompleted(unit: photo, deletedCount: 0, savedRecord: false, protectPhoto: false)
        }
        guard case .completed = vm.state else { return XCTFail("The verified batch should finish") }
        XCTAssertTrue(store.dailySessionProgress().curatedPhotoIdentifiers.isEmpty)
        let before = store.weeklySnapshot()
        store.resetScannedPhotos()

        // The scanner deliberately repeats its result to exercise Home's second boundary.
        await vm.loadMoreDecisions()

        XCTAssertTrue(vm.photoIdentifiers.isEmpty, "Already reviewed photos must not become a new batch")
        guard case .noCandidate = vm.state else { return XCTFail("Previously reviewed photos are not a new batch") }
        let calls = await service.fetchLimits
        XCTAssertEqual(calls, [3, 3])
        XCTAssertEqual(store.reviewedPhotoIdentifiers(), Set(photos.compactMap(\.displayIdentifier)))
        XCTAssertEqual(store.weeklySnapshot().savedRecordCount, before.savedRecordCount)
        XCTAssertEqual(store.weeklySnapshot().deletedPhotoCount, before.deletedPhotoCount)
    }

    func testRelaunchRestoresPersistedReflectionReasonWithoutStartingAnotherSearch() async {
        let (_, store, subscriptions, service, access, defaults) = context()
        let photo = reflection("persisted-reflection")
        store.beginDailySession(photoIdentifiers: ["persisted-reflection"],
            curationReasons: ["persisted-reflection": .dailyReflection])
        let originalSession = store.dailySessionProgress()
        XCTAssertEqual(originalSession.curationReasons["persisted-reflection"], .dailyReflection)
        let restoredStore = LocalActivityStore(defaults: defaults)
        await service.setRestored(.init(decisions: [photo], retryableFailureCount: 0))
        let reopened = HomeViewModel(subscriptions: subscriptions, curationService: service, activity: restoredStore,
            authorizationStatus: { access.status }, observesPhotoLibrary: false)

        await reopened.onAppear()

        guard case .ready(let selected) = reopened.state else { return XCTFail("Persisted reflection should restore directly") }
        XCTAssertEqual(selected.type, .recallMoment)
        XCTAssertEqual(selected.reasonCodes, [.dailyReflection])
        XCTAssertTrue(selected.removalIdentifiers.isEmpty)
        let reasons = await service.restoreReasons
        XCTAssertEqual(reasons, [["persisted-reflection": .dailyReflection]])
        let reflectionCalls = await service.reflectionCalls
        let cleanupCalls = await service.fetchLimits
        XCTAssertTrue(reflectionCalls.isEmpty)
        XCTAssertTrue(cleanupCalls.isEmpty)
        XCTAssertEqual(restoredStore.dailySessionProgress().curatedPhotoIdentifiers, originalSession.curatedPhotoIdentifiers)
        XCTAssertEqual(restoredStore.dailySessionProgress().savedRecordCount, originalSession.savedRecordCount)
        XCTAssertEqual(restoredStore.dailySessionProgress().deletedPhotoCount, originalSession.deletedPhotoCount)
    }

    func testAnniversaryReasonAndCaptureDateRestoreWithoutStartingAnotherSearch() async {
        let (_, store, subscriptions, service, access, defaults) = context()
        var photo = reflection("anniversary-photo", reason: .anniversaryReflection)
        photo.capturedAt = Date(timeIntervalSince1970: 1_761_177_600)
        store.beginDailySession(photoIdentifiers: ["anniversary-photo"],
            curationReasons: ["anniversary-photo": .anniversaryReflection])
        XCTAssertEqual(store.dailySessionProgress().curationReasons["anniversary-photo"], .anniversaryReflection)
        let reopenedStore = LocalActivityStore(defaults: defaults)
        XCTAssertEqual(reopenedStore.dailySessionProgress().curationReasons["anniversary-photo"], .anniversaryReflection)
        await service.setRestored(.init(decisions: [photo], retryableFailureCount: 0))
        let reopened = HomeViewModel(subscriptions: subscriptions, curationService: service, activity: reopenedStore,
            authorizationStatus: { access.status }, observesPhotoLibrary: false)

        await reopened.onAppear()

        guard case .ready(let restored) = reopened.state else { return XCTFail("The anniversary should restore as the same reflection") }
        XCTAssertEqual(restored.reasonCodes, [.anniversaryReflection])
        XCTAssertEqual(restored.capturedAt, photo.capturedAt)
        XCTAssertTrue(CurationReasonCode.anniversaryReflection.isReflection)
        let reasons = await service.restoreReasons
        XCTAssertEqual(reasons, [["anniversary-photo": .anniversaryReflection]])
        let searches = await service.fetchLimits
        let reflectionCalls = await service.reflectionCalls
        XCTAssertTrue(searches.isEmpty)
        XCTAssertTrue(reflectionCalls.isEmpty)
        XCTAssertEqual(reopenedStore.weeklySnapshot().deletedPhotoCount, 0)
        XCTAssertEqual(reopenedStore.weeklySnapshot().savedRecordCount, 0)
    }

    func testAnniversaryNeverAuthorizesRecommendedDeletionButKeepsExplicitSinglePhotoChoice() async throws {
        let photo = reflection("anniversary-photo", reason: .anniversaryReflection)
        let forgedReason = DecisionUnit(id: UUID(), type: .cleanupSingle, status: .pending,
            candidateLocalIdentifiers: ["forged-reason"], recommendedLocalIdentifier: "forged-reason",
            reasonCodes: [.anniversaryReflection], capturedDateDescription: nil, createdAt: Date())
        let forgedEvidence = DecisionUnit(id: UUID(), type: .cleanupSingle, status: .pending,
            candidateLocalIdentifiers: ["forged-evidence"], recommendedLocalIdentifier: "forged-evidence",
            reasonCodes: [.reviewDateReached], capturedDateDescription: nil, createdAt: Date(), evidence: photo.evidence)
        let controller = PhotoDeletionController(validate: { _ in
            XCTFail("Anniversary is not evidence for recommended cleanup"); return true
        }, commit: { _ in XCTFail("Recommended cleanup cannot delete an anniversary") })
        for invalid in [photo, forgedReason, forgedEvidence] {
            XCTAssertTrue(invalid.removalIdentifiers.isEmpty)
            let allowed = await PhotoCurationService().canDelete(invalid, protectedIdentifiers: [])
            XCTAssertFalse(allowed)
            do {
                try await controller.delete(invalid) { _ in XCTFail("No recommendation completion is permitted") }
                XCTFail("Recommended cleanup must reject reflection")
            } catch PhotoDeletionController.DeletionError.changedPhotos {
            } catch { XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertNil(forgedReason.userSelectedPhotoIdentifier)
        XCTAssertNil(forgedEvidence.userSelectedPhotoIdentifier)
        XCTAssertEqual(photo.userSelectedPhotoIdentifier, "anniversary-photo")
        var committed: [String] = []
        var completions: [Int] = []
        let explicit = PhotoDeletionController(validateSelection: { $0 == "anniversary-photo" },
            commitSelection: { committed.append($0) })
        let deleted = try await explicit.deleteChosenPhoto(photo) { completions.append($0) }
        XCTAssertTrue(deleted)
        XCTAssertEqual(committed, ["anniversary-photo"])
        XCTAssertEqual(completions, [1])
    }

    func testPermissionRevokedDuringAutomaticCleanupRejectsResultBeforePersistence() async {
        let (vm, store, _, service, access, _) = context()
        let entered = expectation(description: "automatic cleanup started")
        let release = AsyncScanRelease()
        await service.setBatch(.init(decisions: [unit("late-cleanup")], visitedIdentifiers: ["late-cleanup"], hasMore: false))
        await service.setBeforeFetch { entered.fulfill(); await release.wait() }
        let task = Task { await vm.onAppear() }
        await fulfillment(of: [entered], timeout: 2)

        access.status = .denied
        await release.finish()
        await task.value

        guard case .noPermission = vm.state else { return XCTFail("Revoked permission must reject the whole pending set") }
        XCTAssertTrue(vm.photoIdentifiers.isEmpty)
        XCTAssertTrue(store.dailySessionProgress().curatedPhotoIdentifiers.isEmpty)
        XCTAssertTrue(store.dailySessionProgress().curationReasons.isEmpty)
        XCTAssertEqual(store.dailySessionProgress().savedRecordCount, 0)
        XCTAssertEqual(store.dailySessionProgress().deletedPhotoCount, 0)
    }

    func testPausedAutomaticCleanupIgnoresLateResults() async {
        let (vm, store, subscriptions, service, _, _) = context()
        let entered = expectation(description: "automatic cleanup started")
        let release = AsyncScanRelease()
        await service.setBatch(.init(decisions: [unit("late-cleanup")], visitedIdentifiers: ["late-cleanup"], hasMore: false))
        await service.setBeforeFetch { entered.fulfill(); await release.wait() }
        let task = Task { await vm.onAppear() }
        await fulfillment(of: [entered], timeout: 2)

        vm.pauseCuration()
        await release.finish()
        await task.value

        guard case .scanPaused = vm.state else { return XCTFail("A late cleanup response cannot override a pause") }
        XCTAssertTrue(vm.photoIdentifiers.isEmpty)
        XCTAssertTrue(store.dailySessionProgress().curatedPhotoIdentifiers.isEmpty)
        XCTAssertFalse(subscriptions.firstExperienceCompleted)
    }

    func testChangedPhotoSelectionRestartsActiveScanAndRejectsOldScopeResult() async {
        let (vm, store, _, service, access, _) = context()
        access.status = .limited
        let entered = expectation(description: "old selection scan started")
        let release = AsyncScanRelease()
        await service.setBatch(.init(decisions: [unit("old-selection")], visitedIdentifiers: ["old-selection"], hasMore: false))
        await service.setBeforeFetch { entered.fulfill(); await release.wait() }
        let oldScan = Task { await vm.onAppear() }
        await fulfillment(of: [entered], timeout: 2)
        await service.setBeforeFetch(nil)
        await service.setBatch(.init(decisions: [unit("new-selection")], visitedIdentifiers: ["new-selection"], hasMore: false, accessiblePhotoCount: 1))

        await vm.refreshPhotoSelection()

        XCTAssertEqual(vm.photoIdentifiers, ["new-selection"])
        await release.finish()
        await oldScan.value
        guard case .ready(let selected) = vm.state else { return XCTFail("The new selection must remain ready") }
        XCTAssertEqual(selected.displayIdentifier, "new-selection")
        XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, ["new-selection"])
        XCTAssertFalse(store.scannedPhotoIdentifiers().contains("old-selection"))
        let cleanupCalls = await service.fetchLimits
        XCTAssertEqual(cleanupCalls.count, 2, "A picker change must start its own scan while the old worker is pending")
    }

    func testChangedPhotoSelectionRestartsPendingRestoreBeforeLibraryNotification() async {
        let (vm, store, _, service, access, _) = context()
        access.status = .limited
        let removed = reflection("removed-from-selection")
        let retained = reflection("still-selected")
        store.beginDailySession(photoIdentifiers: ["removed-from-selection", "still-selected"],
            curationReasons: ["removed-from-selection": .dailyReflection, "still-selected": .dailyReflection])
        await service.setRestored(.init(decisions: [removed, retained], retryableFailureCount: 0))
        await vm.onAppear()
        XCTAssertEqual(vm.photoIdentifiers, ["removed-from-selection", "still-selected"])
        let entered = expectation(description: "old selection restoration started")
        let release = AsyncScanRelease()
        await service.setBeforeRestore { entered.fulfill(); await release.wait() }
        let oldRestore = Task { await vm.onAppear() }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertFalse(vm.photoIdentifiers.isEmpty, "The in-flight validation still has a previously displayed queue")
        await service.setBeforeRestore(nil)
        await service.setRestored(.init(decisions: [retained], retryableFailureCount: 0,
                                       inaccessibleIdentifiers: ["removed-from-selection"]))

        // The picker can finish before PhotoKit delivers a library-change callback.
        await vm.refreshPhotoSelection()

        XCTAssertEqual(vm.photoIdentifiers, ["still-selected"])
        let restores = await service.restoreIdentifiers
        XCTAssertEqual(restores.count, 3, "Picker completion must resume validation despite cancelling an earlier restore")
        await release.finish()
        await oldRestore.value
        guard case .ready(let selected) = vm.state else { return XCTFail("The new selection must remain ready after the stale restore finishes") }
        XCTAssertEqual(selected.displayIdentifier, "still-selected")
        XCTAssertEqual(vm.photoIdentifiers, ["still-selected"])
        XCTAssertEqual(vm.inaccessiblePhotoCount, 1)
        XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, ["removed-from-selection", "still-selected"])
        XCTAssertTrue(store.dailySessionProgress().processedDecisionKeys.isEmpty)
        let searches = await service.fetchLimits
        XCTAssertTrue(searches.isEmpty, "Existing recommendations need revalidation, not a new search")
    }

    func testCleanupReadFailuresKeepRecoveryWithoutSubstitutingOrdinaryPhotos() async {
        let (vm, store, _, service, _, _) = context()
        await service.setBatch(.init(decisions: [], visitedIdentifiers: ["checked"], hasMore: true,
                                     retryableFailureCount: 2, hasFreshPhotos: true, accessiblePhotoCount: 5))
        await service.setReflections([reflection("readable-reflection")])

        await vm.onAppear()

        guard case .searchPending = vm.state else { return XCTFail("Unreadable photos must not hide other unfinished work or substitute an unrelated recent photo") }
        XCTAssertTrue(vm.photoIdentifiers.isEmpty)
        XCTAssertTrue(vm.hasScanIssue)
        XCTAssertEqual(vm.unavailablePhotoCount, 2)
        XCTAssertFalse(vm.hasBlockingScanIssue)
        XCTAssertEqual(vm.emptyPrimaryAction, .findMore)
        XCTAssertTrue(store.dailySessionProgress().curationReasons.isEmpty)
        XCTAssertEqual(store.dailySessionProgress().deletedPhotoCount, 0)
        XCTAssertEqual(store.dailySessionProgress().savedRecordCount, 0)
        let calls = await service.reflectionCalls
        XCTAssertTrue(calls.isEmpty)
    }

    func testReflectionCannotBecomeRemovableThroughForgedCleanupReasonOrType() async {
        let ordinary = reflection("reflection")
        let forgedReason = DecisionUnit(id: UUID(), type: .recallMoment, status: .pending,
            candidateLocalIdentifiers: ["recall-with-cleanup-reason"], recommendedLocalIdentifier: "recall-with-cleanup-reason",
            reasonCodes: [.exactDuplicate], capturedDateDescription: nil, createdAt: Date(),
            comparisonLocalIdentifier: "reference")
        let forgedType = DecisionUnit(id: UUID(), type: .cleanupSingle, status: .pending,
            candidateLocalIdentifiers: ["cleanup-with-reflection-reason"], recommendedLocalIdentifier: "cleanup-with-reflection-reason",
            reasonCodes: [.dailyReflection], capturedDateDescription: nil, createdAt: Date())
        let forgedEvidence = DecisionUnit(id: UUID(), type: .cleanupSingle, status: .pending,
            candidateLocalIdentifiers: ["cleanup-with-reflection-evidence"], recommendedLocalIdentifier: "cleanup-with-reflection-evidence",
            reasonCodes: [.reviewDateReached], capturedDateDescription: nil, createdAt: Date(),
            evidence: ordinary.evidence)
        let service = PhotoCurationService()

        for photo in [ordinary, forgedReason, forgedType, forgedEvidence] {
            XCTAssertTrue(photo.removalIdentifiers.isEmpty)
            XCTAssertEqual(photo.removalCount, 0)
            let canDelete = await service.canDelete(photo, protectedIdentifiers: [])
            XCTAssertFalse(canDelete, "Reflection must fail deletion validation before any PhotoKit read")
        }
    }

    func testExplicitPhotoSelectionRejectsMalformedRecallAndForgedCleanup() async {
        let valid = reflection("chosen-photo")
        XCTAssertEqual(valid.userSelectedPhotoIdentifier, "chosen-photo")
        var mismatchedDisplay = valid
        mismatchedDisplay.selectedLocalIdentifier = "different-photo"
        var comparison = valid
        comparison.comparisonLocalIdentifier = "reference"
        let empty = reflection("")
        let noCandidates = DecisionUnit(id: UUID(), type: .recallMoment, status: .pending,
            candidateLocalIdentifiers: [], recommendedLocalIdentifier: "chosen-photo",
            reasonCodes: [.dailyReflection], capturedDateDescription: nil, createdAt: Date())
        let multiple = DecisionUnit(id: UUID(), type: .recallMoment, status: .pending,
            candidateLocalIdentifiers: ["chosen-photo", "unselected-photo"], recommendedLocalIdentifier: "chosen-photo",
            reasonCodes: [.dailyReflection], capturedDateDescription: nil, createdAt: Date())
        let forgedCleanup = DecisionUnit(id: UUID(), type: .cleanupSingle, status: .pending,
            candidateLocalIdentifiers: ["chosen-photo"], recommendedLocalIdentifier: "chosen-photo",
            reasonCodes: [.dailyReflection], capturedDateDescription: nil, createdAt: Date())
        let controller = PhotoDeletionController(validateSelection: { _ in
            XCTFail("Malformed selection must be rejected before photo validation"); return true
        }, commitSelection: { _ in XCTFail("Malformed selection must never reach deletion") })

        for invalid in [mismatchedDisplay, comparison, empty, noCandidates, multiple, forgedCleanup, unit("cleanup")] {
            XCTAssertNil(invalid.userSelectedPhotoIdentifier)
            do {
                try await controller.deleteChosenPhoto(invalid) { _ in XCTFail("Invalid selection cannot complete") }
                XCTFail("Invalid selection must reject the transaction")
            } catch PhotoDeletionController.DeletionError.changedPhotos {
            } catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertFalse(controller.isDeleting)
        }
    }

    func testRecommendedDeletionCannotUseExplicitReflectionSelection() async {
        let photo = reflection("chosen-photo")
        XCTAssertNotNil(photo.userSelectedPhotoIdentifier)
        let controller = PhotoDeletionController(validate: { _ in
            XCTFail("Reflection is not a cleanup candidate"); return true
        }, commit: { _ in XCTFail("Recommended cleanup must never delete reflection") },
            validateSelection: { _ in XCTFail("Recommended cleanup cannot switch to explicit validation"); return true },
            commitSelection: { _ in XCTFail("Recommended cleanup cannot switch deletion paths") })

        do {
            try await controller.delete(photo) { _ in XCTFail("Recommended deletion must remain unavailable") }
            XCTFail("Reflection requires the separate explicit-selection path")
        } catch PhotoDeletionController.DeletionError.changedPhotos {
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(controller.isDeleting)
    }

    func testExplicitReflectionDeletionAdvancesOnePhotoAndPreservesSavedRecords() async throws {
        let (vm, store, _, service, _, defaults) = context(enabled: false)
        let photo = reflection("chosen-reflection")
        let remaining = reflection("remaining-reflection")
        let records = SavedRecordStore(defaults: defaults)
        let saved = try records.save(text: "사진을 비워도 남길 기억", photoLocalIdentifier: "chosen-reflection", capturedDateDescription: nil)
        store.recordIndependentMemory(recordID: saved.id)
        let recordsBefore = records.records()
        let bytesBefore = defaults.data(forKey: UserScopedStorage.key(SavedRecordStore.storageKey))
        store.beginDailySession(photoIdentifiers: ["chosen-reflection", "remaining-reflection"],
            curationReasons: ["chosen-reflection": .dailyReflection, "remaining-reflection": .dailyReflection])
        await service.setRestored(.init(decisions: [photo, remaining], retryableFailureCount: 0))
        await vm.onAppear()
        var validated: [String] = []
        var committed: [String] = []
        var completions: [Int] = []
        let controller = PhotoDeletionController(validateSelection: { identifier in
            validated.append(identifier); return true
        }, commitSelection: { identifier in committed.append(identifier) })

        let succeeded = try await controller.deleteChosenPhoto(photo) { count in
            completions.append(count)
            vm.markTodayCompleted(unit: photo, deletedCount: count, savedRecord: false, protectPhoto: false)
        }

        XCTAssertTrue(succeeded)
        XCTAssertEqual(validated, ["chosen-reflection"])
        XCTAssertEqual(committed, ["chosen-reflection"])
        XCTAssertEqual(completions, [1])
        XCTAssertFalse(controller.isDeleting)
        XCTAssertEqual(vm.photoIdentifiers, ["remaining-reflection"])
        XCTAssertEqual(store.dailySessionProgress().processedDecisionKeys, ["chosen-reflection"])
        XCTAssertEqual(store.dailySessionProgress().deletedPhotoCount, 1)
        XCTAssertEqual(store.weeklySnapshot().deletedPhotoCount, 1)
        XCTAssertEqual(store.weeklySnapshot().savedRecordCount, 1)
        XCTAssertEqual(records.records(), recordsBefore)
        XCTAssertEqual(defaults.data(forKey: UserScopedStorage.key(SavedRecordStore.storageKey)), bytesBefore)

        vm.markTodayCompleted(unit: remaining, deletedCount: 0, savedRecord: false, protectPhoto: false)
        guard case .completed(let summary) = vm.state else { return XCTFail("The remaining choice should finish the two-photo session") }
        XCTAssertEqual(summary.deletedCount, 1)
        XCTAssertEqual(summary.reviewedCount, 2)
        let reopened = LocalActivityStore(defaults: defaults)
        XCTAssertEqual(reopened.todaySummary()?.deletedPhotoCount, 1)
        XCTAssertEqual(reopened.todaySummary()?.savedRecordCount, 1)
        XCTAssertEqual(SavedRecordStore(defaults: defaults).records(), recordsBefore)
    }

    func testExplicitReflectionCancellationFailureAndRevokedAccessKeepQueueAndActivity() async {
        enum Outcome: Equatable { case cancelled, failed, inaccessible }
        for outcome in [Outcome.cancelled, .failed, .inaccessible] {
            let (vm, store, _, service, _, _) = context(enabled: false)
            let photo = reflection("still-pending")
            store.beginDailySession(photoIdentifiers: ["still-pending"], curationReasons: ["still-pending": .dailyReflection])
            await service.setRestored(.init(decisions: [photo], retryableFailureCount: 0))
            await vm.onAppear()
            var commits = 0
            let controller = PhotoDeletionController(validateSelection: { _ in outcome != .inaccessible },
                commitSelection: { _ in
                    commits += 1
                    switch outcome {
                    case .cancelled:
                        throw NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.Code.userCancelled.rawValue)
                    case .failed:
                        throw NSError(domain: "test.explicit-delete-failure", code: 1)
                    case .inaccessible:
                        XCTFail("An inaccessible selection cannot reach the commit")
                    }
                })

            do {
                let succeeded = try await controller.deleteChosenPhoto(photo) { count in
                    vm.markTodayCompleted(unit: photo, deletedCount: count, savedRecord: false, protectPhoto: false)
                    XCTFail("An unconfirmed deletion must not advance the queue")
                }
                XCTAssertEqual(outcome, .cancelled)
                XCTAssertFalse(succeeded)
            } catch {
                XCTAssertNotEqual(outcome, .cancelled, "System cancellation returns without an error")
            }

            XCTAssertFalse(controller.isDeleting)
            XCTAssertEqual(commits, outcome == .inaccessible ? 0 : 1)
            XCTAssertEqual(vm.photoIdentifiers, ["still-pending"])
            XCTAssertTrue(store.dailySessionProgress().processedDecisionKeys.isEmpty)
            XCTAssertTrue(store.reviewedPhotoIdentifiers().isEmpty)
            XCTAssertEqual(store.weeklySnapshot().deletedPhotoCount, 0)
            XCTAssertEqual(store.weeklySnapshot().savedRecordCount, 0)
            XCTAssertFalse(store.hasCompletedCleanupToday())
        }
    }

    func testConcurrentExplicitAndRecommendedDeletionShareOneTransactionGuard() async throws {
        let photo = reflection("chosen-photo")
        let started = expectation(description: "explicit selection validation started")
        let release = AsyncScanRelease()
        var commits: [String] = []
        var completions: [Int] = []
        let controller = PhotoDeletionController(validate: { _ in
            XCTFail("Another deletion cannot validate during the active transaction"); return true
        }, commit: { _ in XCTFail("Another deletion cannot commit during the active transaction") },
            validateSelection: { _ in started.fulfill(); await release.wait(); return true },
            commitSelection: { commits.append($0) })
        let first = Task { try await controller.deleteChosenPhoto(photo) { completions.append($0) } }
        await fulfillment(of: [started], timeout: 2)

        let repeated = try? await controller.deleteChosenPhoto(photo) { _ in XCTFail("Repeated confirmation cannot complete twice") }
        let competing = try? await controller.delete(unit("cleanup")) { _ in XCTFail("A competing cleanup cannot complete") }

        XCTAssertEqual(repeated, false)
        XCTAssertEqual(competing, false)
        await release.finish()
        let succeeded = try await first.value
        XCTAssertTrue(succeeded)
        XCTAssertEqual(commits, ["chosen-photo"])
        XCTAssertEqual(completions, [1])
        XCTAssertFalse(controller.isDeleting)
    }

    func testExplicitDeletionTaskCancellationBeforeCommitDoesNotComplete() async {
        let started = expectation(description: "explicit selection validation started")
        let release = AsyncScanRelease()
        let controller = PhotoDeletionController(validateSelection: { _ in
            started.fulfill(); await release.wait(); return true
        }, commitSelection: { _ in XCTFail("Task cancellation before confirmation must stop deletion") })
        let task = Task {
            try await controller.deleteChosenPhoto(reflection("chosen-photo")) { _ in XCTFail("Cancelled validation cannot complete") }
        }
        await fulfillment(of: [started], timeout: 2)

        task.cancel()
        await release.finish()

        do {
            _ = try await task.value
            XCTFail("The cancelled task must stop before Photos mutation")
        } catch is CancellationError {
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(controller.isDeleting)
    }

    func testConfirmedExplicitDeletionStillReportsSuccessWhenTaskIsCancelledDuringCommit() async throws {
        let started = expectation(description: "explicit deletion commit started")
        let release = AsyncScanRelease()
        var completions: [Int] = []
        let controller = PhotoDeletionController(validateSelection: { _ in true }, commitSelection: { _ in
            started.fulfill(); await release.wait()
        })
        let task = Task {
            try await controller.deleteChosenPhoto(reflection("chosen-photo")) { completions.append($0) }
        }
        await fulfillment(of: [started], timeout: 2)

        task.cancel()
        await release.finish()

        let succeeded = try await task.value
        XCTAssertTrue(succeeded, "A confirmed Photos transaction must still be accounted for")
        XCTAssertEqual(completions, [1])
        XCTAssertFalse(controller.isDeleting)
    }

    func testRelaunchRestoresPendingCarouselBeforeEarlierCompletion() async {
        let (vm, store, _, service, _, _) = context(enabled: false)
        store.recordCompletion(deletedPhotoCount: 1, savedRecordCount: 1)
        store.beginDailySession(photoIdentifiers: ["return-first", "return-pending"])
        store.recordDailyDecision(decisionKey: "return-first", deletedPhotoCount: 0, savedRecord: false)
        await service.setRestored(.init(decisions: [unit("return-pending")], retryableFailureCount: 0))
        let before = store.weeklySnapshot()
        await vm.onAppear()
        guard case .ready(let photo) = vm.state else { return XCTFail("Remaining recommendation must open directly") }
        XCTAssertEqual(photo.displayIdentifier, "return-pending")
        XCTAssertEqual(vm.photoIdentifiers, ["return-pending"])
        XCTAssertEqual(store.weeklySnapshot().deletedPhotoCount, before.deletedPhotoCount)
        XCTAssertEqual(store.weeklySnapshot().savedRecordCount, before.savedRecordCount)
        let fetches = await service.fetchLimits
        XCTAssertTrue(fetches.isEmpty, "Restore the existing batch without scanning unrelated photos")
    }

    func testPendingRecommendationsRestoreWhenNewSearchAccessHasExpired() async {
        let (vm, store, subscriptions, service, _, _) = context()
        subscriptions.finishFirstExperience()
        XCTAssertFalse(subscriptions.canStartCuration)
        store.beginDailySession(photoIdentifiers: ["known-pending"])
        await service.setRestored(.init(decisions: [unit("known-pending")], retryableFailureCount: 0))

        await vm.onAppear()

        guard case .ready(let restored) = vm.state else { return XCTFail("Known recommendation should be restored") }
        XCTAssertEqual(restored.displayIdentifier, "known-pending")
        XCTAssertFalse(subscriptions.canStartCuration, "Restoring cannot grant recommendation access")
        let restoredIDs = await service.restoreIdentifiers
        let fetches = await service.fetchLimits
        XCTAssertEqual(restoredIDs, [["known-pending"]])
        XCTAssertTrue(fetches.isEmpty)

        await vm.loadMoreDecisions()
        XCTAssertTrue(vm.showSubscription)
        let fetchesAfterNewRequest = await service.fetchLimits
        XCTAssertTrue(fetchesAfterNewRequest.isEmpty, "A new request still enforces its existing entitlement gate")
        XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, ["known-pending"])
    }

    func testNewBatchCannotBeFetchedWhenRecommendationAccessHasExpired() async {
        let (vm, _, subscriptions, service, _, _) = context()
        subscriptions.finishFirstExperience()
        await service.setBatch(.init(decisions: [unit("must-not-fetch")], visitedIdentifiers: [], hasMore: true))

        await vm.onAppear()

        guard case .subscriptionRequired = vm.state else { return XCTFail("New search must remain gated") }
        let fetches = await service.fetchLimits
        let restoredIDs = await service.restoreIdentifiers
        XCTAssertTrue(fetches.isEmpty)
        XCTAssertTrue(restoredIDs.isEmpty)
    }

    func testCompletedDayWithUnscannedPhotosOffersSearchWithoutPromisingOrStartingRecommendations() async {
        let (vm, store, _, service, access, _) = context(enabled: false, hasUnscanned: true)
        access.status = .limited
        store.recordCompletion(deletedPhotoCount: 0, savedRecordCount: 1)
        let before = store.weeklySnapshot()

        await vm.onAppear()
        await vm.onAppear()

        guard case .noCandidate = vm.state else { return XCTFail("Unscanned photos are not verified recommendations") }
        XCTAssertTrue(vm.photoIdentifiers.isEmpty)
        XCTAssertNil(vm.accessiblePhotoCount, "A boolean availability query cannot infer a photo count")
        XCTAssertEqual(vm.emptyPrimaryAction, .findMore)
        XCTAssertEqual(vm.scanStatusTitle, "오늘 고른 사진을 모두 살펴봤어요.")
        XCTAssertEqual(vm.scanStatusMessage, "더 살펴보고 싶다면 이어서 찾아볼 수 있어요.")
        let fetches = await service.fetchLimits
        XCTAssertTrue(fetches.isEmpty, "Returning to Home must not begin another automatic search")
        XCTAssertEqual(store.weeklySnapshot().savedRecordCount, before.savedRecordCount)
        XCTAssertEqual(store.weeklySnapshot().deletedPhotoCount, before.deletedPhotoCount)
    }

    func testPendingPreviewNeverBecomesActionableBeforeValidation() async {
        let (vm, store, _, service, _, _) = context(enabled: false)
        store.beginDailySession(photoIdentifiers: ["preview-done", "preview-pending"])
        store.recordDailyDecision(decisionKey: "preview-done", deletedPhotoCount: 0, savedRecord: true)
        let entered = expectation(description: "restoration started")
        let release = AsyncScanRelease()
        await service.setBeforeRestore { entered.fulfill(); await release.wait() }
        await service.setRestored(.init(decisions: [], retryableFailureCount: 1))
        let task = Task { await vm.onAppear() }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(vm.preparingPhotoIdentifier, "preview-pending")
        guard case .loading = vm.state else { return XCTFail("Preview must not enable decisions") }
        XCTAssertTrue(vm.photoIdentifiers.isEmpty)
        await release.finish()
        await task.value
        XCTAssertNil(vm.preparingPhotoIdentifier)
        guard case .noCandidate = vm.state else { return XCTFail("Failed validation must offer recovery") }
        XCTAssertEqual(store.dailySessionProgress().savedRecordCount, 1)
        XCTAssertEqual(store.dailySessionProgress().processedDecisionKeys, ["preview-done"])
    }

    func testReturningPreviewKeepsSelectedPhotoAndClearsOnPause() async {
        let (vm, store, _, service, _, _) = context(enabled: false)
        store.beginDailySession(photoIdentifiers: ["preview-first", "preview-second"])
        await service.setRestored(.init(decisions: [unit("preview-first"), unit("preview-second")], retryableFailureCount: 0))
        await vm.onAppear()
        vm.currentDecisionIndex = 1
        let entered = expectation(description: "revalidation started")
        let release = AsyncScanRelease()
        await service.setBeforeRestore { entered.fulfill(); await release.wait() }
        let task = Task { await vm.onAppear() }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(vm.preparingPhotoIdentifier, "preview-second")
        guard case .loading = vm.state else { return XCTFail("Must revalidate on return") }
        vm.pauseCuration()
        XCTAssertNil(vm.preparingPhotoIdentifier)
        await release.finish()
        await task.value
        guard case .scanPaused = vm.state else { return XCTFail("Late validation must not activate preview") }
    }

    func testCompletionIsShownOnlyImmediatelyAndRelaunchPreservesActivity() async {
        let (vm, store, subscriptions, service, access, _) = context(enabled: false)
        access.status = .limited
        store.beginDailySession(photoIdentifiers: ["return-last"])
        await service.setRestored(.init(decisions: [unit("return-last")], retryableFailureCount: 0))
        await vm.onAppear()
        vm.markTodayCompleted(unit: unit("return-last"), deletedCount: 1, savedRecord: false, protectPhoto: false)
        guard case .completed = vm.state else { return XCTFail("A just-finished action still gets feedback") }
        let restored = HomeViewModel(subscriptions: subscriptions, curationService: service, activity: store,
            authorizationStatus: { .limited }, observesPhotoLibrary: false)
        await restored.onAppear()
        guard case .noCandidate = restored.state else { return XCTFail("Relaunch must never replay completion") }
        XCTAssertEqual(restored.emptyPrimaryAction, .selectPhotos)
        XCTAssertEqual(restored.weeklyProgress.deletedPhotoCount, 1)
        XCTAssertEqual(restored.scanStatusTitle, "오늘 고른 사진을 모두 살펴봤어요.")
        XCTAssertEqual(restored.scanStatusMessage, "더 살펴보고 싶다면 다른 사진을 선택할 수 있어요.")
        XCTAssertEqual(restored.emptyNextStepMessage, restored.scanStatusMessage)
        await restored.onAppear()
        XCTAssertEqual(store.todaySummary()?.deletedPhotoCount, 1)
        guard case .noCandidate = restored.state else { return XCTFail("Returning to Home stays in Home") }
    }

    func testCompletedHomeKeepsSuccessfulContextAndExistingRecordsWithoutNewSearch() async throws {
        let (vm, store, _, service, _, defaults) = context(enabled: false)
        let records = SavedRecordStore(defaults: defaults)
        try records.save(text: "기존 기록", photoLocalIdentifier: "existing-record", capturedDateDescription: nil)
        let recordsBefore = defaults.data(forKey: UserScopedStorage.key(SavedRecordStore.storageKey))
        store.recordCompletion(deletedPhotoCount: 3, savedRecordCount: 0)

        await vm.onAppear()
        await vm.onAppear()

        guard case .noCandidate = vm.state else { return XCTFail("Completed Home must not replay the completion screen") }
        XCTAssertEqual(vm.scanStatusTitle, "오늘 고른 사진을 모두 살펴봤어요.")
        XCTAssertEqual(vm.scanStatusMessage, "비움 내역은 리포트에 남아 있어요.")
        XCTAssertEqual(vm.emptyPrimaryAction, .finish)
        XCTAssertEqual(store.todaySummary()?.deletedPhotoCount, 3)
        XCTAssertTrue(store.dailySessionProgress().curatedPhotoIdentifiers.isEmpty)
        XCTAssertEqual(defaults.data(forKey: UserScopedStorage.key(SavedRecordStore.storageKey)), recordsBefore)
        let fetches = await service.fetchLimits
        XCTAssertTrue(fetches.isEmpty, "A clearer return message must not start a new batch")
    }

    func testUnsuccessfulFirstSearchDoesNotClaimACompletedBatch() async {
        let (vm, store, _, service, access, _) = context(enabled: false)
        access.status = .limited
        await service.setBatch(.init(decisions: [], visitedIdentifiers: ["checked-one", "checked-two"],
                                     hasMore: false, accessiblePhotoCount: 2))

        await vm.onAppear()

        guard case .noCandidate = vm.state else { return XCTFail("A valid empty search stays in Home") }
        XCTAssertEqual(vm.scanStatusTitle, "선택한 사진에서 정리 후보를 찾지 못했어요.")
        XCTAssertEqual(vm.scanStatusMessage, "허용한 사진 2장을 확인했어요. 사진을 더 선택하면 그 안에서 다시 찾아볼게요.")
        XCTAssertEqual(vm.emptyPrimaryAction, .selectPhotos)
        XCTAssertFalse(store.hasCompletedCleanupToday())
        XCTAssertEqual(store.weeklySnapshot().deletedPhotoCount, 0)
    }

    func testEarlierCompletionDoesNotHidePendingReadOrAccessRecovery() async {
        for inaccessible in [false, true] {
            let (vm, store, _, service, access, _) = context(enabled: false, hasUnscanned: true)
            access.status = .limited
            store.recordCompletion(deletedPhotoCount: 3, savedRecordCount: 0)
            store.beginDailySession(photoIdentifiers: ["still-pending"])
            await service.setRestored(.init(decisions: [], retryableFailureCount: inaccessible ? 0 : 1,
                                           inaccessibleIdentifiers: inaccessible ? ["still-pending"] : []))

            await vm.onAppear()

            guard case .noCandidate = vm.state else { return XCTFail("An unresolved photo must retain recovery") }
            XCTAssertEqual(vm.scanStatusTitle, vm.scanIssueTitle)
            XCTAssertEqual(vm.scanStatusMessage, vm.scanIssueMessage)
            XCTAssertEqual(vm.emptyPrimaryAction, inaccessible ? .selectPhotos : .retry)
            XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, ["still-pending"])
            XCTAssertEqual(store.todaySummary()?.deletedPhotoCount, 3)
            let fetches = await service.fetchLimits
            XCTAssertTrue(fetches.isEmpty)
        }
    }

    func testFinishedBatchOffersOptionalMoreWithoutAutomaticallyScanningOrChangingRecords() async throws {
        let (vm, store, _, service, access, defaults) = context(enabled: false, hasUnscanned: true)
        access.status = .limited
        let photos = (1...3).map { reflection("optional-more-\($0)") }
        let records = SavedRecordStore(defaults: defaults)
        try records.save(text: "그대로 남아 있을 기억", photoLocalIdentifier: "existing-record-photo", capturedDateDescription: nil)
        let savedBefore = defaults.data(forKey: UserScopedStorage.key(SavedRecordStore.storageKey))
        store.beginDailySession(photoIdentifiers: photos.compactMap(\.displayIdentifier))
        await service.setRestored(.init(decisions: photos, retryableFailureCount: 0))
        await vm.onAppear()
        for photo in photos {
            XCTAssertTrue(vm.markTodayCompleted(unit: photo, deletedCount: 0, savedRecord: false, protectPhoto: false))
        }

        guard case .completed(let summary) = vm.state else { return XCTFail("The third decision must finish the batch") }
        XCTAssertEqual(summary.title, "모두 살펴봤어요.")
        XCTAssertEqual(summary.reviewedCount, 3)
        XCTAssertEqual(vm.completionSecondaryAction, .findMore,
                       "Limited access alone must not make users choose photos again while unscanned photos remain")
        XCTAssertEqual(vm.completionMessage, "지금 마쳐도 비움 내역은 이 기기에 남아요.")
        XCTAssertEqual(vm.emptyPrimaryAction, .findMore, "The separate empty-Home policy must remain intact")
        XCTAssertFalse(vm.showSubscription)
        XCTAssertTrue(vm.photoIdentifiers.isEmpty)
        let calls = await service.fetchLimits
        XCTAssertTrue(calls.isEmpty, "Completion must wait for an explicit request instead of starting another batch")
        XCTAssertEqual(defaults.data(forKey: UserScopedStorage.key(SavedRecordStore.storageKey)), savedBefore)
        XCTAssertEqual(store.reviewedPhotoIdentifiers(), Set(photos.map(\.persistenceKey)),
                       "Finishing clears the active queue but preserves today's handled-photo history")
    }

    func testOptionalMoreSearchStartsOnlyOnRequestAndPreservesPriorRecordsAndActivity() async throws {
        let (vm, store, _, service, _, defaults) = context(enabled: false, hasUnscanned: true)
        let first = reflection("optional-more-finished")
        let next = unit("optional-more-next")
        let records = SavedRecordStore(defaults: defaults)
        try records.save(text: "이전 묶음에서 남긴 기록", photoLocalIdentifier: first.displayIdentifier, capturedDateDescription: nil)
        let savedBefore = defaults.data(forKey: UserScopedStorage.key(SavedRecordStore.storageKey))
        store.beginDailySession(photoIdentifiers: [first.persistenceKey])
        await service.setRestored(.init(decisions: [first], retryableFailureCount: 0))
        await vm.onAppear()
        XCTAssertTrue(vm.markTodayCompleted(unit: first, deletedCount: 0, savedRecord: true, protectPhoto: false))
        let activityBefore = store.weeklySnapshot()
        XCTAssertEqual(vm.completionSecondaryAction, .findMore)
        let callsBefore = await service.fetchLimits
        XCTAssertTrue(callsBefore.isEmpty)

        await service.setBatch(.init(decisions: [next], visitedIdentifiers: [next.persistenceKey], hasMore: false, accessiblePhotoCount: 2))
        await vm.loadMoreDecisions()

        guard case .ready(let current) = vm.state else { return XCTFail("An explicit request must open the actual next recommendation") }
        XCTAssertEqual(current.persistenceKey, next.persistenceKey)
        XCTAssertEqual(vm.photoIdentifiers, [next.persistenceKey], "One available recommendation must not be presented as three")
        XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, [next.persistenceKey])
        XCTAssertEqual(store.weeklySnapshot().savedRecordCount, activityBefore.savedRecordCount)
        XCTAssertEqual(store.weeklySnapshot().deletedPhotoCount, activityBefore.deletedPhotoCount)
        XCTAssertEqual(defaults.data(forKey: UserScopedStorage.key(SavedRecordStore.storageKey)), savedBefore)
        let callsAfter = await service.fetchLimits
        XCTAssertEqual(callsAfter, [3])
    }

    func testFinishedBatchExplainsSubscriptionAndDoesNotScanUntilEntitled() async throws {
        let (vm, store, subscriptions, service, _, defaults) = context(hasUnscanned: true)
        let photo = reflection("finished-intro-photo")
        let records = SavedRecordStore(defaults: defaults)
        try records.save(text: "구독 선택과 무관하게 남는 기록", photoLocalIdentifier: "earlier-photo", capturedDateDescription: nil)
        store.beginDailySession(photoIdentifiers: [photo.persistenceKey])
        await service.setRestored(.init(decisions: [photo], retryableFailureCount: 0))
        await vm.onAppear()
        XCTAssertTrue(vm.markTodayCompleted(unit: photo, deletedCount: 0, savedRecord: false, protectPhoto: false))
        let savedBefore = defaults.data(forKey: UserScopedStorage.key(SavedRecordStore.storageKey))
        let sessionBefore = store.dailySessionProgress()

        XCTAssertTrue(subscriptions.firstExperienceCompleted)
        XCTAssertFalse(subscriptions.canStartCuration)
        XCTAssertEqual(vm.completionSecondaryAction, .subscription)
        XCTAssertTrue(vm.completionMessage.contains("구독"))
        XCTAssertTrue(vm.completionMessage.contains("조건"))
        XCTAssertFalse(vm.showSubscription, "Finishing the first batch must not automatically open the offer")

        await vm.loadMoreDecisions()

        XCTAssertTrue(vm.showSubscription, "Only the explicit optional-more action presents the existing offer")
        guard case .completed = vm.state else { return XCTFail("The offer must not discard the completion state") }
        let calls = await service.fetchLimits
        XCTAssertTrue(calls.isEmpty, "The optional action must not bypass the existing entitlement gate")
        XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, sessionBefore.curatedPhotoIdentifiers)
        XCTAssertEqual(store.dailySessionProgress().processedDecisionKeys, sessionBefore.processedDecisionKeys)
        XCTAssertEqual(defaults.data(forKey: UserScopedStorage.key(SavedRecordStore.storageKey)), savedBefore)
    }

    func testFinishedLimitedBatchExplainsSubscriptionBeforeRequestingMorePhotos() async {
        let (vm, store, subscriptions, service, access, _) = context()
        access.status = .limited
        let photo = reflection("finished-limited-intro")
        store.beginDailySession(photoIdentifiers: [photo.persistenceKey])
        await service.setRestored(.init(decisions: [photo], retryableFailureCount: 0))
        await vm.onAppear()
        XCTAssertTrue(vm.markTodayCompleted(unit: photo, deletedCount: 0, savedRecord: false, protectPhoto: false))

        XCTAssertFalse(subscriptions.canStartCuration)
        XCTAssertEqual(vm.emptyPrimaryAction, .selectPhotos, "The ordinary empty-Home policy remains unchanged")
        XCTAssertEqual(vm.completionSecondaryAction, .subscription,
                       "Do not ask for extra photo access before explaining the existing subscription gate")
        XCTAssertTrue(vm.completionMessage.contains("구독"))
        XCTAssertFalse(vm.showSubscription)
        await vm.loadMoreDecisions()
        XCTAssertTrue(vm.showSubscription)
        let calls = await service.fetchLimits
        XCTAssertTrue(calls.isEmpty)

        // Access recovery for an existing unfinished photo must remain available.
        store.beginDailySession(photoIdentifiers: ["temporarily-inaccessible"])
        await service.setRestored(.init(decisions: [], retryableFailureCount: 0,
                                       inaccessibleIdentifiers: ["temporarily-inaccessible"]))
        vm.state = .loading
        await vm.onAppear()
        XCTAssertTrue(vm.hasScanIssue)
        XCTAssertEqual(vm.completionSecondaryAction, .selectPhotos)
    }

    func testFinishedBatchOnlyOffersPhotoSelectionWhenLimitedPhotosAreExhausted() async {
        for limited in [false, true] {
            let (vm, store, _, service, access, _) = context(enabled: false)
            access.status = limited ? .limited : .authorized
            let photo = reflection(limited ? "finished-limited" : "finished-full-library")
            store.beginDailySession(photoIdentifiers: [photo.persistenceKey])
            await service.setRestored(.init(decisions: [photo], retryableFailureCount: 0))
            await vm.onAppear()
            XCTAssertTrue(vm.markTodayCompleted(unit: photo, deletedCount: 0, savedRecord: false, protectPhoto: false))

            guard case .completed = vm.state else { return XCTFail("The last handled photo still receives completion feedback") }
            XCTAssertEqual(vm.completionSecondaryAction, limited ? .selectPhotos : nil)
            XCTAssertEqual(vm.completionMessage, limited
                ? "다른 사진을 더 선택하면 추천을 찾아볼게요."
                : "내일 앱을 열면 새 정리 후보를 찾아볼게요.")
            XCTAssertEqual(vm.emptyPrimaryAction, limited ? .selectPhotos : .finish)
            let calls = await service.fetchLimits
            XCTAssertTrue(calls.isEmpty)
        }
    }

    func testCompletionDoesNotOfferRefreshAsMoreWhileEmptyHomeKeepsItsRecoveryAction() async {
        let (vm, _, _, service, _, _) = context(enabled: false)
        await service.setBatch(.init(decisions: [], visitedIdentifiers: [], hasMore: false, accessiblePhotoCount: 0))
        await vm.loadMoreDecisions()

        XCTAssertEqual(vm.emptyPrimaryAction, .refresh, "The empty-library recovery action is still needed on Home")
        XCTAssertNil(vm.completionSecondaryAction, "A completed batch must not imply more recommendations in an empty library")
        XCTAssertTrue(vm.completionMessage.hasPrefix("추가로 추천할 사진을 찾지 못했어요."))
        XCTAssertTrue(vm.completionMessage.contains("새 사진이 생기면"))
    }

    func testCompletionRecoveryKeepsUnreadableAndInaccessiblePhotosDistinctFromOptionalMore() async {
        let (unreadable, unreadableStore, _, unreadableService, _, _) = context(enabled: false, hasUnscanned: true)
        unreadableStore.beginDailySession(photoIdentifiers: ["unreadable-completion-photo"])
        await unreadableService.setRestored(.init(decisions: [], retryableFailureCount: 1))
        await unreadable.onAppear()
        XCTAssertEqual(unreadable.completionSecondaryAction, .retry)
        XCTAssertEqual(unreadable.completionMessage, unreadable.scanIssueMessage)
        XCTAssertFalse(unreadable.completionMessage.contains("새 사진이 생기면"))

        for limited in [false, true] {
            let (vm, store, _, service, access, _) = context(enabled: false, hasUnscanned: true)
            access.status = limited ? .limited : .authorized
            store.beginDailySession(photoIdentifiers: ["inaccessible-completion-photo"])
            await service.setRestored(.init(decisions: [], retryableFailureCount: 0,
                inaccessibleIdentifiers: ["inaccessible-completion-photo"]))
            await vm.onAppear()
            XCTAssertEqual(vm.completionSecondaryAction, limited ? .selectPhotos : .findOtherPhotos)
            XCTAssertEqual(vm.completionMessage, vm.scanIssueMessage)
            XCTAssertTrue(vm.completionMessage.contains("이전 선택과 기록은 남아 있어요."))
            XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, ["inaccessible-completion-photo"])
            let calls = await service.fetchLimits
            XCTAssertTrue(calls.isEmpty)
        }
    }

    func testInterruptedLastDecisionFinalizesAccountingWithoutReplayingCompletion() async {
        let (vm, store, _, _, _, _) = context(enabled: false)
        store.beginDailySession(photoIdentifiers: ["return-interrupted"])
        store.recordDailyDecision(decisionKey: "return-interrupted", deletedPhotoCount: 1, savedRecord: false)
        await vm.onAppear()
        guard case .noCandidate = vm.state else { return XCTFail("Recovered accounting is not a new action") }
        XCTAssertTrue(store.hasCompletedCleanupToday())
        XCTAssertEqual(store.todaySummary()?.deletedPhotoCount, 1)
        await vm.onAppear()
        XCTAssertEqual(store.todaySummary()?.deletedPhotoCount, 1)
    }

    func testCompletedAdditionalScanReportsEmptyResultAndOffersLimitedSelection() async {
        let (vm, store, _, service, access, _) = context(enabled: false)
        access.status = .limited
        store.recordCompletion(deletedPhotoCount: 1, savedRecordCount: 1)
        vm.state = .completed(summary: .init(deletedCount: 1, savedRecordCount: 1, reviewedCount: 2))
        await service.setBatch(.init(decisions: [], visitedIdentifiers: ["checked"], hasMore: false, accessiblePhotoCount: 2))
        await vm.loadMoreDecisions()
        XCTAssertTrue(vm.additionalSearchFoundNoCandidates)
        XCTAssertEqual(vm.scanStatusTitle, "선택한 사진에서 정리 후보를 찾지 못했어요.")
        XCTAssertEqual(vm.scanStatusMessage, "허용한 사진 2장을 확인했어요. 사진을 더 선택하면 그 안에서 다시 찾아볼게요.")
        XCTAssertEqual(vm.emptyPrimaryAction, .selectPhotos)
        XCTAssertEqual(vm.completionSecondaryAction, .selectPhotos)
        XCTAssertTrue(vm.completionMessage.hasPrefix("추가로 추천할 사진을 찾지 못했어요."))
        XCTAssertTrue(vm.completionMessage.contains("다른 사진을 더 선택하면"))
        XCTAssertEqual(store.todaySummary()?.deletedPhotoCount, 1)
        XCTAssertEqual(store.todaySummary()?.savedRecordCount, 1)
        guard case .noCandidate = vm.state else { return XCTFail("An empty search returns to Home, not completion feedback") }
    }

    func testAdditionalEmptyWindowDoesNotClaimTheEntireLibraryIsFinished() async {
        let (vm, _, _, service, _, _) = context()
        await service.setBatch(.init(decisions: [], visitedIdentifiers: ["checked"], hasMore: true, accessiblePhotoCount: 80))
        await vm.loadMoreDecisions()
        XCTAssertEqual(vm.emptyPrimaryAction, .findMore)
        XCTAssertEqual(vm.scanStatusTitle, "아직 정리할 사진을 찾지 못했어요.")
        XCTAssertEqual(vm.scanStatusMessage, "아직 살펴보지 않은 사진에서 찾아볼게요.")
        XCTAssertEqual(vm.emptyNextStepMessage, vm.scanStatusMessage)
        XCTAssertFalse(vm.hasScanIssue)
    }

    func testCopyOnlyLibraryFillsThreeWithTruthfulReasonsAndPreservesQueueOnReturn() async {
        let (vm, store, _, service, _, _) = context(enabled: false, hasUnscanned: true)
        let copies = [unit("copy-a"), unit("copy-b"), unit("copied-screen", .duplicateScreenshot)]
        let expectedReasons: [String: CurationReasonCode] = [
            "copy-a": .exactDuplicate, "copy-b": .exactDuplicate, "copied-screen": .duplicateScreenshot
        ]
        await service.setBatch(.init(decisions: copies, visitedIdentifiers: Set(copies.map(\.persistenceKey)), hasMore: false))
        await vm.onAppear()
        XCTAssertEqual(vm.photoIdentifiers, copies.map(\.persistenceKey))
        XCTAssertEqual(vm.totalDecisionCount, 3)
        XCTAssertEqual(store.dailySessionProgress().curationReasons, expectedReasons,
                       "Same-type fallback keeps the file and screenshot evidence truthful")
        vm.toggleCleanupSelection(copies[0])
        let searchesBeforeReturn = await service.fetchLimits
        await service.setRestored(.init(decisions: copies, retryableFailureCount: 0))
        let nearby = unit("nearby-cut", .visuallySimilar), expired = unit("expired-event", .expiredScreen)
        await service.setBatch(.init(decisions: [copies[1], nearby, expired],
            visitedIdentifiers: ["copy-b", "nearby-cut", "expired-event"], hasMore: false))
        await vm.onAppear()
        XCTAssertEqual(vm.photoIdentifiers, copies.map(\.persistenceKey),
                       "An already full verified queue is not replaced to manufacture diversity")
        XCTAssertEqual(vm.selectedCleanupUnits.map(\.persistenceKey), ["copy-a"])
        XCTAssertEqual(store.dailySessionProgress().curationReasons, expectedReasons)
        XCTAssertEqual(store.dailySessionProgress().comparisonReferences,
                       Dictionary(uniqueKeysWithValues: copies.map { ($0.persistenceKey, $0.comparisonLocalIdentifier!) }))
        let searchesAfterReturn = await service.fetchLimits
        XCTAssertEqual(searchesAfterReturn, searchesBeforeReturn, "Returning to a full queue needs no replacement search")
        XCTAssertTrue(store.recommendationExcludedIdentifiers().contains("copy-b"))
        XCTAssertFalse(store.recommendationExcludedIdentifiers().contains("nearby-cut"))
    }

    func testVisibleDiversityUpgradeKeepsCheckedPhotoAndCarouselPosition() async {
        let (vm, store, _, service, _, _) = context(enabled: false)
        let copies = [unit("visible-copy"), unit("checked-copy"), unit("other-copy")]
        await service.setBatch(.init(decisions: copies, visitedIdentifiers: [], hasMore: false))
        await vm.onAppear()
        vm.toggleCleanupSelection(copies[1])
        let beforeCount = store.weeklySnapshot().deletedPhotoCount
        await service.setBatch(.init(decisions: [unit("similar", .visuallySimilar), unit("context", .expiredScreen)],
            visitedIdentifiers: [], hasMore: false))
        await vm.diversifyVisibleRecommendations()
        XCTAssertEqual(vm.photoIdentifiers, ["visible-copy", "checked-copy", "similar"])
        XCTAssertEqual(vm.selectedCleanupUnits.map(\.persistenceKey), ["checked-copy"])
        XCTAssertEqual(vm.currentDecisionIndex, 0)
        XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, vm.photoIdentifiers)
        XCTAssertEqual(store.weeklySnapshot().deletedPhotoCount, beforeCount)
        XCTAssertTrue(store.recommendationExcludedIdentifiers().contains("other-copy"))
    }

    func testCheckingPhotoDuringDiversitySearchCancelsLateReplacement() async {
        let (vm, store, _, service, _, _) = context(enabled: false)
        let copies = [unit("visible-copy"), unit("checked-copy"), unit("other-copy")]
        await service.setBatch(.init(decisions: copies, visitedIdentifiers: [], hasMore: false))
        await vm.onAppear()
        await service.setBatch(.init(decisions: [unit("similar", .visuallySimilar)], visitedIdentifiers: [], hasMore: false))
        let entered = expectation(description: "diversity search")
        let release = AsyncScanRelease()
        await service.setBeforeFetch { entered.fulfill(); await release.wait() }
        let task = Task { await vm.diversifyVisibleRecommendations() }
        await fulfillment(of: [entered], timeout: 2)
        vm.toggleCleanupSelection(copies[2])
        await release.finish()
        await task.value
        XCTAssertEqual(vm.photoIdentifiers, copies.map(\.persistenceKey))
        XCTAssertEqual(vm.selectedCleanupUnits.map(\.persistenceKey), ["other-copy"])
        XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, copies.map(\.persistenceKey))
        XCTAssertFalse(store.recommendationExcludedIdentifiers().contains("similar"))
    }

    func testPendingPhotoRecoveryPreventsCompetingBackgroundPreparation() async {
        for restoredCount in [1, 2] {
            let (vm, store, _, service, _, _) = context(enabled: false, hasUnscanned: true)
            let photos = [unit("one"), unit("two"), unit("three")]
            store.beginDailySession(photoIdentifiers: photos.map(\.persistenceKey),
                curationReasons: ["one": .exactDuplicate, "two": .exactDuplicate, "three": .exactDuplicate])
            await service.setRestored(.init(decisions: Array(photos.prefix(restoredCount)),
                retryableFailureCount: 3 - restoredCount))
            await vm.onAppear()
            await vm.prepareHomeRecommendations()
            let fetches = await service.fetchLimits
            XCTAssertTrue(fetches.isEmpty, "Recovering today's photos must take priority over network/CPU work for future or alternative photos")
            XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, photos.map(\.persistenceKey))
            XCTAssertTrue(vm.selectedCleanupKeys.isEmpty)
        }
    }

    func testDiversitySearchPreparesVerifiedAlternativesWithoutChangingVisibleChoices() async {
        let (vm, store, _, service, _, _) = context(enabled: false)
        let copies = [unit("visible-copy"), unit("checked-copy"), unit("other-copy")]
        await service.setBatch(.init(decisions: copies, visitedIdentifiers: [], hasMore: false))
        await vm.onAppear()
        vm.toggleCleanupSelection(copies[1])
        let before = store.dailySessionProgress()
        let reserve = [unit("reserve-one"), unit("reserve-two")]
        await service.setBatch(.init(decisions: [], visitedIdentifiers: [], hasMore: false,
            deferredIdentifiers: Set(reserve.map(\.persistenceKey)),
            deferredReferences: Set(reserve.compactMap(\.comparisonLocalIdentifier)), deferredDecisions: reserve))
        await vm.prepareHomeRecommendations()
        XCTAssertEqual(vm.photoIdentifiers, copies.map(\.persistenceKey))
        XCTAssertEqual(vm.selectedCleanupUnits.map(\.persistenceKey), ["checked-copy"])
        XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, before.curatedPhotoIdentifiers)
        XCTAssertEqual(store.preparedRecommendations()?.photoIdentifiers, reserve.map(\.persistenceKey))
        XCTAssertTrue(store.recommendationExcludedIdentifiers().isDisjoint(with: reserve.map(\.persistenceKey)))
        XCTAssertEqual(store.weeklySnapshot().deletedPhotoCount, 0)
    }

    func testCancelingDiversitySearchCannotSaveLateAlternatives() async {
        let (vm, store, _, service, _, _) = context(enabled: false)
        let copies = [unit("visible-copy"), unit("checked-copy"), unit("other-copy")]
        await service.setBatch(.init(decisions: copies, visitedIdentifiers: [], hasMore: false))
        await vm.onAppear()
        await service.setBatch(.init(decisions: [], visitedIdentifiers: [], hasMore: false,
            deferredDecisions: [unit("late-reserve")]))
        let entered = expectation(description: "diversity alternative scan")
        let release = AsyncScanRelease()
        await service.setBeforeFetch { entered.fulfill(); await release.wait() }
        let task = Task { await vm.prepareHomeRecommendations() }
        await fulfillment(of: [entered], timeout: 2)
        vm.toggleCleanupSelection(copies[2])
        await release.finish()
        await task.value
        XCTAssertNil(store.preparedRecommendations())
        XCTAssertEqual(vm.selectedCleanupUnits.map(\.persistenceKey), ["other-copy"])
        XCTAssertEqual(vm.photoIdentifiers, copies.map(\.persistenceKey))
    }

    func testNewHomeCollectsTwoThenOneInTheSameIntroductoryBatch() async {
        let (vm, store, subscription, service, _, _) = context()
        await service.setBatches([
            .init(decisions: [unit("one"), unit("two", .visuallySimilar)], visitedIdentifiers: ["one", "two"], hasMore: true, hasFreshPhotos: true),
            .init(decisions: [unit("three", .expiredScreen)], visitedIdentifiers: ["three"], hasMore: true, hasFreshPhotos: true)
        ])
        await vm.onAppear()
        XCTAssertEqual(vm.photoIdentifiers, ["one", "two", "three"])
        XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, ["one", "two", "three"])
        let limits = await service.fetchLimits
        XCTAssertEqual(limits, [3, 1])
        XCTAssertFalse(subscription.firstExperienceCompleted)
        XCTAssertTrue(store.dailySessionProgress().processedDecisionKeys.isEmpty)
        XCTAssertEqual(service.cloudConsent.count, 0)
    }

    func testRestoredPhotosAreVisibleWhileTopUpRunsAndSwipeSurvivesAppend() async {
        let (vm, store, _, service, _, _) = context(hasUnscanned: true)
        store.beginDailySession(photoIdentifiers: ["one", "two"],
            comparisonReferences: ["one": "kept-one", "two": "kept-two"],
            curationReasons: ["one": .exactDuplicate, "two": .exactDuplicate])
        await service.setRestored(.init(decisions: [unit("one"), unit("two")], retryableFailureCount: 0))
        await service.setBatch(.init(decisions: [unit("three", .expiredScreen)], visitedIdentifiers: ["three"], hasMore: false))
        let entered = expectation(description: "background top-up started")
        let release = AsyncScanRelease()
        await service.setBeforeFetch { entered.fulfill(); await release.wait() }
        let task = Task { await vm.onAppear() }
        await fulfillment(of: [entered], timeout: 2)

        guard case .ready(let visible) = vm.state else { await release.finish(); await task.value; return XCTFail("Verified photos must be visible before top-up finishes") }
        XCTAssertEqual(visible.persistenceKey, "one")
        XCTAssertEqual(vm.photoIdentifiers, ["one", "two"])
        XCTAssertFalse(vm.canPauseCuration, "A quiet top-up must not expose a foreground pause action")
        XCTAssertNil(vm.preparingPhotoIdentifier)
        vm.currentDecisionIndex = 1
        await release.finish()
        await task.value

        XCTAssertEqual(vm.photoIdentifiers, ["one", "two", "three"])
        XCTAssertEqual(vm.currentDecisionIndex, 1)
        guard case .ready(let selected) = vm.state else { return XCTFail("The selected photo must remain visible") }
        XCTAssertEqual(selected.persistenceKey, "two")
        XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, ["one", "two", "three"])
    }

    func testDecisionOrNavigationCancelsBackgroundTopUpWithoutReplacingVisibleQueue() async {
        for action in ["record-or-delete", "navigate", "keep"] {
            let (vm, store, _, service, _, _) = context(hasUnscanned: true)
            let first = unit("one")
            store.beginDailySession(photoIdentifiers: ["one", "two"],
                curationReasons: ["one": .exactDuplicate, "two": .exactDuplicate])
            await service.setRestored(.init(decisions: [first, unit("two")], retryableFailureCount: 0))
            await service.setBatch(.init(decisions: [unit("late")], visitedIdentifiers: ["late"], hasMore: false))
            let entered = expectation(description: "background \(action)")
            let release = AsyncScanRelease()
            await service.setBeforeFetch { entered.fulfill(); await release.wait() }
            let task = Task { await vm.onAppear() }
            await fulfillment(of: [entered], timeout: 2)
            switch action {
            case "navigate": vm.pauseCuration()
            case "keep": XCTAssertTrue(vm.markTodayCompleted(unit: first, deletedCount: 0, savedRecord: false, protectPhoto: false))
            default: vm.cancelBackgroundTopUp()
            }
            let visibleAfterAction = vm.photoIdentifiers
            let sessionAfterAction = store.dailySessionProgress()
            guard case .ready = vm.state else { await release.finish(); await task.value; return XCTFail("Cancelling a top-up must not replace valid photos with paused UI") }
            await release.finish()
            await task.value
            XCTAssertEqual(vm.photoIdentifiers, visibleAfterAction, action)
            XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, sessionAfterAction.curatedPhotoIdentifiers, action)
            XCTAssertEqual(store.dailySessionProgress().processedDecisionKeys, action == "keep" ? ["one"] : [], action)
            XCTAssertTrue(store.scannedPhotoIdentifiers().isEmpty, action)
            XCTAssertFalse(vm.photoIdentifiers.contains("late"), action)
        }
    }

    func testSubscriptionExpiryDuringBackgroundTopUpKeepsOriginalPhotos() async {
        let (vm, store, subscription, service, _, _) = context(hasUnscanned: true)
        store.beginDailySession(photoIdentifiers: ["one", "two"], curationReasons: ["one": .exactDuplicate, "two": .exactDuplicate])
        await service.setRestored(.init(decisions: [unit("one"), unit("two")], retryableFailureCount: 0))
        await service.setBatch(.init(decisions: [unit("late")], visitedIdentifiers: ["late"], hasMore: false))
        await service.setBeforeFetch { subscription.finishFirstExperience() }
        await vm.onAppear()
        guard case .ready = vm.state else { return XCTFail("Existing recommendations remain available when new-search access expires") }
        XCTAssertEqual(vm.photoIdentifiers, ["one", "two"])
        XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, ["one", "two"])
        XCTAssertTrue(store.scannedPhotoIdentifiers().isEmpty)
    }

    func testRestoredShortSetAppendsThirdAndKeepsSelectionRecordsAndCounts() async throws {
        let (vm, store, subscription, service, _, defaults) = context(hasUnscanned: true)
        let existing = [unit("one"), unit("two")]
        store.beginDailySession(photoIdentifiers: ["one", "two"],
            comparisonReferences: ["one": "kept-one", "two": "kept-two"],
            curationReasons: ["one": .exactDuplicate, "two": .exactDuplicate])
        _ = try SavedRecordStore(defaults: defaults).save(text: "기존 기록", photoLocalIdentifier: "saved", capturedDateDescription: nil)
        let recordBytes = defaults.data(forKey: UserScopedStorage.key(SavedRecordStore.storageKey))
        await service.setRestored(.init(decisions: existing, retryableFailureCount: 0))
        await vm.onAppear()
        vm.currentDecisionIndex = 1
        await service.setBatch(.init(decisions: [unit("three", .visuallySimilar)], visitedIdentifiers: ["three"], hasMore: false))

        await vm.onAppear()

        XCTAssertEqual(vm.photoIdentifiers, ["one", "two", "three"])
        XCTAssertEqual(vm.currentDecisionIndex, 1)
        XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, ["one", "two", "three"])
        XCTAssertEqual(store.dailySessionProgress().comparisonReferences, ["one": "kept-one", "two": "kept-two", "three": "kept-three"])
        XCTAssertTrue(store.dailySessionProgress().processedDecisionKeys.isEmpty)
        XCTAssertEqual(store.dailySessionProgress().savedRecordCount, 0)
        XCTAssertEqual(store.dailySessionProgress().deletedPhotoCount, 0)
        XCTAssertEqual(defaults.data(forKey: UserScopedStorage.key(SavedRecordStore.storageKey)), recordBytes)
        XCTAssertFalse(subscription.firstExperienceCompleted)
        XCTAssertEqual(service.cloudConsent.count, 0)
        let limits = await service.fetchLimits
        XCTAssertEqual(limits, [1, 1])
    }

    func testProtectedPendingPhotoRemovedDuringRestoreDoesNotTriggerTopUp() async {
        let (vm, store, _, service, _, _) = context(hasUnscanned: true)
        let protectedID = "newly-protected-\(UUID().uuidString)"
        let key = UserScopedStorage.key("recoco_protected_photos_v1")
        let previous = UserDefaults.standard.object(forKey: key)
        CurationProtectionStore.shared.protect([protectedID])
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        store.beginDailySession(photoIdentifiers: [protectedID, "still-valid"],
            curationReasons: [protectedID: .exactDuplicate, "still-valid": .exactDuplicate])
        await service.setRestored(.init(decisions: [unit("still-valid")], retryableFailureCount: 0))
        await service.setBatch(.init(decisions: [unit("must-not-append")], visitedIdentifiers: ["must-not-append"], hasMore: true, hasFreshPhotos: true))
        await vm.onAppear()
        guard case .ready = vm.state else { return XCTFail("A protected missing seed must not pause the remaining valid recommendation") }
        XCTAssertEqual(vm.photoIdentifiers, ["still-valid"])
        XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, [protectedID, "still-valid"])
        let searches = await service.fetchLimits
        XCTAssertTrue(searches.isEmpty)
        XCTAssertTrue(store.scannedPhotoIdentifiers().isEmpty)
    }

    func testRestoreTopUpDoesNotReplaceFailedOrInaccessiblePendingPhotos() async {
        for inaccessible in [true, false] {
            let (vm, store, _, service, _, _) = context(hasUnscanned: true)
            store.beginDailySession(photoIdentifiers: ["one", "unavailable"], curationReasons: ["one": .exactDuplicate, "unavailable": .exactDuplicate])
            await service.setRestored(.init(decisions: [unit("one")], retryableFailureCount: inaccessible ? 0 : 1,
                inaccessibleIdentifiers: inaccessible ? ["unavailable"] : []))
            await service.setBatch(.init(decisions: [unit("replacement")], visitedIdentifiers: ["replacement"], hasMore: true, hasFreshPhotos: true))
            await vm.onAppear()
            XCTAssertEqual(vm.photoIdentifiers, ["one"])
            XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, ["one", "unavailable"])
            let searches = await service.fetchLimits
            XCTAssertTrue(searches.isEmpty)
        }
    }

    func testRestoreTopUpRespectsExpiredEntitlementAndCompletedDailySlots() async {
        for expired in [true, false] {
            let (vm, store, subscription, service, _, _) = context(hasUnscanned: true)
            let identifiers = expired ? ["one", "two"] : ["done", "one", "two"]
            store.beginDailySession(photoIdentifiers: identifiers, curationReasons: Dictionary(uniqueKeysWithValues: identifiers.map { ($0, .exactDuplicate) }))
            if expired { subscription.finishFirstExperience() }
            else { store.recordDailyDecision(decisionKey: "done", deletedPhotoCount: 0, savedRecord: true) }
            await service.setRestored(.init(decisions: [unit("one"), unit("two")], retryableFailureCount: 0))
            await vm.onAppear()
            XCTAssertEqual(vm.photoIdentifiers, ["one", "two"])
            XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, identifiers)
            let searches = await service.fetchLimits
            XCTAssertTrue(searches.isEmpty)
        }
    }

    func testRestoreTopUpFillsOnlyMissingDailySlotAndDoesNotResetCompletedChoice() async {
        let (vm, store, subscription, service, _, _) = context(hasUnscanned: true)
        store.beginDailySession(photoIdentifiers: ["done", "one"],
            comparisonReferences: ["one": "kept-one"], curationReasons: ["done": .exactDuplicate, "one": .exactDuplicate])
        store.recordDailyDecision(decisionKey: "done", deletedPhotoCount: 1, savedRecord: true)
        await service.setRestored(.init(decisions: [unit("one")], retryableFailureCount: 0))
        await service.setBatch(.init(decisions: [unit("two", .visuallySimilar)], visitedIdentifiers: ["two"], hasMore: true, hasFreshPhotos: true))
        await vm.onAppear()
        XCTAssertEqual(vm.photoIdentifiers, ["one", "two"])
        XCTAssertEqual(vm.totalDecisionCount, 3)
        XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, ["done", "one", "two"])
        XCTAssertEqual(store.dailySessionProgress().processedDecisionKeys, ["done"])
        XCTAssertEqual(store.dailySessionProgress().deletedPhotoCount, 1)
        XCTAssertEqual(store.dailySessionProgress().savedRecordCount, 1)
        let limits = await service.fetchLimits
        XCTAssertEqual(limits, [1])
        XCTAssertFalse(subscription.firstExperienceCompleted)
    }

    func testRestoreTopUpCloudFailureKeepsTwoRecommendationsWithinBoundedSearch() async {
        let (vm, store, _, service, _, _) = context(hasUnscanned: true, cloudPhotoCount: 1)
        store.beginDailySession(photoIdentifiers: ["one", "two"], curationReasons: ["one": .exactDuplicate, "two": .exactDuplicate])
        await service.setRestored(.init(decisions: [unit("one"), unit("two")], retryableFailureCount: 0))
        await service.setBatch(.init(decisions: [], visitedIdentifiers: [], hasMore: true,
            retryableFailureCount: 1, hasFreshPhotos: true))
        await vm.onAppear()
        guard case .ready = vm.state else { return XCTFail("A top-up failure cannot hide successfully restored photos") }
        XCTAssertEqual(vm.photoIdentifiers, ["one", "two"])
        XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, ["one", "two"])
        let limits = await service.fetchLimits
        // A foreground visit allows at most three bounded chunks. This mock has
        // no work-revision signal, so the fallback cap is 3 × 32 short requests.
        XCTAssertEqual(limits, Array(repeating: 1, count: 96))
        XCTAssertEqual(service.cloudConsent.count, 0)
    }

    func testLegacySeedsRejectedByCollectorAreNotReplacedByNewCandidates() async {
        let (vm, store, _, service, _, _) = context(hasUnscanned: true)
        let contexts = ["context-one", "context-two"].map { id in
            DecisionUnit(id: UUID(), type: .cleanupSingle, status: .pending,
                candidateLocalIdentifiers: [id], recommendedLocalIdentifier: id,
                reasonCodes: [.reviewDateReached], capturedDateDescription: nil, createdAt: Date())
        }
        store.beginDailySession(photoIdentifiers: ["context-one", "context-two"],
            curationReasons: ["context-one": .reviewDateReached, "context-two": .reviewDateReached])
        await service.setRestored(.init(decisions: contexts, retryableFailureCount: 0))
        await service.setBatch(.init(decisions: [unit("new")], visitedIdentifiers: ["new"], hasMore: false))
        await vm.onAppear()
        XCTAssertEqual(vm.photoIdentifiers, ["context-one", "context-two"])
        XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, ["context-one", "context-two"])
        XCTAssertTrue(store.scannedPhotoIdentifiers().isEmpty)
    }

    func testChangedSessionDuringRestoreTopUpRejectsLateAppendAndCoverage() async {
        let (vm, store, _, service, _, _) = context(hasUnscanned: true)
        store.beginDailySession(photoIdentifiers: ["one", "two"], curationReasons: ["one": .exactDuplicate, "two": .exactDuplicate])
        await service.setRestored(.init(decisions: [unit("one"), unit("two")], retryableFailureCount: 0))
        await service.setBatch(.init(decisions: [unit("late")], visitedIdentifiers: ["late"], hasMore: false))
        await service.setBeforeFetch { store.recordDailyDecision(decisionKey: "one", deletedPhotoCount: 0, savedRecord: true) }
        await vm.onAppear()
        guard case .ready = vm.state else { return XCTFail("A stale append must leave the revalidated photos visible") }
        XCTAssertEqual(vm.photoIdentifiers, ["one", "two"])
        XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, ["one", "two"])
        XCTAssertEqual(store.dailySessionProgress().processedDecisionKeys, ["one"])
        XCTAssertEqual(store.dailySessionProgress().savedRecordCount, 1)
        XCTAssertTrue(store.scannedPhotoIdentifiers().isEmpty)
        XCTAssertFalse(vm.photoIdentifiers.contains("late"))
    }

    func testHomeAutomaticallyContinuesEmptyFreshWindowWithoutChangingRecords() async throws {
        let (vm, store, subscription, service, _, defaults) = context(cloudPhotoCount: 2)
        _ = try SavedRecordStore(defaults: defaults).save(text: "기존 기록", photoLocalIdentifier: "saved-before-search", capturedDateDescription: nil)
        let recordsBefore = defaults.data(forKey: SavedRecordStore.storageKey)
        store.recordScannedPhotos(["previously-checked"])
        let candidates = [unit("first"), unit("second", .visuallySimilar), unit("third", .expiredScreen)]
        await service.setBatches([
            .init(decisions: [], visitedIdentifiers: ["fully-compared"], hasMore: true,
                  retryableFailureCount: 2, hasFreshPhotos: true, accessiblePhotoCount: 50),
            .init(decisions: candidates, visitedIdentifiers: ["first", "second", "third"], hasMore: true,
                  retryableFailureCount: 2, hasFreshPhotos: true, accessiblePhotoCount: 50)
        ])

        await vm.onAppear()

        XCTAssertEqual(vm.photoIdentifiers, ["first", "second", "third"])
        XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, vm.photoIdentifiers)
        let exclusions = await service.fetchExclusions
        XCTAssertEqual(exclusions, [["previously-checked"], ["previously-checked", "fully-compared"]])
        XCTAssertEqual(store.scannedPhotoIdentifiers(), ["previously-checked", "fully-compared", "first", "second", "third"])
        XCTAssertFalse(subscription.firstExperienceCompleted)
        XCTAssertTrue(store.dailySessionProgress().processedDecisionKeys.isEmpty)
        XCTAssertEqual(store.dailySessionProgress().savedRecordCount, 0)
        XCTAssertEqual(store.dailySessionProgress().deletedPhotoCount, 0)
        XCTAssertEqual(defaults.data(forKey: SavedRecordStore.storageKey), recordsBefore)
        XCTAssertEqual(service.cloudConsent.count, 0)
    }

    func testHomeContinuesASecondBoundedSliceWithoutRequiringAnotherTap() async throws {
        let (vm, store, _, service, _, defaults) = context(enabled: false)
        _ = try SavedRecordStore(defaults: defaults).save(text: "보존할 기록", photoLocalIdentifier: "saved", capturedDateDescription: nil)
        let records = defaults.data(forKey: UserScopedStorage.key(SavedRecordStore.storageKey))
        var batches = (1...32).map { index in
            PhotoCurationService.ScanBatch(decisions: [], visitedIdentifiers: ["checked-\(index)"],
                hasMore: true, hasFreshPhotos: true, accessiblePhotoCount: 22_576, workRevision: UInt64(index))
        }
        batches.append(.init(decisions: [unit("first"), unit("second", .visuallySimilar), unit("third", .expiredScreen)],
            visitedIdentifiers: ["first", "second", "third"], hasMore: false, workRevision: 33))
        await service.setBatches(batches)

        await vm.onAppear()

        let calls = await service.fetchLimits
        XCTAssertEqual(calls.count, 33)
        XCTAssertEqual(vm.photoIdentifiers, ["first", "second", "third"])
        XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, vm.photoIdentifiers)
        XCTAssertEqual(store.dailySessionProgress().deletedPhotoCount, 0)
        XCTAssertTrue(vm.selectedCleanupKeys.isEmpty)
        XCTAssertEqual(defaults.data(forKey: UserScopedStorage.key(SavedRecordStore.storageKey)), records)
    }

    func testUnfinishedBudgetHasDistinctStateAndNextHomeVisitResumesWithoutClearingCoverage() async throws {
        let (vm, store, _, service, _, defaults) = context(enabled: false)
        store.recordCompletion(deletedPhotoCount: 3, savedRecordCount: 0)
        _ = try SavedRecordStore(defaults: defaults).save(text: "탐색 중에도 유지", photoLocalIdentifier: "saved", capturedDateDescription: nil)
        let records = defaults.data(forKey: UserScopedStorage.key(SavedRecordStore.storageKey))
        await service.setBatches((1...96).map { index in
            .init(decisions: [], visitedIdentifiers: ["checked-\(index)"],
                  hasMore: true, hasFreshPhotos: true, accessiblePhotoCount: 22_576, workRevision: UInt64(index))
        })

        await vm.loadTodayDecision(skipFinishedSessionScan: false)

        guard case .searchPending = vm.state else { return XCTFail("Time budget is unfinished work, not no candidates or completion") }
        XCTAssertEqual(store.scannedPhotoIdentifiers().count, 96)
        XCTAssertEqual(store.monthlyDeletedPhotoCount(), 3)
        let resetsBeforeReturn = await service.resetCount
        await service.setBatch(.init(decisions: [unit("one"), unit("two", .visuallySimilar), unit("three", .expiredScreen)],
            visitedIdentifiers: ["one", "two", "three"], hasMore: false, workRevision: 97))

        await vm.onAppear(reuseValidatedQueue: true)

        XCTAssertEqual(vm.photoIdentifiers, ["one", "two", "three"])
        XCTAssertEqual(store.scannedPhotoIdentifiers().count, 99)
        let resetsAfterReturn = await service.resetCount
        XCTAssertEqual(resetsAfterReturn, resetsBeforeReturn)
        XCTAssertEqual(store.monthlyDeletedPhotoCount(), 3)
        XCTAssertTrue(vm.selectedCleanupKeys.isEmpty)
        XCTAssertEqual(defaults.data(forKey: UserScopedStorage.key(SavedRecordStore.storageKey)), records)
    }

    func testCachedRecommendationAppearsBeforeSlowMissingProofRecovery() async {
        let (vm, store, _, service, _, _) = context(hasUnscanned: true)
        let first = unit("one"), second = unit("two", .visuallySimilar), third = unit("three", .expiredScreen)
        store.beginDailySession(photoIdentifiers: ["one", "two", "three"],
            curationReasons: ["one": .exactDuplicate, "two": .visuallySimilar, "three": .expiredScreen])
        await service.setCachedRestored(.init(decisions: [third], retryableFailureCount: 2,
            hasPendingAnalysis: true, retryableIdentifiers: ["one", "two"]))
        await service.setRestored(.init(decisions: [first, second, third], retryableFailureCount: 0))
        let entered = expectation(description: "uncached comparison is still loading")
        let release = AsyncScanRelease()
        await service.setBeforeRestore { entered.fulfill(); await release.wait() }
        let task = Task { await vm.onAppear() }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(vm.photoIdentifiers, ["three"], "The valid cached photo must not wait behind an evicted comparison")
        if case .ready = vm.state {} else { XCTFail("Home should show the verified cached subset while recovery continues") }
        XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, ["one", "two", "three"])
        await release.finish()
        await task.value
        XCTAssertEqual(vm.photoIdentifiers, ["one", "two", "three"])
        XCTAssertTrue(vm.selectedCleanupKeys.isEmpty)
        XCTAssertEqual(store.dailySessionProgress().deletedPhotoCount, 0)
    }

    func testRestoredQueueStreamsSecondBeforeThirdAndPreservesNewCheckAndCurrentPhoto() async throws {
        let (vm, store, _, service, _, defaults) = context(enabled: false, hasUnscanned: true)
        let first = unit("one"), second = unit("two", .visuallySimilar), third = unit("three", .expiredScreen)
        store.beginDailySession(photoIdentifiers: ["one"], comparisonReferences: ["one": "kept-one"],
                                curationReasons: ["one": .exactDuplicate])
        _ = try SavedRecordStore(defaults: defaults).save(text: "기존 기록", photoLocalIdentifier: "saved", capturedDateDescription: nil)
        let records = defaults.data(forKey: UserScopedStorage.key(SavedRecordStore.storageKey))
        await service.setRestored(.init(decisions: [first], retryableFailureCount: 0))
        await service.setBatches([
            .init(decisions: [second], visitedIdentifiers: ["two"], hasMore: true, hasFreshPhotos: true, workRevision: 1),
            .init(decisions: [third], visitedIdentifiers: ["three"], hasMore: false, workRevision: 2)
        ])
        let entered = expectation(description: "third photo still processing")
        let release = AsyncScanRelease()
        var fetches = 0
        await service.setBeforeFetch {
            fetches += 1
            if fetches == 2 { entered.fulfill(); await release.wait() }
        }
        let task = Task { await vm.onAppear() }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(vm.photoIdentifiers, ["one", "two"], "The second verified photo must not wait for the whole set")
        vm.currentDecisionIndex = 1
        vm.toggleCleanupSelection(second)
        await release.finish()
        await task.value

        XCTAssertEqual(vm.photoIdentifiers, ["one", "two", "three"])
        XCTAssertEqual(vm.currentDecisionIndex, 1)
        XCTAssertEqual(vm.selectedCleanupKeys, ["two"])
        XCTAssertEqual(store.dailySessionProgress().deletedPhotoCount, 0)
        XCTAssertEqual(store.dailySessionProgress().savedRecordCount, 0)
        XCTAssertEqual(defaults.data(forKey: UserScopedStorage.key(SavedRecordStore.storageKey)), records)
    }

    func testRequestedMoreUsesAutomaticContinuationWithoutCompletingAnotherSession() async {
        let (vm, store, subscription, service, _, _) = context()
        await service.setBatches([
            .init(decisions: [], visitedIdentifiers: [], hasMore: true, retryableFailureCount: 1, hasFreshPhotos: true),
            .init(decisions: [unit("available")], visitedIdentifiers: ["available"], hasMore: false)
        ])
        await vm.loadMoreDecisions()
        XCTAssertEqual(vm.photoIdentifiers, ["available"])
        let limits = await service.fetchLimits
        XCTAssertEqual(limits, [3, 3])
        XCTAssertFalse(subscription.firstExperienceCompleted)
        XCTAssertFalse(store.hasCompletedCleanupToday())
        XCTAssertTrue(store.dailySessionProgress().processedDecisionKeys.isEmpty)
    }

    func testPauseDuringContinuationRejectsLateResultAndEarlierCoverage() async {
        let (vm, store, subscription, service, _, _) = context()
        let entered = expectation(description: "continuation started")
        let release = AsyncScanRelease()
        var calls = 0
        await service.setBatches([
            .init(decisions: [], visitedIdentifiers: ["first-window"], hasMore: true, hasFreshPhotos: true),
            .init(decisions: [unit("late")], visitedIdentifiers: ["late"], hasMore: false)
        ])
        await service.setBeforeFetch {
            calls += 1
            if calls == 2 { entered.fulfill(); await release.wait() }
        }
        let task = Task { await vm.onAppear() }
        await fulfillment(of: [entered], timeout: 2)
        vm.pauseCuration()
        await release.finish()
        await task.value
        guard case .scanPaused = vm.state else { return XCTFail("A late continuation must not reopen Home") }
        XCTAssertTrue(vm.photoIdentifiers.isEmpty)
        XCTAssertTrue(store.scannedPhotoIdentifiers().isEmpty)
        XCTAssertTrue(store.dailySessionProgress().curatedPhotoIdentifiers.isEmpty)
        XCTAssertFalse(subscription.firstExperienceCompleted)
    }

    func testRevokedPermissionBetweenEmptyWindowsStopsAutomaticContinuation() async {
        let (vm, store, _, service, access, _) = context()
        await service.setBatch(.init(decisions: [], visitedIdentifiers: ["checked"], hasMore: true, hasFreshPhotos: true))
        await service.setBeforeFetch { access.status = .denied }
        await vm.onAppear()
        guard case .noPermission = vm.state else { return XCTFail("A revoked scope cannot continue searching") }
        let calls = await service.fetchLimits
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(store.scannedPhotoIdentifiers().isEmpty)
        XCTAssertTrue(store.dailySessionProgress().curatedPhotoIdentifiers.isEmpty)
    }

    func testFreshPhotosRemainPrimaryWhenSomeNewReadsFail() async {
        let (vm, _, _, service, access, _) = context(enabled: false)
        access.status = .limited
        await service.setBatch(.init(decisions: [], visitedIdentifiers: [], hasMore: true,
                                     retryableFailureCount: 2, hasFreshPhotos: true, accessiblePhotoCount: 3))

        await vm.loadMoreDecisions()

        XCTAssertTrue(vm.hasScanIssue, "Keep the underlying failure count available for later recovery")
        XCTAssertFalse(vm.hasBlockingScanIssue)
        XCTAssertTrue(vm.canSearchOtherPhotos)
        XCTAssertEqual(vm.emptyPrimaryAction, .findMore)
        XCTAssertEqual(vm.scanStatusTitle, "아직 정리할 사진을 찾지 못했어요.")
        XCTAssertEqual(vm.scanStatusMessage, "읽지 못한 사진은 잠시 두고, 다른 사진에서 찾아볼게요.")
        XCTAssertEqual(vm.completionSecondaryAction, .findMore)
        XCTAssertFalse(vm.completionMessage.contains("다시 시도해주세요"))
    }

    func testCloudOnlyPartOfNewScanDoesNotRequireConsentBeforeOtherPhotos() async throws {
        let (vm, store, _, service, _, defaults) = context(enabled: false, cloudPhotoCount: 2)
        _ = try SavedRecordStore(defaults: defaults).save(text: "기존 기록", photoLocalIdentifier: "saved-photo", capturedDateDescription: nil)
        let existingRecords = defaults.data(forKey: SavedRecordStore.storageKey)
        await service.setBatch(.init(decisions: [], visitedIdentifiers: ["checked"], hasMore: true,
            retryableFailureCount: 2, hasFreshPhotos: true, accessiblePhotoCount: 40))

        await vm.onAppear()

        XCTAssertEqual(vm.cloudPhotoCount, 2)
        XCTAssertTrue(vm.hasScanIssue)
        XCTAssertFalse(vm.hasBlockingScanIssue)
        XCTAssertEqual(vm.emptyPrimaryAction, .findMore)
        XCTAssertEqual(vm.scanStatusTitle, "아직 정리할 사진을 찾지 못했어요.")
        XCTAssertFalse(vm.scanStatusMessage.contains("iCloud"))
        XCTAssertFalse(vm.scanStatusMessage.contains("허용"))
        XCTAssertEqual(service.cloudConsent.count, 0)
        XCTAssertEqual(defaults.data(forKey: SavedRecordStore.storageKey), existingRecords)
        XCTAssertTrue(store.dailySessionProgress().processedDecisionKeys.isEmpty)

        await service.setBatch(.init(decisions: [unit("readable-candidate")], visitedIdentifiers: ["readable-candidate"], hasMore: true,
            retryableFailureCount: 2, hasFreshPhotos: true, accessiblePhotoCount: 40))
        await vm.loadMoreDecisions()
        XCTAssertEqual(vm.photoIdentifiers, ["readable-candidate"])
        XCTAssertEqual(service.cloudConsent.count, 0, "Finding other photos must never silently enable iCloud reads")
        XCTAssertEqual(defaults.data(forKey: SavedRecordStore.storageKey), existingRecords)
    }

    func testCloudRecoveryBecomesPrimaryOnlyWhenFreshPhotosAreExhausted() async {
        let (vm, _, _, service, _, _) = context(enabled: false, cloudPhotoCount: 2)
        await service.setBatch(.init(decisions: [], visitedIdentifiers: [], hasMore: true,
            retryableFailureCount: 2, hasFreshPhotos: false, accessiblePhotoCount: 2))
        await vm.loadMoreDecisions()

        XCTAssertTrue(vm.hasBlockingScanIssue)
        XCTAssertFalse(vm.canSearchOtherPhotos)
        XCTAssertEqual(vm.emptyPrimaryAction, .retry)
        XCTAssertEqual(vm.scanRetryTitle, "iCloud에서 사진 불러오기")
        XCTAssertEqual(vm.scanStatusTitle, vm.scanIssueTitle)
        XCTAssertEqual(vm.scanStatusMessage, vm.scanIssueMessage)
        XCTAssertEqual(service.cloudConsent.count, 0)
    }

    func testExistingPendingCloudPhotoRequiresRecoveryEvenWhenLibraryHasOtherPhotos() async {
        let (vm, store, _, service, _, _) = context(enabled: false, hasUnscanned: true, cloudPhotoCount: 1)
        store.beginDailySession(photoIdentifiers: ["pending-photo"], curationReasons: ["pending-photo": .exactDuplicate])
        await service.setRestored(.init(decisions: [], retryableFailureCount: 1))
        await vm.onAppear()

        XCTAssertTrue(vm.hasBlockingScanIssue)
        XCTAssertFalse(vm.canSearchOtherPhotos)
        XCTAssertEqual(vm.emptyPrimaryAction, .retry)
        XCTAssertEqual(vm.scanStatusTitle, "iCloud에서 사진을 불러와야 해요.")
        XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, ["pending-photo"])
        let fetches = await service.fetchLimits
        XCTAssertTrue(fetches.isEmpty, "A pending recommendation cannot be silently replaced by a new candidate")
        XCTAssertEqual(service.cloudConsent.count, 0)
    }

    func testNonblockingCloudFailureDoesNotBypassSubscriptionForNewSearch() async {
        let (vm, _, subscription, service, _, _) = context(cloudPhotoCount: 2)
        await service.setBatch(.init(decisions: [], visitedIdentifiers: [], hasMore: true,
            retryableFailureCount: 2, hasFreshPhotos: true, accessiblePhotoCount: 40))
        await vm.loadMoreDecisions()
        let searchesBeforeGate = await service.fetchLimits
        subscription.finishFirstExperience()

        XCTAssertEqual(vm.emptyPrimaryAction, .subscription)
        XCTAssertTrue(vm.scanStatusMessage.contains("구독"))
        await vm.loadMoreDecisions()
        XCTAssertTrue(vm.showSubscription)
        XCTAssertEqual(service.cloudConsent.count, 0)
        let fetches = await service.fetchLimits
        XCTAssertEqual(fetches.count, searchesBeforeGate.count)
    }

    func testChangedSelectionAfterCompletionFindsNewCandidateWithoutResettingActivity() async {
        let (vm, store, _, service, access, _) = context(enabled: false)
        access.status = .limited
        store.recordCompletion(deletedPhotoCount: 1, savedRecordCount: 1)
        await vm.onAppear()
        guard case .noCandidate = vm.state else { return XCTFail("A completed day reopens as empty Home") }
        await service.setBatch(.init(decisions: [unit("newly-allowed")], visitedIdentifiers: ["newly-allowed"], hasMore: false, accessiblePhotoCount: 3))
        await vm.refreshPhotoSelection()
        XCTAssertEqual(vm.photoIdentifiers, ["newly-allowed"])
        XCTAssertEqual(store.todaySummary()?.deletedPhotoCount, 1)
        XCTAssertEqual(store.todaySummary()?.savedRecordCount, 1)
        XCTAssertFalse(vm.additionalSearchFoundNoCandidates)
    }

    func testEmptyLibrarySelectionAndReadFailureHaveDifferentNextActions() async {
        let (vm, _, _, service, access, _) = context()
        access.status = .limited
        await service.setBatch(.init(decisions: [], visitedIdentifiers: [], hasMore: false, accessiblePhotoCount: 0))
        await vm.loadMoreDecisions()
        XCTAssertEqual(vm.scanStatusTitle, "선택한 사진이 없어요.")
        XCTAssertEqual(vm.scanStatusMessage, "선택한 사진 안에서만 추천을 찾아요.")
        XCTAssertEqual(vm.emptyPrimaryAction, .selectPhotos)
        await service.setBatch(.init(decisions: [], visitedIdentifiers: [], hasMore: true, retryableFailureCount: 2, accessiblePhotoCount: 2))
        await vm.loadMoreDecisions()
        XCTAssertEqual(vm.emptyPrimaryAction, .retry)
        XCTAssertEqual(vm.scanStatusTitle, "사진을 확인하지 못했어요.")
        XCTAssertEqual(vm.scanStatusMessage, "사진 2장을 읽지 못했어요. 아래 버튼을 누르면 다시 확인해요. 사진을 따로 고를 필요는 없어요.")
    }

    func testMoreRecommendationActionExplainsSubscriptionBeforeNavigation() async {
        let (vm, _, subscriptions, service, _, _) = context()
        await service.setBatch(.init(decisions: [], visitedIdentifiers: [], hasMore: true))
        await vm.loadMoreDecisions()
        subscriptions.finishFirstExperience()
        XCTAssertEqual(vm.emptyPrimaryAction, .subscription)
        XCTAssertTrue(vm.emptyNextStepMessage.contains("구독"))
        await vm.loadMoreDecisions()
        XCTAssertTrue(vm.showSubscription)
        let calls = await service.fetchLimits
        XCTAssertEqual(calls.count, 1)
    }

    func testPausedHomeStillChecksRevokedPermissionAndRetainsChoices() async {
        let (vm, store, subscriptions, service, access, _) = context()
        store.beginDailySession(photoIdentifiers: ["done", "pending"])
        store.recordDailyDecision(decisionKey: "done", deletedPhotoCount: 1, savedRecord: true)
        vm.state = .scanPaused
        access.status = .denied
        await vm.onAppear()
        guard case .noPermission = vm.state else { return XCTFail("Revoked permission must override pause") }
        XCTAssertEqual(vm.permissionStatus, .denied)
        XCTAssertEqual(vm.weeklyProgress.deletedPhotoCount, 1)
        XCTAssertEqual(vm.weeklyProgress.savedRecordCount, 1)
        XCTAssertEqual(store.dailySessionProgress().deletedPhotoCount, 1)
        XCTAssertEqual(store.dailySessionProgress().savedRecordCount, 1)
        XCTAssertFalse(subscriptions.firstExperienceCompleted)
        let calls = await service.fetchLimits
        XCTAssertTrue(calls.isEmpty)
    }

    func testUndeterminedAndRestrictedPermissionDoNotStartPhotoReads() async {
        for status: PHAuthorizationStatus in [.notDetermined, .restricted] {
            let (vm, _, _, service, access, _) = context()
            access.status = status
            await vm.onAppear()
            guard case .noPermission = vm.state else { return XCTFail("Permission required") }
            XCTAssertEqual(vm.permissionStatus, status)
            let calls = await service.fetchLimits
            XCTAssertTrue(calls.isEmpty)
        }
    }

    func testReturnKeepsSelectedPhotoEvenWhenValidationReordersQueue() async {
        let (vm, store, _, service, _, _) = context()
        let units = [unit("a"), unit("b"), unit("c")]
        store.beginDailySession(photoIdentifiers: ["a", "b", "c"])
        await service.setRestored(.init(decisions: units, retryableFailureCount: 0))
        await vm.onAppear()
        vm.currentDecisionIndex = 1
        await service.setRestored(.init(decisions: [units[2], units[0], units[1]], retryableFailureCount: 0))
        await vm.onAppear()
        guard case let .ready(selected) = vm.state else { return XCTFail("Ready expected") }
        XCTAssertEqual(selected.persistenceKey, "b")
        XCTAssertEqual(vm.currentDecisionIndex, 2)
    }

    func testInaccessiblePhotosKeepSessionAndRecordUntilExplicitReplacement() async throws {
        let (vm, store, subscriptions, service, access, defaults) = context()
        access.status = .limited
        store.beginDailySession(photoIdentifiers: ["done", "pending"], comparisonReferences: ["pending": "reference"])
        store.recordDailyDecision(decisionKey: "done", deletedPhotoCount: 1, savedRecord: true)
        let records = SavedRecordStore(defaults: defaults)
        _ = try records.save(text: "남겨둔 기억", photoLocalIdentifier: "done", capturedDateDescription: nil)
        await service.setRestored(.init(decisions: [], retryableFailureCount: 0,
                                       inaccessibleIdentifiers: ["pending", "reference"]))
        await vm.onAppear()
        guard case .noCandidate = vm.state else { return XCTFail("Recoverable state expected") }
        XCTAssertEqual(vm.inaccessiblePhotoCount, 2)
        XCTAssertFalse(vm.scanIssueMessage.contains("삭제되었어요"))
        XCTAssertFalse(subscriptions.firstExperienceCompleted)
        XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, ["done", "pending"])

        await service.setBatch(.init(decisions: [unit("replacement")], visitedIdentifiers: ["replacement"], hasMore: false))
        await vm.findOtherPhotos()
        XCTAssertEqual(vm.photoIdentifiers, ["replacement"])
        let limits = await service.fetchLimits
        XCTAssertEqual(limits, [2], "Completed choice still occupies the introductory batch")
        let progress = store.dailySessionProgress()
        XCTAssertEqual(progress.processedDecisionKeys, ["done"])
        XCTAssertEqual(progress.deletedPhotoCount, 1)
        XCTAssertEqual(progress.savedRecordCount, 1)
        XCTAssertEqual(records.records().map(\.text), ["남겨둔 기억"])
        XCTAssertFalse(subscriptions.firstExperienceCompleted)
    }

    func testFailedReplacementScanDoesNotConsumeFreeSessionOrEraseChoices() async {
        let (vm, store, subscriptions, service, _, _) = context()
        store.beginDailySession(photoIdentifiers: ["done", "missing"])
        store.recordDailyDecision(decisionKey: "done", deletedPhotoCount: 1, savedRecord: false)
        await service.setRestored(.init(decisions: [], retryableFailureCount: 0, inaccessibleIdentifiers: ["missing"]))
        await vm.onAppear()
        await service.setBatch(.init(decisions: [], visitedIdentifiers: [], hasMore: true, retryableFailureCount: 2))
        await vm.findOtherPhotos()
        guard case .noCandidate = vm.state else { return XCTFail("Replacement read failure is not completion") }
        XCTAssertTrue(vm.hasScanIssue)
        XCTAssertFalse(subscriptions.firstExperienceCompleted)
        XCTAssertEqual(store.dailySessionProgress().processedDecisionKeys, ["done"])
        XCTAssertEqual(store.dailySessionProgress().deletedPhotoCount, 1)
    }

    func testPartialRecoveryDoesNotFinishWhileAnotherPhotoIsUnreadable() async {
        let (vm, store, subscriptions, service, _, _) = context()
        let available = unit("available")
        store.beginDailySession(photoIdentifiers: ["available", "unreadable"])
        await service.setRestored(.init(decisions: [available], retryableFailureCount: 1))
        await vm.onAppear()
        vm.markTodayCompleted(unit: available, deletedCount: 0, savedRecord: false, protectPhoto: false)
        guard case .noCandidate = vm.state else { return XCTFail("Failure must remain recoverable") }
        XCTAssertFalse(subscriptions.firstExperienceCompleted)
        XCTAssertEqual(store.dailySessionProgress().processedDecisionKeys, ["available"])
        await service.setRestored(.init(decisions: [unit("unreadable")], retryableFailureCount: 0))
        await vm.retryCuration()
        XCTAssertEqual(vm.photoIdentifiers, ["unreadable"])
        XCTAssertEqual(vm.currentDecisionNumber, 2)
        XCTAssertFalse(vm.hasScanIssue)
    }

    func testPausedScanIgnoresLateResultsAndRequiresExplicitResume() async {
        let (vm, store, subscriptions, service, _, _) = context()
        let entered = expectation(description: "scan started")
        let release = AsyncScanRelease()
        await service.setBatch(.init(decisions: [unit("late")], visitedIdentifiers: ["late"], hasMore: false))
        await service.setBeforeFetch { entered.fulfill(); await release.wait() }
        let task = Task { await vm.onAppear() }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertTrue(vm.scanIsTakingLong(at: Date().addingTimeInterval(9)))
        vm.pauseCuration()
        await release.finish()
        await task.value
        guard case .scanPaused = vm.state else { return XCTFail("Late response must not change pause") }
        XCTAssertTrue(store.scannedPhotoIdentifiers().isEmpty)
        XCTAssertTrue(store.dailySessionProgress().curatedPhotoIdentifiers.isEmpty)
        XCTAssertFalse(subscriptions.firstExperienceCompleted)
        XCTAssertFalse(vm.scanIsTakingLong(at: Date().addingTimeInterval(9)))
        await vm.onAppear()
        var calls = await service.fetchLimits
        XCTAssertEqual(calls.count, 1)
        await service.setBeforeFetch(nil)
        await vm.resumeCuration()
        calls = await service.fetchLimits
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(vm.photoIdentifiers, ["late"])
    }

    func testPermissionRevokedDuringReadRejectsResultBeforePersistence() async {
        let (vm, store, _, service, access, _) = context()
        let entered = expectation(description: "read started")
        let release = AsyncScanRelease()
        await service.setBatch(.init(decisions: [unit("late")], visitedIdentifiers: ["late"], hasMore: false))
        await service.setBeforeFetch { entered.fulfill(); await release.wait() }
        let task = Task { await vm.onAppear() }
        await fulfillment(of: [entered], timeout: 2)
        access.status = .denied
        await release.finish()
        await task.value
        guard case .noPermission = vm.state else { return XCTFail("Revoked access must reject the result") }
        XCTAssertTrue(vm.photoIdentifiers.isEmpty)
        XCTAssertTrue(store.scannedPhotoIdentifiers().isEmpty)
        XCTAssertTrue(store.dailySessionProgress().curatedPhotoIdentifiers.isEmpty)
    }

    func testConfirmedFullToLimitedChangeAutomaticallyLoadsAllowedPhotosAndPreservesHistory() async throws {
        for relaunch in [false, true] {
            let (original, store, subscriptions, service, access, defaults) = context(enabled: false)
            let oldPhotos = (1...3).map { unit("private-\($0)") }
            let newPhotos = (1...3).map { variedUnit("allowed-\($0)", position: $0) }
            let records = SavedRecordStore(defaults: defaults)
            try records.save(text: "기존 기록", photoLocalIdentifier: "older-photo", capturedDateDescription: nil)
            let recordsBefore = defaults.data(forKey: UserScopedStorage.key(SavedRecordStore.storageKey))
            let protectedBefore = CurationProtectionStore.shared.identifiers()
            store.beginDailySession(photoIdentifiers: oldPhotos.map(\.persistenceKey))
            await service.setRestored(.init(decisions: oldPhotos, retryableFailureCount: 0))
            await original.onAppear()
            let reviewedBefore = store.reviewedPhotoIdentifiers()
            store.recordScannedPhotos(["old-full-scope"])
            access.status = .limited
            await service.setRestored(.init(decisions: [], retryableFailureCount: 0,
                inaccessibleIdentifiers: Set(oldPhotos.map(\.persistenceKey))))
            await service.setBatch(.init(decisions: newPhotos, visitedIdentifiers: Set(newPhotos.map(\.persistenceKey)),
                                         hasMore: false, accessiblePhotoCount: 4))
            let vm = relaunch ? HomeViewModel(subscriptions: subscriptions, curationService: service, activity: store,
                authorizationStatus: { access.status }, observesPhotoLibrary: false, selectionDefaults: defaults) : original

            await vm.onAppear()

            guard case .ready = vm.state else { return XCTFail("Confirmed narrowed scope should recover without another tap") }
            XCTAssertEqual(vm.photoIdentifiers, newPhotos.map(\.persistenceKey))
            XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, newPhotos.map(\.persistenceKey))
            XCTAssertFalse(store.scannedPhotoIdentifiers().contains("old-full-scope"))
            XCTAssertEqual(vm.selectedCleanupCount, 0)
            XCTAssertEqual(store.dailySessionProgress().deletedPhotoCount, 0)
            XCTAssertEqual(store.reviewedPhotoIdentifiers(), reviewedBefore, "Revoked access is not a review or deletion")
            XCTAssertEqual(defaults.data(forKey: UserScopedStorage.key(SavedRecordStore.storageKey)), recordsBefore)
            XCTAssertEqual(CurationProtectionStore.shared.identifiers(), protectedBefore)
            XCTAssertEqual(service.cloudConsent.count, 0)
            let limits = await service.fetchLimits
            XCTAssertEqual(limits, [3])
        }
    }

    func testReadyFullAccessBatchWithUnrelatedReadFailureRecoversAfterLimitedAccessRelaunch() async throws {
        let (original, store, subscriptions, service, access, defaults) = context(enabled: false)
        let oldPhotos = (1...3).map { variedUnit("verified-full-\($0)", position: $0) }
        let allowedPhotos = (1...3).map { variedUnit("allowed-after-relaunch-\($0)", position: $0) }
        let records = SavedRecordStore(defaults: defaults)
        try records.save(text: "기존 기록 보존", photoLocalIdentifier: "older-record-photo", capturedDateDescription: nil)
        let recordsBefore = defaults.data(forKey: UserScopedStorage.key(SavedRecordStore.storageKey))
        let protectedBefore = CurationProtectionStore.shared.identifiers()
        await service.setBatch(.init(decisions: oldPhotos, visitedIdentifiers: Set(oldPhotos.map(\.persistenceKey)),
            hasMore: true, retryableFailureCount: 1, hasFreshPhotos: true, accessiblePhotoCount: 100))

        await original.onAppear()

        guard case .ready = original.state else { return XCTFail("Three verified candidates remain ready despite an unrelated read failure") }
        XCTAssertEqual(original.photoIdentifiers, oldPhotos.map(\.persistenceKey))
        XCTAssertGreaterThan(original.unavailablePhotoCount, 0, "Exercise partial library scanning, not a fully successful scan")
        let activityBefore = defaults.data(forKey: UserScopedStorage.key("recoco_activity_events_v1"))
        access.status = .limited
        await service.setRestored(.init(decisions: [], retryableFailureCount: 0,
            inaccessibleIdentifiers: Set(oldPhotos.map(\.persistenceKey))))
        await service.setBatch(.init(decisions: allowedPhotos, visitedIdentifiers: Set(allowedPhotos.map(\.persistenceKey)),
            hasMore: false, accessiblePhotoCount: 4))
        let restarted = HomeViewModel(subscriptions: subscriptions, curationService: service, activity: store,
            authorizationStatus: { access.status }, observesPhotoLibrary: false, selectionDefaults: defaults)

        await restarted.onAppear()

        guard case .ready = restarted.state else { return XCTFail("Verified queue authorization must survive process restart even when unrelated photos failed to read") }
        XCTAssertEqual(restarted.photoIdentifiers, allowedPhotos.map(\.persistenceKey))
        XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, allowedPhotos.map(\.persistenceKey))
        XCTAssertEqual(restarted.selectedCleanupCount, 0)
        XCTAssertEqual(store.weeklySnapshot().deletedPhotoCount, 0)
        XCTAssertEqual(defaults.data(forKey: UserScopedStorage.key("recoco_activity_events_v1")), activityBefore)
        XCTAssertEqual(defaults.data(forKey: UserScopedStorage.key(SavedRecordStore.storageKey)), recordsBefore)
        XCTAssertEqual(CurationProtectionStore.shared.identifiers(), protectedBefore)
        XCTAssertEqual(service.cloudConsent.count, 0)
        let limits = await service.fetchLimits
        XCTAssertEqual(limits, [3, 3], "Relaunch performs one automatic replacement scan without a recovery-button tap")
    }

    func testValidatedVisibleShortQueuePersistsAuthorizationBeforeBackgroundTopUpFinishes() async {
        let (original, store, subscriptions, service, access, defaults) = context(enabled: false, hasUnscanned: true)
        let initial = [unit("visible-full-one"), unit("visible-full-two")]
        store.beginDailySession(photoIdentifiers: initial.map(\.persistenceKey),
            comparisonReferences: Dictionary(uniqueKeysWithValues: initial.map { ($0.persistenceKey, $0.comparisonLocalIdentifier!) }),
            curationReasons: Dictionary(uniqueKeysWithValues: initial.map { ($0.persistenceKey, CurationReasonCode.exactDuplicate) }))
        await service.setRestored(.init(decisions: initial, retryableFailureCount: 0))
        let entered = expectation(description: "visible queue background top-up started")
        let release = AsyncScanRelease()
        await service.setBatch(.init(decisions: [unit("late-full-third")], visitedIdentifiers: ["late-full-third"], hasMore: false))
        await service.setBeforeFetch { entered.fulfill(); await release.wait() }
        let oldTask = Task { await original.onAppear() }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(original.photoIdentifiers, initial.map(\.persistenceKey))
        XCTAssertNotNil(defaults.data(forKey: UserScopedStorage.key("recoco_curation_authorization_v1")),
                        "Already validated visible photos need restart provenance before optional top-up completes")
        original.pauseCuration()
        access.status = .limited
        await service.setBeforeFetch(nil)
        await service.setRestored(.init(decisions: [], retryableFailureCount: 0,
            inaccessibleIdentifiers: Set(initial.map(\.persistenceKey))))
        let allowed = (1...3).map { variedUnit("limited-after-topup-\($0)", position: $0) }
        await service.setBatch(.init(decisions: allowed, visitedIdentifiers: Set(allowed.map(\.persistenceKey)),
                                     hasMore: false, accessiblePhotoCount: 4))
        let restarted = HomeViewModel(subscriptions: subscriptions, curationService: service, activity: store,
            authorizationStatus: { access.status }, observesPhotoLibrary: false, selectionDefaults: defaults)

        await restarted.onAppear()
        await release.finish()
        await oldTask.value

        guard case .ready = restarted.state else { return XCTFail("Background top-up cancellation cannot lose the visible queue's known authorization") }
        XCTAssertEqual(restarted.photoIdentifiers, allowed.map(\.persistenceKey))
        XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, allowed.map(\.persistenceKey))
        XCTAssertEqual(store.weeklySnapshot().deletedPhotoCount, 0)
        XCTAssertTrue(restarted.selectedCleanupKeys.isEmpty)
        let limits = await service.fetchLimits
        XCTAssertEqual(limits, [1, 3], "The cancelled old top-up must not add photos to the replacement batch")
    }

    func testPartiallyRestoredQueueDoesNotCreateAuthorizationProofForUnvalidatedPendingPhotos() async {
        let (original, store, subscriptions, service, access, defaults) = context(enabled: false)
        let pending = ["validated-one", "validated-two", "unread-pending"]
        store.beginDailySession(photoIdentifiers: pending)
        await service.setRestored(.init(decisions: pending.prefix(2).map { unit($0) }, retryableFailureCount: 1))

        await original.onAppear()

        XCTAssertEqual(original.photoIdentifiers, Array(pending.prefix(2)))
        XCTAssertNil(defaults.data(forKey: UserScopedStorage.key("recoco_curation_authorization_v1")),
                     "Only a completely validated pending queue can establish scope provenance")
        access.status = .limited
        await service.setRestored(.init(decisions: [], retryableFailureCount: 0, inaccessibleIdentifiers: Set(pending)))
        let restarted = HomeViewModel(subscriptions: subscriptions, curationService: service, activity: store,
            authorizationStatus: { access.status }, observesPhotoLibrary: false, selectionDefaults: defaults)

        await restarted.onAppear()

        guard case .noCandidate = restarted.state else { return XCTFail("Unproven missing photos keep explicit recovery") }
        XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, pending)
        XCTAssertEqual(restarted.inaccessiblePhotoCount, 3)
        let limits = await service.fetchLimits
        XCTAssertTrue(limits.isEmpty)
    }

    func testCompletedThreePhotosAndProtectedReferenceOnlyEmptySearchPreserveReportAcrossRelaunch() async throws {
        let (original, store, subscriptions, service, access, defaults) = context(enabled: false)
        let reference = "retained-reference-\(UUID().uuidString)"
        let protectionKey = UserScopedStorage.key("recoco_protected_photos_v1")
        let originalProtection = UserDefaults.standard.object(forKey: protectionKey)
        CurationProtectionStore.shared.protect([reference])
        defer {
            if let originalProtection { UserDefaults.standard.set(originalProtection, forKey: protectionKey) }
            else { UserDefaults.standard.removeObject(forKey: protectionKey) }
        }
        let records = SavedRecordStore(defaults: defaults)
        try records.save(text: "그대로 남길 기록", photoLocalIdentifier: "older-record", capturedDateDescription: nil)
        store.recordCompletion(deletedPhotoCount: 3, savedRecordCount: 0)
        let eventsBefore = defaults.data(forKey: UserScopedStorage.key("recoco_activity_events_v1"))
        let recordsBefore = defaults.data(forKey: UserScopedStorage.key(SavedRecordStore.storageKey))
        await original.onAppear()
        access.status = .limited
        let restarted = HomeViewModel(subscriptions: subscriptions, curationService: service, activity: store,
            authorizationStatus: { access.status }, observesPhotoLibrary: false, selectionDefaults: defaults)
        await restarted.onAppear()
        XCTAssertEqual(restarted.scanStatusTitle, "오늘 고른 사진을 모두 살펴봤어요.")
        let beforeSearches = await service.fetchLimits
        XCTAssertTrue(beforeSearches.isEmpty, "Completed relaunch must not replay another automatic batch")
        // Deliberately nominate the sole retained reference: the shared
        // collector must still exclude it rather than pad the new carousel.
        await service.setBatch(.init(decisions: [unit(reference)], visitedIdentifiers: [reference],
                                     hasMore: false, accessiblePhotoCount: 1))

        await restarted.loadMoreDecisions()

        guard case .noCandidate = restarted.state else { return XCTFail("A protected comparison copy is not a replacement candidate") }
        XCTAssertTrue(restarted.photoIdentifiers.isEmpty)
        XCTAssertTrue(store.dailySessionProgress().curatedPhotoIdentifiers.isEmpty)
        XCTAssertEqual(restarted.selectedCleanupCount, 0)
        XCTAssertEqual(store.todaySummary()?.deletedPhotoCount, 3)
        XCTAssertEqual(store.weeklySnapshot().deletedPhotoCount, 3)
        XCTAssertEqual(defaults.data(forKey: UserScopedStorage.key("recoco_activity_events_v1")), eventsBefore)
        XCTAssertEqual(defaults.data(forKey: UserScopedStorage.key(SavedRecordStore.storageKey)), recordsBefore)
        XCTAssertTrue(CurationProtectionStore.shared.identifiers().contains(reference))
        let reopened = HomeViewModel(subscriptions: subscriptions, curationService: service, activity: store,
            authorizationStatus: { access.status }, observesPhotoLibrary: false, selectionDefaults: defaults)
        await reopened.onAppear()
        guard case .noCandidate = reopened.state else { return XCTFail("Relaunch keeps Home instead of replaying completion") }
        XCTAssertEqual(reopened.scanStatusTitle, "오늘 고른 사진을 모두 살펴봤어요.")
        XCTAssertEqual(reopened.weeklyProgress.deletedPhotoCount, 3)
        XCTAssertEqual(defaults.data(forKey: UserScopedStorage.key("recoco_activity_events_v1")), eventsBefore)
        let searches = await service.fetchLimits
        XCTAssertEqual(searches, [3], "Only the explicit optional search is counted")
    }

    func testAutomaticScopeRecoveryRespectsRemainingCapacityAndCompletedCounts() async {
        let (vm, store, _, service, access, _) = context(enabled: false)
        store.beginDailySession(photoIdentifiers: ["already-done", "old-one", "old-two"])
        store.recordDailyDecision(decisionKey: "already-done", deletedPhotoCount: 1, savedRecord: true)
        await service.setRestored(.init(decisions: [unit("old-one"), unit("old-two")], retryableFailureCount: 0))
        await vm.onAppear()
        access.status = .limited
        await service.setRestored(.init(decisions: [], retryableFailureCount: 0,
                                       inaccessibleIdentifiers: ["old-one", "old-two"]))
        await service.setBatch(.init(decisions: [unit("new-one"), unit("new-two", .visuallySimilar)],
                                     visitedIdentifiers: ["new-one", "new-two"], hasMore: false))

        await vm.onAppear()

        XCTAssertEqual(vm.photoIdentifiers, ["new-one", "new-two"])
        XCTAssertEqual(store.dailySessionProgress().processedDecisionKeys, ["already-done"])
        XCTAssertEqual(store.dailySessionProgress().deletedPhotoCount, 1)
        XCTAssertEqual(store.dailySessionProgress().savedRecordCount, 1)
        XCTAssertEqual(store.weeklySnapshot().deletedPhotoCount, 1)
        let limits = await service.fetchLimits
        XCTAssertEqual(limits, [2], "Recovery cannot start an extra three-photo batch")
    }

    func testPermissionNarrowingPreservesCheckedPhotosAcrossRelaunchAndConfirmation() async {
        for relaunch in [false, true] {
            let (original, store, subscriptions, service, access, defaults) = context(enabled: false)
            let checked = unit("checked-pending")
            store.beginDailySession(photoIdentifiers: ["done", "checked-pending", "unchecked-pending"])
            store.recordDailyDecision(decisionKey: "done", deletedPhotoCount: 1, savedRecord: false)
            await service.setRestored(.init(decisions: [checked, unit("unchecked-pending")], retryableFailureCount: 0))
            await original.onAppear()
            original.toggleCleanupSelection(checked)
            renderHomePreviews(original)
            XCTAssertNotNil(original.beginSelectedCleanup())
            access.status = .limited
            await service.setRestored(.init(decisions: [], retryableFailureCount: 0,
                inaccessibleIdentifiers: ["checked-pending", "unchecked-pending"]))
            await original.onAppear()
            XCTAssertEqual(original.photoIdentifiers, ["checked-pending", "unchecked-pending"],
                           "A system confirmation owns its original selection until it finishes")
            original.endSelectedCleanup()
            let selectionBefore = defaults.stringArray(forKey: UserScopedStorage.key("recoco_cleanup_selection_v1"))
            let vm = relaunch ? HomeViewModel(subscriptions: subscriptions, curationService: service, activity: store,
                authorizationStatus: { access.status }, observesPhotoLibrary: false, selectionDefaults: defaults) : original

            await vm.onAppear()

            guard case .noCandidate = vm.state else { return XCTFail("An existing checked choice needs explicit recovery") }
            XCTAssertEqual(vm.selectedCleanupKeys, ["checked-pending"])
            XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, ["done", "checked-pending", "unchecked-pending"])
            XCTAssertEqual(store.dailySessionProgress().deletedPhotoCount, 1)
            XCTAssertEqual(defaults.stringArray(forKey: UserScopedStorage.key("recoco_cleanup_selection_v1")), selectionBefore)
            let limits = await service.fetchLimits
            XCTAssertTrue(limits.isEmpty)
        }
    }

    func testPermissionNarrowingNeverTreatsICloudOrReadFailureAsRevokedAccess() async {
        for mixedMissingAsset in [false, true] {
            let (vm, store, _, service, access, _) = context(enabled: false, cloudPhotoCount: 1)
            store.beginDailySession(photoIdentifiers: ["cloud-pending"])
            await service.setRestored(.init(decisions: [unit("cloud-pending")], retryableFailureCount: 0))
            await vm.onAppear()
            access.status = .limited
            await service.setRestored(.init(decisions: [], retryableFailureCount: 1,
                inaccessibleIdentifiers: mixedMissingAsset ? ["reference"] : []))

            await vm.onAppear()

            guard case .noCandidate = vm.state else { return XCTFail("Unreadable photos retain recovery") }
            XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, ["cloud-pending"])
            XCTAssertEqual(vm.unavailablePhotoCount, 1)
            XCTAssertEqual(vm.scanStatusTitle, vm.scanIssueTitle)
            XCTAssertEqual(service.cloudConsent.count, 0, "A scope change does not grant network consent")
            let limits = await service.fetchLimits
            XCTAssertTrue(limits.isEmpty)
        }
    }

    func testGenericLibraryChangeOrSurvivingPhotoDoesNotAutomaticallyReplacePendingQueue() async {
        for hasSurvivor in [false, true] {
            let (vm, store, _, service, access, _) = context(enabled: false)
            access.status = hasSurvivor ? .authorized : .limited
            store.beginDailySession(photoIdentifiers: ["old-one", "old-two"])
            await service.setRestored(.init(decisions: [unit("old-one"), unit("old-two")], retryableFailureCount: 0))
            await vm.onAppear()
            access.status = .limited
            vm.photoLibraryDidChange()
            await service.setRestored(.init(decisions: hasSurvivor ? [unit("old-one")] : [], retryableFailureCount: 0,
                inaccessibleIdentifiers: hasSurvivor ? ["old-two"] : ["old-one", "old-two"]))

            await vm.onAppear()

            XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, ["old-one", "old-two"])
            XCTAssertEqual(vm.photoIdentifiers, hasSurvivor ? ["old-one"] : [])
            XCTAssertGreaterThan(vm.inaccessiblePhotoCount, 0)
            let limits = await service.fetchLimits
            XCTAssertTrue(limits.isEmpty, "Unknown scope changes and partially valid queues keep explicit recovery")
        }
    }

    func testPermissionNarrowingRejectsLateOldRestorationAfterAutomaticReplacement() async {
        let (vm, store, _, service, access, _) = context(enabled: false)
        let oldPhotos = (1...3).map { unit("old-\($0)") }
        store.beginDailySession(photoIdentifiers: oldPhotos.map(\.persistenceKey))
        await service.setRestored(.init(decisions: oldPhotos, retryableFailureCount: 0))
        await vm.onAppear()
        let entered = expectation(description: "old scope validation started")
        let release = AsyncScanRelease()
        await service.setBeforeRestore { entered.fulfill(); await release.wait() }
        let oldTask = Task { await vm.onAppear() }
        await fulfillment(of: [entered], timeout: 2)
        access.status = .limited
        await service.setBeforeRestore(nil)
        await service.setRestored(.init(decisions: [], retryableFailureCount: 0,
                                       inaccessibleIdentifiers: Set(oldPhotos.map(\.persistenceKey))))
        let newPhotos = (1...3).map { variedUnit("new-\($0)", position: $0) }
        await service.setBatch(.init(decisions: newPhotos, visitedIdentifiers: Set(newPhotos.map(\.persistenceKey)), hasMore: false))

        await vm.onAppear()
        await release.finish()
        await oldTask.value

        XCTAssertEqual(vm.photoIdentifiers, newPhotos.map(\.persistenceKey))
        XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, newPhotos.map(\.persistenceKey))
        let limits = await service.fetchLimits
        XCTAssertEqual(limits, [3])
    }

    func testLateUnscannedPhotoResultCannotReplaceANewerSessionOrAvailability() async {
        for completedReturn in [false, true] {
            let (vm, store, _, service, _, _) = context(enabled: false)
            if completedReturn {
                store.recordCompletion(deletedPhotoCount: 3, savedRecordCount: 0)
            } else {
                let oldPhotos = (1...3).map { unit("availability-old-\($0)") }
                store.beginDailySession(photoIdentifiers: oldPhotos.map(\.persistenceKey))
                await service.setRestored(.init(decisions: oldPhotos, retryableFailureCount: 0))
            }
            let entered = expectation(description: "old availability lookup started")
            let release = AsyncScanRelease()
            await service.setHasUnscannedResponses([true, false])
            await service.setBeforeHasUnscanned { entered.fulfill(); await release.wait() }
            let oldTask = Task { await vm.onAppear() }
            await fulfillment(of: [entered], timeout: 2)
            let newPhotos = (1...3).map { unit("availability-new-\($0)") }
            // Model an explicit replacement: beginDailySession deliberately
            // refuses to overwrite an existing queue until it is retired.
            store.clearPendingRecommendations()
            store.beginDailySession(photoIdentifiers: newPhotos.map(\.persistenceKey))
            XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, newPhotos.map(\.persistenceKey))
            await service.setRestored(.init(decisions: newPhotos, retryableFailureCount: 0))
            await service.setBeforeHasUnscanned(nil)
            vm.photoLibraryDidChange()

            await vm.onAppear()
            await release.finish()
            await oldTask.value

            guard case .ready = vm.state else { return XCTFail("An old availability result cannot restore an earlier screen") }
            XCTAssertEqual(vm.photoIdentifiers, newPhotos.map(\.persistenceKey))
            XCTAssertFalse(vm.hasMorePhotos, "Only the current generation may publish photo availability")
            XCTAssertEqual(store.dailySessionProgress().curatedPhotoIdentifiers, newPhotos.map(\.persistenceKey))
            XCTAssertEqual(store.weeklySnapshot().deletedPhotoCount, completedReturn ? 3 : 0)
        }
    }

    func testAddingLimitedPhotosWithThreePendingPreservesQueueSelectionAndHistory() async throws {
        let (home, store, _, service, access, defaults) = context(enabled: false, hasUnscanned: true)
        access.status = .limited
        let pending = (1...3).map { variedUnit("before-grant-\($0)", position: $0) }
        let previousIDs = pending.map(\.persistenceKey)
        let reasons = Dictionary(uniqueKeysWithValues: pending.map { ($0.persistenceKey, $0.reasonCodes[0]) })
        let references = Dictionary(uniqueKeysWithValues: pending.compactMap { photo in
            photo.comparisonLocalIdentifier.map { (photo.persistenceKey, $0) }
        })
        let records = SavedRecordStore(defaults: defaults)
        let keptRecord = try records.save(text: "보관한 기록", photoLocalIdentifier: nil, capturedDateDescription: nil)
        store.recordCompletion(deletedPhotoCount: 2, savedRecordCount: 0)
        store.beginDailySession(photoIdentifiers: previousIDs, comparisonReferences: references, curationReasons: reasons)
        await service.setRestored(.init(decisions: pending, retryableFailureCount: 0))
        await home.onAppear()
        home.browsePhoto(at: 1)
        home.toggleCleanupSelection(pending[1])
        store.recordScannedPhotos(["previous-scope-only"])
        let added = unit("newly-allowed")
        await service.setBatch(.init(decisions: [added], visitedIdentifiers: [added.persistenceKey], hasMore: false))

        // The picker can finish before Photos sends its change notification.
        await home.refreshPhotoSelection()

        let restoration = await service.restoreIdentifiers
        let newScans = await service.fetchLimits
        XCTAssertEqual(restoration.last, previousIDs, "Three pending photos must be revalidated after the grant.")
        XCTAssertGreaterThanOrEqual(restoration.count, 2)
        XCTAssertTrue(newScans.isEmpty, "Granting access to another photo must not displace an existing three-card batch.")
        XCTAssertEqual(home.photoIdentifiers, previousIDs)
        XCTAssertEqual(home.currentDecisionIndex, 1)
        XCTAssertEqual(home.selectedCleanupKeys, [pending[1].persistenceKey])
        XCTAssertEqual(store.dailySessionProgress().comparisonReferences, references)
        XCTAssertEqual(store.dailySessionProgress().curationReasons, reasons)
        XCTAssertFalse(store.scannedPhotoIdentifiers().contains("previous-scope-only"))
        XCTAssertEqual(store.monthlyDeletedPhotoCount(), 2)
        XCTAssertEqual(records.records().map(\.id), [keptRecord.id])
    }

    func testAddingLimitedPhotosTopsUpShortQueueWithDifferentReasonsWithoutClearingCheck() async {
        let (home, store, _, service, access, _) = context(enabled: false)
        access.status = .limited
        let old = unit("existing-duplicate")
        store.beginDailySession(photoIdentifiers: [old.persistenceKey],
            comparisonReferences: [old.persistenceKey: "kept-existing"],
            curationReasons: [old.persistenceKey: .exactDuplicate])
        await service.setRestored(.init(decisions: [old], retryableFailureCount: 0))
        await home.onAppear()
        home.toggleCleanupSelection(old)
        let similar = unit("new-similar", .visuallySimilar)
        let expiry = unit("new-expired", .expiredScreen)
        let redundant = unit("new-extra-duplicate")
        await service.setHasUnscannedResponses([true])
        await service.setBatch(.init(decisions: [redundant, similar, expiry],
                                     visitedIdentifiers: [redundant.persistenceKey, similar.persistenceKey, expiry.persistenceKey],
                                     hasMore: false))

        await home.refreshPhotoSelection()

        XCTAssertEqual(home.photoIdentifiers, [old.persistenceKey, similar.persistenceKey, expiry.persistenceKey])
        XCTAssertEqual(home.selectedCleanupKeys, [old.persistenceKey])
        XCTAssertEqual(store.dailySessionProgress().curationReasons,
                       [old.persistenceKey: .exactDuplicate, similar.persistenceKey: .visuallySimilar, expiry.persistenceKey: .expiredScreen])
        XCTAssertEqual(store.monthlyDeletedPhotoCount(), 0)
    }

    func testChangedLimitedSelectionRevalidatesEvenThoughAuthorizationIsUnchanged() async {
        let (vm, store, _, service, access, _) = context()
        access.status = .limited
        let selected = unit("still-allowed")
        store.beginDailySession(photoIdentifiers: ["removed-from-selection", "still-allowed"])
        await service.setRestored(.init(decisions: [unit("removed-from-selection"), selected], retryableFailureCount: 0))
        await vm.onAppear()
        vm.currentDecisionIndex = 1
        store.recordScannedPhotos(["old-scope"])
        vm.state = .scanPaused
        vm.photoLibraryDidChange()
        guard case .scanPaused = vm.state else { return XCTFail("A background library callback must not replace the screen") }
        await service.setRestored(.init(decisions: [selected], retryableFailureCount: 0,
                                       inaccessibleIdentifiers: ["removed-from-selection"]))
        await vm.onAppear()
        guard case let .ready(current) = vm.state else { return XCTFail("Updated selection should be restored") }
        XCTAssertEqual(current.persistenceKey, "still-allowed")
        XCTAssertEqual(vm.permissionStatus, .limited)
        XCTAssertEqual(vm.inaccessiblePhotoCount, 1)
        XCTAssertTrue(store.scannedPhotoIdentifiers().isEmpty)
    }

    func testPermissionRestoredResumesPendingPhotoWithoutResettingActivity() async {
        let (vm, store, _, service, access, _) = context()
        store.beginDailySession(photoIdentifiers: ["done", "pending"])
        store.recordDailyDecision(decisionKey: "done", deletedPhotoCount: 0, savedRecord: true)
        store.recordScannedPhotos(["old-scope"])
        access.status = .denied
        await vm.onAppear()
        access.status = .limited
        await service.setRestored(.init(decisions: [unit("pending")], retryableFailureCount: 0))
        await vm.onAppear()
        XCTAssertEqual(vm.photoIdentifiers, ["pending"])
        XCTAssertTrue(vm.isLimitedAccess)
        XCTAssertTrue(store.scannedPhotoIdentifiers().isEmpty)
        XCTAssertEqual(store.dailySessionProgress().savedRecordCount, 1)
        XCTAssertEqual(vm.currentDecisionNumber, 2)
    }
}

private final class CloudConsentProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
    func record() { lock.lock(); defer { lock.unlock() }; requests += 1 }
}

private actor RecoveryService: PhotoCurationServing {
    struct ReflectionCall {
        let excluding: Set<String>
        let reviewDates: [String: Date]
        let limit: Int
    }
    var fetchLimits: [Int] = []
    var fetchExclusions: [Set<String>] = []
    var batches: [PhotoCurationService.ScanBatch] = []
    var restoreIdentifiers: [[String]] = []
    var restoreReasons: [[String: CurationReasonCode]] = []
    var reflectionCalls: [ReflectionCall] = []
    nonisolated let hasUnscanned: Bool
    nonisolated let cloudPhotoCount: Int
    nonisolated let cloudConsent = CloudConsentProbe()
    var batch = PhotoCurationService.ScanBatch(decisions: [], visitedIdentifiers: [], hasMore: false)
    var restored = PhotoCurationService.RestoredDecisions(decisions: [], retryableFailureCount: 0)
    var cachedRestored: PhotoCurationService.RestoredDecisions?
    var reflections: [DecisionUnit] = []
    var beforeFetch: (() async -> Void)?
    var beforeRestore: (() async -> Void)?
    var beforeHasUnscanned: (() async -> Void)?
    var hasUnscannedResponses: [Bool] = []
    var beforeReflection: (() async -> Void)?
    var resetCount = 0
    init(hasUnscanned: Bool = false, cloudPhotoCount: Int = 0) {
        self.hasUnscanned = hasUnscanned
        self.cloudPhotoCount = cloudPhotoCount
    }
    nonisolated func allowCloudPhotoAccess() { cloudConsent.record() }
    func setBatch(_ value: PhotoCurationService.ScanBatch) { batch = value; batches = [] }
    func setBatches(_ values: [PhotoCurationService.ScanBatch]) { batches = values }
    func setRestored(_ value: PhotoCurationService.RestoredDecisions) { restored = value }
    func setCachedRestored(_ value: PhotoCurationService.RestoredDecisions?) { cachedRestored = value }
    func setReflections(_ value: [DecisionUnit]) { reflections = value }
    func setBeforeFetch(_ value: (() async -> Void)?) { beforeFetch = value }
    func setBeforeRestore(_ value: (() async -> Void)?) { beforeRestore = value }
    func setBeforeHasUnscanned(_ value: (() async -> Void)?) { beforeHasUnscanned = value }
    func setHasUnscannedResponses(_ values: [Bool]) { hasUnscannedResponses = values }
    func setBeforeReflection(_ value: (() async -> Void)?) { beforeReflection = value }
    func resetScan() async { resetCount += 1 }
    func hasUnscannedPhotos(excluding: Set<String>) async -> Bool {
        let result = hasUnscannedResponses.isEmpty ? hasUnscanned : hasUnscannedResponses.removeFirst()
        await beforeHasUnscanned?()
        return result
    }
    func fetchNextBatch(excluding: Set<String>, protectedIdentifiers: Set<String>, reviewDates: [String: Date],
        limit: Int, firstResult: Bool, excludingReasonGroups: Set<CleanupReasonGroup>,
                        onProgress: (@Sendable (PhotoCurationService.ScanProgress) -> Void)?) async -> PhotoCurationService.ScanBatch {
        fetchLimits.append(limit)
        fetchExclusions.append(excluding)
        let result = batches.isEmpty ? batch : batches.removeFirst()
        await beforeFetch?()
        return result
    }
    func fetchReflectionPhotos(excluding: Set<String>, reviewDates: [String: Date], limit: Int) async -> [DecisionUnit] {
        reflectionCalls.append(ReflectionCall(excluding: excluding, reviewDates: reviewDates, limit: limit))
        await beforeReflection?()
        return reflections
    }
    func restoreDecisions(localIdentifiers: [String], references: [String: String], reasons: [String: CurationReasonCode],
        protectedIdentifiers: Set<String>, reviewDates: [String: Date]) async -> PhotoCurationService.RestoredDecisions {
        restoreIdentifiers.append(localIdentifiers)
        restoreReasons.append(reasons)
        let result = restored
        await beforeRestore?()
        return result
    }
    func restoreCachedDecisions(localIdentifiers: [String], references: [String: String], reasons: [String: CurationReasonCode],
        protectedIdentifiers: Set<String>, reviewDates: [String: Date]) async -> PhotoCurationService.RestoredDecisions? { cachedRestored }
    func fetchSimilarPhotoDecision(scanLimit: Int, protectedIdentifiers: Set<String>, reviewDates: [String: Date]) async -> DecisionUnit? { nil }
}

final class PhotoReadBoundaryTests: XCTestCase {
    @MainActor
    func testAsyncPreviewReadDoesNotBlockMainActorOrAcceptDuplicateResults() async {
        let value: Int? = await PhotoCurationService.boundedPhotoReadAsync(timeout: 1, cancel: { _ in }) { complete in
            Task { @MainActor in complete(7); complete(9) }
            return 42
        }
        XCTAssertEqual(value, 7)
    }

    func testAsyncPreviewTimeoutCanRecoverOnNextRequest() async {
        let cancelled = expectation(description: "stalled preview cancelled")
        let missing: Int? = await PhotoCurationService.boundedPhotoReadAsync(timeout: 0.08, cancel: { id in
            XCTAssertEqual(id, 42); cancelled.fulfill()
        }) { _ in 42 }
        XCTAssertNil(missing)
        await fulfillment(of: [cancelled], timeout: 1)
        let recovered: Int? = await PhotoCurationService.boundedPhotoReadAsync(timeout: 1, cancel: { _ in }) { complete in
            complete(11); return 43
        }
        XCTAssertEqual(recovered, 11)
    }

    func testCancellingPreviewPropagatesToPhotoKitAndRejectsLateImage() async {
        let started = expectation(description: "preview started")
        let cancelled = expectation(description: "PhotoKit request cancelled")
        let task = Task {
            await PhotoCurationService.boundedPhotoReadAsync(timeout: 30, cancel: { id in
                XCTAssertEqual(id, 71); cancelled.fulfill()
            }) { (complete: @escaping (Int?) -> Void) in
                started.fulfill()
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { complete(8) }
                return 71
            }
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        await fulfillment(of: [cancelled], timeout: 1)
        let value = await task.value
        XCTAssertNil(value)
    }

    func testFirstFinalCallbackWins() {
        var cancelled = false
        let value: Int? = PhotoCurationService.boundedPhotoRead(cancel: { _ in cancelled = true }) { complete in
            complete(7); complete(9)
            return 42
        }
        XCTAssertEqual(value, 7)
        XCTAssertFalse(cancelled)
    }

    func testMissingFinalCallbackTimesOutAndLateCallbackIsIgnored() {
        var callback: ((Int?) -> Void)?
        var cancelled: [PHImageRequestID] = []
        let cancellation = expectation(description: "timed out request cancelled")
        let started = Date()
        let value: Int? = PhotoCurationService.boundedPhotoRead(timeout: 0.08, cancel: {
            cancelled.append($0); cancellation.fulfill()
        }) { complete in
            callback = complete
            return 42
        }
        XCTAssertNil(value)
        wait(for: [cancellation], timeout: 1)
        XCTAssertEqual(cancelled, [42])
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        callback?(7)
        callback?(9)
        XCTAssertEqual(cancelled, [42])
    }

    func testCancellationStopsWaitingWithoutWaitingForTimeout() async {
        let started = expectation(description: "request started")
        let cancelled = expectation(description: "request cancelled")
        let task = Task.detached {
            let value: Int? = PhotoCurationService.boundedPhotoRead(timeout: 30, cancel: { id in
                XCTAssertEqual(id, 71); cancelled.fulfill()
            }) { _ in started.fulfill(); return 71 }
            return value
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await fulfillment(of: [cancelled], timeout: 1)
        let value = await task.value
        XCTAssertNil(value)
    }
}

final class PhotoCloudAccessTests: XCTestCase {
    private func context() -> (PhotoCloudAccess, UserDefaults) {
        let suite = "cloud-read-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (PhotoCloudAccess(defaults: defaults), defaults)
    }

    func testFailureAloneNeverAuthorizesNetwork() {
        let (access, _) = context()
        access.noteCloudFailure(id: "candidate", revision: "v1")
        XCTAssertFalse(access.allows(id: "candidate", revision: "v1"))
    }

    func testConsentOnlyIncludesStillAccessibleUnchangedFailedPhotos() {
        let (access, _) = context()
        access.noteCloudFailure(id: "candidate", revision: "v1")
        access.noteCloudFailure(id: "removed-from-access", revision: "v1")
        access.noteCloudFailure(id: "edited", revision: "v1")
        access.approve(["candidate": "v1", "edited": "v2", "unrelated": "v1"])
        XCTAssertTrue(access.allows(id: "candidate", revision: "v1"))
        for id in ["removed-from-access", "edited", "unrelated"] {
            XCTAssertFalse(access.allows(id: id, revision: "v1"))
        }
        XCTAssertFalse(access.allows(id: "edited", revision: "v2"))
    }

    func testRelaunchRetainsConsentForSamePhotoButNotChangedRevision() {
        let (access, defaults) = context()
        access.noteCloudFailure(id: "candidate", revision: "v1")
        access.approve(["candidate": "v1"])
        access.resolved(id: "candidate")
        let reopened = PhotoCloudAccess(defaults: defaults)
        XCTAssertTrue(reopened.pendingRevisions.isEmpty)
        XCTAssertTrue(reopened.allows(id: "candidate", revision: "v1"))
        XCTAssertFalse(reopened.allows(id: "candidate", revision: "v2"))
        XCTAssertFalse(reopened.allows(id: "other", revision: "v1"))
    }

    func testDataResetRevokesExistingInstanceConsent() {
        let (access, defaults) = context()
        access.noteCloudFailure(id: "candidate", revision: "v1")
        access.approve(["candidate": "v1"])
        defaults.removeObject(forKey: PhotoCloudAccess.storageKey)
        XCTAssertFalse(access.allows(id: "candidate", revision: "v1"))
    }

    func testFailedPhotoWindowIsBounded() {
        let (access, _) = context()
        for index in 0..<500 { access.noteCloudFailure(id: "photo-\(index)", revision: "v1") }
        XCTAssertEqual(access.pendingRevisions.count, 64)
        XCTAssertFalse(access.allows(id: "photo-0", revision: "v1"))
    }
}

@MainActor
final class AccountDeletionIsolationTests: XCTestCase {
    private func context() -> (UserDefaults, String) {
        let suite = "Recoco.AccountDeletionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (defaults, suite)
    }

    private func recordData(_ text: String) throws -> Data {
        try JSONEncoder().encode([SavedMemoryRecord(id: UUID(), createdAt: Date(), text: text,
            photoLocalIdentifier: "test-photo", capturedDateDescription: nil,
            photoThumbnailData: Data([1, 2, 3]))])
    }

    func testDeletionRemovesOnlyTargetAccountRecordsActivityAndDraftsAcrossRelaunch() throws {
        let (defaults, suite) = context()
        let target = "A", other = "team_A"
        let accountBases = [SavedRecordStore.storageKey, "recoco_activity_events_v1", "recoco_daily_session_v1",
            "recoco_photo_review_dates_v1", "recoco_protected_photos_v1", "recoco_curation_scan_v1",
            "recoco_scanned_photos_v1", "recoco_reviewed_photos_v1", "recoco_recommendation_history_v1", SubscriptionStore.previewKey]
        let otherRecord = try recordData("다른 계정의 바다 기억 🌊")
        for base in accountBases {
            defaults.set(Data("target".utf8), forKey: UserScopedStorage.key(base, userID: target))
            defaults.set(otherRecord, forKey: UserScopedStorage.key(base, userID: other))
        }
        defaults.set(try recordData("개발용으로 남긴 기록"), forKey: SavedRecordStore.storageKey)
        let targetDraft = UserScopedStorage.draftKey(photoID: "photo_team_A", userID: target)
        let otherDraft = UserScopedStorage.draftKey(photoID: "photo", userID: other)
        defaults.set(Data("target draft".utf8), forKey: targetDraft)
        defaults.set(Data("other draft".utf8), forKey: otherDraft)
        let untouched: [String: Any] = [
            "recoco_record_draft_photo": Data("development draft".utf8),
            "recoco_record_draft_legacy_team_A": Data("legacy owner unknown".utf8),
            "recoco_onboarding_completed": true, "recoco_notification_enabled": true,
            "recoco_notification_hour": 9, "recoco_notification_minute": 30,
            PhotoCloudAccess.storageKey: ["photo": "revision"],
            "recoco_development_session_v1": true, "firebase_sdk_value_A": "sdk"
        ]
        untouched.forEach { defaults.set($0.value, forKey: $0.key) }
        let before = defaults.dictionaryRepresentation() as NSDictionary

        try UserScopedStorage.removeAccountData(for: target, defaults: defaults)

        let relaunched = try XCTUnwrap(UserDefaults(suiteName: suite))
        for base in accountBases {
            XCTAssertNil(relaunched.object(forKey: UserScopedStorage.key(base, userID: target)))
            let key = UserScopedStorage.key(base, userID: other)
            XCTAssertEqual(relaunched.data(forKey: key), otherRecord)
        }
        XCTAssertNil(relaunched.object(forKey: targetDraft))
        let survivors = Array(untouched.keys) + [otherDraft, SavedRecordStore.storageKey]
        for key in survivors {
            XCTAssertEqual(relaunched.object(forKey: key) as? NSObject, before[key] as? NSObject, key)
        }
        let survivingRecords = try JSONDecoder().decode([SavedMemoryRecord].self,
            from: XCTUnwrap(relaunched.data(forKey: UserScopedStorage.key(SavedRecordStore.storageKey, userID: other))))
        XCTAssertEqual(survivingRecords.first?.text, "다른 계정의 바다 기억 🌊")
        XCTAssertEqual(survivingRecords.first?.photoThumbnailData, Data([1, 2, 3]))
        let after = relaunched.dictionaryRepresentation() as NSDictionary
        try UserScopedStorage.removeAccountData(for: target, defaults: relaunched)
        XCTAssertEqual(relaunched.dictionaryRepresentation() as NSDictionary, after, "Cleanup is idempotent")
    }

    func testDraftNamespacesCannotConfusePhotoOrAccountSuffixes() {
        XCTAssertNotEqual(UserScopedStorage.draftKey(photoID: "photo_team", userID: "A"),
                          UserScopedStorage.draftKey(photoID: "photo", userID: "team_A"))
        XCTAssertNotEqual(UserScopedStorage.draftKey(photoID: "x:y", userID: "A"),
                          UserScopedStorage.draftKey(photoID: "y", userID: "A:x"))
        XCTAssertEqual(UserScopedStorage.draftKey(photoID: "photo", userID: nil), "recoco_record_draft_photo")
        XCTAssertEqual(UserScopedStorage.key(SavedRecordStore.storageKey, userID: "A"), "recoco_saved_records_v1_A")
    }

    func testMissingAccountIdentityCannotFallBackToDeletingAnonymousData() throws {
        let (defaults, _) = context()
        defaults.set(try recordData("보존할 기록"), forKey: SavedRecordStore.storageKey)
        let before = defaults.dictionaryRepresentation() as NSDictionary
        for userID in ["", " \n\t"] {
            XCTAssertThrowsError(try AccountDeletionScope(userID: userID))
            XCTAssertThrowsError(try UserScopedStorage.removeAccountData(for: userID, defaults: defaults))
        }
        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before)
    }

    func testRemoteFailureOrCancellationLeavesAllLocalDataAndDoesNotFinish() async throws {
        let (defaults, _) = context()
        let key = UserScopedStorage.key(SavedRecordStore.storageKey, userID: "A")
        defaults.set(try recordData("취소되어 남길 기록"), forKey: key)
        let scope = try AccountDeletionScope(userID: "A")
        let before = defaults.dictionaryRepresentation() as NSDictionary
        for failure in [NSError(domain: "Network", code: -1009) as Error, CancellationError()] {
            var cleaned = false, finished = false
            do {
                try await scope.delete(currentUserID: { "A" }, deleteRemote: { throw failure },
                    clearLocalData: { id in cleaned = true; try UserScopedStorage.removeAccountData(for: id, defaults: defaults) },
                    finishSession: { finished = true })
                XCTFail("The remote failure must propagate")
            } catch {}
            XCTAssertFalse(cleaned); XCTAssertFalse(finished)
            XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before)
        }
    }

    func testCapturedOwnerIsUsedAfterFirebaseClearsCurrentUser() async throws {
        let (defaults, _) = context()
        let key = UserScopedStorage.key(SavedRecordStore.storageKey, userID: "A")
        defaults.set("A", forKey: key)
        defaults.set("anonymous", forKey: SavedRecordStore.storageKey)
        var active: String? = "A"
        var actions: [String] = []
        let scope = try AccountDeletionScope(userID: "A")
        try await scope.delete(currentUserID: { active }, deleteRemote: {
            actions.append("remote"); active = nil
        }, clearLocalData: { id in
            actions.append("local:\(id)"); try UserScopedStorage.removeAccountData(for: id, defaults: defaults)
        }, finishSession: { actions.append("finish") })
        XCTAssertEqual(actions, ["remote", "local:A", "finish"])
        XCTAssertNil(defaults.object(forKey: key))
        XCTAssertEqual(defaults.string(forKey: SavedRecordStore.storageKey), "anonymous")
    }

    func testSessionChangeBeforeRemoteDeletionStopsEveryDestructiveStep() async throws {
        let scope = try AccountDeletionScope(userID: "A")
        for active in [nil, "B"] as [String?] {
            var calls = 0
            do {
                try await scope.delete(currentUserID: { active }, deleteRemote: { calls += 1 },
                    clearLocalData: { _ in calls += 1 }, finishSession: { calls += 1 })
                XCTFail("A changed session must stop deletion")
            } catch {
                XCTAssertTrue(error is AccountDeletionScope.Error)
            }
            XCTAssertEqual(calls, 0)
        }
    }

    func testSessionChangeDuringRemoteDeletionCannotEraseOrExitNewAccount() async throws {
        let (defaults, _) = context()
        let a = UserScopedStorage.key(SavedRecordStore.storageKey, userID: "A")
        let b = UserScopedStorage.key(SavedRecordStore.storageKey, userID: "B")
        defaults.set("A", forKey: a); defaults.set("B", forKey: b)
        var active: String? = "A", finished = false
        try await AccountDeletionScope(userID: "A").delete(currentUserID: { active },
            deleteRemote: { active = "B" },
            clearLocalData: { try UserScopedStorage.removeAccountData(for: $0, defaults: defaults) },
            finishSession: { finished = true })
        XCTAssertNil(defaults.object(forKey: a))
        XCTAssertEqual(defaults.string(forKey: b), "B")
        XCTAssertEqual(active, "B"); XCTAssertFalse(finished)
    }

    func testLocalCleanupFailureCannotAnnounceCompletion() async throws {
        var finished = false
        do {
            try await AccountDeletionScope(userID: "A").delete(currentUserID: { "A" }, deleteRemote: {},
                clearLocalData: { _ in throw NSError(domain: "Storage", code: 1) },
                finishSession: { finished = true })
            XCTFail("Cleanup failure must propagate")
        } catch {}
        XCTAssertFalse(finished)
    }
}

final class LoginIntegrationTests: XCTestCase {
    @MainActor
    func testOnboardingStartsLocalSessionBeforeCompletingAndUsesExistingPhotoPermission() throws {
        for status: PhotoAuthStatus in [.notDetermined, .authorized, .limited, .denied] {
            let suite = "Recoco.OnboardingStartTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let records = Data("existing local records".utf8)
            let draft = Data("existing draft".utf8)
            defaults.set(records, forKey: SavedRecordStore.storageKey)
            defaults.set(draft, forKey: "recoco_record_draft_photo")
            let auth = AuthViewModel(signOut: {}, localDefaults: defaults, finishProviderSignOut: {})
            let onboarding = OnboardingViewModel(defaults: defaults)
            onboarding.skipToLastSlide()
            XCTAssertTrue(onboarding.isLastSlide)
            XCTAssertFalse(defaults.bool(forKey: "recoco_onboarding_completed"))

            let route = onboarding.startLocalExperience(startLocalSession: {
                XCTAssertFalse(defaults.bool(forKey: "recoco_onboarding_completed"))
                return auth.startLocalSession()
            }, photoAuthStatus: status)

            XCTAssertEqual(route, status == .notDetermined ? .photoPermission : .main)
            XCTAssertTrue(LocalSession.isActive(defaults: defaults))
            XCTAssertTrue(defaults.bool(forKey: "recoco_onboarding_completed"))
            XCTAssertEqual(defaults.data(forKey: SavedRecordStore.storageKey), records)
            XCTAssertEqual(defaults.data(forKey: "recoco_record_draft_photo"), draft)
            XCTAssertNil(onboarding.errorMessage)
        }
    }

    @MainActor
    func testOnboardingStartFailureStaysIncompleteAndCanRetry() throws {
        let suite = "Recoco.OnboardingFailureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var fails = true
        let auth = AuthViewModel(signOut: {
            if fails { throw NSError(domain: "AuthKeychain", code: 1) }
        }, localDefaults: defaults, finishProviderSignOut: {})
        let onboarding = OnboardingViewModel(defaults: defaults)
        onboarding.skipToLastSlide()

        XCTAssertNil(onboarding.startLocalExperience(startLocalSession: auth.startLocalSession,
                                                    photoAuthStatus: .notDetermined))
        XCTAssertTrue(onboarding.isLastSlide)
        XCTAssertFalse(defaults.bool(forKey: "recoco_onboarding_completed"))
        XCTAssertFalse(LocalSession.isActive(defaults: defaults))
        XCTAssertNotNil(auth.errorMessage)

        fails = false
        XCTAssertEqual(onboarding.startLocalExperience(startLocalSession: auth.startLocalSession,
                                                       photoAuthStatus: .notDetermined), .photoPermission)
        XCTAssertNil(auth.errorMessage)
    }

    @MainActor
    func testOnboardingDoesNotCompleteWhenSessionMarkerCannotBeStored() throws {
        let suite = "Recoco.OnboardingSessionStorageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(OnboardingRejectingDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: LocalSession.legacyStorageKey)
        let records = Data("existing local records".utf8)
        defaults.set(records, forKey: SavedRecordStore.storageKey)
        defaults.rejectedKeys = [LocalSession.storageKey]
        let auth = AuthViewModel(signOut: {}, localDefaults: defaults, finishProviderSignOut: {})
        let onboarding = OnboardingViewModel(defaults: defaults)

        XCTAssertNil(onboarding.startLocalExperience(startLocalSession: auth.startLocalSession,
                                                    photoAuthStatus: .authorized))
        XCTAssertFalse(defaults.bool(forKey: "recoco_onboarding_completed"))
        XCTAssertTrue(defaults.bool(forKey: LocalSession.legacyStorageKey))
        XCTAssertEqual(defaults.data(forKey: SavedRecordStore.storageKey), records)
        XCTAssertNotNil(auth.errorMessage)
    }

    @MainActor
    func testOnboardingCompletionStorageFailureIsVisibleAndRetryable() throws {
        let suite = "Recoco.OnboardingCompletionStorageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(OnboardingRejectingDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.rejectedKeys = ["recoco_onboarding_completed"]
        let auth = AuthViewModel(signOut: {}, localDefaults: defaults, finishProviderSignOut: {})
        let onboarding = OnboardingViewModel(defaults: defaults)

        XCTAssertNil(onboarding.startLocalExperience(startLocalSession: auth.startLocalSession,
                                                    photoAuthStatus: .limited))
        XCTAssertFalse(defaults.bool(forKey: "recoco_onboarding_completed"))
        XCTAssertNotNil(onboarding.errorMessage)
        defaults.rejectedKeys = []
        XCTAssertEqual(onboarding.startLocalExperience(startLocalSession: auth.startLocalSession,
                                                       photoAuthStatus: .limited), .main)
        XCTAssertNil(onboarding.errorMessage)
    }

    @MainActor
    func testLocalStartReleasesAccountBeforePersistingLocalSession() throws {
        let suite = "Recoco.LocalStartTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let localRecords = Data("local records".utf8)
        let accountRecords = Data("account records".utf8)
        let accountKey = UserScopedStorage.key(SavedRecordStore.storageKey, userID: "account-A")
        defaults.set(localRecords, forKey: SavedRecordStore.storageKey)
        defaults.set(accountRecords, forKey: accountKey)
        var activeUserID: String? = "account-A"
        var actions: [String] = []
        let vm = AuthViewModel(signOut: {
            XCTAssertFalse(LocalSession.isActive(defaults: defaults))
            activeUserID = nil
            actions.append("firebase")
        }, localDefaults: defaults, finishProviderSignOut: {
            XCTAssertNil(activeUserID)
            XCTAssertFalse(LocalSession.isActive(defaults: defaults))
            actions.append("provider")
        })

        XCTAssertTrue(vm.startLocalSession())
        XCTAssertNil(activeUserID)
        XCTAssertEqual(actions, ["firebase", "provider"])
        XCTAssertTrue(LocalSession.isActive(defaults: defaults))
        XCTAssertEqual(defaults.data(forKey: SavedRecordStore.storageKey), localRecords)
        XCTAssertEqual(defaults.data(forKey: accountKey), accountRecords)
        XCTAssertNil(vm.errorMessage)
    }

    @MainActor
    func testFailedLocalStartPreservesAccountRecordsAndSessionMarkersAndCanRetry() throws {
        for hadLocalSession in [false, true] {
            let suite = "Recoco.FailedLocalStartTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let records = Data("existing local records".utf8)
            let draft = Data("existing draft".utf8)
            let accountKey = UserScopedStorage.key(SavedRecordStore.storageKey, userID: "account-A")
            defaults.set(records, forKey: SavedRecordStore.storageKey)
            defaults.set(records, forKey: accountKey)
            defaults.set(draft, forKey: "recoco_record_draft_photo")
            defaults.set(true, forKey: SubscriptionStore.previewKey)
            if hadLocalSession {
                defaults.set(true, forKey: LocalSession.storageKey)
                defaults.set(true, forKey: LocalSession.legacyStorageKey)
            }
            let before = defaults.dictionaryRepresentation() as NSDictionary
            var activeUserID: String? = "account-A"
            var fails = true
            var providerCleanupCount = 0
            let vm = AuthViewModel(signOut: {
                if fails { throw NSError(domain: "AuthKeychain", code: 1) }
                activeUserID = nil
            }, localDefaults: defaults, finishProviderSignOut: { providerCleanupCount += 1 })

            XCTAssertFalse(vm.startLocalSession())
            XCTAssertEqual(activeUserID, "account-A")
            XCTAssertEqual(providerCleanupCount, 0)
            XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before)
            XCTAssertEqual(vm.errorMessage, "기기 저장으로 전환하지 못했어요. 기존 기록은 그대로 있어요. 다시 시도해주세요.")

            fails = false
            XCTAssertTrue(vm.startLocalSession())
            XCTAssertNil(activeUserID)
            XCTAssertEqual(providerCleanupCount, 1)
            XCTAssertTrue(LocalSession.isActive(defaults: defaults))
            XCTAssertNil(defaults.object(forKey: LocalSession.legacyStorageKey))
            XCTAssertEqual(defaults.data(forKey: SavedRecordStore.storageKey), records)
            XCTAssertEqual(defaults.data(forKey: accountKey), records)
            XCTAssertEqual(defaults.data(forKey: "recoco_record_draft_photo"), draft)
            XCTAssertTrue(defaults.bool(forKey: SubscriptionStore.previewKey))
            XCTAssertNil(vm.errorMessage)
        }
    }

    @MainActor
    func testFailedLogoutKeepsSessionAndCanRetry() throws {
        let suite = "Recoco.LogoutRetryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var fails = true
        var cleanupCount = 0
        let vm = ProfileViewModel(signOut: {
            if fails { throw NSError(domain: "AuthKeychain", code: 1) }
        }, localDefaults: defaults, finishSignOut: { cleanupCount += 1 })

        XCTAssertFalse(vm.logout())
        XCTAssertEqual(cleanupCount, 0)
        XCTAssertNotNil(vm.logoutErrorMessage)

        fails = false
        XCTAssertTrue(vm.logout())
        XCTAssertEqual(cleanupCount, 1)
        XCTAssertNil(vm.logoutErrorMessage)
    }

    @MainActor
    func testSuccessfulLogoutFinishesProviderSessionAfterFirebase() throws {
        let suite = "Recoco.LogoutOrderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var actions: [String] = []
        let vm = ProfileViewModel(signOut: { actions.append("firebase") },
                                  localDefaults: defaults,
                                  finishSignOut: { actions.append("provider") })
        XCTAssertTrue(vm.logout())
        XCTAssertEqual(actions, ["firebase", "provider"])
        XCTAssertNil(vm.logoutErrorMessage)
    }

    private func configuration(configured: Bool = true, bundle: String? = "app.recoco.ios",
                               enabled: Bool = true) -> LoginConfiguration {
        LoginConfiguration(firebaseConfigured: configured, firebaseBundleID: bundle,
                           bundleID: "app.recoco.ios", appleEnabled: enabled)
    }
    func testMissingFirebaseBlocksAppleAuthentication() {
        let value = configuration(configured: false)
        XCTAssertEqual(value.appleIssue, .missingFirebase)
    }
    func testDifferentInstalledBundleCannotUseProductionCredentials() {
        let value = configuration(bundle: "app.recoco.another")
        XCTAssertEqual(value.appleIssue, .bundleMismatch)
    }
    func testAppleGateStaysDisabledUntilReleaseSetupIsReady() {
        let value = configuration(enabled: false)
        XCTAssertEqual(value.appleIssue, .disabled)
        XCTAssertNotNil(value.message)
    }
    func testUnknownBundleCannotStartAppleAuthentication() {
        XCTAssertEqual(configuration(bundle: nil).appleIssue, .bundleMismatch)
    }
    func testMatchingConfigurationEnablesAppleWithoutCallbackScheme() {
        let value = configuration()
        XCTAssertNil(value.appleIssue)
        XCTAssertNil(value.message)
    }
    func testNetworkErrorHasActionableMessage() {
        XCTAssertEqual(LoginFailure.message(for: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)),
                       "인터넷 연결을 확인한 뒤 다시 시도해주세요.")
    }
    @MainActor
    func testLocalSessionPreservesLegacyRecordsDraftsAndUsageAcrossRelaunchAndExit() throws {
        let suite = "Recoco.LocalSessionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let records = Data("existing local records".utf8)
        let draft = Data("existing local draft".utf8)
        let accountRecords = Data("separate account records".utf8)
        defaults.set(records, forKey: SavedRecordStore.storageKey)
        defaults.set(draft, forKey: "recoco_record_draft_photo")
        defaults.set(accountRecords, forKey: UserScopedStorage.key(SavedRecordStore.storageKey, userID: "account-A"))
        defaults.set(true, forKey: SubscriptionStore.previewKey)
        defaults.set(true, forKey: LocalSession.legacyStorageKey)

        XCTAssertTrue(LocalSession.isActive(defaults: defaults))
        LocalSession.begin(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: LocalSession.legacyStorageKey))
        let relaunched = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertTrue(LocalSession.isActive(defaults: relaunched))
        XCTAssertTrue(LocalSession.hasLocalRecords(defaults: relaunched))
        LocalSession.end(defaults: relaunched)
        XCTAssertFalse(LocalSession.isActive(defaults: relaunched))
        XCTAssertEqual(relaunched.data(forKey: SavedRecordStore.storageKey), records)
        XCTAssertEqual(relaunched.data(forKey: "recoco_record_draft_photo"), draft)
        XCTAssertEqual(relaunched.data(forKey: UserScopedStorage.key(SavedRecordStore.storageKey, userID: "account-A")), accountRecords)
        XCTAssertTrue(relaunched.bool(forKey: SubscriptionStore.previewKey))
    }

    @MainActor
    func testLocalSessionDoesNotGrantEntitlementOrBypassEnabledCurationGate() throws {
        let suite = "Recoco.LocalSessionPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        LocalSession.begin(defaults: defaults)
        defaults.set(true, forKey: UserScopedStorage.key(SubscriptionStore.previewKey))
        let enabled = SubscriptionStore(defaults: defaults, enabled: true)
        XCTAssertTrue(enabled.salesEnabled)
        XCTAssertFalse(enabled.isActive)
        XCTAssertFalse(enabled.canStartCuration)
        XCTAssertFalse(enabled.canPurchase)
        let disabled = SubscriptionStore(defaults: defaults, enabled: false)
        XCTAssertFalse(disabled.salesEnabled)
        XCTAssertFalse(disabled.canPurchase)
    }

    @MainActor
    func testLocalSessionRoutesThroughOnboardingAndRealPhotoPermissionState() {
        let router = AppRouter()
        router.resolveInitialRoute(isLoggedIn: false, hasCompletedOnboarding: false,
                                   photoAuthStatus: .authorized, hasLocalSession: true)
        XCTAssertEqual(router.route, .onboarding)
        router.resolveInitialRoute(isLoggedIn: false, hasCompletedOnboarding: true,
                                   photoAuthStatus: .notDetermined, hasLocalSession: true)
        XCTAssertEqual(router.route, .photoPermission)
        for status: PhotoAuthStatus in [.authorized, .limited, .denied] {
            router.resolveInitialRoute(isLoggedIn: false, hasCompletedOnboarding: true,
                                       photoAuthStatus: status, hasLocalSession: true)
            XCTAssertEqual(router.route, .main)
        }
        router.resolveInitialRoute(isLoggedIn: false, hasCompletedOnboarding: true,
                                   photoAuthStatus: .authorized, hasLocalSession: false)
        XCTAssertEqual(router.route, .login)
    }

    @MainActor
    func testMissingAccountProfileClearlyUsesLocalStorage() async {
        let vm = ProfileViewModel()
        await vm.onAppear()
        XCTAssertTrue(vm.isLocalSession)
        XCTAssertEqual(vm.email, "비움 내역은 이 기기에 남아요.")
        XCTAssertNil(vm.photoURL)
    }
}

private final class OnboardingRejectingDefaults: UserDefaults {
    var rejectedKeys: Set<String> = []

    override func set(_ value: Any?, forKey defaultName: String) {
        guard !rejectedKeys.contains(defaultName) else { return }
        super.set(value, forKey: defaultName)
    }
}

@MainActor
final class PhotoBatchDeletionTests: XCTestCase {
    private func unit(_ identifier: String, keeping reference: String? = nil) -> DecisionUnit {
        DecisionUnit(id: UUID(), type: .cleanupSingle, status: .pending,
                     candidateLocalIdentifiers: [identifier], recommendedLocalIdentifier: identifier,
                     reasonCodes: [.exactDuplicate], capturedDateDescription: nil, createdAt: Date(),
                     comparisonLocalIdentifier: reference ?? "kept-\(identifier)")
    }

    func testSelectedRecommendationsCommitOnceWithExactCount() async throws {
        let units = [unit("first"), unit("third")]
        var validated: [String] = []
        var commits = 0
        var result = 0
        let controller = PhotoDeletionController(validate: { unit in
            validated.append(unit.persistenceKey)
            return true
        }, commitBatch: { snapshot in
            commits += 1
            XCTAssertEqual(snapshot.map(\.persistenceKey), ["first", "third"])
            XCTAssertEqual(snapshot.compactMap(\.comparisonLocalIdentifier), ["kept-first", "kept-third"])
        })
        let succeeded = try await controller.deleteBatch(units) { result = $0 }
        XCTAssertTrue(succeeded)
        XCTAssertEqual(validated, ["first", "third"])
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(result, 2)
        XCTAssertFalse(controller.isDeleting)
    }

    func testSystemCancellationDoesNotReportAnyCompletedPhoto() async throws {
        var completions = 0
        let controller = PhotoDeletionController(validateBatch: { _ in true }, commitBatch: { _ in
            throw NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.Code.userCancelled.rawValue)
        })
        let succeeded = try await controller.deleteBatch([unit("first"), unit("second")]) { _ in completions += 1 }
        XCTAssertFalse(succeeded)
        XCTAssertEqual(completions, 0)
        XCTAssertFalse(controller.isDeleting)
    }

    func testFailedTransactionDoesNotReportPartialSuccess() async {
        var completions = 0
        let controller = PhotoDeletionController(validateBatch: { _ in true }, commitBatch: { _ in
            throw NSError(domain: "test.batch.failed", code: 1)
        })
        do {
            _ = try await controller.deleteBatch([unit("first"), unit("second")]) { _ in completions += 1 }
            XCTFail("A failed Photos transaction must fail the whole selection")
        } catch { }
        XCTAssertEqual(completions, 0)
        XCTAssertFalse(controller.isDeleting)
    }

    func testOneChangedRecommendationPreventsTheEntireCommit() async {
        var commits = 0
        let controller = PhotoDeletionController(validate: { $0.persistenceKey != "changed" },
                                                commitBatch: { _ in commits += 1 })
        do {
            _ = try await controller.deleteBatch([unit("first"), unit("changed")]) { _ in
                XCTFail("Invalid evidence must never complete")
            }
            XCTFail("Changed evidence must reject the selection")
        } catch { }
        XCTAssertEqual(commits, 0)
        XCTAssertFalse(controller.isDeleting)
    }

    func testKeptReferenceCannotBeAnotherSelectedPhoto() async {
        var validations = 0
        let controller = PhotoDeletionController(validateBatch: { _ in validations += 1; return true },
                                                commitBatch: { _ in XCTFail("A kept copy must never be removed") })
        do {
            _ = try await controller.deleteBatch([unit("first", keeping: "second"), unit("second")]) { _ in
                XCTFail("A conflicting selection must never complete")
            }
            XCTFail("Reference/removal overlap must be rejected")
        } catch { }
        XCTAssertEqual(validations, 0)
    }

    func testEmptyRepeatedOrNonSingleSnapshotsAreRejected() async {
        let candidate = unit("first")
        let reflection = DecisionUnit(id: UUID(), type: .recallMoment, status: .pending,
                                      candidateLocalIdentifiers: ["memory"], recommendedLocalIdentifier: "memory",
                                      reasonCodes: [.dailyReflection], capturedDateDescription: nil, createdAt: Date())
        let cluster = DecisionUnit(id: UUID(), type: .cleanupCluster, status: .pending,
                                   candidateLocalIdentifiers: ["keep", "remove"], recommendedLocalIdentifier: "keep",
                                   reasonCodes: [.exactDuplicate], capturedDateDescription: nil, createdAt: Date())
        var completed = candidate
        completed.status = .completed
        let controller = PhotoDeletionController(validateBatch: { _ in XCTFail("Malformed snapshots must fail first"); return true },
                                                commitBatch: { _ in XCTFail("Malformed snapshots must not commit") })
        for units in [[], [candidate, candidate], [reflection], [cluster], [completed]] {
            do {
                _ = try await controller.deleteBatch(units) { _ in XCTFail("Must not complete") }
                XCTFail("Malformed selection must throw")
            } catch { }
        }
    }

    func testConcurrentBatchAndSingleTapsShareOneTransactionGuard() async throws {
        let started = expectation(description: "Batch validation began")
        var resume: CheckedContinuation<Bool, Never>?
        var commits = 0
        var completions = 0
        let controller = PhotoDeletionController(validate: { _ in true },
                                                commit: { _ in XCTFail("Single tap must remain blocked") },
                                                validateBatch: { _ in
            await withCheckedContinuation { resume = $0; started.fulfill() }
        }, commitBatch: { _ in commits += 1 })
        let first = Task { @MainActor in
            try await controller.deleteBatch([self.unit("first"), self.unit("second")]) { count in
                XCTAssertEqual(count, 2)
                completions += 1
            }
        }
        await fulfillment(of: [started], timeout: 2)
        let duplicate = try await controller.deleteBatch([unit("first"), unit("second")]) { _ in XCTFail("Duplicate tap") }
        let single = try await controller.delete(unit("first")) { _ in XCTFail("Concurrent single tap") }
        XCTAssertFalse(duplicate)
        XCTAssertFalse(single)
        resume?.resume(returning: true)
        let succeeded = try await first.value
        XCTAssertTrue(succeeded)
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(completions, 1)
        XCTAssertFalse(controller.isDeleting)
    }

    func testTaskCancellationDuringSuccessfulCommitStillReportsAllPhotos() async throws {
        let started = expectation(description: "Photos commit began")
        var resume: CheckedContinuation<Void, Never>?
        var result = 0
        let controller = PhotoDeletionController(validateBatch: { _ in true }, commitBatch: { _ in
            await withCheckedContinuation { resume = $0; started.fulfill() }
        })
        let operation = Task { @MainActor in
            try await controller.deleteBatch([self.unit("first"), self.unit("second")]) { result = $0 }
        }
        await fulfillment(of: [started], timeout: 2)
        operation.cancel()
        resume?.resume()
        let succeeded = try await operation.value
        XCTAssertTrue(succeeded)
        XCTAssertEqual(result, 2)
        XCTAssertFalse(controller.isDeleting)
    }
}


@MainActor
final class NotificationSettingsTests: XCTestCase {
    func testOnlyExistingLegacyDailyReminderIsLocalizedWithoutChangingSchedule() throws {
        let content = UNMutableNotificationContent()
        content.title = "RECOCO"
        content.body = "잠깐, 사진을 살펴볼까요?"
        content.userInfo = ["existing": true]
        var time = DateComponents(hour: 18, minute: 30)
        time.timeZone = TimeZone(identifier: "Europe/Dublin")
        let trigger = UNCalendarNotificationTrigger(dateMatching: time, repeats: true)
        let daily = UNNotificationRequest(identifier: "recoco.daily", content: content, trigger: trigger)
        let other = UNNotificationRequest(identifier: "another.reminder", content: content, trigger: trigger)
        XCTAssertNil(NotificationSettingsClient.localizedReplacement(for: other))
        let upgraded = try XCTUnwrap(NotificationSettingsClient.localizedReplacement(for: daily))
        XCTAssertEqual(upgraded.identifier, daily.identifier)
        XCTAssertEqual(upgraded.content.title, daily.content.title)
        XCTAssertEqual(upgraded.content.userInfo["existing"] as? Bool, true)
        XCTAssertEqual((upgraded.trigger as? UNCalendarNotificationTrigger)?.dateComponents, time)
        XCTAssertEqual(upgraded.trigger?.repeats, true)
        XCTAssertNil(NotificationSettingsClient.localizedReplacement(for: upgraded))
    }

    func testProfileSummaryRecoversAfterPermissionIsReenabledOutsideApp() async {
        let time = NotificationReminderTime(hour: 14, minute: 30)
        let scheduler = NotificationSettingsMockScheduler(time: time)
        scheduler.authorization = .denied
        let vm = ProfileViewModel(signOut: {}, finishSignOut: {})

        await vm.refreshSettingsSummary(notificationClient: scheduler.client())
        XCTAssertEqual(vm.notificationSummary, "권한 꺼짐")
        XCTAssertEqual(scheduler.persistedEnabled, false)

        scheduler.authorization = .authorized
        await vm.refreshSettingsSummary(notificationClient: scheduler.client())
        XCTAssertEqual(vm.notificationSummary, "14:30")
        XCTAssertEqual(scheduler.persistedEnabled, true)
        XCTAssertEqual(scheduler.persistedTime, time)
        XCTAssertTrue(scheduler.scheduledTimes.isEmpty, "Reading the summary must not create a notification")
        XCTAssertEqual(scheduler.removals, 0)
    }

    func testProfileSummaryClearsStaleEnabledFlagWhenScheduleIsAbsent() async {
        let scheduler = NotificationSettingsMockScheduler(time: nil)
        scheduler.persistedEnabled = true
        scheduler.savedTime = .init(hour: 11, minute: 30)
        let vm = ProfileViewModel(signOut: {}, finishSignOut: {})

        await vm.refreshSettingsSummary(notificationClient: scheduler.client())

        XCTAssertEqual(vm.notificationSummary, "꺼짐")
        XCTAssertEqual(scheduler.persistedEnabled, false)
        XCTAssertEqual(scheduler.persistedTime, scheduler.savedTime)
        XCTAssertTrue(scheduler.scheduledTimes.isEmpty)
        XCTAssertEqual(scheduler.removals, 0)
    }

    func testTurningOffImmediatelyRemovesScheduleWithoutSavingEditedTime() async {
        let scheduler = NotificationSettingsMockScheduler(time: .init(hour: 9, minute: 0))
        let vm = NotificationSettingsViewModel(client: scheduler.client())
        await vm.refresh()
        vm.selectedHour = 18
        vm.selectedMinute = 30

        vm.setEnabled(false)
        await waitUntil { !vm.isBusy }

        XCTAssertNil(scheduler.time)
        XCTAssertFalse(vm.isEnabled)
        XCTAssertEqual(scheduler.persistedEnabled, false)
        XCTAssertEqual(scheduler.persistedTime, .init(hour: 9, minute: 0))
        XCTAssertEqual(vm.selectedHour, 9)
        XCTAssertEqual(vm.selectedMinute, 0)
        XCTAssertTrue(scheduler.scheduledTimes.isEmpty)
    }

    func testTurningOnImmediatelySchedulesAndPersistsSavedTime() async {
        let scheduler = NotificationSettingsMockScheduler(time: nil)
        scheduler.savedTime = .init(hour: 10, minute: 30)
        let vm = NotificationSettingsViewModel(client: scheduler.client())
        await vm.refresh()

        vm.setEnabled(true)
        await waitUntil { !vm.isBusy }

        XCTAssertTrue(vm.isEnabled)
        XCTAssertEqual(scheduler.time, scheduler.savedTime)
        XCTAssertEqual(scheduler.scheduledTimes, [scheduler.savedTime])
        XCTAssertEqual(scheduler.persistedEnabled, true)
        XCTAssertEqual(scheduler.persistedTime, scheduler.savedTime)
        XCTAssertEqual(scheduler.authorizationRequests, 0)
    }

    func testFirstPermissionRefusalRestoresOffWithoutAnotherPermissionAlert() async {
        let scheduler = NotificationSettingsMockScheduler(time: nil)
        scheduler.authorization = .notDetermined
        scheduler.acceptAuthorization = false
        let vm = NotificationSettingsViewModel(client: scheduler.client())
        await vm.refresh()

        vm.setEnabled(true)
        await waitUntil { !vm.isBusy }

        XCTAssertEqual(scheduler.authorizationRequests, 1)
        XCTAssertFalse(vm.isEnabled)
        XCTAssertEqual(scheduler.persistedEnabled, false)
        XCTAssertNil(scheduler.time)
        XCTAssertTrue(scheduler.scheduledTimes.isEmpty)
        XCTAssertFalse(vm.showPermissionAlert)
    }

    func testExistingDeniedPermissionOffersSettingsAndRemovesDormantSchedule() async {
        let scheduler = NotificationSettingsMockScheduler(time: .init(hour: 9, minute: 0))
        scheduler.authorization = .denied
        let vm = NotificationSettingsViewModel(client: scheduler.client())
        await vm.refresh()

        vm.setEnabled(true)
        await waitUntil { !vm.isBusy }

        XCTAssertFalse(vm.isEnabled)
        XCTAssertTrue(vm.showPermissionAlert)
        XCTAssertNil(scheduler.time)
        XCTAssertEqual(scheduler.persistedEnabled, false)
        XCTAssertEqual(scheduler.authorizationRequests, 0)
    }

    func testFailedEnableRestoresActualOffState() async {
        let scheduler = NotificationSettingsMockScheduler(time: nil)
        scheduler.failScheduling = true
        let vm = NotificationSettingsViewModel(client: scheduler.client())
        await vm.refresh()

        vm.setEnabled(true)
        await waitUntil { !vm.isBusy }

        XCTAssertFalse(vm.isEnabled)
        XCTAssertNil(scheduler.time)
        XCTAssertEqual(scheduler.persistedEnabled, false)
        XCTAssertNotNil(vm.errorMessage)
    }

    func testFailedTimeSaveKeepsExistingScheduleAndDraftAvailableForRetry() async {
        let original = NotificationReminderTime(hour: 9, minute: 0)
        let scheduler = NotificationSettingsMockScheduler(time: original)
        scheduler.failScheduling = true
        let vm = NotificationSettingsViewModel(client: scheduler.client())
        await vm.refresh()
        vm.selectedHour = 19
        vm.selectedMinute = 30

        vm.saveTime()
        await waitUntil { !vm.isBusy }

        XCTAssertTrue(vm.isEnabled)
        XCTAssertEqual(vm.committedTime, original)
        XCTAssertEqual(scheduler.time, original)
        XCTAssertEqual(scheduler.persistedTime, original)
        XCTAssertEqual(vm.selectedHour, 19)
        XCTAssertEqual(vm.selectedMinute, 30)
        XCTAssertTrue(vm.hasTimeChanges)
        XCTAssertFalse(vm.didSaveTime)
        XCTAssertNotNil(vm.errorMessage)
    }

    func testRapidTogglesDoNotOverlapPendingScheduleOperation() async {
        let scheduler = NotificationSettingsMockScheduler(time: nil)
        scheduler.holdSchedule = true
        let vm = NotificationSettingsViewModel(client: scheduler.client())
        await vm.refresh()

        vm.setEnabled(true)
        vm.setEnabled(false)
        vm.setEnabled(true)
        await waitUntil { scheduler.scheduleContinuation != nil }
        XCTAssertTrue(vm.isBusy)
        XCTAssertEqual(scheduler.scheduledTimes.count, 1)
        XCTAssertEqual(scheduler.removals, 0)

        scheduler.scheduleContinuation?.resume()
        scheduler.scheduleContinuation = nil
        await waitUntil { !vm.isBusy }
        XCTAssertTrue(vm.isEnabled)
        XCTAssertEqual(scheduler.persistedEnabled, true)
        XCTAssertEqual(scheduler.scheduledTimes.count, 1)
    }

    func testTimeEditOnlyReplacesScheduleAfterExplicitSave() async {
        let original = NotificationReminderTime(hour: 9, minute: 0)
        let desired = NotificationReminderTime(hour: 20, minute: 30)
        let scheduler = NotificationSettingsMockScheduler(time: original)
        let vm = NotificationSettingsViewModel(client: scheduler.client())
        await vm.refresh()
        vm.selectedHour = desired.hour
        vm.selectedMinute = desired.minute
        XCTAssertEqual(scheduler.time, original)
        XCTAssertTrue(scheduler.scheduledTimes.isEmpty)

        vm.saveTime()
        await waitUntil { !vm.isBusy }

        XCTAssertEqual(scheduler.time, desired)
        XCTAssertEqual(scheduler.persistedTime, desired)
        XCTAssertEqual(vm.committedTime, desired)
        XCTAssertFalse(vm.hasTimeChanges)
        XCTAssertTrue(vm.didSaveTime)
    }

    func testRefreshUsesActualScheduleAndReconcilesStoredFlag() async {
        let actual = NotificationReminderTime(hour: 14, minute: 30)
        let scheduler = NotificationSettingsMockScheduler(time: actual)
        scheduler.savedTime = .init(hour: 9, minute: 0)
        let vm = NotificationSettingsViewModel(client: scheduler.client())

        await vm.refresh()

        XCTAssertTrue(vm.isEnabled)
        XCTAssertEqual(vm.committedTime, actual)
        XCTAssertEqual(scheduler.persistedEnabled, true)
        XCTAssertEqual(scheduler.persistedTime, actual)
        XCTAssertTrue(scheduler.scheduledTimes.isEmpty)
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Notification state update did not finish", file: file, line: line)
    }
}

@MainActor
private final class NotificationSettingsMockScheduler {
    var authorization: UNAuthorizationStatus = .authorized
    var acceptAuthorization = true
    var authorizationRequests = 0
    var time: NotificationReminderTime?
    var savedTime = NotificationReminderTime(hour: 9, minute: 0)
    var scheduledTimes: [NotificationReminderTime] = []
    var removals = 0
    var failScheduling = false
    var holdSchedule = false
    var scheduleContinuation: CheckedContinuation<Void, Never>?
    var persistedEnabled: Bool?
    var persistedTime: NotificationReminderTime?

    init(time: NotificationReminderTime?) { self.time = time }

    func client() -> NotificationSettingsClient {
        NotificationSettingsClient(
            authorizationStatus: { self.authorization },
            requestAuthorization: {
                self.authorizationRequests += 1
                self.authorization = self.acceptAuthorization ? .authorized : .denied
                return self.acceptAuthorization
            },
            scheduledTime: { self.time },
            schedule: { desired in
                self.scheduledTimes.append(desired)
                if self.holdSchedule {
                    await withCheckedContinuation { self.scheduleContinuation = $0 }
                }
                if self.failScheduling { throw NSError(domain: "Recoco.NotificationTests", code: 1) }
                self.time = desired
            },
            remove: { self.removals += 1; self.time = nil },
            savedTime: { self.savedTime },
            persist: { enabled, time in self.persistedEnabled = enabled; self.persistedTime = time },
            announce: { _ in }
        )
    }
}

#if targetEnvironment(simulator)
/// Real view conversion and scroll insets are intentional here: the regression
/// involved SwiftUI layout timing, which a calculated-offset mock cannot cover.
@MainActor
final class CalendarResultRevealTests: XCTestCase {
    func testObscuredCardMovesJustEnoughToClearBottomInset() async {
        let fixture = makeFixture(cardFrame: CGRect(x: 20, y: 700, width: 350, height: 100))
        defer { fixture.close() }

        fixture.reveal.requestReveal(UUID(), animated: false)
        await drainRevealQueue()

        XCTAssertEqual(fixture.scroll.contentOffset.y, 430, accuracy: 0.5)
        let card = fixture.reveal.convert(fixture.reveal.bounds, to: fixture.scroll)
        let visibleBottom = fixture.scroll.contentOffset.y + fixture.scroll.bounds.height - fixture.scroll.adjustedContentInset.bottom
        XCTAssertLessThanOrEqual(card.maxY, visibleBottom + 0.5)
        XCTAssertLessThanOrEqual(fixture.scroll.contentOffset.y,
            fixture.scroll.contentSize.height - fixture.scroll.bounds.height + fixture.scroll.adjustedContentInset.bottom)
    }

    func testAlreadyVisibleCardPreservesCurrentScrollPosition() async {
        let fixture = makeFixture(cardFrame: CGRect(x: 20, y: 200, width: 350, height: 100))
        defer { fixture.close() }
        fixture.scroll.setContentOffset(CGPoint(x: 0, y: 100), animated: false)

        fixture.reveal.requestReveal(UUID(), animated: false)
        await drainRevealQueue()

        XCTAssertEqual(fixture.scroll.contentOffset.y, 100, accuracy: 0.5)
    }

    func testSameDayNewRequestRevealsAgainButHandledRequestDoesNotSnapBack() async {
        let fixture = makeFixture(cardFrame: CGRect(x: 20, y: 700, width: 350, height: 100))
        defer { fixture.close() }
        let firstTap = UUID()
        fixture.reveal.requestReveal(firstTap, animated: false)
        await drainRevealQueue()
        XCTAssertEqual(fixture.scroll.contentOffset.y, 430, accuracy: 0.5)

        // The user scrolls away. A re-render with the consumed request must not
        // undo that movement, but tapping the same day again has a new request.
        fixture.scroll.setContentOffset(.zero, animated: false)
        fixture.reveal.requestReveal(firstTap, animated: false)
        fixture.reveal.setNeedsLayout()
        fixture.reveal.layoutIfNeeded()
        await drainRevealQueue()
        XCTAssertEqual(fixture.scroll.contentOffset.y, 0, accuracy: 0.5)

        fixture.reveal.requestReveal(UUID(), animated: false)
        await drainRevealQueue()
        XCTAssertEqual(fixture.scroll.contentOffset.y, 430, accuracy: 0.5)
    }

    func testInitialNilRequestDoesNotScrollOnWindowAttachmentOrLayout() async {
        let fixture = makeFixture(cardFrame: CGRect(x: 20, y: 700, width: 350, height: 100))
        defer { fixture.close() }

        fixture.reveal.requestReveal(nil, animated: false)
        fixture.reveal.setNeedsLayout()
        fixture.reveal.layoutIfNeeded()
        await drainRevealQueue()

        XCTAssertEqual(fixture.scroll.contentOffset.y, 0, accuracy: 0.5)
    }

    func testPendingRequestSurvivesZeroLayoutAndIsConsumedOnceLayoutBecomesValid() async {
        let fixture = makeFixture(cardFrame: CGRect(x: 20, y: 700, width: 350, height: 0))
        defer { fixture.close() }
        let request = UUID()
        fixture.reveal.requestReveal(request, animated: false)
        await drainRevealQueue()
        XCTAssertEqual(fixture.scroll.contentOffset.y, 0, accuracy: 0.5)

        fixture.reveal.frame.size.height = 100
        fixture.reveal.setNeedsLayout()
        fixture.reveal.layoutIfNeeded()
        await drainRevealQueue()
        XCTAssertEqual(fixture.scroll.contentOffset.y, 430, accuracy: 0.5)

        fixture.scroll.setContentOffset(.zero, animated: false)
        fixture.reveal.requestReveal(request, animated: false)
        await drainRevealQueue()
        XCTAssertEqual(fixture.scroll.contentOffset.y, 0, accuracy: 0.5)
    }

    func testCardTallerThanViewportAlignsTopBelowTopInset() async {
        let fixture = makeFixture(cardFrame: CGRect(x: 20, y: 600, width: 350, height: 500))
        defer { fixture.close() }

        fixture.reveal.requestReveal(UUID(), animated: false)
        await drainRevealQueue()

        XCTAssertEqual(fixture.scroll.contentOffset.y, 580, accuracy: 0.5)
        let card = fixture.reveal.convert(fixture.reveal.bounds, to: fixture.scroll)
        let visibleTop = fixture.scroll.contentOffset.y + fixture.scroll.adjustedContentInset.top
        XCTAssertEqual(card.minY, visibleTop, accuracy: 0.5)
    }

    func testNilCancelsQueuedRequestAndLaterLayoutsDoNotRevealIt() async {
        let fixture = makeFixture(cardFrame: CGRect(x: 20, y: 700, width: 350, height: 100))
        defer { fixture.close() }

        fixture.reveal.requestReveal(UUID(), animated: false)
        fixture.reveal.requestReveal(nil, animated: false)
        await drainRevealQueue()
        fixture.reveal.setNeedsLayout()
        fixture.reveal.layoutIfNeeded()
        await drainRevealQueue()

        XCTAssertEqual(fixture.scroll.contentOffset.y, 0, accuracy: 0.5)
    }

    private func makeFixture(cardFrame: CGRect) -> Fixture {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let controller = UIViewController()
        controller.view = UIView(frame: window.bounds)
        window.rootViewController = controller
        window.isHidden = false

        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.contentInset = UIEdgeInsets(top: 20, left: 0, bottom: 30, right: 0)
        scroll.contentSize = CGSize(width: 390, height: 1_200)
        controller.view.addSubview(scroll)

        // Match the representable's real hierarchy: it is nested inside card
        // content, not a direct child of the scroll view.
        let content = UIView(frame: CGRect(origin: .zero, size: scroll.contentSize))
        scroll.addSubview(content)
        let reveal = CalendarResultRevealView(frame: cardFrame)
        content.addSubview(reveal)
        window.layoutIfNeeded()
        scroll.layoutIfNeeded()
        reveal.layoutIfNeeded()
        scroll.setContentOffset(.zero, animated: false)
        XCTAssertNotNil(reveal.window)
        return Fixture(window: window, scroll: scroll, reveal: reveal)
    }

    private func drainRevealQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private struct Fixture {
        let window: UIWindow
        let scroll: UIScrollView
        let reveal: CalendarResultRevealView

        @MainActor func close() {
            window.isHidden = true
            window.rootViewController = nil
        }
    }
}
#endif


@MainActor
final class OptionalAppleAccountTests: XCTestCase {
    private func fixture() throws -> (defaults: UserDefaults, suite: String) {
        let suite = "Recoco.OptionalAppleAccountTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let records = SavedRecordStore(defaults: defaults)
        for index in 0..<4 {
            try records.save(text: "Existing record \(index)", photoLocalIdentifier: "saved-\(index)",
                             capturedDateDescription: nil)
        }
        let activity = LocalActivityStore(defaults: defaults)
        activity.recordCompletion(deletedPhotoCount: 2, savedRecordCount: 0, completesDailySession: false)
        activity.beginDailySession(photoIdentifiers: ["qa-a", "qa-b", "qa-c"],
            comparisonReferences: ["qa-a": "qa-kept", "qa-b": "qa-kept", "qa-c": "qa-kept"],
            curationReasons: ["qa-a": .exactDuplicate, "qa-b": .exactDuplicate, "qa-c": .exactDuplicate])
        defaults.set(["qa-a", "qa-b"], forKey: "recoco_cleanup_selection_v1")
        defaults.set(activity.recommendationDayKey, forKey: "recoco_cleanup_selection_day_v1")
        defaults.set(Data("device draft".utf8), forKey: UserScopedStorage.draftKey(photoID: "qa-a"))
        // Previously scoped data is neither promoted into this library nor erased.
        defaults.set(Data("legacy A".utf8), forKey: UserScopedStorage.key(SavedRecordStore.storageKey, userID: "A"))
        defaults.set(Data("legacy B".utf8), forKey: UserScopedStorage.key(SavedRecordStore.storageKey, userID: "B"))
        defaults.set(Data("legacy draft".utf8), forKey: UserScopedStorage.draftKey(photoID: "qa-a", userID: "A"))
        return (defaults, suite)
    }

    private func appleConfiguration(enabled: Bool = true) -> LoginConfiguration {
        LoginConfiguration(firebaseConfigured: true, firebaseBundleID: "app.recoco.ios",
                           bundleID: "app.recoco.ios", appleEnabled: enabled)
    }

    func testUnsupportedOrMixedLegacyProvidersCannotEnterAccountDeletion() {
        XCTAssertTrue(AppleAccountPolicy.canDelete(providerIDs: ["apple.com"]))
        let unsupported: [Set<String>] = [[], ["google.com"], ["password"],
                                          ["apple.com", "google.com"], ["unknown.example"]]
        for providers in unsupported {
            XCTAssertFalse(AppleAccountPolicy.canDelete(providerIDs: providers))
        }
    }

    func testDeviceLibraryKeysDoNotResolveToAnAccountNamespace() throws {
        let context = try fixture()
        let before = context.defaults.dictionaryRepresentation() as NSDictionary
        XCTAssertEqual(UserScopedStorage.key(SavedRecordStore.storageKey), SavedRecordStore.storageKey)
        XCTAssertEqual(UserScopedStorage.key("recoco_cleanup_selection_v1"), "recoco_cleanup_selection_v1")
        XCTAssertEqual(UserScopedStorage.draftKey(photoID: "qa-a"), "recoco_record_draft_qa-a")
        XCTAssertNotEqual(UserScopedStorage.key(SavedRecordStore.storageKey),
                          UserScopedStorage.key(SavedRecordStore.storageKey, userID: "A"))
        XCTAssertEqual(try SavedRecordStore(defaults: context.defaults).readRecords().count, 4)
        XCTAssertEqual(context.defaults.stringArray(forKey: "recoco_cleanup_selection_v1")?.count, 2)
        XCTAssertEqual(context.defaults.dictionaryRepresentation() as NSDictionary, before)
    }

    func testNewIntroductionOffersAccountChoiceWithoutStartingOrClearingSession() throws {
        let context = try fixture()
        let before = context.defaults.dictionaryRepresentation()
        let vm = OnboardingViewModel(defaults: context.defaults)
        XCTAssertEqual(vm.finishIntroduction(), .login)
        XCTAssertTrue(context.defaults.bool(forKey: "recoco_onboarding_completed"))
        XCTAssertFalse(LocalSession.isActive(defaults: context.defaults))
        for (key, value) in before {
            XCTAssertEqual(context.defaults.object(forKey: key) as? NSObject, value as? NSObject, key)
        }
    }

    func testIntroductionSaveFailureStaysOnIntroduction() throws {
        let suite = "Recoco.OptionalIntroductionFailure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(OnboardingRejectingDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.rejectedKeys = ["recoco_onboarding_completed"]
        let vm = OnboardingViewModel(defaults: defaults)
        XCTAssertNil(vm.finishIntroduction())
        XCTAssertFalse(defaults.bool(forKey: "recoco_onboarding_completed"))
        XCTAssertNotNil(vm.errorMessage)
    }

    func testUnreadyAppleGateDoesNotStartAuthenticationEvenWithFirebaseOptions() throws {
        let context = try fixture()
        let configuration = appleConfiguration(enabled: false)
        let vm = AuthViewModel(signOut: {}, localDefaults: context.defaults,
                               configuration: configuration, finishProviderSignOut: {})
        let request = ASAuthorizationAppleIDProvider().createRequest()
        vm.configureAppleRequest(request)
        XCTAssertEqual(configuration.appleIssue, .disabled)
        XCTAssertNotNil(configuration.message)
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(request.nonce)
    }

    func testAppleRequestOnlyAsksForEmailAndCancellationKeepsEveryLocalValue() async throws {
        let context = try fixture()
        let before = context.defaults.dictionaryRepresentation() as NSDictionary
        let vm = AuthViewModel(signOut: {}, localDefaults: context.defaults,
                               configuration: appleConfiguration(), finishProviderSignOut: {})
        let request = ASAuthorizationAppleIDProvider().createRequest()
        vm.configureAppleRequest(request)
        XCTAssertEqual(request.requestedScopes, [.email])
        XCTAssertNotNil(request.nonce)
        XCTAssertTrue(vm.isLoading)
        let result = await vm.signInWithApple(result: .failure(NSError(
            domain: ASAuthorizationError.errorDomain, code: ASAuthorizationError.canceled.rawValue)))
        XCTAssertFalse(result)
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(context.defaults.dictionaryRepresentation() as NSDictionary, before)
    }

    func testLogoutReturnsToDeviceUseAndPreservesFourRecordsAndSelectionAcrossRelaunch() throws {
        let context = try fixture()
        let before = context.defaults.dictionaryRepresentation()
        var calls: [String] = []
        let vm = ProfileViewModel(signOut: { calls.append("auth") }, localDefaults: context.defaults,
                                  finishSignOut: { calls.append("provider") })
        XCTAssertTrue(vm.logout())
        XCTAssertEqual(calls, ["auth", "provider"])
        let reopened = try XCTUnwrap(UserDefaults(suiteName: context.suite))
        XCTAssertTrue(LocalSession.isActive(defaults: reopened))
        for (key, value) in before {
            XCTAssertEqual(reopened.object(forKey: key) as? NSObject, value as? NSObject, key)
        }
        XCTAssertEqual(try SavedRecordStore(defaults: reopened).readRecords().count, 4)
        XCTAssertEqual(reopened.stringArray(forKey: "recoco_cleanup_selection_v1")?.count, 2)
        let router = AppRouter(route: .splash)
        router.resolveInitialRoute(isLoggedIn: false, hasCompletedOnboarding: true,
                                   photoAuthStatus: .limited, hasLocalSession: LocalSession.isActive(defaults: reopened))
        XCTAssertEqual(router.route, .main)
    }

    func testLogoutStorageFailureDoesNotSignOutOrLoseData() throws {
        let suite = "Recoco.OptionalLogoutFailure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(OnboardingRejectingDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("records".utf8), forKey: SavedRecordStore.storageKey)
        defaults.rejectedKeys = [LocalSession.storageKey]
        let before = defaults.dictionaryRepresentation() as NSDictionary
        var calls = 0
        let vm = ProfileViewModel(signOut: { calls += 1 }, localDefaults: defaults,
                                  finishSignOut: { calls += 1 })
        XCTAssertFalse(vm.logout())
        XCTAssertEqual(calls, 0)
        XCTAssertNotNil(vm.logoutErrorMessage)
        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before)
    }

    func testSuccessfulAccountDeletionPreservesDeviceAndBothLegacyAccountLibraries() async throws {
        let context = try fixture()
        let before = context.defaults.dictionaryRepresentation() as NSDictionary
        var active: String? = "A"
        var finished = false
        try await AccountDeletionScope(userID: "A").deleteAccountOnly(currentUserID: { active },
            deleteRemote: { active = nil }, finishSession: { finished = true })
        XCTAssertTrue(finished)
        XCTAssertEqual(context.defaults.dictionaryRepresentation() as NSDictionary, before)
        let reopened = try XCTUnwrap(UserDefaults(suiteName: context.suite))
        XCTAssertEqual(try SavedRecordStore(defaults: reopened).readRecords().count, 4)
        XCTAssertEqual(reopened.stringArray(forKey: "recoco_cleanup_selection_v1")?.count, 2)
    }

    func testFailedOrCancelledAccountDeletionPreservesEveryLocalValue() async throws {
        let context = try fixture()
        let before = context.defaults.dictionaryRepresentation() as NSDictionary
        for failure in [CancellationError() as Error, NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)] {
            var finished = false
            do {
                try await AccountDeletionScope(userID: "A").deleteAccountOnly(currentUserID: { "A" },
                    deleteRemote: { throw failure }, finishSession: { finished = true })
                XCTFail("A failed account deletion must not finish")
            } catch {}
            XCTAssertFalse(finished)
            XCTAssertEqual(context.defaults.dictionaryRepresentation() as NSDictionary, before)
        }
    }

    func testChangedIdentityCannotDeleteOrExitTheNewAccount() async throws {
        let context = try fixture()
        let before = context.defaults.dictionaryRepresentation() as NSDictionary
        var calls = 0
        do {
            try await AccountDeletionScope(userID: "A").deleteAccountOnly(currentUserID: { "B" },
                deleteRemote: { calls += 1 }, finishSession: { calls += 1 })
            XCTFail("The captured identity must still match")
        } catch {}
        XCTAssertEqual(calls, 0)
        var active: String? = "A"
        try await AccountDeletionScope(userID: "A").deleteAccountOnly(currentUserID: { active },
            deleteRemote: { active = "B" }, finishSession: { calls += 1 })
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(context.defaults.dictionaryRepresentation() as NSDictionary, before)
    }
}


@MainActor
final class AccountIdentityLifecycleTests: XCTestCase {
    private func drainAccountUpdates() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    func testProfileObservesBackgroundSignOutWithoutWaitingForAnotherAppearance() async throws {
        let suite = "Recoco.ProfileAuthChanges.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("untouched records".utf8), forKey: SavedRecordStore.storageKey)
        defaults.set(["one", "two"], forKey: "recoco_cleanup_selection_v1")
        let before = (defaults.persistentDomain(forName: suite) ?? [:]) as NSDictionary
        var identity: ProfileAccountClient.Identity? = .init(displayName: "Account A",
            email: "a@example.test", photoURL: URL(string: "https://example.test/avatar"))
        var changed: (() -> Void)?
        var removals = 0
        let client = ProfileAccountClient(current: { identity }, observe: { callback in
            changed = callback
            return { removals += 1 }
        })
        let vm = ProfileViewModel(signOut: {}, localDefaults: defaults, finishSignOut: {}, accountClient: client)
        vm.startObservingAuthentication()
        changed?()
        await drainAccountUpdates()
        XCTAssertFalse(vm.isLocalSession)
        XCTAssertEqual(vm.email, "a@example.test")
        identity = nil
        changed?()
        await drainAccountUpdates()
        XCTAssertTrue(vm.isLocalSession)
        XCTAssertEqual(vm.email, "비움 내역은 이 기기에 남아요.")
        XCTAssertNil(vm.photoURL)
        XCTAssertEqual((defaults.persistentDomain(forName: suite) ?? [:]) as NSDictionary, before)
        vm.stopObservingAuthentication()
        XCTAssertEqual(removals, 1)
    }

    func testProfileListenerIsSingleAndOldCallbacksCannotUpdateAfterStopOrRestart() async {
        var identity: ProfileAccountClient.Identity? = .init(displayName: "A", email: "a@example.test", photoURL: nil)
        var callbacks: [() -> Void] = []
        var removals = 0
        let client = ProfileAccountClient(current: { identity }, observe: { callback in
            callbacks.append(callback)
            return { removals += 1 }
        })
        let vm = ProfileViewModel(signOut: {}, finishSignOut: {}, accountClient: client)
        vm.startObservingAuthentication()
        vm.startObservingAuthentication()
        XCTAssertEqual(callbacks.count, 1)
        callbacks[0]()
        await drainAccountUpdates()
        XCTAssertEqual(vm.displayName, "A")
        vm.stopObservingAuthentication()
        identity = .init(displayName: "B", email: "b@example.test", photoURL: nil)
        callbacks[0]()
        await drainAccountUpdates()
        XCTAssertEqual(vm.displayName, "A")
        vm.startObservingAuthentication()
        XCTAssertEqual(callbacks.count, 2)
        callbacks[1]()
        await drainAccountUpdates()
        XCTAssertEqual(vm.displayName, "B")
        identity = nil
        callbacks[0]()
        await drainAccountUpdates()
        XCTAssertFalse(vm.isLocalSession)
        callbacks[1]()
        await drainAccountUpdates()
        XCTAssertTrue(vm.isLocalSession)
        vm.stopObservingAuthentication()
        vm.stopObservingAuthentication()
        XCTAssertEqual(removals, 2)
    }

    func testProfileListenerIsRemovedWhenViewModelIsReleased() {
        var removals = 0
        let client = ProfileAccountClient(current: { nil }, observe: { _ in
            return { removals += 1 }
        })
        var vm: ProfileViewModel? = ProfileViewModel(signOut: {}, finishSignOut: {}, accountClient: client)
        vm?.startObservingAuthentication()
        vm = nil
        XCTAssertEqual(removals, 1)
    }

    func testAccountDeletionCoordinationIsUIDScopedRevisionedAndIdempotent() {
        let coordinator = AccountDeletionCoordination(notificationCenter: NotificationCenter())
        XCTAssertEqual(coordinator.revision(userID: "A"), 0)
        let first = coordinator.begin(userID: "A")
        XCTAssertTrue(coordinator.isDeleting(userID: "A"))
        XCTAssertFalse(coordinator.isDeleting(userID: "B"))
        XCTAssertEqual(coordinator.revision(userID: "A"), 1)
        let second = coordinator.begin(userID: "A")
        coordinator.end(first)
        XCTAssertTrue(coordinator.isDeleting(userID: "A"))
        XCTAssertEqual(coordinator.revision(userID: "A"), 3)
        coordinator.end(first)
        XCTAssertEqual(coordinator.revision(userID: "A"), 3)
        coordinator.end(second)
        XCTAssertFalse(coordinator.isDeleting(userID: "A"))
        XCTAssertEqual(coordinator.revision(userID: "A"), 4)
        XCTAssertEqual(coordinator.revision(userID: "B"), 0)
    }

    func testEndingDeletionNotifiesCredentialRecheckExactlyOnce() async {
        let center = NotificationCenter()
        let coordinator = AccountDeletionCoordination(notificationCenter: center)
        let recheck = expectation(description: "A finished deletion allows a fresh credential check")
        recheck.assertForOverFulfill = true
        let observation = center.addObserver(forName: .recocoAccountDeletionFinished, object: nil, queue: nil) { _ in
            recheck.fulfill()
        }
        defer { center.removeObserver(observation) }
        let token = coordinator.begin(userID: "A")
        coordinator.end(token)
        coordinator.end(token)
        await fulfillment(of: [recheck], timeout: 1)
        XCTAssertFalse(coordinator.isDeleting(userID: "A"))
    }
}
