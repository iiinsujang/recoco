import Photos
import UIKit

/// A small, local preview for a saved memory. This never requests permission or
/// downloads the original; the record is not a backup of the library photo.
@MainActor
enum RecordPhotoPreviewService {
    static func image(for identifier: String) async -> UIImage? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-ui-testing"), identifier.hasPrefix("carousel-test-"),
           arguments.contains("-ui-testing-home-carousel") || arguments.contains("-ui-testing-anniversary") {
            if arguments.contains("-ui-testing-record-preview-unavailable") { return nil }
            return UIImage(named: "recoco_sample_portrait")
        }
        #endif
        guard !Task.isCancelled, let asset = accessibleAsset(identifier) else { return nil }
        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false

        let image = await RecordPhotoPreviewRequest().load(request: { deliver in
            manager.requestImage(for: asset, targetSize: CGSize(width: 320, height: 320),
                                 contentMode: .aspectFit, options: options) { image, info in
                let cancelled = info?[PHImageCancelledKey] as? Bool == true
                let failed = info?[PHImageErrorKey] != nil
                let degraded = info?[PHImageResultIsDegradedKey] as? Bool == true
                deliver(image, !degraded || failed, cancelled)
            }
        }, cancel: { manager.cancelImageRequest($0) })

        // Access may have changed while PhotoKit was preparing the preview.
        guard !Task.isCancelled, accessibleAsset(identifier) != nil else { return nil }
        return image
    }

    private static func accessibleAsset(_ identifier: String) -> PHAsset? {
        guard !identifier.isEmpty else { return nil }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard assets.count == 1, let asset = assets.firstObject,
              asset.localIdentifier == identifier, asset.mediaType == .image,
              !asset.isHidden else { return nil }
        return asset
    }
}

/// PhotoKit can supply a degraded preview without a final image. Keep that
/// usable image on timeout/failure, but discard it when the caller cancels.
@MainActor
final class RecordPhotoPreviewRequest {
    private var continuation: CheckedContinuation<UIImage?, Never>?
    private var timeout: Task<Void, Never>?
    private var requestID: PHImageRequestID?
    private var cancelRequest: ((PHImageRequestID) -> Void)?
    private var bestImage: UIImage?
    private var finished = false

    func load(
        timeoutNanoseconds: UInt64 = 3_000_000_000,
        request: (@escaping (UIImage?, Bool, Bool) -> Void) -> PHImageRequestID,
        cancel: @escaping (PHImageRequestID) -> Void
    ) async -> UIImage? {
        let image: UIImage? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !finished, !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                self.continuation = continuation
                cancelRequest = cancel
                requestID = request { [weak self] image, isFinal, cancelled in
                    DispatchQueue.main.async { [weak self] in
                        self?.receive(image, isFinal: isFinal, cancelled: cancelled)
                    }
                }
                timeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: timeoutNanoseconds) }
                    catch { return }
                    self?.finish(usePreview: true)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(usePreview: false) }
        }
        return Task.isCancelled ? nil : image
    }

    private func receive(_ image: UIImage?, isFinal: Bool, cancelled: Bool) {
        guard !finished else { return }
        guard !cancelled else { finish(usePreview: false); return }
        if let image, image.size.width > 0, image.size.height > 0 {
            let area = image.size.width * image.size.height * image.scale * image.scale
            let bestArea = bestImage.map { $0.size.width * $0.size.height * $0.scale * $0.scale } ?? 0
            if area >= bestArea { bestImage = image }
        }
        if isFinal { finish(usePreview: true) }
    }

    private func finish(usePreview: Bool) {
        guard !finished else { return }
        finished = true
        timeout?.cancel()
        timeout = nil
        let pending = continuation
        continuation = nil
        let result = usePreview ? bestImage : nil
        bestImage = nil
        let identifier = requestID
        requestID = nil
        if let identifier, identifier != PHInvalidImageRequestID { cancelRequest?(identifier) }
        cancelRequest = nil
        pending?.resume(returning: result)
    }
}
