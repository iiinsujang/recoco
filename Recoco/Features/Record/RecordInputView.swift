import SwiftUI

// MARK: - S-07 Record 작성
// 명세서 §8 S-07
// - 사진 + MEANING 입력
// - 기록 만들기 → AI 생성 → S-08
// - 나중에 → 초안 유지, 홈 복귀
// - Keep과 Record는 별개 (강제 진입 없음)

struct RecordInputView: View {
    @StateObject private var vm: RecordViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showResult: Bool = false
    @FocusState private var isMeaningFocused: Bool

    init(unit: DecisionUnit, onCompleted: @escaping () -> Void) {
        _vm = StateObject(wrappedValue: RecordViewModel(
            unit: unit,
            onCompleted: onCompleted
        ))
    }

    var body: some View {
        ZStack {
            Color.rBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // 네비게이션
                RNavigationBar(
                    title: "기록하기",
                    leadingAction: {
                        // 뒤로가기: 초안 유지 (자동 저장됨)
                        dismiss()
                    }
                )
                .padding(.horizontal, RSpacing.xs)

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
                    .padding(RSpacing.md)
                    .padding(.bottom, RSpacing.xxxl)
                }
            }
        }
        .rToast(isPresented: $vm.showToast, message: vm.toastMessage)
        // S-08: 생성 성공 시 결과 화면으로
        .fullScreenCover(isPresented: $showResult) {
            RecordResultView(vm: vm) {
                showResult = false
                dismiss()
            }
        }
        .onChange(of: vm.generationState) { state in
            if case .success = state {
                showResult = true
            }
        }
    }

    // MARK: - 선택된 사진

    private var selectedPhotoSection: some View {
        VStack(alignment: .leading, spacing: RSpacing.xs) {
            Text("SELECTED MOMENT")
                .rTextStyle(.caption, color: .rTextTertiary)
                .tracking(1)

            PHAssetImageView(
                localIdentifier: vm.unit.displayIdentifier ?? "",
                targetSize: CGSize(width: 400, height: 300)
            )
            .frame(maxWidth: .infinity)
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: RRadius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: RRadius.lg)
                    .strokeBorder(Color.rBorder, lineWidth: 0.5)
            )
        }
    }

    // MARK: - MEANING 입력

    private var meaningSection: some View {
        VStack(alignment: .leading, spacing: RSpacing.sm) {
            Text("MEANING")
                .rTextStyle(.caption, color: .rTextTertiary)
                .tracking(1)

            ZStack(alignment: .topLeading) {
                // placeholder
                if vm.draft.meaning.isEmpty {
                    Text("이 순간은 당신에게 어떤 의미인가요?")
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
                .frame(minHeight: 100)
                .focused($isMeaningFocused)
            }
            .background(Color.rSurface)
            .cornerRadius(RRadius.md)
            .overlay(
                RoundedRectangle(cornerRadius: RRadius.md)
                    .strokeBorder(
                        isMeaningFocused ? Color.rTextPrimary : Color.rBorder,
                        lineWidth: isMeaningFocused ? 1.5 : 1
                    )
            )
            .animation(.easeInOut(duration: 0.15), value: isMeaningFocused)

            Text("길게 쓰지 않아도 괜찮아요.")
                .rTextStyle(.caption, color: .rTextTertiary)
        }
    }

    // MARK: - 액션 버튼

    private var actionButtons: some View {
        VStack(spacing: RSpacing.sm) {
            let isGenerating = {
                if case .generating = vm.generationState { return true }
                return false
            }()

            RButton(
                title: isGenerating ? "기억을 분석하는 중..." : "기록 만들기",
                variant: .primary,
                isLoading: isGenerating,
                isDisabled: vm.draft.meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ) {
                isMeaningFocused = false
                Task { await vm.generateNarrative() }
            }

            // 실패 상태 안내
            if case .failed = vm.generationState {
                HStack(spacing: RSpacing.xs) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 13))
                        .foregroundColor(.rDestructive)
                    Text("기록을 만들지 못했어요.")
                        .rTextStyle(.caption, color: .rDestructive)
                    Spacer()
                    Button("다시 시도") {
                        Task { await vm.retryGeneration() }
                    }
                    .rTextStyle(.caption, color: .rTextPrimary)
                }
                .padding(.horizontal, RSpacing.xs)
            }

            // 오프라인 상태 안내
            if case .pendingOffline = vm.generationState {
                HStack(spacing: RSpacing.xs) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 13))
                        .foregroundColor(.rTextTertiary)
                    Text("인터넷 연결 후 기록을 만들 수 있어요.")
                        .rTextStyle(.caption, color: .rTextTertiary)
                }
                .padding(.horizontal, RSpacing.xs)
            }

            Button("나중에 할게요") {
                dismiss()
            }
            .rTextStyle(.subLabel, color: .rTextTertiary)
            .frame(minHeight: RSize.minTouchTarget)
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    RecordInputView(unit: .mockRecall) {}
}
#endif
