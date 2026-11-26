import XCTest
import UIKit
@testable import Recoco

final class RecordViewModelTests: XCTestCase {
    @MainActor
    func testChangedMeaningRejectsLateGenerationResult() async {
        let context = makeContext()
        let started = expectation(description: "Generation started")
        let service = SuspendedNarrativeService(started: started)
        let vm = makeViewModel(unit: context.unit, defaults: context.defaults,
                                 narrativeService: service, onCompleted: { _ in })
        vm.onMeaningChanged("처음 입력")
        let request = Task { await vm.generateNarrative() }
        await fulfillment(of: [started], timeout: 2)
        vm.onMeaningChanged("수정한 입력")
        await service.finish()
        await request.value
        XCTAssertEqual(vm.draft.meaning, "수정한 입력")
        XCTAssertEqual(vm.draft.narrative, "")
        XCTAssertEqual(vm.generationState, .idle)
    }

    @MainActor
    func testRepeatedGenerationDoesNotStartAnotherRequest() async {
        let context = makeContext()
        let started = expectation(description: "Generation started once")
        started.assertForOverFulfill = true
        let service = SuspendedNarrativeService(started: started)
        let vm = makeViewModel(unit: context.unit, defaults: context.defaults,
                                 narrativeService: service, onCompleted: { _ in })
        vm.onMeaningChanged("남길 기억")
        let request = Task { await vm.generateNarrative() }
        await fulfillment(of: [started], timeout: 2)
        let repeated = Task { await vm.retryGeneration() }
        await Task.yield()
        await service.finish()
        await request.value
        await repeated.value
        let count = await service.requestCount
        XCTAssertEqual(count, 1)
        XCTAssertEqual(vm.draft.narrative, "생성된 기억")
    }

    @MainActor
    func testBlankMeaningDoesNotGenerateOrComplete() async {
        let context = makeContext()
        var completions = 0
        let vm = makeViewModel(unit: context.unit, defaults: context.defaults,
                                 onCompleted: { _ in completions += 1 })
        vm.onMeaningChanged("  \n  ")
        await vm.generateNarrative()
        await vm.saveRecord()
        XCTAssertEqual(vm.generationState, .idle)
        XCTAssertFalse(vm.isSaved)
        XCTAssertEqual(completions, 0)
    }

    @MainActor
    func testDraftRestoresAcrossViewModelInstances() {
        let context = makeContext()
        let first = makeViewModel(
            unit: context.unit,
            defaults: context.defaults,
            onCompleted: { _ in }
        )
        first.onMeaningChanged("바닷가에서 함께 웃던 오후")

        let restored = makeViewModel(
            unit: context.unit,
            defaults: context.defaults,
            onCompleted: { _ in }
        )
        XCTAssertEqual(restored.draft.meaning, "바닷가에서 함께 웃던 오후")
    }

    @MainActor
    func testEditedPreviewSurvivesBackAndReopeningIncludingEmptyEdits() async {
        for edited in ["직접 다듬은 마지막 문장", ""] {
            let context = makeContext()
            let service = LocalOnlyNarrativeService(error: .firebaseNotConfigured)
            let vm = makeViewModel(unit: context.unit, defaults: context.defaults,
                                     narrativeService: service, onCompleted: { _ in })
            vm.onMeaningChanged("처음 적은 한 줄")
            await vm.generateNarrative()
            vm.updateNarrative(edited)
            await vm.generateNarrative()
            XCTAssertEqual(vm.draft.narrative, edited)
            XCTAssertEqual(vm.generationState, .success(narrative: edited, keywords: []))

            let restored = makeViewModel(unit: context.unit, defaults: context.defaults,
                                           narrativeService: service, onCompleted: { _ in })
            await restored.generateNarrative()
            XCTAssertEqual(restored.draft.narrative, edited)
            XCTAssertEqual(restored.generationState, .success(narrative: edited, keywords: []))

            restored.onMeaningChanged("새로 작성한 한 줄")
            await restored.generateNarrative()
            XCTAssertEqual(restored.draft.narrative, edited)
            XCTAssertEqual(restored.shareText, edited)

            let reopened = makeViewModel(unit: context.unit, defaults: context.defaults,
                                           narrativeService: service, onCompleted: { _ in })
            await reopened.generateNarrative()
            XCTAssertEqual(reopened.draft.meaning, "새로 작성한 한 줄")
            XCTAssertEqual(reopened.draft.narrative, edited)
            XCTAssertEqual(reopened.generationState, .success(narrative: edited, keywords: []))
        }
    }

    @MainActor
    func testLegacyEditedDraftSurvivesSourceEditWithoutRegeneration() async throws {
        let context = makeContext()
        let data = try JSONSerialization.data(withJSONObject: [
            "meaning": "처음 적은 한 줄", "narrative": "이전 버전에서 수정한 기록", "keywords": []
        ])
        context.defaults.set(data, forKey: "recoco_record_draft_\(context.unit.displayIdentifier!)")
        let vm = makeViewModel(unit: context.unit, defaults: context.defaults,
                                 narrativeService: LocalOnlyNarrativeService(error: .firebaseNotConfigured),
                                 onCompleted: { _ in })
        vm.onMeaningChanged("뒤로 돌아와 수정한 한 줄")
        await vm.generateNarrative()
        XCTAssertEqual(vm.draft.narrative, "이전 버전에서 수정한 기록")
    }

    @MainActor
    func testLegacyIntentionallyEmptyPreviewSurvivesSourceEditAndReopening() async throws {
        let context = makeContext()
        let data = try JSONSerialization.data(withJSONObject: [
            "meaning": "처음 적은 한 줄", "narrative": "", "hasPreparedNarrative": true, "keywords": []
        ])
        context.defaults.set(data, forKey: "recoco_record_draft_\(context.unit.displayIdentifier!)")
        let vm = makeViewModel(unit: context.unit, defaults: context.defaults,
                                 narrativeService: LocalOnlyNarrativeService(error: .firebaseNotConfigured),
                                 onCompleted: { _ in XCTFail("An empty edited preview must not be saved") })
        vm.onMeaningChanged("이 문장을 자동으로 되살리면 안 돼요")
        await vm.generateNarrative()
        await vm.saveRecord()
        XCTAssertEqual(vm.draft.narrative, "")
        XCTAssertEqual(vm.shareText, "")
        XCTAssertFalse(vm.isSaved)

        let reopened = makeViewModel(unit: context.unit, defaults: context.defaults,
                                       narrativeService: LocalOnlyNarrativeService(error: .firebaseNotConfigured),
                                       onCompleted: { _ in })
        await reopened.generateNarrative()
        XCTAssertEqual(reopened.generationState, .success(narrative: "", keywords: []))
        XCTAssertEqual(reopened.shareText, "")
    }

    @MainActor
    func testClearingOriginalInputStillAllowsReopeningEditedPreview() async {
        let context = makeContext()
        let vm = makeViewModel(unit: context.unit, defaults: context.defaults,
                                 narrativeService: LocalOnlyNarrativeService(error: .firebaseNotConfigured),
                                 onCompleted: { _ in })
        vm.onMeaningChanged("처음 적은 한 줄")
        await vm.generateNarrative()
        vm.updateNarrative("오래 남기고 싶은 내 문장 🌊")
        vm.onMeaningChanged(" \n ")
        await vm.generateNarrative()
        XCTAssertEqual(vm.draft.meaning, " \n ")
        XCTAssertEqual(vm.draft.narrative, "오래 남기고 싶은 내 문장 🌊")
        XCTAssertEqual(vm.generationState, .success(narrative: "오래 남기고 싶은 내 문장 🌊", keywords: []))
    }

    @MainActor
    func testUneditedGeneratedPreviewUpdatesWhenOriginalInputChanges() async {
        let context = makeContext()
        let vm = makeViewModel(unit: context.unit, defaults: context.defaults,
                                 narrativeService: LocalOnlyNarrativeService(error: .firebaseNotConfigured),
                                 onCompleted: { _ in })
        vm.onMeaningChanged("처음 적은 한 줄")
        await vm.generateNarrative()
        let reopened = makeViewModel(unit: context.unit, defaults: context.defaults,
                                     narrativeService: LocalOnlyNarrativeService(error: .firebaseNotConfigured),
                                     onCompleted: { _ in })
        reopened.onMeaningChanged("새로 적은 한 줄")
        await reopened.generateNarrative()
        XCTAssertEqual(reopened.draft.narrative, "새로 적은 한 줄")
        XCTAssertEqual(reopened.shareText, "새로 적은 한 줄")
    }

    @MainActor
    func testEditedPreviewSavedAfterSourceChangesAndRelaunchKeepsExistingRecord() async throws {
        for originalInput in ["다시 고친 원문", ""] {
            let context = makeContext()
            let store = SavedRecordStore(defaults: context.defaults)
            let existing = try store.save(text: "이미 보관 중인 기록", photoLocalIdentifier: nil,
                                          capturedDateDescription: "2026. 10. 20.")
            let vm = makeViewModel(unit: context.unit, defaults: context.defaults,
                                   narrativeService: LocalOnlyNarrativeService(error: .firebaseNotConfigured),
                                   onCompleted: { _ in })
            vm.onMeaningChanged("원래 적었던 한 줄")
            await vm.generateNarrative()
            vm.updateNarrative("직접 다듬은 최종 기록 🌊\n그날의 바람을 기억해요.")
            vm.onMeaningChanged(originalInput)

            let reopened = makeViewModel(unit: context.unit, defaults: context.defaults,
                                         narrativeService: LocalOnlyNarrativeService(error: .firebaseNotConfigured),
                                         onCompleted: { _ in })
            await reopened.generateNarrative()
            await reopened.saveRecord()
            XCTAssertTrue(reopened.isSaved)
            XCTAssertEqual(reopened.savedRecord?.text, "직접 다듬은 최종 기록 🌊\n그날의 바람을 기억해요.")
            let records = try store.readRecords()
            XCTAssertEqual(records.count, 2)
            XCTAssertEqual(records.first(where: { $0.id == existing.id }), existing)
        }
    }

    @MainActor
    func testEditingPreviewRejectsLateGenerationSuccessAndFailure() async {
        for fails in [false, true] {
            for edited in ["늦은 응답보다 우선인 내 글", ""] {
                let context = makeContext()
                let started = expectation(description: "Generation started before direct edit")
                let service = SuspendedNarrativeService(started: started)
                let vm = makeViewModel(unit: context.unit, defaults: context.defaults,
                                         narrativeService: service, onCompleted: { _ in })
                vm.onMeaningChanged("처음 입력")
                let request = Task { await vm.generateNarrative() }
                await fulfillment(of: [started], timeout: 2)
                vm.updateNarrative(edited)
                await service.finish(failing: fails)
                await request.value
                XCTAssertEqual(vm.draft.narrative, edited)
                XCTAssertEqual(vm.shareText, edited)
                XCTAssertFalse(vm.showToast, "A superseded failure must not report a fallback")

                let reopened = makeViewModel(unit: context.unit, defaults: context.defaults,
                                               narrativeService: service, onCompleted: { _ in })
                await reopened.generateNarrative()
                XCTAssertEqual(reopened.draft.narrative, edited)
                let requestCount = await service.requestCount
                XCTAssertEqual(requestCount, 1)
            }
        }
    }

    @MainActor
    func testDismissedEditorLateGenerationCannotOverwriteReopenedDraft() async throws {
        for fails in [false, true] {
            let context = makeContext()
            let started = expectation(description: "Old editor starts generation")
            let service = SuspendedNarrativeService(started: started)
            let first = makeViewModel(unit: context.unit, defaults: context.defaults,
                                      narrativeService: service, onCompleted: { _ in })
            first.onMeaningChanged("떠나기 전에 적은 원문")
            let oldRequest = Task { await first.generateNarrative() }
            await fulfillment(of: [started], timeout: 2)
            first.cancelPendingWork()

            // This editor has its own model, but the same photo's persistent
            // draft. The departed editor no longer owns that draft's writes.
            let second = makeViewModel(unit: context.unit, defaults: context.defaults,
                                       narrativeService: LocalOnlyNarrativeService(error: .firebaseNotConfigured),
                                       onCompleted: { _ in })
            second.onMeaningChanged("다시 열어서 수정한 원문")
            second.updateNarrative("두 번째 화면에서 직접 다듬은 최신 기록")
            let key = "recoco_record_draft_\(context.unit.displayIdentifier!)"
            let latestDraft = try XCTUnwrap(context.defaults.data(forKey: key))

            await service.finish(failing: fails)
            await oldRequest.value
            XCTAssertEqual(context.defaults.data(forKey: key), latestDraft,
                           "A departed editor's late success or fallback must not write over the new draft")
            XCTAssertFalse(first.showToast)

            let third = makeViewModel(unit: context.unit, defaults: context.defaults,
                                      narrativeService: LocalOnlyNarrativeService(error: .firebaseNotConfigured),
                                      onCompleted: { _ in })
            await third.generateNarrative()
            XCTAssertEqual(third.draft.meaning, "다시 열어서 수정한 원문")
            XCTAssertEqual(third.draft.narrative, "두 번째 화면에서 직접 다듬은 최신 기록")
            XCTAssertEqual(third.shareText, "두 번째 화면에서 직접 다듬은 최신 기록")
        }
    }

    @MainActor
    func testNarrativeGenerationTrimsMeaning() async {
        let context = makeContext()
        let viewModel = makeViewModel(
            unit: context.unit,
            defaults: context.defaults,
            onCompleted: { _ in }
        )
        viewModel.onMeaningChanged("  오래 기억하고 싶은 풍경  \n")

        await viewModel.generateNarrative()

        XCTAssertEqual(viewModel.draft.narrative, "오래 기억하고 싶은 풍경")
        XCTAssertEqual(
            viewModel.generationState,
            .success(narrative: "오래 기억하고 싶은 풍경", keywords: [])
        )
        XCTAssertTrue(viewModel.usedLocalFallback)
    }

    @MainActor
    func testRemoteNarrativeReplacesMeaning() async {
        let context = makeContext()
        let generated = GeneratedNarrative(
            narrative: "남해의 푸른 수평선을 오래 기억하고 싶어요.",
            keywords: ["남해", "바다"]
        )
        let viewModel = makeViewModel(
            unit: context.unit,
            defaults: context.defaults,
            narrativeService: NarrativeServiceStub(result: .success(generated)),
            onCompleted: { _ in }
        )
        viewModel.onMeaningChanged("남해 바다를 기억하고 싶다")

        await viewModel.generateNarrative()

        XCTAssertEqual(viewModel.draft.narrative, generated.narrative)
        XCTAssertEqual(viewModel.draft.keywords, generated.keywords)
        XCTAssertFalse(viewModel.usedLocalFallback)
    }

    @MainActor
    func testRemoteFailureUsesLocalFallback() async {
        let context = makeContext()
        let viewModel = makeViewModel(
            unit: context.unit,
            defaults: context.defaults,
            narrativeService: NarrativeServiceStub(result: .failure(.unavailable)),
            onCompleted: { _ in }
        )
        viewModel.onMeaningChanged("  비 오는 날의 시장  ")

        await viewModel.generateNarrative()

        XCTAssertEqual(viewModel.draft.narrative, "비 오는 날의 시장")
        XCTAssertTrue(viewModel.usedLocalFallback)
        XCTAssertEqual(viewModel.toastMessage, "연결이 어려워 작성한 글을 그대로 준비했어요.")
    }

    @MainActor
    func testDeviceOnlyPreviewKeepsOriginalTextWithoutConnectionError() async {
        for error: NarrativeServiceError in [.firebaseNotConfigured, .unauthenticated] {
            let context = makeContext()
            let vm = makeViewModel(
                unit: context.unit,
                defaults: context.defaults,
                narrativeService: LocalOnlyNarrativeService(error: error),
                onCompleted: { _ in }
            )
            vm.onMeaningChanged("  내 말 그대로 남길 기억  ")
            await vm.generateNarrative()
            XCTAssertEqual(vm.draft.narrative, "내 말 그대로 남길 기억")
            XCTAssertTrue(vm.usedLocalFallback)
            XCTAssertFalse(vm.showToast)
            XCTAssertEqual(vm.toastMessage, "")
            XCTAssertEqual(vm.generationState, .success(narrative: "내 말 그대로 남길 기억", keywords: []))
        }
    }

    @MainActor
    func testCompletedRecordSavesOnlyOnce() async throws {
        let context = makeContext()
        var completionCount = 0
        let viewModel = makeViewModel(
            unit: context.unit,
            defaults: context.defaults,
            onCompleted: { _ in completionCount += 1 }
        )
        viewModel.onMeaningChanged("남해의 푸른 바다")

        await viewModel.saveRecord()
        await viewModel.saveRecord()

        let data = try XCTUnwrap(
            context.defaults.data(forKey: "recoco_saved_records_v1")
        )
        let records = try JSONDecoder().decode([SavedRecordFixture].self, from: data)
        XCTAssertEqual(records.map(\.text), ["남해의 푸른 바다"])
        XCTAssertEqual(completionCount, 1)
        XCTAssertTrue(viewModel.isSaved)
        XCTAssertEqual(viewModel.savedRecord?.text, "남해의 푸른 바다")
        XCTAssertNil(viewModel.saveError)
    }

    @MainActor
    func testRestartBetweenSavingRecordAndClearingDraftDoesNotDuplicateRecord() async throws {
        let context = makeContext()
        let original = makeViewModel(unit: context.unit, defaults: context.defaults, onCompleted: { _ in })
        original.onMeaningChanged("다시 열어도 한 번만 남길 기록")
        let id = try XCTUnwrap(original.draft.recordID)
        try SavedRecordStore(defaults: context.defaults).save(id: id, text: original.shareText,
            photoLocalIdentifier: context.unit.displayIdentifier, capturedDateDescription: context.unit.capturedDateDescription)
        var completions = 0
        let restored = makeViewModel(unit: context.unit, defaults: context.defaults, onCompleted: { _ in completions += 1 })
        XCTAssertEqual(restored.draft.recordID, id)
        await restored.saveRecord()
        XCTAssertTrue(restored.isSaved)
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(SavedRecordStore(defaults: context.defaults).records().count, 1)
    }

    @MainActor
    func testInterruptedIndependentSavePreservesTwoRecordsAndCountsSavedIDOnce() async throws {
        let context = makeContext()
        let records = SavedRecordStore(defaults: context.defaults)
        let originalOne = try records.save(text: "기존 기록 하나", photoLocalIdentifier: "original-one",
                                           capturedDateDescription: "2026. 1. 1.")
        let originalTwo = try records.save(text: "기존 기록 둘", photoLocalIdentifier: nil,
                                           capturedDateDescription: nil)
        let activity = LocalActivityStore(defaults: context.defaults)
        activity.beginDailySession(photoIdentifiers: ["pending-one", "pending-two"],
                                    comparisonReferences: ["pending-two": "reference"])
        let vm = makeViewModel(unit: context.unit, defaults: context.defaults,
                                 onCompleted: { activity.recordIndependentMemory(recordID: $0.id) })
        vm.onMeaningChanged("새로운 기억")
        let draftKey = "recoco_record_draft_\(context.unit.displayIdentifier!)"
        let interruptedDraft = try XCTUnwrap(context.defaults.data(forKey: draftKey))
        await vm.saveRecord()
        let savedID = try XCTUnwrap(vm.savedRecord?.id)

        // Simulate interruption after the activity was committed but before draft cleanup.
        context.defaults.set(interruptedDraft, forKey: draftKey)
        let restoredActivity = LocalActivityStore(defaults: context.defaults)
        let restored = makeViewModel(unit: context.unit, defaults: context.defaults,
                                       onCompleted: { restoredActivity.recordIndependentMemory(recordID: $0.id) })
        await restored.saveRecord()

        let stored = try records.readRecords()
        XCTAssertEqual(stored.count, 3)
        XCTAssertEqual(stored.first(where: { $0.id == originalOne.id }), originalOne)
        XCTAssertEqual(stored.first(where: { $0.id == originalTwo.id }), originalTwo)
        XCTAssertEqual(stored.filter { $0.id == savedID }.count, 1)
        XCTAssertEqual(restored.savedRecord?.id, savedID)
        XCTAssertEqual(restoredActivity.weeklySnapshot().savedRecordCount, 1)
        let pending = restoredActivity.dailySessionProgress()
        XCTAssertEqual(pending.curatedPhotoIdentifiers, ["pending-one", "pending-two"])
        XCTAssertEqual(pending.comparisonReferences, ["pending-two": "reference"])
        XCTAssertTrue(pending.processedDecisionKeys.isEmpty)
        XCTAssertNil(context.defaults.object(forKey: draftKey))
    }

    @MainActor
    func testMetadataFinishingAfterSaveCannotRecreateDraft() async throws {
        let context = makeContext()
        let started = expectation(description: "Metadata started")
        let metadata = SuspendedPhotoMetadata(started: started)
        var completions = 0
        let vm = makeViewModel(unit: context.unit, defaults: context.defaults,
                                 photoMetadata: { await metadata.locationName(for: $0) },
                                 onCompleted: { _ in completions += 1 })
        vm.onMeaningChanged("위치 조회보다 먼저 저장한 기록")
        let request = Task { await vm.loadPhotoMetadata() }
        await fulfillment(of: [started], timeout: 2)
        await vm.saveRecord()
        let stored = vm.savedRecord
        let draftKey = "recoco_record_draft_\(context.unit.displayIdentifier!)"
        XCTAssertNil(context.defaults.object(forKey: draftKey))

        await metadata.finish("서울")
        await request.value

        XCTAssertNil(context.defaults.object(forKey: draftKey))
        XCTAssertNil(vm.draft.cityName)
        XCTAssertEqual(vm.savedRecord, stored)
        XCTAssertEqual(try SavedRecordStore(defaults: context.defaults).readRecords(), [try XCTUnwrap(stored)])
        XCTAssertEqual(completions, 1)
    }

    @MainActor
    func testStorageFailurePreservesDraftAndDoesNotCompletePhoto() async {
        let context = makeContext()
        let original = Data("broken existing records".utf8)
        context.defaults.set(original, forKey: SavedRecordStore.storageKey)
        let model = makeViewModel(unit: context.unit, defaults: context.defaults, onCompleted: { _ in XCTFail("Must not complete") })
        model.onMeaningChanged("저장에 실패해도 남아 있어야 하는 초안")
        await model.saveRecord()
        XCTAssertFalse(model.isSaved)
        XCTAssertFalse(model.isSaving)
        XCTAssertNil(model.savedRecord)
        XCTAssertNotNil(model.saveError)
        XCTAssertEqual(context.defaults.data(forKey: SavedRecordStore.storageKey), original)
        let restored = makeViewModel(unit: context.unit, defaults: context.defaults, onCompleted: { _ in })
        XCTAssertEqual(restored.shareText, model.shareText)
        XCTAssertEqual(restored.draft.recordID, model.draft.recordID)
    }

    @MainActor
    func testSaveFailureCanRetryAndSavedResultCannotDriftFromStoredText() async throws {
        let context = makeContext()
        context.defaults.set(Data("broken".utf8), forKey: SavedRecordStore.storageKey)
        var completions = 0
        let model = makeViewModel(unit: context.unit, defaults: context.defaults, onCompleted: { _ in completions += 1 })
        model.onMeaningChanged("처음 적은 기억")
        model.updateNarrative("저장할 최종 문장")
        await model.saveRecord()
        XCTAssertNotNil(model.saveError)
        XCTAssertEqual(completions, 0)
        // Simulate storage becoming writable again, without clearing the draft.
        context.defaults.removeObject(forKey: SavedRecordStore.storageKey)
        await model.saveRecord()
        XCTAssertNil(model.saveError)
        XCTAssertEqual(model.savedRecord?.text, "저장할 최종 문장")
        model.updateNarrative("저장 후 화면만 바꾸면 안 되는 글")
        model.onMeaningChanged("새 의미")
        await model.saveRecord()
        XCTAssertEqual(model.shareText, "저장할 최종 문장")
        XCTAssertEqual(model.draft.narrative, "저장할 최종 문장")
        XCTAssertEqual(completions, 1)
        let records = try SavedRecordStore(defaults: context.defaults).readRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.id, model.savedRecord?.id)
    }

    @MainActor
    func testUnreadableDraftIsPreservedWhenOpeningEditingAndSaving() async {
        let context = makeContext()
        let key = "recoco_record_draft_\(context.unit.displayIdentifier!)"
        let original = Data("unreadable draft".utf8)
        context.defaults.set(original, forKey: key)
        let model = makeViewModel(unit: context.unit, defaults: context.defaults, onCompleted: { _ in XCTFail("Must not complete") })
        model.onMeaningChanged("새로 입력한 글")
        await model.saveRecord()
        XCTAssertFalse(model.isSaved)
        XCTAssertEqual(context.defaults.data(forKey: key), original)
        XCTAssertTrue(SavedRecordStore(defaults: context.defaults).records().isEmpty)
    }

    @MainActor
    func testPickerOnlyPhotoSavesBoundedPreviewWithItsRecord() async throws {
        let context = makeContext()
        let unit = DecisionUnit(
            id: UUID(), type: .cleanupSingle, status: .pending,
            candidateLocalIdentifiers: [], recommendedLocalIdentifier: nil,
            selectedLocalIdentifier: nil, reasonCodes: [],
            capturedDateDescription: nil, createdAt: Date()
        )
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1000, height: 600)).image { renderer in
            UIColor.blue.setFill(); renderer.fill(CGRect(x: 0, y: 0, width: 1000, height: 600))
        }
        let model = makeViewModel(unit: unit, selectedImage: image, defaults: context.defaults, onCompleted: { _ in })
        model.onMeaningChanged("직접 고른 순간")
        await model.saveRecord()
        let stored = try XCTUnwrap(SavedRecordStore(defaults: context.defaults).records().first)
        XCTAssertNil(stored.photoLocalIdentifier)
        let data = try XCTUnwrap(stored.photoThumbnailData)
        let preview = try XCTUnwrap(UIImage(data: data))
        XCTAssertLessThanOrEqual(max(preview.size.width, preview.size.height), 320)
        XCTAssertEqual(stored.text, "직접 고른 순간")
    }

    @MainActor
    func testPickerImageWithIdentifierRetainsBoundedPreviewAcrossDraftAndSavedRecord() async throws {
        let context = makeContext()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 800)).image { renderer in
            UIColor.orange.setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
        }
        let vm = makeViewModel(unit: context.unit, selectedImage: image, defaults: context.defaults,
                                 onCompleted: { _ in })
        vm.onMeaningChanged("사진 접근 범위가 달라져도 남길 기억")
        let restored = makeViewModel(unit: context.unit, defaults: context.defaults, onCompleted: { _ in })
        XCTAssertNotNil(restored.draft.photoThumbnailData)
        await restored.saveRecord()
        let stored = try XCTUnwrap(restored.savedRecord)
        XCTAssertEqual(stored.photoLocalIdentifier, context.unit.displayIdentifier)
        let preview = try XCTUnwrap(stored.photoThumbnailData.flatMap(UIImage.init(data:)))
        XCTAssertLessThanOrEqual(max(preview.size.width, preview.size.height), 320)
        XCTAssertEqual(try SavedRecordStore(defaults: context.defaults).readRecords(), [stored])
    }

    @MainActor
    private func makeViewModel(
        unit: DecisionUnit,
        selectedImage: UIImage? = nil,
        defaults: UserDefaults = .standard,
        narrativeService: any NarrativeGenerating = FirebaseNarrativeService(),
        photoMetadata: @escaping @MainActor (String?) async -> String? = { _ in nil },
        onCompleted: @escaping (SavedMemoryRecord) -> Void
    ) -> RecordViewModel {
        RecordViewModel(unit: unit, selectedImage: selectedImage, defaults: defaults,
                        narrativeService: narrativeService, photoMetadata: photoMetadata,
                        photoPreview: { _ in
                            UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { renderer in
                                UIColor.blue.setFill()
                                renderer.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
                            }
                        }, onCompleted: onCompleted)
    }

    @MainActor
    private func makeContext() -> RecordTestContext {
        let suiteName = "RecordViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let identifier = "photo-\(UUID().uuidString)"
        let unit = DecisionUnit(
            id: UUID(),
            type: .cleanupSingle,
            status: .pending,
            candidateLocalIdentifiers: [identifier],
            recommendedLocalIdentifier: identifier,
            selectedLocalIdentifier: nil,
            reasonCodes: [.oldUnopened],
            capturedDateDescription: nil,
            createdAt: Date()
        )
        return RecordTestContext(defaults: defaults, unit: unit)
    }
}

private struct RecordTestContext {
    let defaults: UserDefaults
    let unit: DecisionUnit
}

private struct SavedRecordFixture: Decodable {
    let id: UUID
    let createdAt: Date
    let text: String
}

private struct NarrativeServiceStub: NarrativeGenerating {
    let result: Result<GeneratedNarrative, NarrativeServiceStubError>

    func generate(
        meaning: String,
        capturedAt: String?,
        cityName: String?,
        locale: String,
        clues: [String]
    ) async throws -> GeneratedNarrative {
        try result.get()
    }
}

private enum NarrativeServiceStubError: Error {
    case unavailable
}

private struct LocalOnlyNarrativeService: NarrativeGenerating {
    let error: NarrativeServiceError

    func generate(meaning: String, capturedAt: String?, cityName: String?,
                  locale: String, clues: [String]) async throws -> GeneratedNarrative {
        throw error
    }
}

private actor SuspendedPhotoMetadata {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<String?, Never>?

    init(started: XCTestExpectation) { self.started = started }

    func locationName(for identifier: String?) async -> String? {
        started.fulfill()
        return await withCheckedContinuation { continuation = $0 }
    }

    func finish(_ name: String) {
        continuation?.resume(returning: name)
        continuation = nil
    }
}

private actor SuspendedNarrativeService: NarrativeGenerating {
    let started: XCTestExpectation
    private var continuations: [CheckedContinuation<GeneratedNarrative, Error>] = []
    private(set) var requestCount = 0
    private var finished = false

    init(started: XCTestExpectation) { self.started = started }

    func generate(meaning: String, capturedAt: String?, cityName: String?,
                  locale: String, clues: [String]) async throws -> GeneratedNarrative {
        requestCount += 1
        started.fulfill()
        if finished { return GeneratedNarrative(narrative: "생성된 기억", keywords: []) }
        return try await withCheckedThrowingContinuation { continuations.append($0) }
    }

    func finish(failing: Bool = false) {
        finished = true
        continuations.forEach {
            if failing { $0.resume(throwing: NarrativeServiceStubError.unavailable) }
            else { $0.resume(returning: GeneratedNarrative(narrative: "생성된 기억", keywords: [])) }
        }
        continuations.removeAll()
    }
}

final class SavedRecordBrowsingTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 9 * 3600)!
        return value
    }
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
    private func memory(_ text: String, _ date: Date) -> SavedMemoryRecord {
        SavedMemoryRecord(id: UUID(), createdAt: date, text: text,
                          photoLocalIdentifier: nil, capturedDateDescription: nil)
    }

    func testRecentWindowAndMonthYearBoundaryDoNotDuplicateRecords() {
        let records = [memory("작년", date(2025, 12, 20)), memory("최근", date(2026, 1, 2)),
                       memory("경계 포함", date(2025, 12, 27, 0)), memory("경계 밖", date(2025, 12, 26)),
                       memory("재작년", date(2024, 12, 20))]
        let groups = SavedRecordBrowsing.sections(records, query: "", now: date(2026, 1, 2), calendar: calendar)
        XCTAssertEqual(groups.map(\.title), ["최근 7일", "2025년 12월", "2024년 12월"])
        XCTAssertEqual(groups.map { $0.records.count }, [2, 2, 1])
        XCTAssertEqual(Set(groups.flatMap(\.records).map(\.id)), Set(records.map(\.id)))
        XCTAssertEqual(groups[0].records.first?.text, "최근")
    }

    func testSearchPreservesUnicodeAndMatchesStoredTextOnly() {
        let records = [memory("바다 Café 👨‍👩‍👧‍👦", date(2026, 10, 15)), memory("다른 기억", date(2026, 10, 14))]
        for query in ["  CAFE  ", "바다".decomposedStringWithCanonicalMapping, "👨‍👩‍👧‍👦", "ＣＡＦＥ"] {
            let groups = SavedRecordBrowsing.sections(records, query: query, now: date(2026, 10, 15), calendar: calendar)
            XCTAssertEqual(groups.flatMap(\.records).map(\.id), [records[0].id])
            XCTAssertEqual(groups.first?.records.first?.text, records[0].text)
        }
        XCTAssertTrue(SavedRecordBrowsing.sections(records, query: "찾을 수 없는 단어").isEmpty)
        XCTAssertEqual(SavedRecordBrowsing.sections(records, query: " \n ").flatMap(\.records).count, 2)
    }

    func testHundredsOfRecordsKeepTheirIdentityAndStableOrder() {
        let now = date(2026, 10, 15)
        let records = (0..<501).map { memory("같은 글 \($0 % 2)", now.addingTimeInterval(Double(-$0))) }
        let result = SavedRecordBrowsing.sections(Array(records.reversed()), query: "같은 글", now: now, calendar: calendar).flatMap(\.records)
        XCTAssertEqual(result.map(\.id), records.map(\.id))
        XCTAssertEqual(result.count, 501)
    }
}
