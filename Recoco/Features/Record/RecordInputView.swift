import SwiftUI

// MARK: - S-07 Record 작성
// 명세서 §8 S-07
// - 사진 + MEANING 입력
// - 기록 만들기 → AI 생성 → S-08
// - 나중에 → 초안 유지, 홈 복귀
// - Keep과 Record는 별개 (강제 진입 없음)

struct RecordInputView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var vm: RecordViewModel
    @Environment(\.dismiss) private var dismiss

    private let selectedImage: UIImage?
    private let onOpenRecords: (() -> Void)?
    private let returnsAfterSave: Bool
    @State private var showResult: Bool = false
    @FocusState private var isMeaningFocused: Bool

    init(unit: DecisionUnit, selectedImage: UIImage? = nil,
         onOpenRecords: (() -> Void)? = nil,
         returnsAfterSave: Bool = false,
         onCompleted: @escaping (SavedMemoryRecord) -> Void) {
        self.selectedImage = selectedImage
        self.onOpenRecords = onOpenRecords
        self.returnsAfterSave = returnsAfterSave
        _vm = StateObject(wrappedValue: RecordViewModel(
            unit: unit,
            selectedImage: selectedImage,
            onCompleted: onCompleted
        ))
    }

    var body: some View {
        ZStack {
            Color.rBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // 네비게이션
                RNavigationBar(
                    title: String(localized: "기록하기"),
                    leadingAction: {
                        // 뒤로가기: 초안 유지 (자동 저장됨)
                        guard !vm.isSaving else { return }
                        vm.cancelPendingWork()
                        dismiss()
                    }
                )
                .disabled(vm.isSaving)

                RDivider()

                ScrollView {
                    VStack(alignment: .leading, spacing: RSpacing.xl) {
                        // 선택된 사진
                        selectedPhotoSection

                        // MEANING 입력
                        meaningSection

                        // 액션 버튼
                        actionButtons
                    }
                    .rScreenPadding()
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("완료") { isMeaningFocused = false }
            }
        }
        .rToast(isPresented: $vm.showToast, message: vm.toastMessage)
        .interactiveDismissDisabled(vm.isSaving)
        .onDisappear {
            if !showResult { vm.cancelPendingWork() }
        }
        // S-08: 생성 성공 시 결과 화면으로
        .fullScreenCover(isPresented: $showResult, onDismiss: {
            // Finish the nested presentation before dismissing this input.
            // The parent handles any requested library route after its cover closes.
            if vm.isSaved { dismiss() }
        }) {
            RecordResultView(vm: vm, onDismiss: {
                showResult = false
            }, onOpenRecords: onOpenRecords, returnsAfterSave: returnsAfterSave)
        }
        .task {
            async let metadata: Void = vm.loadPhotoMetadata()
            async let preview: Void = vm.loadPhotoPreview()
            _ = await (metadata, preview)
        }
    }

    // MARK: - 선택된 사진

    private var selectedPhotoSection: some View {
        VStack(alignment: .leading, spacing: RSpacing.xs) {
            Text("선택한 사진")
                .rTextStyle(.caption, color: .rTextTertiary)

            Group {
                if let selectedImage {
                    Image(uiImage: selectedImage).resizable().scaledToFit()
                } else {
                    PHAssetImageView(localIdentifier: vm.unit.displayIdentifier ?? "", targetSize: CGSize(width: 400, height: 300), scalesToFit: true,
                                     fallbackImage: vm.draft.photoThumbnailData.flatMap { UIImage(data: $0) })
                }
            }
            .rPhotoPreview()

            if let locationHint = vm.photoLocationHint {
                Label("장소 단서 · \(locationHint) 근처", systemImage: "mappin.and.ellipse")
                    .rTextStyle(.caption, color: .rTextTertiary)
                    .accessibilityLabel("촬영 장소 추정, \(locationHint) 근처")
            }
        }
    }

    // MARK: - MEANING 입력

    private var meaningSection: some View {
        VStack(alignment: .leading, spacing: RSpacing.sm) {
            HStack {
                Text("나의 한 줄")
                    .rTextStyle(.caption, color: .rTextTertiary)
                    Spacer()
                if isGenerating {
                    RLoadingIndicator(size: RCharacterSize.companion * 0.75)
                        .frame(width: RCharacterSize.companion)
                        .accessibilityHidden(true)
                } else {
                    RSealIllustration(pose: .writing, width: RCharacterSize.companion)
                }
            }

            ZStack(alignment: .topLeading) {
                // placeholder
                if vm.draft.meaning.isEmpty {
                    Text("이 사진에서 기억하고 싶은 순간이 있나요?")
                        .rTextStyle(.body, color: .rTextTertiary)
                        .padding(RSpacing.md)
                        .allowsHitTesting(false)
                }

                TextEditor(text: Binding(
                    get: { vm.draft.meaning },
                    set: { vm.onMeaningChanged($0) }
                ))
                .rTextStyle(.body, color: .rTextPrimary)
                .scrollContentBackground(.hidden)
                .padding(RSpacing.sm)
                .frame(minHeight: RSize.inputMinHeight)
                .focused($isMeaningFocused)
                .accessibilityLabel("나의 한 줄")
            }
            .background(Color.rSurface)
            .cornerRadius(RRadius.md)
            .overlay(
                RoundedRectangle(cornerRadius: RRadius.md)
                    .strokeBorder(
                        isMeaningFocused ? Color.rAccent : Color.rBorder,
                        lineWidth: isMeaningFocused ? 1.5 : 1
                    )
            )
            .animation(reduceMotion ? nil : RMotion.feedback, value: isMeaningFocused)

        }
    }

    // MARK: - 액션 버튼

    private var isGenerating: Bool {
        if case .generating = vm.generationState { return true }
        return false
    }

    private var needsRetry: Bool {
        switch vm.generationState {
        case .failed, .pendingOffline: return true
        default: return false
        }
    }

    private var actionButtons: some View {
        VStack(spacing: RSpacing.sm) {
            if vm.draft.hasMeaningChangesAfterEditing == true {
                Text("미리보기에서 수정한 글은 그대로예요. 이어서 다듬을 수 있어요.")
                    .rTextStyle(.caption, color: .rTextSecondary)
                    .accessibilityIdentifier("record.editedPreviewPreserved")
            }
            if case .failed = vm.generationState {
                RInlineFeedback(message: String(localized: "기록을 만들지 못했어요. 적어둔 글은 그대로예요."), tone: .error)
            }
            if case .pendingOffline = vm.generationState {
                RInlineFeedback(message: String(localized: "인터넷 연결을 확인한 뒤 다시 시도해주세요."))
            }
            RButton(
                title: isGenerating ? String(localized: "기록을 준비하고 있어요") : needsRetry ? String(localized: "다시 시도하기") : String(localized: "기록 미리보기"),
                variant: .primary,
                isLoading: isGenerating,
                isDisabled: !vm.canOpenPreview
            ) {
                isMeaningFocused = false
                Task {
                    if needsRetry { await vm.retryGeneration() }
                    else { await vm.generateNarrative() }
                    // Existing edited previews may keep the same success state.
                    // Opening them must not depend on a new state transition.
                    if case .success = vm.generationState { showResult = true }
                }
            }
        }
    }

}

// MARK: - Preview

#if DEBUG
#Preview {
    RecordInputView(unit: .mockRecall) { _ in }
}
#endif
