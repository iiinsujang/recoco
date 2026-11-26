import SwiftUI
import Photos
import UIKit

/// A role is provided only when the presenting decision identifies that photo.
/// Recall and generic previews keep the neutral title by default.
enum PhotoDetailRole {
    case photo
    case candidate
    case kept

    var label: String {
        switch self {
        case .photo: return String(localized: "사진")
        case .candidate: return String(localized: "비울 후보")
        case .kept: return String(localized: "남길 사진")
        }
    }

    var title: String { self == .photo ? String(localized: "사진 보기") : label }
}

// MARK: - 사진 캐러셀
// 영상 프로토타입 기준:
// 중앙 1장 크게 + 양옆 이전/다음 사진 흐리게 노출 (3장 동시 표시)
// 스와이프로 포커스 이동, 포커스 사진이 대표 사진으로 자동 선정

struct PhotoCarousel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let identifiers: [String]           // 후보 사진 식별자 전체
    @Binding var focusedIndex: Int      // 현재 포커스 인덱스
    var rolesByIdentifier: [String: PhotoDetailRole] = [:]
    @State private var detailSelection: PhotoDetailSelection?

    private var validIndex: Int { min(max(focusedIndex, 0), max(identifiers.count - 1, 0)) }

    var body: some View {
        GeometryReader { geometry in
            TabView(selection: $focusedIndex) {
                ForEach(Array(identifiers.enumerated()), id: \.element) { index, identifier in
                    let role = rolesByIdentifier[identifier] ?? .photo
                    Button { detailSelection = PhotoDetailSelection(id: identifier, role: role) } label: {
                        PHAssetImageView(localIdentifier: identifier,
                                         targetSize: CGSize(width: 800, height: 800), scalesToFit: true)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(RPressFeedbackStyle())
                    .accessibilityLabel("\(role.label) \(index + 1), 크게 보기")
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: identifiers.count > 1 ? .automatic : .never))
            .clipShape(RoundedRectangle(cornerRadius: RRadius.photo))
            .overlay(alignment: .top) {
                if identifiers.count > 1 {
                    Text("\(validIndex + 1)/\(identifiers.count)")
                        .rTextStyle(.caption, color: .white)
                        .padding(.horizontal, RSpacing.sm)
                        .padding(.vertical, RSpacing.xxs)
                        .background(Color.rTextPrimary.opacity(0.75), in: Capsule())
                        .padding(RSpacing.sm)
                        .allowsHitTesting(false)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityIdentifier("decision.photoCarousel")
        .onChange(of: identifiers) { _ in focusedIndex = validIndex }
        .fullScreenCover(item: $detailSelection) { selection in
            PhotoDetailView(localIdentifier: selection.id, role: selection.role)
        }
    }

}

// MARK: - Cleanup Cluster 카드

struct CleanupClusterCard: View {
    let unit: DecisionUnit
    var showsActions = true
    let onConfirm: () -> Void
    let onSelectPhoto: () -> Void
    let onDefer: () -> Void

    // 캐러셀 포커스 인덱스
    // 초기값: 추천 대표 사진 위치
    @State private var focusedIndex: Int = 0

    var body: some View {
        VStack(spacing: RSpacing.xl) {
            // 섹션 라벨
            HStack {
                Text("오늘의 정리")
                    .rTextStyle(.caption, color: .rTextTertiary)
                Spacer()
            }

            PhotoCarousel(
                identifiers: unit.candidateLocalIdentifiers,
                focusedIndex: $focusedIndex,
                rolesByIdentifier: photoRoles
            )

            // 날짜 | 위치 + 추천 이유
            captionArea

            // 추천 이유 상세
            reasonArea

            // 버튼
            if showsActions { actionButtons }
        }
        .onAppear {
            // 추천 대표 사진이 있으면 해당 인덱스로 초기화
            if let recommended = unit.recommendedLocalIdentifier,
               let idx = unit.candidateLocalIdentifiers.firstIndex(of: recommended) {
                focusedIndex = idx
            }
        }
    }

    private var photoRoles: [String: PhotoDetailRole] {
        let removals = Set(unit.removalIdentifiers)
        return unit.candidateLocalIdentifiers.reduce(into: [:]) { roles, identifier in
            if identifier == unit.displayIdentifier {
                roles[identifier] = .kept
            } else if removals.contains(identifier) {
                roles[identifier] = .candidate
            }
        }
    }

    // MARK: - 날짜 | 위치 캡션

    private var captionArea: some View {
        VStack(alignment: .leading, spacing: RSpacing.xxs) {
            // 포커스된 사진 기준 날짜·위치 표시
            // 실제 구현에서는 PHAsset EXIF 기반으로 교체
            Text("사진 \(unit.candidateCount)장 중 한 장을 남겨요.")
                .rTextStyle(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineSpacing(RLineSpacing.body)
        }
    }

    // MARK: - 추천 이유

    private var reasonArea: some View {
        VStack(alignment: .leading, spacing: RSpacing.xxs) {
            ForEach(unit.reasonCodes.prefix(2), id: \.rawValue) { code in
                HStack(spacing: RSpacing.xs) {
                    Circle()
                        .fill(Color.rTextTertiary)
                        .frame(width: 4, height: 4)
                    Text(code.displayText)
                        .rTextStyle(.subLabel, color: .rTextSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 버튼

    private var actionButtons: some View {
        VStack(spacing: RLayout.actionGap) {
            RButton(title: String(localized: "추천대로 정리하기"), variant: .primary, action: onConfirm)
            RButton(title: String(localized: "다른 사진 고르기"), variant: .secondary, action: onSelectPhoto)
            RButton(title: String(localized: "나중에"), variant: .ghost, action: onDefer)
        }
    }
}

// MARK: - Recall Moment 카드

struct RecallMomentCard: View {
    let unit: DecisionUnit
    var showsActions = true
    let onKeep: () -> Void
    let onRecord: () -> Void
    let onDefer: () -> Void

    @State private var focusedIndex: Int = 0

    var body: some View {
        VStack(spacing: RSpacing.xl) {
            HStack {
                Text("오늘의 회상")
                    .rTextStyle(.caption, color: .rTextTertiary)
                Spacer()
            }

            if let dateDesc = unit.capturedDateDescription {
                Text("\(dateDesc)의 사진이에요.")
                    .rTextStyle(.body, color: .rTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Recall도 단일 사진이지만 캐러셀 컨테이너로 통일
            // 후보가 1장이면 양옆 없이 중앙만 표시됨
            PhotoCarousel(
                identifiers: unit.candidateLocalIdentifiers,
                focusedIndex: $focusedIndex
            )

            Text("이날의 공기와 기분이 기억나나요?")
                .rTextStyle(.body, color: .rTextSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineSpacing(RLineSpacing.body)

            if showsActions {
                VStack(spacing: RSpacing.sm) {
                    RButton(title: String(localized: "남기기"), variant: .primary, action: onKeep)
                    RButton(title: String(localized: "기록하기"), variant: .secondary, action: onRecord)
                    RButton(title: String(localized: "나중에"), variant: .ghost, action: onDefer)
                }
            }
        }
    }
}

// MARK: - 오늘의 사진 단위 검토 카드

// Native paging keeps horizontal swipes independent from the parent vertical ScrollView.
struct StackedPhotoCarousel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let identifiers: [String]
    @Binding var focusedIndex: Int
    var photoHeight: CGFloat = 320
    var rolesByIdentifier: [String: PhotoDetailRole] = [:]
    var previewGeneration: UUID? = nil
    var onPreviewStateChange: ((String, UUID, HomePhotoPreviewState) -> Void)? = nil
    @State private var detailSelection: PhotoDetailSelection?
    @State private var readyPreviews = Set<String>()

    private let backplate = Color(hex: "C9E0F8")
    private let frontPlate = Color(hex: "E7F1FC")
    private let counterBackground = Color(hex: "152334").opacity(0.66)

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: RRadius.photo)
                        .fill(backplate)
                        .rotationEffect(.degrees(-4))
                        .padding(6)
                        .accessibilityHidden(true)
                    RoundedRectangle(cornerRadius: RRadius.photo)
                        .fill(frontPlate)
                        .rotationEffect(.degrees(3))
                        .padding(6)
                        .accessibilityHidden(true)
                    TabView(selection: $focusedIndex) {
                        ForEach(Array(identifiers.enumerated()), id: \.element) { index, identifier in
                            let role = rolesByIdentifier[identifier] ?? .photo
                            ZStack {
                                PHAssetImageView(localIdentifier: identifier, targetSize: CGSize(width: 800, height: 800),
                                                 showsRetryButton: true, loadGeneration: previewGeneration,
                                                 onLoadStateChange: { requestID, state in
                                    if state == .ready { readyPreviews.insert(identifier) }
                                    else { readyPreviews.remove(identifier) }
                                    onPreviewStateChange?(identifier, requestID, state)
                                })
                                    .frame(width: geo.size.width, height: geo.size.height)
                                    .clipped()
                                    .contentShape(Rectangle())
                                // Keep Retry outside another Button. Only a visible image opens the viewer.
                                if readyPreviews.contains(identifier) {
                                    Button { detailSelection = PhotoDetailSelection(id: identifier, role: role) } label: {
                                        Color.clear.contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("\(role.label) \(index + 1), 크게 보기")
                                }
                            }
                            .tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: RRadius.photo))
                    .accessibilityIdentifier("home.photoCarousel")
                    Text("\(identifiers.isEmpty ? 0 : focusedIndex + 1)/\(identifiers.count)")
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(counterBackground, in: Capsule())
                        .padding(.top, 12)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("home.photoCounter")
                }
                .overlay(alignment: .leading) {
                    if focusedIndex > 0 { pageArrow(forward: false) }
                }
                .overlay(alignment: .trailing) {
                    if focusedIndex + 1 < identifiers.count { pageArrow(forward: true) }
                }
            }
            .frame(height: photoHeight)

        }
        .fullScreenCover(item: $detailSelection) { selection in
            PhotoDetailView(localIdentifier: selection.id, role: selection.role)
        }
    }

    private func pageArrow(forward: Bool) -> some View {
        Button {
            let target = focusedIndex + (forward ? 1 : -1)
            guard identifiers.indices.contains(target) else { return }
            withAnimation(reduceMotion ? nil : RMotion.transition) {
                focusedIndex = target
            }
        } label: {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.rTextPrimary)
                .frame(width: 32, height: 32)
                .background(Color.white.opacity(0.94), in: Circle())
                .frame(width: RSize.minTouchTarget, height: RSize.minTouchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(RPressFeedbackStyle())
        .accessibilityLabel(forward ? String(localized: "다음 사진") : String(localized: "이전 사진"))
        .accessibilityIdentifier(forward ? "home.nextPhoto" : "home.previousPhoto")
    }
}

struct SinglePhotoDecisionCard: View {
    let identifiers: [String]
    @Binding var focusedIndex: Int
    var photoHeight: CGFloat = 320
    var rolesByIdentifier: [String: PhotoDetailRole]? = nil
    var previewGeneration: UUID? = nil
    var onPreviewStateChange: ((String, UUID, HomePhotoPreviewState) -> Void)? = nil

    var body: some View {
        StackedPhotoCarousel(
            identifiers: identifiers,
            focusedIndex: $focusedIndex,
            photoHeight: photoHeight,
            rolesByIdentifier: rolesByIdentifier ?? identifiers.reduce(into: [:]) { $0[$1] = .candidate },
            previewGeneration: previewGeneration,
            onPreviewStateChange: onPreviewStateChange
        )
    }
}

/// Context grows inline with the photo instead of using a nested modal scroll.
struct PhotoExplanationDetails: View {
    let unit: DecisionUnit
    let onScheduleReview: (Int) -> Void
    @State private var photoContext: PhotoContextMetadata?

    private var isReflection: Bool {
        unit.reasonCodes.contains(where: \.isReflection) || unit.evidence?.reason.isReflection == true
    }

    private var contextCaption: String? {
        guard let context = photoContext, context.identifier == unit.displayIdentifier else { return nil }
        return PhotoContextFormatter.caption(capturedAt: context.capturedAt, place: context.place)
    }

    private var observedDescription: String? {
        guard !isReflection,
              let description = unit.evidence?.photoDescription.trimmingCharacters(in: .whitespacesAndNewlines),
              !description.isEmpty else { return nil }
        return description
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RSpacing.md) {
            Text(unit.selectionDetail)
                .rTextStyle(.body)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("home.evidenceDetail")
            if let reference = unit.comparisonLocalIdentifier, let candidate = unit.displayIdentifier {
                CurationComparisonView(candidateIdentifier: candidate, referenceIdentifier: reference)
            }
            if let observedDescription {
                VStack(alignment: .leading, spacing: RSpacing.xs) {
                    Text("사진 설명")
                        .rTextStyle(.subLabel, color: .rTextSecondary)
                        .accessibilityAddTraits(.isHeader)
                    Text(observedDescription)
                        .rTextStyle(.body, color: .rTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("home.photoDescription")
                }
            }
            if let contextCaption {
                Text(contextCaption)
                    .rTextStyle(.caption, color: .rTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("home.photoCaption")
            }
            Menu {
                Button("내일 다시 확인") { onScheduleReview(1) }
                Button("7일 뒤 다시 확인") { onScheduleReview(7) }
                Button("30일 뒤 다시 확인") { onScheduleReview(30) }
            } label: {
                Label("다시 확인할 날짜 정하기", systemImage: "calendar")
                    .rTextStyle(.subLabel, color: .rAccent)
                    .frame(minHeight: RSize.minTouchTarget)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: unit.displayIdentifier) {
            photoContext = nil
            let service = PhotoMetadataService()
            photoContext = service.localContext(for: unit.displayIdentifier, capturedAt: unit.capturedAt)
            let metadata = await service.context(for: unit.displayIdentifier, capturedAt: unit.capturedAt)
            guard !Task.isCancelled else { return }
            photoContext = metadata
        }
    }
}

struct CurationComparisonView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let candidateIdentifier: String
    let referenceIdentifier: String
    @State private var detailSelection: PhotoDetailSelection?

    var body: some View {
        VStack(alignment: .leading, spacing: RSpacing.xs) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: RSpacing.md))
                : AnyLayout(HStackLayout(spacing: RSpacing.sm))
            layout {
                photo(candidateIdentifier, role: .candidate)
                photo(referenceIdentifier, role: .kept)
            }
            Text("비울 후보만 삭제하고, 남길 사진은 그대로 두어요.")
                .rTextStyle(.caption, color: .rTextSecondary)
        }
        .fullScreenCover(item: $detailSelection) { selection in
            PhotoDetailView(localIdentifier: selection.id, role: selection.role)
        }
    }

    private func photo(_ identifier: String, role: PhotoDetailRole) -> some View {
        Button { detailSelection = PhotoDetailSelection(id: identifier, role: role) } label: {
            VStack(alignment: .leading, spacing: RSpacing.xs) {
                PHAssetImageView(localIdentifier: identifier, targetSize: CGSize(width: 400, height: 400), scalesToFit: true)
                    .rPhotoPreview(height: RSize.photoComparison)
                    .frame(maxWidth: .infinity)
                    .clipped()
                Label(role.label, systemImage: "arrow.up.left.and.arrow.down.right")
                    .rTextStyle(.caption, color: .rTextSecondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(role.label), 크게 보기")
    }
}

// MARK: - PHAssetImageView

struct PHAssetImageView: View {
    @Environment(\.scenePhase) private var scenePhase
    let localIdentifier: String
    let targetSize: CGSize
    var scalesToFit: Bool = false
    var unavailableMessage: String? = nil
    var allowsNetworkAccess: Bool = true
    var showsLoadingIndicator: Bool = true
    var backgroundColor: Color = .rSurface
    // Only opt in when this image is not already inside another Button.
    var showsRetryButton: Bool = false
    // A photo explicitly picked for a memory may be outside limited PhotoKit access.
    // Its bounded local preview remains visible while the library image is unavailable.
    var fallbackImage: UIImage? = nil
    var loadGeneration: UUID? = nil
    var onLoadStateChange: ((UUID, HomePhotoPreviewState) -> Void)? = nil

    @State private var image: UIImage? = nil
    @State private var isLoading: Bool = true
    @State private var isScreenshot = false
    @State private var retryAttempt = 0
    @State private var activeRequestID: UUID?
    #if DEBUG
    @State private var manuallyRetriedFixture = false
    #endif

    private struct Request: Equatable {
        let identifier: String
        let size: CGSize
        let fit: Bool
        let network: Bool
        let attempt: Int
        let generation: UUID?
    }

    var body: some View {
        ZStack {
            backgroundColor

            if let image = image ?? fallbackImage {
                if scalesToFit || isScreenshot {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            } else if isLoading {
                if showsLoadingIndicator {
                    RLoadingIndicator(style: .compact, size: 28, accessibilityLabel: String(localized: "사진 불러오는 중"))
                }
            } else {
                VStack(spacing: RSpacing.xs) {
                    Image(systemName: "photo")
                        .font(.system(size: 24))
                    if unavailableMessage != nil || min(targetSize.width, targetSize.height) >= 300 {
                        Text(unavailableMessage ?? String(localized: "사진을 불러오지 못했어요."))
                            .font(.caption2).multilineTextAlignment(.center)
                    }
                    if showsRetryButton {
                        Button {
                            #if DEBUG
                            manuallyRetriedFixture = true
                            #endif
                            retryAttempt += 1
                        } label: {
                            Text("다시 불러오기")
                                .frame(minHeight: RSize.minTouchTarget)
                                .contentShape(Rectangle())
                        }
                            .buttonStyle(.plain)
                            .font(.callout.weight(.semibold))
                            .foregroundColor(.rAccent)
                            .accessibilityIdentifier("photo.retryLoad")
                    }
                }
                .padding(RSpacing.xs)
                .foregroundColor(.rTextTertiary)
            }
        }
        .task(id: Request(identifier: localIdentifier, size: targetSize, fit: scalesToFit,
                          network: allowsNetworkAccess, attempt: retryAttempt, generation: loadGeneration)) {
            await loadImage()
        }
        .onChange(of: scenePhase) { phase in
            // A retained image must not bypass a changed limited-library scope.
            if phase == .active {
                if HomePhotoPreviewCache.accessibleAsset(localIdentifier) == nil {
                    image = nil
                    let revokedRequest = activeRequestID ?? UUID()
                    activeRequestID = nil
                    isLoading = false
                    onLoadStateChange?(revokedRequest, .failed)
                }
                if image == nil, !isLoading { retryAttempt += 1 }
            }
        }
    }

    @MainActor
    private func loadImage() async {
        let requestID = UUID()
        activeRequestID = requestID
        isLoading = true
        image = nil
        isScreenshot = false
        onLoadStateChange?(requestID, .loading)
        #if DEBUG
        // Isolated UI tests render a bundled sample; never read or change the user's library.
        if ProcessInfo.processInfo.arguments.contains("-ui-testing"), localIdentifier.hasPrefix("carousel-test-") {
            // An activation retry can arrive before XCTest sees the failure.
            // This fixture stays unavailable until the user taps the recovery action.
            let shouldFail = ProcessInfo.processInfo.arguments.contains("-ui-testing-preview-failure")
                && localIdentifier == "carousel-test-1" && !manuallyRetriedFixture
            await Task.yield()
            finishLoading(shouldFail ? nil : UIImage(named: "recoco_sample_portrait"), requestID: requestID)
            return
        }
        #endif
        guard !localIdentifier.isEmpty else { finishLoading(nil, requestID: requestID); return }

        guard let asset = HomePhotoPreviewCache.accessibleAsset(localIdentifier) else {
            finishLoading(nil, requestID: requestID); return
        }
        isScreenshot = asset.mediaSubtypes.contains(.photoScreenshot)
        let contentMode: PHImageContentMode = (scalesToFit || isScreenshot) ? .aspectFit : .aspectFill
        let key = HomePhotoPreviewCache.Key(asset: asset, size: targetSize, fit: contentMode == .aspectFit)
        let accessRevision = HomePhotoPreviewCache.revision
        var usableImage: UIImage?

        func publish(_ result: HomePhotoPreviewResult) {
            guard !Task.isCancelled, activeRequestID == requestID,
                  HomePhotoPreviewCache.isCurrent(key, revision: accessRevision) else { return }
            usableImage = result.image
            image = result.image
            isLoading = false
            onLoadStateChange?(requestID, .ready)
            HomePhotoPreviewCache.store(result, key: key)
        }

        if let cached = HomePhotoPreviewCache.image(for: key) {
            // The lookup revalidated access synchronously; avoid a second
            // PhotoKit round trip before returning to an unchanged carousel.
            usableImage = cached.image
            image = cached.image
            isLoading = false
            onLoadStateChange?(requestID, .ready)
            if cached.finalQuality { return }
        }

        let minimumSize = HomePhotoPreviewQuality.minimumSize(
            original: CGSize(width: asset.pixelWidth, height: asset.pixelHeight),
            target: targetSize, fit: contentMode == .aspectFit)
        let manager = PHImageManager.default()
        func request(network: Bool, firstUsable: Bool) async -> HomePhotoPreviewResult? {
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = network
            options.isSynchronous = false
            return await HomePhotoPreviewRequest().load(
                timeoutNanoseconds: network ? 30_000_000_000 : 1_500_000_000,
                minimumSize: minimumSize, finishOnUsable: firstUsable,
                onUsable: publish, request: { deliver in
                    manager.requestImage(for: asset, targetSize: targetSize, contentMode: contentMode,
                                         options: options) { result, info in
                        let cancelled = info?[PHImageCancelledKey] as? Bool == true
                        let failed = info?[PHImageErrorKey] != nil
                        let degraded = info?[PHImageResultIsDegradedKey] as? Bool == true
                        // Error/cancellation callbacks never make a photo selectable.
                        deliver(failed ? nil : result, !degraded || failed, cancelled)
                    }
                }, cancel: { manager.cancelImageRequest($0) })
        }

        if usableImage == nil {
            if let local = await request(network: false, firstUsable: true) {
                guard HomePhotoPreviewCache.isCurrent(key, revision: accessRevision) else {
                    finishLoading(nil, requestID: requestID); return
                }
                publish(local)
                if local.finalQuality { return }
            }
        }
        guard !Task.isCancelled, activeRequestID == requestID else { return }
        guard HomePhotoPreviewCache.isCurrent(key, revision: accessRevision) else {
            finishLoading(nil, requestID: requestID); return
        }
        if allowsNetworkAccess, let upgraded = await request(network: true, firstUsable: false) {
            publish(upgraded)
        }
        guard HomePhotoPreviewCache.isCurrent(key, revision: accessRevision) else {
            finishLoading(nil, requestID: requestID); return
        }
        finishLoading(usableImage, requestID: requestID)
    }

    @MainActor
    private func finishLoading(_ loadedImage: UIImage?, requestID: UUID) {
        guard !Task.isCancelled, activeRequestID == requestID else { return }
        image = loadedImage
        isLoading = false
        onLoadStateChange?(requestID, (loadedImage ?? fallbackImage) == nil ? .failed : .ready)
    }
}

struct HomePhotoPreviewResult {
    let image: UIImage
    let finalQuality: Bool
}

enum HomePhotoPreviewQuality {
    // PhotoKit's tiny degraded thumbnail is not sufficient for a deletion decision.
    // A 480px preview (or the original dimensions for a smaller source) is clear
    // enough for the carousel while PhotoKit prepares the requested larger image.
    static func minimumSize(original: CGSize, target: CGSize, fit: Bool) -> CGSize {
        let bounds = CGSize(width: min(480, target.width), height: min(480, target.height))
        guard fit, original.width > 0, original.height > 0 else {
            return CGSize(width: min(original.width, bounds.width), height: min(original.height, bounds.height))
        }
        let scale = min(1, min(bounds.width / original.width, bounds.height / original.height))
        return CGSize(width: floor(original.width * scale), height: floor(original.height * scale))
    }

    static func isUsable(_ image: UIImage, minimum: CGSize) -> Bool {
        image.size.width * image.scale >= max(1, minimum.width)
            && image.size.height * image.scale >= max(1, minimum.height)
    }
}

/// Current-access-validated previews. A small protected cache avoids requesting
/// the same displayed photo again on every launch; it is never deletion evidence.
@MainActor
enum HomePhotoPreviewCache {
    struct Key: Hashable {
        let identifier: String
        let modifiedAt: Date?
        let pixelWidth: Int
        let pixelHeight: Int
        let subtypes: UInt
        let width: Int
        let height: Int
        let fit: Bool

        init(asset: PHAsset, size: CGSize, fit: Bool) {
            identifier = asset.localIdentifier
            modifiedAt = asset.modificationDate
            pixelWidth = asset.pixelWidth
            pixelHeight = asset.pixelHeight
            subtypes = asset.mediaSubtypes.rawValue
            width = Int(size.width.rounded(.up))
            height = Int(size.height.rounded(.up))
            self.fit = fit
        }

        var diskRevision: String? {
            guard let modifiedAt else { return nil }
            return "\(modifiedAt.timeIntervalSince1970)|\(pixelWidth)|\(pixelHeight)|\(subtypes)|\(width)|\(height)|\(fit)"
        }
    }

    private struct Entry {
        let value: HomePhotoPreviewResult
        let cost: Int
    }
    private static var entries: [Key: Entry] = [:]
    private static var order: [Key] = []
    private static let disk = HomePhotoPreviewDiskStore(directory:
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RecocoHomePreviews", isDirectory: true))
    private(set) static var revision: UInt64 = 0

    static func invalidateAll() {
        entries.removeAll()
        order.removeAll()
        revision &+= 1
    }

    static func accessibleAsset(_ identifier: String) -> PHAsset? {
        let access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard access == .authorized || access == .limited, !identifier.isEmpty else { return nil }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject,
              asset.localIdentifier == identifier, asset.mediaType == .image, !asset.isHidden else { return nil }
        return asset
    }

    static func isCurrent(_ key: Key, revision expectedRevision: UInt64) -> Bool {
        guard expectedRevision == revision, let asset = accessibleAsset(key.identifier) else { return false }
        return Key(asset: asset, size: CGSize(width: key.width, height: key.height), fit: key.fit) == key
    }

    static func image(for key: Key) -> HomePhotoPreviewResult? {
        guard isCurrent(key, revision: revision) else {
            entries[key] = nil
            order.removeAll { $0 == key }
            disk.remove(identifier: key.identifier)
            return nil
        }
        if entries[key] == nil, key.width >= 600, key.height >= 600,
           let revision = key.diskRevision, let cached = disk.image(identifier: key.identifier, revision: revision) {
            // Current PhotoKit access and revision were checked above, before
            // decoding any retained bitmap. Recheck again at delivery as usual.
            storeInMemory(cached, key: key)
        }
        guard let entry = entries[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return entry.value
    }

    static func store(_ result: HomePhotoPreviewResult, key: Key) {
        guard isCurrent(key, revision: revision) else { return }
        storeInMemory(result, key: key)
        // Only carousel-sized previews, never tiny selection thumbnails or
        // full original files. Encoding/file IO do not hold the UI thread.
        if key.width >= 600, key.height >= 600, let revision = key.diskRevision {
            let disk = disk
            let requestedAt = Date()
            Task.detached(priority: .utility) {
                disk.store(result, identifier: key.identifier, revision: revision, requestedAt: requestedAt)
            }
        }
    }

    /// Warm only the next three verified recommendations while Home is already
    /// usable. No permission request, network download, or selection is made.
    /// The ordinary presenter still rechecks access and the asset revision.
    static func prepare(_ identifiers: [String], preserving currentIdentifiers: [String], canContinue: () -> Bool) async {
        // Preparing a better reserve must not evict an older-but-still-visible
        // carousel. Three current + three future photos fit the existing limit.
        disk.retainCurrentPhotos(Set(currentIdentifiers.prefix(3)))
        let size = CGSize(width: 800, height: 800)
        let manager = PHImageManager.default()
        for identifier in identifiers.prefix(3) {
            guard !Task.isCancelled, canContinue() else { return }
            guard let asset = accessibleAsset(identifier) else { continue }
            let fit = asset.mediaSubtypes.contains(.photoScreenshot)
            let key = Key(asset: asset, size: size, fit: fit)
            if image(for: key) != nil { continue }
            let accessRevision = revision
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false
            options.isSynchronous = false
            let minimum = HomePhotoPreviewQuality.minimumSize(
                original: CGSize(width: asset.pixelWidth, height: asset.pixelHeight), target: size, fit: fit)
            let result = await HomePhotoPreviewRequest().load(timeoutNanoseconds: 1_500_000_000,
                minimumSize: minimum, finishOnUsable: true, onUsable: { _ in }, request: { deliver in
                    manager.requestImage(for: asset, targetSize: size, contentMode: fit ? .aspectFit : .aspectFill,
                                         options: options) { image, info in
                        let cancelled = info?[PHImageCancelledKey] as? Bool == true
                        let failed = info?[PHImageErrorKey] != nil
                        let degraded = info?[PHImageResultIsDegradedKey] as? Bool == true
                        deliver(failed ? nil : image, !degraded || failed, cancelled)
                    }
                }, cancel: { manager.cancelImageRequest($0) })
            guard !Task.isCancelled, canContinue(), isCurrent(key, revision: accessRevision) else { return }
            if let result { store(result, key: key) }
        }
    }

    private static func storeInMemory(_ result: HomePhotoPreviewResult, key: Key) {
        let cost = Int(result.image.size.width * result.image.size.height * result.image.scale * result.image.scale * 4)
        guard cost <= 24 * 1024 * 1024 else { return }
        entries[key] = Entry(value: result, cost: cost)
        order.removeAll { $0 == key }
        order.append(key)
        while entries.count > 8 || entries.values.reduce(0, { $0 + $1.cost }) > 24 * 1024 * 1024 {
            guard !order.isEmpty else { break }
            entries[order.removeFirst()] = nil
        }
    }
}

/// Up to six current/prepared previews, at most4MiB each, expiring after24hours.
/// Atomic protected files in Caches are excluded from device/iCloud backup by
/// the underlying store. The caller must validate current library access first.
final class HomePhotoPreviewDiskStore {
    private struct Preview: Codable {
        let image: Data
        let finalQuality: Bool
        let requestedAt: Date
        let expiresAt: Date
    }
    private let cache: CurationDiskProofCache<Preview>
    private let lock = NSLock()
    private let now: () -> Date
    private let maximumBytes = 4 * 1024 * 1024

    init(directory: URL, now: @escaping () -> Date = Date.init) {
        cache = CurationDiskProofCache(directory: directory, version: 1, capacity: 6)
        self.now = now
        cache.removeValues(olderThan: now().addingTimeInterval(-24 * 60 * 60))
    }

    func image(identifier: String, revision: String) -> HomePhotoPreviewResult? {
        lock.lock(); defer { lock.unlock() }
        guard let value = cache.value(for: identifier, revision: revision) else { return nil }
        guard value.expiresAt > now(), value.image.count <= maximumBytes,
              let image = UIImage(data: value.image), image.size.width > 0, image.size.height > 0 else {
            cache.removeValue(for: identifier)
            return nil
        }
        return HomePhotoPreviewResult(image: image, finalQuality: value.finalQuality)
    }

    func store(_ result: HomePhotoPreviewResult, identifier: String, revision: String, requestedAt: Date) {
        guard !Task.isCancelled, !revision.isEmpty,
              result.image.size.width * result.image.scale <= 2048,
              result.image.size.height * result.image.scale <= 2048,
              let data = result.image.pngData(), data.count <= maximumBytes else { return }
        lock.lock(); defer { lock.unlock() }
        if let previous = cache.value(for: identifier, revision: revision), previous.requestedAt > requestedAt { return }
        cache.removeValues(olderThan: now().addingTimeInterval(-24 * 60 * 60))
        cache.store(Preview(image: data, finalQuality: result.finalQuality, requestedAt: requestedAt,
            expiresAt: requestedAt.addingTimeInterval(24 * 60 * 60)), for: identifier, revision: revision)
    }

    func remove(identifier: String) { cache.removeValue(for: identifier) }

    func retainCurrentPhotos(_ identifiers: Set<String>) { cache.retainIdentifiers(identifiers) }
}

/// Multi-callback PhotoKit boundary. Tiny/degraded images never report ready;
/// a usable local preview survives a later iCloud upgrade failure, but cancellation
/// discards it. Permission/asset validation happens at the presenting boundary.
@MainActor
final class HomePhotoPreviewRequest {
    private var continuation: CheckedContinuation<HomePhotoPreviewResult?, Never>?
    private var timer: Task<Void, Never>?
    private var handle: HomePhotoRequestHandle?
    private var best: HomePhotoPreviewResult?
    private var finished = false

    func load(timeoutNanoseconds: UInt64, minimumSize: CGSize, finishOnUsable: Bool,
              onUsable: @escaping (HomePhotoPreviewResult) -> Void,
              request: @escaping (@escaping (UIImage?, Bool, Bool) -> Void) -> PHImageRequestID,
              cancel: @escaping (PHImageRequestID) -> Void) async -> HomePhotoPreviewResult? {
        let result: HomePhotoPreviewResult? = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<HomePhotoPreviewResult?, Never>) in
                guard !finished, !Task.isCancelled else { continuation.resume(returning: nil); return }
                self.continuation = continuation
                let handle = HomePhotoRequestHandle(cancel: cancel)
                self.handle = handle
                // Start the clock before queueing PhotoKit, whose asynchronous
                // request/cancel methods can themselves stall before returning.
                timer = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: timeoutNanoseconds) }
                    catch { return }
                    self?.finish(keepPreview: true)
                }
                handle.start { request { [weak self] image, isFinal, cancelled in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !self.finished else { return }
                        guard !cancelled else { self.finish(keepPreview: false); return }
                        if let image, HomePhotoPreviewQuality.isUsable(image, minimum: minimumSize) {
                            let value = HomePhotoPreviewResult(image: image, finalQuality: isFinal)
                            let area = image.size.width * image.size.height * image.scale * image.scale
                            let priorArea = self.best.map { $0.image.size.width * $0.image.size.height * $0.image.scale * $0.image.scale } ?? 0
                            if area >= priorArea {
                                self.best = value
                                onUsable(value)
                            }
                            if finishOnUsable { self.finish(keepPreview: true); return }
                        }
                        if isFinal { self.finish(keepPreview: true) }
                    }
                } }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(keepPreview: false) }
        }
        return Task.isCancelled ? nil : result
    }

    private func finish(keepPreview: Bool) {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        timer = nil
        let pending = continuation
        continuation = nil
        let result = keepPreview ? best : nil
        best = nil
        handle?.close()
        handle = nil
        pending?.resume(returning: result)
    }
}

/// Own a PhotoKit request even if its ID arrives after the view has timed out.
/// Both framework calls stay off the main actor; late IDs are cancelled once.
private final class HomePhotoRequestHandle {
    private static let starts: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private static let cancellations: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private let lock = NSLock()
    private var identifier: PHImageRequestID?
    private var closed = false
    private var cancellationScheduled = false
    private let cancel: (PHImageRequestID) -> Void

    init(cancel: @escaping (PHImageRequestID) -> Void) { self.cancel = cancel }

    func start(_ request: @escaping () -> PHImageRequestID) {
        Self.starts.addOperation { [self] in
            lock.lock(); let mayStart = !closed; lock.unlock()
            guard mayStart else { return }
            let id = request()
            lock.lock(); identifier = id; let toCancel = cancellationIdentifier(); lock.unlock()
            scheduleCancellation(toCancel)
        }
    }

    func close() {
        lock.lock(); closed = true; let id = cancellationIdentifier(); lock.unlock()
        scheduleCancellation(id)
    }

    private func cancellationIdentifier() -> PHImageRequestID? {
        guard closed, !cancellationScheduled, let identifier, identifier != PHInvalidImageRequestID else { return nil }
        cancellationScheduled = true
        return identifier
    }

    private func scheduleCancellation(_ identifier: PHImageRequestID?) {
        guard let identifier else { return }
        let cancel = self.cancel
        Self.cancellations.addOperation { cancel(identifier) }
    }
}

private struct PhotoDetailSelection: Identifiable {
    let id: String
    var role: PhotoDetailRole = .photo
}

private struct PhotoDetailView: View {
    let localIdentifier: String
    var role: PhotoDetailRole = .photo
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                RNavigationBar(
                    title: role.title,
                    theme: .inverse,
                    leadingAction: { dismiss() }
                )
                .padding(.horizontal, RSpacing.xs)

                Spacer(minLength: RSpacing.md)

                PHAssetImageView(
                    localIdentifier: localIdentifier,
                    targetSize: CGSize(
                        width: UIScreen.main.bounds.width * UIScreen.main.scale,
                        height: UIScreen.main.bounds.height * UIScreen.main.scale
                    ),
                    scalesToFit: true,
                    showsRetryButton: true
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Spacer(minLength: RSpacing.md)
            }
        }
        .statusBarHidden(true)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Cleanup Cluster - 캐러셀") {
    ScrollView {
        CleanupClusterCard(
            unit: .mockCluster,
            onConfirm: {},
            onSelectPhoto: {},
            onDefer: {}
        )
        .padding()
    }
    .background(Color.rBackground)
}

#Preview("Recall Moment") {
    ScrollView {
        RecallMomentCard(
            unit: .mockRecall,
            onKeep: {},
            onRecord: {},
            onDefer: {}
        )
        .padding()
    }
    .background(Color.rBackground)
}
#endif
