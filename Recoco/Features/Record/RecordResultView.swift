import SwiftUI
import UIKit

// MARK: - S-08 Record 결과 및 저장
// 명세서 §8 S-08
// - AI 내러티브 + 감정 키워드 최대 3개
// - 직접 수정 가능
// - 저장하기 / 문구 복사하기
// - 뒤로가기: 초안 로컬 저장

struct RecordResultView: View {
    @ObservedObject var vm: RecordViewModel
    let onDismiss: () -> Void

    @State private var isEditingNarrative: Bool = false
    @FocusState private var isNarrativeFocused: Bool

    var body: some View {
        ZStack {
            Color.rBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // 네비게이션
                RNavigationBar(
                    title: "기록 결과",
                    leadingAction: {
                        // 뒤로가기: 초안 자동 저장
                        onDismiss()
                    },
                    trailingTitle: isEditingNarrative ? "완료" : nil,
                    trailingAction: isEditingNarrative ? {
                        isEditingNarrative = false
                        isNarrativeFocused = false
                    } : nil
                )
                .padding(.horizontal, RSpacing.xs)

                RDivider()

                ScrollView {
                    VStack(alignment: .leading, spacing: RSpacing.xl) {
                        // 선택된 사진
                        photoSection

                        // 메타 정보 (날짜·위치)
                        if let date = vm.draft.capturedDate {
                            metaSection(date: date, city: vm.draft.cityName)
                        }

                        // NARRATIVE
                        narrativeSection

                        // 하단 액션
                        actionButtons
                    }
                    .padding(RSpacing.md)
                    .padding(.bottom, RSpacing.xxxl)
                }
            }
        }
        .rToast(isPresented: $vm.showToast, message: vm.toastMessage)
    }

    // MARK: - 사진

    private var photoSection: some View {
        VStack(alignment: .leading, spacing: RSpacing.xs) {
            Text("SELECTED MOMENT")
                .rTextStyle(.caption, color: .rTextTertiary)
                .tracking(1)

            PHAssetImageView(
                localIdentifier: vm.unit.displayIdentifier ?? "",
                targetSize: CGSize(width: 400, height: 300)
            )
            .frame(maxWidth: .infinity)
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: RRadius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: RRadius.lg)
                    .strokeBorder(Color.rBorder, lineWidth: 0.5)
            )
        }
    }

    // MARK: - 메타 정보

    private func metaSection(date: String, city: String?) -> some View {
        HStack(spacing: RSpacing.sm) {
            Label(date, systemImage: "calendar")
                .rTextStyle(.caption, color: .rTextSecondary)

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
            // 헤더
            HStack {
                Text("NARRATIVE")
                    .rTextStyle(.caption, color: .rTextTertiary)
                    .tracking(1)

                Spacer()

                if !isEditingNarrative {
                    Button("수정") {
                        isEditingNarrative = true
                        isNarrativeFocused = true
                    }
                    .rTextStyle(.caption, color: .rTextSecondary)
                    .frame(minWidth: RSize.minTouchTarget, minHeight: RSize.minTouchTarget)
                }
            }

            // 키워드 배지
            if !vm.draft.keywords.isEmpty {
                HStack(spacing: RSpacing.xs) {
                    ForEach(vm.draft.keywords.prefix(3), id: \.self) { keyword in
                        RBadge(text: keyword, variant: .keyword)
                    }
                }
            }

            // 내러티브 텍스트 (수정 가능)
            if isEditingNarrative {
                TextEditor(text: Binding(
                    get: { vm.draft.narrative },
                    set: { vm.updateNarrative($0) }
                ))
                .rTextStyle(.body, color: .rTextPrimary)
                .scrollContentBackground(.hidden)
                .padding(RSpacing.sm)
                .frame(minHeight: 120)
                .background(Color.rSurface)
                .cornerRadius(RRadius.md)
                .overlay(
                    RoundedRectangle(cornerRadius: RRadius.md)
                        .strokeBorder(Color.rTextPrimary, lineWidth: 1.5)
                )
                .focused($isNarrativeFocused)
            } else {
                // 키워드 하이라이트가 포함된 텍스트
                HighlightedNarrativeText(
                    narrative: vm.draft.narrative,
                    keywords: vm.draft.keywords
                )
                .padding(RSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.rSurface)
                .cornerRadius(RRadius.md)
            }

            // 생성 엔진 표시
            HStack {
                Spacer()
                Text("✦ GEMINI ENGINE")
                    .rTextStyle(.caption, color: .rTextTertiary)
            }
        }
    }

    // MARK: - 하단 액션

    private var actionButtons: some View {
        VStack(spacing: RSpacing.sm) {
            RButton(
                title: "저장하기",
                variant: .primary,
                isLoading: vm.isSaving,
                isDisabled: vm.isSaved
            ) {
                Task { await vm.saveRecord() }
            }

            RButton(title: "문구 복사하기", variant: .secondary) {
                vm.copyNarrative()
            }
        }
    }
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

        for keyword in keywords {
            var searchRange = attributed.startIndex..<attributed.endIndex
            while let range = attributed[searchRange].range(of: keyword) {
                attributed[range].backgroundColor = UIColor(Color.rHighlight)
                attributed[range].font = UIFont.systemFont(ofSize: 15, weight: .medium)
                searchRange = range.upperBound..<attributed.endIndex
            }
        }

        return attributed
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    let vm = RecordViewModel(unit: .mockRecall, onCompleted: {})
    vm.draft.narrative = "오래된 사진첩 속에서 다시 꺼낸 이 순간. 잊고 있었던 어느 오후의 온도가 천천히 되살아났다."
    vm.draft.keywords = ["고요함", "따뜻함", "회상"]
    vm.draft.capturedDate = "2022-08-14"
    vm.draft.cityName = "서울"

    return RecordResultView(vm: vm, onDismiss: {})
}
#endif
