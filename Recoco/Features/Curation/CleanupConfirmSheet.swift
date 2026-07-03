import SwiftUI
import Photos

// MARK: - S-05 정리 확인 바텀시트
// 명세서 §8 S-05
// - 삭제 대상 개수, 대표 사진, 삭제 후보 썸네일, 추천 근거
// - 정리하기 → PHPhotoLibrary 삭제 → 완료
// - 삭제 실패 시 부분 성공 안내
// - 자동 삭제 없음 (명세서 §15.4)

struct CleanupConfirmSheet: View {
    let unit: DecisionUnit
    let onCompleted: (Int) -> Void  // 삭제된 장수 전달

    @Environment(\.dismiss) private var dismiss
    @State private var isDeleting: Bool = false
    @State private var showPartialFailure: Bool = false
    @State private var failureMessage: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // 핸들
            handle

            ScrollView {
                VStack(alignment: .leading, spacing: RSpacing.xl) {
                    // 헤더
                    headerSection

                    // 대표 사진 + 삭제 후보 썸네일
                    photoSection

                    // 추천 근거
                    reasonSection

                    // 안내 문구
                    infoText

                    // 버튼
                    actionButtons
                }
                .padding(RSpacing.md)
            }
        }
        .background(Color.rBackground)
        .alert("일부 사진을 정리하지 못했어요.", isPresented: $showPartialFailure) {
            Button("확인") { dismiss() }
        } message: {
            Text(failureMessage)
        }
    }

    // MARK: - 핸들

    private var handle: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.rBorderStrong)
            .frame(width: 36, height: 4)
            .padding(.top, RSpacing.sm)
            .padding(.bottom, RSpacing.md)
    }

    // MARK: - 헤더

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: RSpacing.xs) {
            Text("이 사진들을 정리할까요?")
                .rTextStyle(.headline)
            Text("대표 사진 한 장은 남아 있어요.")
                .rTextStyle(.body, color: .rTextSecondary)
        }
    }

    // MARK: - 사진 섹션

    private var photoSection: some View {
        VStack(alignment: .leading, spacing: RSpacing.sm) {
            // 대표 사진 (남길 사진)
            HStack(alignment: .top, spacing: RSpacing.sm) {
                VStack(alignment: .leading, spacing: RSpacing.xxs) {
                    Text("남길 사진")
                        .rTextStyle(.caption, color: .rTextTertiary)

                    PHAssetImageView(
                        localIdentifier: unit.displayIdentifier ?? "",
                        targetSize: CGSize(width: 200, height: 200)
                    )
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: RRadius.md))
                    .overlay(
                        RoundedRectangle(cornerRadius: RRadius.md)
                            .strokeBorder(Color.rTextPrimary, lineWidth: 1.5)
                    )
                }

                Spacer()

                // 삭제 후보 썸네일 (최대 3개 표시)
                VStack(alignment: .trailing, spacing: RSpacing.xxs) {
                    Text("정리할 사진 \(unit.removalCount)장")
                        .rTextStyle(.caption, color: .rTextTertiary)

                    HStack(spacing: RSpacing.xs) {
                        ForEach(unit.removalIdentifiers.prefix(3), id: \.self) { id in
                            PHAssetImageView(
                                localIdentifier: id,
                                targetSize: CGSize(width: 80, height: 80)
                            )
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: RRadius.sm))
                            .opacity(0.6)
                        }

                        if unit.removalCount > 3 {
                            ZStack {
                                RoundedRectangle(cornerRadius: RRadius.sm)
                                    .fill(Color.rSurface)
                                    .frame(width: 72, height: 72)
                                Text("+\(unit.removalCount - 3)")
                                    .rTextStyle(.subLabel, color: .rTextSecondary)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 추천 근거

    private var reasonSection: some View {
        VStack(alignment: .leading, spacing: RSpacing.xs) {
            Text("추천 근거")
                .rTextStyle(.caption, color: .rTextTertiary)

            VStack(alignment: .leading, spacing: RSpacing.xxs) {
                ForEach(unit.reasonCodes, id: \.rawValue) { code in
                    HStack(spacing: RSpacing.xs) {
                        Circle()
                            .fill(Color.rTextTertiary)
                            .frame(width: 4, height: 4)
                        Text(code.displayText)
                            .rTextStyle(.subLabel, color: .rTextSecondary)
                    }
                }
            }
        }
        .padding(RSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.rSurface)
        .cornerRadius(RRadius.md)
    }

    // MARK: - 안내 문구

    private var infoText: some View {
        HStack(spacing: RSpacing.xs) {
            Image(systemName: "info.circle")
                .font(.system(size: 13))
                .foregroundColor(.rTextTertiary)
            Text("사진 앱의 최근 삭제된 항목으로 이동해요.")
                .rTextStyle(.caption, color: .rTextTertiary)
        }
    }

    // MARK: - 버튼

    private var actionButtons: some View {
        VStack(spacing: RSpacing.sm) {
            RButton(
                title: "정리하기",
                variant: .primary,
                isLoading: isDeleting
            ) {
                Task { await performDeletion() }
            }

            RButton(title: "취소", variant: .secondary) {
                dismiss()
            }
        }
    }

    // MARK: - 삭제 실행

    private func performDeletion() async {
        isDeleting = true

        let identifiers = unit.removalIdentifiers
        let assets = PHAsset.fetchAssets(
            withLocalIdentifiers: identifiers,
            options: nil
        )

        var successCount = 0
        var failCount = 0

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            }
            successCount = identifiers.count
        } catch {
            // 부분 실패 처리 — 삭제된 것과 안 된 것 분리
            let remaining = PHAsset.fetchAssets(
                withLocalIdentifiers: identifiers,
                options: nil
            )
            successCount = identifiers.count - remaining.count
            failCount = remaining.count
        }

        isDeleting = false

        if failCount > 0 {
            failureMessage = "정리된 사진 \(successCount)장, 정리하지 못한 사진 \(failCount)장이에요."
            showPartialFailure = true
        } else {
            // 전체 성공
            onCompleted(successCount)
            dismiss()
        }
    }
}

// MARK: - S-06 대표 사진 선택
// 명세서 §8 S-06

struct PhotoSelectorView: View {
    let unit: DecisionUnit
    let onSelected: (DecisionUnit) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedIdentifier: String?

    private let columns = [
        GridItem(.flexible(), spacing: RSpacing.xs),
        GridItem(.flexible(), spacing: RSpacing.xs),
        GridItem(.flexible(), spacing: RSpacing.xs)
    ]

    var body: some View {
        ZStack {
            Color.rBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // 네비게이션
                RNavigationBar(
                    title: "남길 사진을 골라주세요.",
                    leadingAction: { dismiss() },
                    trailingTitle: selectedIdentifier != nil ? "선택 완료" : nil,
                    trailingAction: selectedIdentifier != nil ? {
                        var updated = unit
                        updated = DecisionUnit(
                            id: unit.id,
                            type: unit.type,
                            status: unit.status,
                            candidateLocalIdentifiers: unit.candidateLocalIdentifiers,
                            recommendedLocalIdentifier: unit.recommendedLocalIdentifier,
                            selectedLocalIdentifier: selectedIdentifier,
                            reasonCodes: unit.reasonCodes,
                            capturedDateDescription: unit.capturedDateDescription,
                            createdAt: unit.createdAt,
                            completedAt: unit.completedAt,
                            deferredUntil: unit.deferredUntil
                        )
                        onSelected(updated)
                    } : nil
                )
                .padding(.horizontal, RSpacing.xs)

                RDivider()
                    .padding(.top, RSpacing.sm)

                // 사진 그리드
                ScrollView {
                    LazyVGrid(columns: columns, spacing: RSpacing.xs) {
                        ForEach(unit.candidateLocalIdentifiers, id: \.self) { id in
                            photoCell(id: id)
                        }
                    }
                    .padding(RSpacing.md)
                }
            }
        }
        .onAppear {
            selectedIdentifier = unit.recommendedLocalIdentifier
        }
    }

    private func photoCell(_ id: String) -> some View {
        let isSelected = selectedIdentifier == id
        let isRecommended = id == unit.recommendedLocalIdentifier

        return ZStack(alignment: .topLeading) {
            PHAssetImageView(
                localIdentifier: id,
                targetSize: CGSize(width: 150, height: 150)
            )
            .aspectRatio(1, contentMode: .fill)
            .clipShape(RoundedRectangle(cornerRadius: RRadius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: RRadius.sm)
                    .strokeBorder(
                        isSelected ? Color.rTextPrimary : Color.clear,
                        lineWidth: 2
                    )
            )

            if isRecommended {
                RBadge(text: "추천", variant: .detox)
                    .padding(RSpacing.xs)
            }

            // 선택 체크
            if isSelected {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.rTextPrimary)
                            .background(Circle().fill(Color.rBackground))
                            .padding(RSpacing.xs)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedIdentifier = id
            }
        }
        .accessibilityLabel("사진 \(unit.candidateLocalIdentifiers.firstIndex(of: id).map { $0 + 1 } ?? 0)번\(isRecommended ? ", 추천" : "")\(isSelected ? ", 선택됨" : "")")
    }
}

// MARK: - Preview

#if DEBUG
#Preview("정리 확인") {
    CleanupConfirmSheet(unit: .mockCluster) { _ in }
}

#Preview("사진 선택") {
    PhotoSelectorView(unit: .mockCluster) { _ in }
}
#endif
