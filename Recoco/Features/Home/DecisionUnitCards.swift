import SwiftUI
import Photos
import UIKit

// MARK: - 사진 캐러셀
// 영상 프로토타입 기준:
// 중앙 1장 크게 + 양옆 이전/다음 사진 흐리게 노출 (3장 동시 표시)
// 스와이프로 포커스 이동, 포커스 사진이 대표 사진으로 자동 선정

struct PhotoCarousel: View {
    let identifiers: [String]           // 후보 사진 식별자 전체
    @Binding var focusedIndex: Int      // 현재 포커스 인덱스

    // 카드 크기
    private let centerWidth: CGFloat  = UIScreen.main.bounds.width * 0.58
    private let sideWidth: CGFloat    = UIScreen.main.bounds.width * 0.20
    private let cardHeight: CGFloat   = UIScreen.main.bounds.width * 0.78
    private let spacing: CGFloat      = 10

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(visibleIndices, id: \.self) { index in
                    carouselCard(index: index, geo: geo)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: cardHeight)
        .gesture(swipeGesture)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: focusedIndex)
    }

    // MARK: - 표시할 인덱스 (포커스 ±1)

    private var visibleIndices: [Int] {
        let count = identifiers.count
        guard count > 0 else { return [] }
        var indices: [Int] = []
        if focusedIndex - 1 >= 0       { indices.append(focusedIndex - 1) }
        indices.append(focusedIndex)
        if focusedIndex + 1 < count    { indices.append(focusedIndex + 1) }
        return indices
    }

    // MARK: - 카드 뷰

    private func carouselCard(index: Int, geo: GeometryProxy) -> some View {
        let offset   = index - focusedIndex   // -1, 0, 1
        let isFocus  = offset == 0
        let width    = isFocus ? centerWidth : sideWidth
        let xOffset  = cardXOffset(offset: offset)
        let opacity  = isFocus ? 1.0 : 0.45
        let scale    = isFocus ? 1.0 : 0.92

        return PHAssetImageView(
            localIdentifier: identifiers[index],
            targetSize: CGSize(width: 400, height: 500)
        )
        .frame(width: width, height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: RRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: RRadius.lg)
                .strokeBorder(Color.rBorder, lineWidth: 0.5)
        )
        .scaleEffect(scale)
        .opacity(opacity)
        .offset(x: xOffset)
        .zIndex(isFocus ? 1 : 0)
        // 사이드 카드 탭 시 포커스 이동
        .onTapGesture {
            if !isFocus {
                focusedIndex = index
            }
        }
    }

    // MARK: - 카드 X 오프셋 계산

    private func cardXOffset(offset: Int) -> CGFloat {
        let centerX: CGFloat = 0
        switch offset {
        case -1:
            return centerX - (centerWidth / 2) - (sideWidth / 2) - spacing
        case 1:
            return centerX + (centerWidth / 2) + (sideWidth / 2) + spacing
        default:
            return centerX
        }
    }

    // MARK: - 스와이프 제스처

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                let threshold: CGFloat = 40
                if value.translation.width < -threshold,
                   focusedIndex < identifiers.count - 1 {
                    focusedIndex += 1
                } else if value.translation.width > threshold,
                          focusedIndex > 0 {
                    focusedIndex -= 1
                }
            }
    }
}

// MARK: - Cleanup Cluster 카드

struct CleanupClusterCard: View {
    let unit: DecisionUnit
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

            // 캐러셀 + 배지
            ZStack(alignment: .topTrailing) {
                PhotoCarousel(
                    identifiers: unit.candidateLocalIdentifiers,
                    focusedIndex: $focusedIndex
                )

                // HIGH DETOX 배지
                if unit.candidateCount >= 3 {
                    RBadge(text: "HIGH DETOX", variant: .detox)
                        .padding(.top, RSpacing.sm)
                        .padding(.trailing, UIScreen.main.bounds.width * 0.21 + 16)
                }
            }

            // 날짜 | 위치 + 추천 이유
            captionArea

            // 추천 이유 상세
            reasonArea

            // 버튼
            actionButtons
        }
        .onAppear {
            // 추천 대표 사진이 있으면 해당 인덱스로 초기화
            if let recommended = unit.recommendedLocalIdentifier,
               let idx = unit.candidateLocalIdentifiers.firstIndex(of: recommended) {
                focusedIndex = idx
            }
        }
    }

    // MARK: - 날짜 | 위치 캡션

    private var captionArea: some View {
        VStack(alignment: .leading, spacing: RSpacing.xxs) {
            // 포커스된 사진 기준 날짜·위치 표시
            // 실제 구현에서는 PHAsset EXIF 기반으로 교체
            Text("사진 \(unit.candidateCount)장 중 이 한 장을 남기길 추천해요.")
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
        VStack(spacing: RSpacing.sm) {
            RButton(title: "추천대로 정리하기", variant: .primary, action: onConfirm)
            RButton(title: "다른 사진 고르기", variant: .secondary, action: onSelectPhoto)
            Button("나중에", action: onDefer)
                .rTextStyle(.subLabel, color: .rTextTertiary)
                .frame(minHeight: RSize.minTouchTarget)
        }
    }
}

// MARK: - Recall Moment 카드

struct RecallMomentCard: View {
    let unit: DecisionUnit
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

            VStack(spacing: RSpacing.sm) {
                RButton(title: "남기기", variant: .primary, action: onKeep)
                RButton(title: "한 줄 기록하기", variant: .secondary, action: onRecord)
                Button("나중에", action: onDefer)
                    .rTextStyle(.subLabel, color: .rTextTertiary)
                    .frame(minHeight: RSize.minTouchTarget)
            }
        }
    }
}

// MARK: - PHAssetImageView

struct PHAssetImageView: View {
    let localIdentifier: String
    let targetSize: CGSize

    @State private var image: UIImage? = nil
    @State private var isLoading: Bool = true

    var body: some View {
        ZStack {
            Color.rSurface

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if isLoading {
                ProgressView()
                    .tint(.rTextTertiary)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 32))
                    .foregroundColor(.rTextTertiary)
            }
        }
        .task(id: localIdentifier) {
            await loadImage()
        }
    }

    private func loadImage() async {
        guard !localIdentifier.isEmpty else { isLoading = false; return }

        isLoading = true
        image = nil

        let assets = PHAsset.fetchAssets(
            withLocalIdentifiers: [localIdentifier],
            options: nil
        )
        guard let asset = assets.firstObject else { isLoading = false; return }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false

        await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { result, info in
                // 최종 결과만 반영 (opportunistic 중간 저화질 무시)
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                Task { @MainActor in
                    if !isDegraded || self.image == nil {
                        self.image = result
                    }
                    if !isDegraded { self.isLoading = false }
                    continuation.resume()
                }
            }
        }
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
