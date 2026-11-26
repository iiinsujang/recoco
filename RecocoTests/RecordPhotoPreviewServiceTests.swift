import Photos
import UIKit
import XCTest
@testable import Recoco

final class RecordPhotoPreviewServiceTests: XCTestCase {
    @MainActor
    func testHomePreviewTimeoutIncludesSlowRequestCreation() async {
        let cancelled = expectation(description: "late request cancelled")
        let began = ProcessInfo.processInfo.systemUptime
        let result = await HomePhotoPreviewRequest().load(timeoutNanoseconds: 50_000_000,
            minimumSize: CGSize(width: 480, height: 480), finishOnUsable: true,
            onUsable: { _ in XCTFail("A late image must not be published") }, request: { _ in
                Thread.sleep(forTimeInterval: 0.5)
                return 91
            }, cancel: { id in
                XCTAssertEqual(id, 91)
                cancelled.fulfill()
            })
        XCTAssertNil(result)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 0.3,
                          "PhotoKit request creation must not freeze Home or postpone its timeout")
        await fulfillment(of: [cancelled], timeout: 2)
    }

    @MainActor
    func testHomePreviewSlowCancellationCannotDelayUsableImage() async {
        let cancelled = expectation(description: "slow cancellation finished")
        let image = homeImage(width: 600, height: 600)
        let began = ProcessInfo.processInfo.systemUptime
        let result = await HomePhotoPreviewRequest().load(timeoutNanoseconds: 1_000_000_000,
            minimumSize: CGSize(width: 480, height: 480), finishOnUsable: true,
            onUsable: { _ in }, request: { deliver in
                deliver(image, true, false)
                return 92
            }, cancel: { id in
                XCTAssertEqual(id, 92)
                Thread.sleep(forTimeInterval: 0.5)
                cancelled.fulfill()
            })
        XCTAssertTrue(result?.image === image)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 0.3,
                          "A completed image must reach Home before PhotoKit cancellation returns")
        await fulfillment(of: [cancelled], timeout: 2)
    }

    @MainActor
    func testHomePreviewRejectsTinyDegradedPhotoEvenOnFinalFailure() async {
        var publications = 0
        let cancelled = expectation(description: "PhotoKit request cancelled once")
        let tiny = homeImage(width: 64, height: 64)
        let result = await HomePhotoPreviewRequest().load(timeoutNanoseconds: 20_000_000,
            minimumSize: CGSize(width: 480, height: 480), finishOnUsable: true,
            onUsable: { _ in publications += 1 }, request: { deliver in
                deliver(tiny, false, false)
                deliver(nil, true, false)
                return 61
            }, cancel: { id in XCTAssertEqual(id, 61); cancelled.fulfill() })
        XCTAssertNil(result)
        XCTAssertEqual(publications, 0, "A blurry thumbnail must never enable selection/deletion")
        await fulfillment(of: [cancelled], timeout: 1)
    }

    @MainActor
    func testHomePreviewPublishesUsablePhotoBeforeFinalCallback() async {
        let image = homeImage(width: 600, height: 600)
        var published: [HomePhotoPreviewResult] = []
        let cancelled = expectation(description: "PhotoKit request cancelled once")
        let result = await HomePhotoPreviewRequest().load(timeoutNanoseconds: 1_000_000_000,
            minimumSize: CGSize(width: 480, height: 480), finishOnUsable: true,
            onUsable: { published.append($0) }, request: { deliver in
                deliver(image, false, false)
                // PhotoKit may never deliver a final callback for an unavailable original.
                return 62
            }, cancel: { id in XCTAssertEqual(id, 62); cancelled.fulfill() })
        XCTAssertTrue(result?.image === image)
        XCTAssertEqual(result?.finalQuality, false)
        XCTAssertEqual(published.count, 1)
        await fulfillment(of: [cancelled], timeout: 1)
    }

    @MainActor
    func testHomePreviewKeepsUsablePhotoWhenUpgradeFails() async {
        let image = homeImage(width: 600, height: 600)
        let result = await HomePhotoPreviewRequest().load(timeoutNanoseconds: 20_000_000,
            minimumSize: CGSize(width: 480, height: 480), finishOnUsable: false,
            onUsable: { _ in }, request: { deliver in
                deliver(image, false, false)
                deliver(nil, true, false)
                return 63
            }, cancel: { _ in })
        XCTAssertTrue(result?.image === image)
        XCTAssertEqual(result?.finalQuality, false)
    }

    @MainActor
    func testHomePreviewCancellationCannotDeliverLatePhoto() async {
        let started = expectation(description: "Photo request started")
        var deliverResult: ((UIImage?, Bool, Bool) -> Void)?
        var published = 0
        let cancelled = expectation(description: "PhotoKit request cancelled once")
        let task = Task { @MainActor in
            await HomePhotoPreviewRequest().load(timeoutNanoseconds: 1_000_000_000,
                minimumSize: CGSize(width: 480, height: 480), finishOnUsable: false,
                onUsable: { _ in published += 1 }, request: { deliver in
                    deliverResult = deliver
                    started.fulfill()
                    return 64
                }, cancel: { id in XCTAssertEqual(id, 64); cancelled.fulfill() })
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        let result = await task.value
        deliverResult?(homeImage(width: 600, height: 600), true, false)
        await Task.yield()
        XCTAssertNil(result)
        XCTAssertEqual(published, 0)
        await fulfillment(of: [cancelled], timeout: 1)
    }

    func testHomePreviewResolutionRespectsPanoramaAndNativeSmallImage() {
        XCTAssertEqual(HomePhotoPreviewQuality.minimumSize(original: CGSize(width: 4000, height: 1000),
                       target: CGSize(width: 800, height: 800), fit: true), CGSize(width: 480, height: 120))
        XCTAssertEqual(HomePhotoPreviewQuality.minimumSize(original: CGSize(width: 80, height: 60),
                       target: CGSize(width: 800, height: 800), fit: false), CGSize(width: 80, height: 60))
    }

    @MainActor
    private func homeImage(width: CGFloat, height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    @MainActor
    func testTimeoutKeepsUsableDegradedPreviewAndCancelsRequestOnce() async {
        let preview = makeImage()
        var cancellations: [PHImageRequestID] = []
        let result = await RecordPhotoPreviewRequest().load(timeoutNanoseconds: 20_000_000, request: { deliver in
            deliver(preview, false, false)
            return 41
        }, cancel: { cancellations.append($0) })

        XCTAssertTrue(result === preview)
        XCTAssertEqual(cancellations, [41])
    }

    @MainActor
    func testFinalFailureKeepsPreviewAndIgnoresDuplicateCallbacks() async {
        let preview = makeImage()
        var cancellations: [PHImageRequestID] = []
        let result = await RecordPhotoPreviewRequest().load(request: { deliver in
            deliver(preview, false, false)
            deliver(nil, true, false)
            deliver(nil, true, false)
            return 42
        }, cancel: { cancellations.append($0) })
        await Task.yield()

        XCTAssertTrue(result === preview)
        XCTAssertEqual(cancellations, [42])
    }

    @MainActor
    func testCancellationDiscardsPreviewAndCancelsRequestOnce() async {
        let started = expectation(description: "Preview request started")
        let preview = makeImage()
        var cancellations: [PHImageRequestID] = []
        var deliverResult: ((UIImage?, Bool, Bool) -> Void)?
        let task = Task { @MainActor in
            await RecordPhotoPreviewRequest().load(request: { deliver in
                deliverResult = deliver
                deliver(preview, false, false)
                started.fulfill()
                return 43
            }, cancel: { cancellations.append($0) })
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        let result = await task.value
        deliverResult?(preview, true, false)
        await Task.yield()

        XCTAssertNil(result)
        XCTAssertEqual(cancellations, [43])
    }

    @MainActor
    func testMissingCallbackTimesOutWithoutPhoto() async {
        var cancellations: [PHImageRequestID] = []
        let result = await RecordPhotoPreviewRequest().load(timeoutNanoseconds: 10_000_000,
            request: { _ in 44 }, cancel: { cancellations.append($0) })

        XCTAssertNil(result)
        XCTAssertEqual(cancellations, [44])
    }

    @MainActor
    func testDeletionNoticeOnlyPromisesValidStoredPreviews() {
        let valid = makeImage().jpegData(compressionQuality: 0.75)!
        let invalid = Data("not a photo".utf8)
        let stored = record(identifier: "selected", data: valid)
        let legacy = record(identifier: "selected", data: nil)
        let broken = record(identifier: "selected", data: invalid)
        let unrelated = record(identifier: "other", data: nil)

        XCTAssertEqual(SavedRecordDeletionNotice.message(records: [stored, unrelated], identifier: "selected"),
                       "남긴 글과 작은 사진 미리보기는 기록에 남아요.")
        XCTAssertEqual(SavedRecordDeletionNotice.message(records: [legacy, broken], identifier: "selected"),
                       "남긴 글은 유지되지만, 기록의 사진은 보이지 않을 수 있어요.")
        XCTAssertEqual(SavedRecordDeletionNotice.message(records: [stored, legacy], identifier: "selected"),
                       "남긴 글과 저장된 작은 미리보기는 남아요. 미리보기가 없는 기록에서는 사진이 보이지 않을 수 있어요.")
        XCTAssertNil(SavedRecordDeletionNotice.message(records: [unrelated], identifier: "selected"))
    }

    @MainActor
    private func makeImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80)).image { renderer in
            UIColor.blue.setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        }
    }

    private func record(identifier: String, data: Data?) -> SavedMemoryRecord {
        SavedMemoryRecord(id: UUID(), createdAt: Date(), text: "남긴 기억",
                          photoLocalIdentifier: identifier, capturedDateDescription: nil,
                          photoThumbnailData: data)
    }
}

@MainActor
final class HomePhotoPreviewDiskStoreTests: XCTestCase {
    private func image() -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 600, height: 600), format: format).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 600, height: 600))
        }
    }

    func testDisplayedPreviewSurvivesRelaunchButRejectsAnEditedPhotoRevision() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        HomePhotoPreviewDiskStore(directory: directory).store(.init(image: image(), finalQuality: true),
            identifier: "photo", revision: "original-revision", requestedAt: now)
        let reopened = HomePhotoPreviewDiskStore(directory: directory)
        let restored = try XCTUnwrap(reopened.image(identifier: "photo", revision: "original-revision"))
        XCTAssertEqual(restored.image.size, CGSize(width: 600, height: 600))
        XCTAssertTrue(restored.finalQuality)
        XCTAssertNil(reopened.image(identifier: "photo", revision: "edited-revision"))
        XCTAssertTrue(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    func testExpiredOrNoLongerAccessiblePreviewIsRemoved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let store = HomePhotoPreviewDiskStore(directory: directory)
        store.store(.init(image: image(), finalQuality: false), identifier: "expired", revision: "r", requestedAt: now)
        let later = HomePhotoPreviewDiskStore(directory: directory, now: { now.addingTimeInterval(24 * 60 * 60 + 1) })
        XCTAssertNil(later.image(identifier: "expired", revision: "r"))
        store.store(.init(image: image(), finalQuality: true), identifier: "revoked", revision: "r", requestedAt: now)
        store.remove(identifier: "revoked")
        XCTAssertNil(store.image(identifier: "revoked", revision: "r"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testDiskCacheRemainsBoundedAcrossManyDisplayedPhotos() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(), preview = image()
        let store = HomePhotoPreviewDiskStore(directory: directory)
        for index in 0..<10 {
            store.store(.init(image: preview, finalQuality: true), identifier: "photo-\(index)", revision: "r", requestedAt: now)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 6)
        XCTAssertNotNil(store.image(identifier: "photo-9", revision: "r"))
        XCTAssertNil(store.image(identifier: "photo-0", revision: "r"))
    }

    func testUpdatingPreparedReserveKeepsAllCurrentPhotosAvailableAfterRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(), preview = image()
        let store = HomePhotoPreviewDiskStore(directory: directory)
        for id in ["current-1", "current-2", "current-3", "old-reserve-1", "old-reserve-2", "old-reserve-3"] {
            store.store(.init(image: preview, finalQuality: true), identifier: id, revision: "r", requestedAt: now)
        }
        store.retainCurrentPhotos(["current-1", "current-2", "current-3"])
        for index in 1...3 {
            store.store(.init(image: preview, finalQuality: true), identifier: "next-\(index)",
                        revision: "r", requestedAt: now)
        }
        let reopened = HomePhotoPreviewDiskStore(directory: directory)
        for index in 1...3 {
            XCTAssertNotNil(reopened.image(identifier: "current-\(index)", revision: "r"))
            XCTAssertNotNil(reopened.image(identifier: "next-\(index)", revision: "r"))
            XCTAssertNil(reopened.image(identifier: "old-reserve-\(index)", revision: "r"))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 6)
        XCTAssertNil(reopened.image(identifier: "current-1", revision: "edited"))
    }
}
