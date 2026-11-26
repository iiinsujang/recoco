import UIKit
import XCTest
@testable import Recoco

final class RecordPhotoPreservationTests: XCTestCase {
    @MainActor
    func testHomeRecordLoadsAndSavesBoundedPreview() async throws {
        let context = makeContext()
        let image = makeImage()
        var requestedIdentifiers: [String] = []
        let vm = RecordViewModel(unit: context.unit, defaults: context.defaults, photoPreview: {
            requestedIdentifiers.append($0)
            return image
        }, onCompleted: { _ in })
        vm.onMeaningChanged("홈에서 남긴 기억")
        await vm.loadPhotoPreview()
        await vm.saveRecord()

        let saved = try XCTUnwrap(vm.savedRecord)
        let thumbnail = try XCTUnwrap(saved.photoThumbnailData.flatMap { UIImage(data: $0) })
        XCTAssertEqual(requestedIdentifiers, [context.unit.displayIdentifier!])
        XCTAssertLessThanOrEqual(max(thumbnail.size.width, thumbnail.size.height), 320)
        XCTAssertEqual(saved.photoLocalIdentifier, context.unit.displayIdentifier)
        XCTAssertEqual(saved.text, "홈에서 남긴 기억")
        XCTAssertTrue(vm.hasPhotoPreview)
        XCTAssertFalse(vm.photoPreviewUnavailable)
    }

    @MainActor
    func testPickerPreviewBypassesLibraryLookup() async throws {
        let context = makeContext()
        let vm = RecordViewModel(unit: context.unit, selectedImage: makeImage(), defaults: context.defaults,
                                 photoPreview: { _ in XCTFail("Picker preview must not require PhotoKit access"); return nil },
                                 onCompleted: { _ in })
        vm.onMeaningChanged("선택한 사진의 기억")
        await vm.loadPhotoPreview()
        await vm.saveRecord()

        XCTAssertNotNil(try XCTUnwrap(vm.savedRecord).photoThumbnailData)
        XCTAssertFalse(vm.photoPreviewUnavailable)
    }

    @MainActor
    func testFailedPreviewPreservesDraftAndRequiresExplicitTextOnlySave() async throws {
        let context = makeContext()
        var completions = 0
        let vm = RecordViewModel(unit: context.unit, defaults: context.defaults,
                                 photoPreview: { _ in nil }, onCompleted: { _ in completions += 1 })
        vm.onMeaningChanged("미리보기가 없어도 지키고 싶은 기억")
        vm.updateNarrative("내가 다듬은 마지막 문장")
        let draftID = vm.draft.recordID
        await vm.saveRecord()

        XCTAssertFalse(vm.isSaved)
        XCTAssertTrue(vm.photoPreviewUnavailable)
        XCTAssertNotNil(vm.saveError)
        XCTAssertEqual(completions, 0)
        XCTAssertTrue(try SavedRecordStore(defaults: context.defaults).readRecords().isEmpty)
        let restored = RecordViewModel(unit: context.unit, defaults: context.defaults,
                                       photoPreview: { _ in nil }, onCompleted: { _ in })
        XCTAssertEqual(restored.draft.recordID, draftID)
        XCTAssertEqual(restored.shareText, "내가 다듬은 마지막 문장")

        await vm.saveRecord(allowTextOnly: true)
        let saved = try XCTUnwrap(vm.savedRecord)
        XCTAssertNil(saved.photoThumbnailData)
        XCTAssertEqual(saved.text, "내가 다듬은 마지막 문장")
        XCTAssertEqual(saved.id, draftID)
        XCTAssertEqual(completions, 1)
    }

    @MainActor
    func testPreviewFailureCanRetryWithoutDuplicatingRecord() async throws {
        let context = makeContext()
        let image = makeImage()
        var requests = 0
        var completions = 0
        let vm = RecordViewModel(unit: context.unit, defaults: context.defaults, photoPreview: { _ in
            requests += 1
            return requests == 1 ? nil : image
        }, onCompleted: { _ in completions += 1 })
        vm.onMeaningChanged("다시 준비한 사진")
        await vm.saveRecord()
        XCTAssertFalse(vm.isSaved)
        await vm.saveRecord()
        await vm.saveRecord()

        XCTAssertTrue(vm.isSaved)
        XCTAssertNil(vm.saveError)
        XCTAssertFalse(vm.photoPreviewUnavailable)
        XCTAssertNotNil(vm.savedRecord?.photoThumbnailData)
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(try SavedRecordStore(defaults: context.defaults).readRecords().count, 1)
    }

    @MainActor
    func testSavingJoinsPreviewAlreadyLoadingWhileWriting() async throws {
        let context = makeContext()
        let started = expectation(description: "Preview starts while writing")
        let gate = PreviewGate(started: started)
        let vm = RecordViewModel(unit: context.unit, defaults: context.defaults,
                                 photoPreview: { _ in await gate.fetch() }, onCompleted: { _ in })
        vm.onMeaningChanged("쓰는 동안 준비한 사진")
        let warming = Task { await vm.loadPhotoPreview() }
        await fulfillment(of: [started], timeout: 1)
        let saving = Task { await vm.saveRecord() }
        for _ in 0..<10 where !vm.isSaving { await Task.yield() }
        XCTAssertTrue(vm.isSaving)
        XCTAssertEqual(gate.requests, 1)
        gate.finish(makeImage())
        await warming.value
        await saving.value

        XCTAssertTrue(vm.isSaved)
        XCTAssertEqual(gate.requests, 1)
        XCTAssertNotNil(try XCTUnwrap(vm.savedRecord).photoThumbnailData)
    }

    @MainActor
    func testPreparedHomePreviewRestoresOfflineWithoutAnotherLookup() async throws {
        let context = makeContext()
        let image = makeImage()
        let first = RecordViewModel(unit: context.unit, defaults: context.defaults,
                                    photoPreview: { _ in image }, onCompleted: { _ in })
        first.onMeaningChanged("다시 열어도 남길 기억")
        await first.loadPhotoPreview()
        let originalPreview = try XCTUnwrap(first.draft.photoThumbnailData)
        let restored = RecordViewModel(unit: context.unit, defaults: context.defaults, photoPreview: { _ in
            XCTFail("Persisted preview must not need library access")
            return nil
        }, onCompleted: { _ in })
        await restored.saveRecord()

        XCTAssertEqual(restored.savedRecord?.photoThumbnailData, originalPreview)
        XCTAssertEqual(restored.savedRecord?.text, "다시 열어도 남길 기억")
    }

    @MainActor
    func testNewRecordLeavesExistingRecordFieldsAndPhotoDataUnchanged() async throws {
        let context = makeContext()
        let store = SavedRecordStore(defaults: context.defaults)
        let legacy = try store.save(text: "이전 글", photoLocalIdentifier: "legacy-photo", capturedDateDescription: "2025년")
        let withPreview = try store.save(text: "이전 사진과 글", photoLocalIdentifier: "prior-photo",
                                         capturedDateDescription: nil,
                                         photoThumbnailData: RecordViewModel.thumbnailData(for: makeImage()))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let before = try [legacy, withPreview].map { try encoder.encode($0) }
        let image = makeImage()
        let vm = RecordViewModel(unit: context.unit, defaults: context.defaults,
                                 photoPreview: { _ in image }, onCompleted: { _ in })
        vm.onMeaningChanged("새로 남긴 글")
        await vm.saveRecord()
        let after = try store.readRecords()

        XCTAssertEqual(after.count, 3)
        for (index, prior) in [legacy, withPreview].enumerated() {
            let unchanged = try XCTUnwrap(after.first { $0.id == prior.id })
            XCTAssertEqual(try encoder.encode(unchanged), before[index])
        }
        XCTAssertTrue(CurationProtectionStore(defaults: context.defaults).identifiers().contains("legacy-photo"))
    }

    @MainActor
    func testRetryOfAlreadySavedTextOnlyRecordReportsActualStoredPreview() async throws {
        let context = makeContext()
        let vm = RecordViewModel(unit: context.unit, selectedImage: makeImage(), defaults: context.defaults,
                                 photoPreview: { _ in XCTFail("Draft already has preview"); return nil },
                                 onCompleted: { _ in })
        vm.onMeaningChanged("이미 저장된 글")
        let store = SavedRecordStore(defaults: context.defaults)
        // Reproduce an interrupted save: storage committed, but its draft was
        // not removed. The retried draft now has an available preview.
        let original = try store.save(id: XCTUnwrap(vm.draft.recordID), text: vm.shareText,
                                      photoLocalIdentifier: context.unit.displayIdentifier,
                                      capturedDateDescription: context.unit.capturedDateDescription,
                                      photoThumbnailData: nil)
        let key = UserScopedStorage.key(SavedRecordStore.storageKey)
        let originalBytes = try XCTUnwrap(context.defaults.data(forKey: key))
        XCTAssertTrue(vm.hasPhotoPreview)

        await vm.saveRecord()

        XCTAssertTrue(vm.isSaved)
        XCTAssertFalse(vm.hasSavedPhotoPreview)
        XCTAssertEqual(vm.savedRecord, original)
        XCTAssertNil(vm.savedRecord?.photoThumbnailData)
        XCTAssertEqual(context.defaults.data(forKey: key), originalBytes)
        XCTAssertEqual(try store.readRecords(), [original])
    }

    @MainActor
    func testCancelledSaveDoesNotCommitOrCompletePhoto() async throws {
        let context = makeContext()
        let started = expectation(description: "Save waits for preview")
        let gate = PreviewGate(started: started)
        let vm = RecordViewModel(unit: context.unit, defaults: context.defaults,
                                 photoPreview: { _ in await gate.fetch() },
                                 onCompleted: { _ in XCTFail("Cancelled save must not complete a photo") })
        vm.onMeaningChanged("취소 후에도 남아 있는 초안")
        let saving = Task { await vm.saveRecord() }
        await fulfillment(of: [started], timeout: 1)
        saving.cancel()
        gate.finish(makeImage())
        await saving.value

        XCTAssertFalse(vm.isSaved)
        XCTAssertFalse(vm.isSaving)
        XCTAssertEqual(vm.shareText, "취소 후에도 남아 있는 초안")
        XCTAssertTrue(try SavedRecordStore(defaults: context.defaults).readRecords().isEmpty)
    }

    @MainActor
    func testCancelledWarmLoadCannotOverwriteReopenedDraft() async throws {
        try await assertLatePreviewPreservesNewerDraft(cancelWarmTask: true)
    }

    @MainActor
    func testLeavingEditorInvalidatesPreviewBeforeReopeningDraft() async throws {
        try await assertLatePreviewPreservesNewerDraft(cancelWarmTask: false)
    }

    @MainActor
    private func assertLatePreviewPreservesNewerDraft(cancelWarmTask: Bool) async throws {
        let context = makeContext()
        let started = expectation(description: "Old editor starts preview")
        let gate = PreviewGate(started: started)
        let old = RecordViewModel(unit: context.unit, defaults: context.defaults,
                                  photoPreview: { _ in await gate.fetch() }, onCompleted: { _ in })
        old.onMeaningChanged("이전 화면에서 쓴 글")
        old.updateNarrative("이전 화면에서 다듬은 문장")
        let warming = Task { await old.loadPhotoPreview() }
        await fulfillment(of: [started], timeout: 1)
        if cancelWarmTask { warming.cancel() }
        else { old.cancelPendingWork() }

        let reopened = RecordViewModel(unit: context.unit, defaults: context.defaults,
                                       photoPreview: { _ in nil }, onCompleted: { _ in })
        reopened.onMeaningChanged("다시 열어 새로 쓴 글")
        reopened.updateNarrative("반드시 보존해야 하는 최신 문장")
        let key = UserScopedStorage.draftKey(photoID: context.unit.displayIdentifier!,
                                             userID: UserScopedStorage.currentUserID)
        let newerDraft = try XCTUnwrap(context.defaults.data(forKey: key))
        gate.finish(makeImage())
        await warming.value

        XCTAssertEqual(context.defaults.data(forKey: key), newerDraft)
        XCTAssertFalse(old.hasPhotoPreview)
        XCTAssertFalse(old.photoPreviewUnavailable)
        let restored = RecordViewModel(unit: context.unit, defaults: context.defaults,
                                       photoPreview: { _ in nil }, onCompleted: { _ in })
        XCTAssertEqual(restored.draft.meaning, "다시 열어 새로 쓴 글")
        XCTAssertEqual(restored.shareText, "반드시 보존해야 하는 최신 문장")
        XCTAssertEqual(restored.draft.recordID, reopened.draft.recordID)
        XCTAssertTrue(try SavedRecordStore(defaults: context.defaults).readRecords().isEmpty)
    }

    @MainActor
    private func makeImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 800)).image { renderer in
            UIColor.cyan.setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
        }
    }

    @MainActor
    private func makeContext() -> (unit: DecisionUnit, defaults: UserDefaults) {
        let suite = "RecordPhotoPreservationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let identifier = "home-photo-\(UUID().uuidString)"
        return (DecisionUnit(id: UUID(), type: .recallMoment, status: .pending,
                             candidateLocalIdentifiers: [identifier], recommendedLocalIdentifier: identifier,
                             selectedLocalIdentifier: nil, reasonCodes: [.dailyReflection],
                             capturedDateDescription: "2026년 10월", createdAt: Date()), defaults)
    }
}

@MainActor
private final class PreviewGate {
    private let started: XCTestExpectation
    private var continuations: [CheckedContinuation<UIImage?, Never>] = []
    private(set) var requests = 0

    init(started: XCTestExpectation) { self.started = started }

    func fetch() async -> UIImage? {
        requests += 1
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
            if requests == 1 { started.fulfill() }
        }
    }

    func finish(_ image: UIImage?) {
        let pending = continuations
        continuations = []
        for continuation in pending { continuation.resume(returning: image) }
    }
}
