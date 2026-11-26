import SwiftUI
import UIKit

// MARK: - S-08 Record 결과 및 내보내기
// 명세서 §8 S-08
// - AI 내러티브 + 감정 키워드 최대 3개
// - 명시적 저장 → 완료 확인 → 선택적 공유 / 복사
// - 뒤로가기: 초안 로컬 저장

struct RecordResultView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var vm: RecordViewModel
    let onDismiss: () -> Void
    let onOpenRecords: (() -> Void)?
    let returnsAfterSave: Bool

    @State private var showShareSheet: Bool = false
    @State private var shareStatus = ""
    @AccessibilityFocusState private var savedConfirmationFocused: Bool
    @FocusState private var editingNarrative: Bool

    init(vm: RecordViewModel, onDismiss: @escaping () -> Void,
         onOpenRecords: (() -> Void)? = nil, returnsAfterSave: Bool = false) {
        self.vm = vm
        self.onDismiss = onDismiss
        self.onOpenRecords = onOpenRecords
        self.returnsAfterSave = returnsAfterSave
    }

    var body: some View {
        ZStack {
            Color.rBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // 네비게이션
                RNavigationBar(
                    title: vm.isSaved ? String(localized: "저장한 기록") : String(localized: "기록 미리보기"),
                    leadingAction: {
                        // 뒤로가기: 초안 자동 저장
                        guard !vm.isSaving else { return }
                        onDismiss()
                    }
                )
                .disabled(vm.isSaving)

                RDivider()

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: RSpacing.xl) {
                            if vm.isSaved {
                                let layout = dynamicTypeSize.isAccessibilitySize
                                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: RSpacing.md))
                                    : AnyLayout(HStackLayout(alignment: .top, spacing: RSpacing.md))
                                layout {
                                    RSealIllustration(pose: .heart, width: RCharacterSize.companion)
                                    VStack(alignment: .leading, spacing: RSpacing.xs) {
                                        Text("기록을 저장했어요.")
                                            .rTextStyle(.headline)
                                            .accessibilityIdentifier("record.saved")
                                            .accessibilityFocused($savedConfirmationFocused)
                                        Text(vm.hasSavedPhotoPreview ? String(localized: "‘남긴 기록’에서 글과 사진 미리보기를 다시 볼 수 있어요.") : String(localized: "‘남긴 기록’에 글을 보관했어요. 사진 원본은 따로 저장하지 않았어요."))
                                            .rTextStyle(.caption, color: .rTextSecondary)
                                    }
                                }
                                .id("record.status")
                            }
                            // 선택된 사진
                            photoSection

                            // 메타 정보 (날짜·위치)
                            if vm.draft.capturedDate != nil || vm.draft.cityName != nil {
                                metaSection(
                                    date: vm.draft.capturedDate,
                                    city: vm.draft.cityName
                                )
                            }

                            narrativeSection

                            // 하단 액션
                            actionButtons
                        }
                        .rScreenPadding()
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: vm.isSaved) { saved in
                        guard saved else { return }
                        // Home owns the next photo and final batch completion. Close
                        // this preview first; the input closes after its dismissal.
                        if returnsAfterSave {
                            onDismiss()
                            return
                        }
                        proxy.scrollTo("record.status", anchor: .top)
                        savedConfirmationFocused = true
                    }
                }
            }
        }
        .rToast(isPresented: $vm.showToast, message: vm.toastMessage)
        .interactiveDismissDisabled(vm.isSaving)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("완료") { editingNarrative = false }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ActivityShareSheet(items: [vm.shareText]) { completed, error in
                shareStatus = completed ? String(localized: "공유했어요. 저장한 기록은 그대로 있어요.")
                    : error == nil ? String(localized: "공유를 취소했어요. 기록은 저장되어 있어요.")
                    : String(localized: "공유하지 못했어요. 저장한 기록에서 다시 시도할 수 있어요.")
            }
        }
    }

    // MARK: - 사진

    private var photoSection: some View {
        VStack(alignment: .leading, spacing: RSpacing.xs) {
            Text(vm.isSaved ? String(localized: "기록한 사진") : String(localized: "선택한 사진"))
                .rTextStyle(.caption, color: .rTextTertiary)

            Group {
                if let data = vm.draft.photoThumbnailData, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    PHAssetImageView(
                        localIdentifier: vm.unit.displayIdentifier ?? "",
                        targetSize: CGSize(width: 400, height: 300),
                        scalesToFit: true
                    )
                }
            }
            .rPhotoPreview()
        }
    }

    // MARK: - 메타 정보

    private func metaSection(date: String?, city: String?) -> some View {
        HStack(spacing: RSpacing.sm) {
            if let date {
                Label(date, systemImage: "calendar")
                    .rTextStyle(.caption, color: .rTextSecondary)
            }

            if let city {
                Label(city, systemImage: "mappin")
                    .rTextStyle(.caption, color: .rTextSecondary)
            }

            Spacer()
        }
    }

    // MARK: - NARRATIVE 섹션

    private var narrativeSection: some View {
        VStack(alignment: .leading, spacing: RSpacing.md) {
            if !vm.isSaved {
                Text("남길 기록 · 수정할 수 있어요")
                    .rTextStyle(.caption, color: .rTextTertiary)
            }

            if vm.isSaved {
                HighlightedNarrativeText(narrative: vm.shareText, keywords: vm.draft.keywords)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("record.savedText")
            } else {
                TextEditor(text: Binding(get: { vm.draft.narrative }, set: { vm.updateNarrative($0) }))
                    .rTextStyle(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 140)
                    .padding(RSpacing.sm)
                    .background(Color.rSurface)
                    .cornerRadius(RRadius.md)
                    .overlay(RoundedRectangle(cornerRadius: RRadius.md)
                        .strokeBorder(editingNarrative ? Color.rAccent : .rBorder, lineWidth: 1))
                    .accessibilityLabel("남길 기록")
                    .focused($editingNarrative)
                    .disabled(vm.isSaving)
            }

            if vm.usedLocalFallback {
                Label("내가 쓴 기록", systemImage: "iphone")
                    .rTextStyle(.caption, color: .rTextTertiary)
                    .accessibilityLabel("AI가 다듬지 않은 내가 쓴 기록")
            }

        }
    }

    // MARK: - 하단 액션

    private var actionButtons: some View {
        VStack(spacing: RLayout.actionGap) {
            if vm.isSaved {
                RActionPair {
                    RButton(title: String(localized: "복사하기"), variant: .secondary) { vm.copyNarrative() }
                } primary: {
                    RButton(title: String(localized: "공유하기"), variant: .primary) { showShareSheet = true }
                }
                if !shareStatus.isEmpty {
                    Text(shareStatus).rTextStyle(.caption, color: .rTextSecondary)
                }
                RButton(title: onOpenRecords == nil ? String(localized: "완료") : String(localized: "남긴 기록 보기"), variant: .ghost) {
                    onOpenRecords?()
                    onDismiss()
                }
                    .accessibilityIdentifier("record.done")
            } else {
                Text(vm.photoPreviewUnavailable ? String(localized: "아직 초안이에요. 글만 저장하면 사진 미리보기는 보관되지 않아요.") : String(localized: "아직 초안이에요. 저장하면 글과 작은 사진 미리보기를 이 기기에 보관해요."))
                    .rTextStyle(.caption, color: .rTextSecondary)
                if let error = vm.saveError {
                    RInlineFeedback(message: error, tone: .error)
                        .accessibilityIdentifier("record.saveError")
                }
                RButton(title: vm.saveError == nil ? String(localized: "기록 저장하기") : String(localized: "다시 저장하기"), variant: .primary,
                        isLoading: vm.isSaving, isDisabled: vm.draft.narrative.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    editingNarrative = false
                    Task { await vm.saveRecord() }
                }
                .accessibilityIdentifier("record.save")
                if vm.photoPreviewUnavailable {
                    if vm.saveError == nil {
                        Text("사진 미리보기를 불러오지 못했어요. 글만 저장할 수도 있어요.")
                            .rTextStyle(.caption, color: .rTextSecondary)
                    }
                    RButton(title: String(localized: "글만 저장하기"), variant: .ghost,
                            isDisabled: vm.isSaving || vm.draft.narrative.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                        editingNarrative = false
                        Task { await vm.saveRecord(allowTextOnly: true) }
                    }
                    .accessibilityIdentifier("record.saveTextOnly")
                }
            }
        }
    }

}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let onComplete: (Bool, Error?) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: items,
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { _, completed, _, error in
            Task { @MainActor in onComplete(completed, error) }
        }
        return controller
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}

// MARK: - 키워드 하이라이트 텍스트
// 내러티브 문장 내 키워드에 배지 스타일 적용

struct HighlightedNarrativeText: View {
    let narrative: String
    let keywords: [String]

    var body: some View {
        // AttributedString으로 키워드 강조
        Text(buildAttributedString())
            .rTextStyle(.body, color: .rTextPrimary)
            .lineSpacing(RLineSpacing.body)
    }

    private func buildAttributedString() -> AttributedString {
        var attributed = AttributedString(narrative)

        for keyword in keywords where !keyword.isEmpty {
            var searchRange = attributed.startIndex..<attributed.endIndex
            while let range = attributed[searchRange].range(of: keyword) {
                attributed[range].backgroundColor = UIColor(Color.rHighlight)
                searchRange = range.upperBound..<attributed.endIndex
            }
        }

        return attributed
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    let vm = RecordViewModel(unit: .mockRecall, onCompleted: { _ in })
    vm.draft.narrative = "오래된 사진첩 속에서 다시 꺼낸 이 순간. 잊고 있었던 어느 오후의 온도가 천천히 되살아났다."
    vm.draft.keywords = ["고요함", "따뜻함", "회상"]
    vm.draft.capturedDate = "2022-08-14"
    vm.draft.cityName = "서울"

    return RecordResultView(vm: vm, onDismiss: {})
}
#endif
