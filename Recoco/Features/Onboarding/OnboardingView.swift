import SwiftUI
import UIKit

// MARK: - S-02 온보딩
// 명세서 §8 S-02
// - 다크 배경
// - 3장 슬라이드 (스와이프 또는 다음 버튼)
// - Skip: 즉시 S-03
// - 최초 1회만 표시

struct OnboardingView: View {
    @EnvironmentObject private var router: AppRouter
    @StateObject private var vm = OnboardingViewModel()

    var body: some View {
        ZStack {
            Color.rDarkBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Skip 버튼
                HStack {
                    Spacer()
                    Button("Skip") {
                        completeOnboarding()
                    }
                    .rTextStyle(.subLabel, color: .rDarkTextSecondary)
                    .frame(minWidth: RSize.minTouchTarget, minHeight: RSize.minTouchTarget)
                    .padding(.trailing, RSpacing.md)
                }
                .padding(.top, RSpacing.sm)

                // 슬라이드 영역
                TabView(selection: $vm.currentIndex) {
                    ForEach(Array(vm.slides.enumerated()), id: \.offset) { index, slide in
                        OnboardingSlideView(slide: slide)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut(duration: 0.35), value: vm.currentIndex)

                // 페이지 인디케이터 + 버튼
                VStack(spacing: RSpacing.xl) {
                    // 도트 인디케이터
                    HStack(spacing: RSpacing.xs) {
                        ForEach(0..<vm.slides.count, id: \.self) { index in
                            Capsule()
                                .fill(index == vm.currentIndex
                                      ? Color.rDarkTextPrimary
                                      : Color.rDarkTextSecondary.opacity(0.3))
                                .frame(
                                    width: index == vm.currentIndex ? 20 : 6,
                                    height: 6
                                )
                                .animation(.spring(response: 0.3), value: vm.currentIndex)
                        }
                    }

                    // CTA 버튼
                    RDarkButton(
                        title: vm.isLastSlide ? "시작하기" : "다음"
                    ) {
                        if vm.isLastSlide {
                            completeOnboarding()
                        } else {
                            withAnimation {
                                vm.next()
                            }
                        }
                    }
                    .padding(.horizontal, RSpacing.md)
                }
                .padding(.bottom, RSpacing.xxxl)
            }
        }
        // 스와이프로 인덱스 변경 허용
        .gesture(
            DragGesture()
                .onEnded { value in
                    if value.translation.width < -50, !vm.isLastSlide {
                        withAnimation { vm.next() }
                    } else if value.translation.width > 50, vm.currentIndex > 0 {
                        withAnimation { vm.currentIndex -= 1 }
                    }
                }
        )
    }

    private func completeOnboarding() {
        vm.markCompleted()
        withAnimation(.easeOut(duration: 0.3)) {
            router.navigateTo(.login)
        }
    }
}

// MARK: - 슬라이드 단위 뷰

private struct OnboardingSlideView: View {
    let slide: OnboardingSlide

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // 브랜드 심볼 영역
            if UIImage(named: "recoco_symbol") != nil {
                Image("recoco_symbol")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)
                    .padding(.bottom, RSpacing.xxxl)
            } else {
                // 심볼 없을 때 여백 유지
                Spacer().frame(height: 72)
            }

            // 헤드라인
            Text(slide.headline)
                .rTextStyle(.headlineLarge, color: .rDarkTextPrimary)
                .multilineTextAlignment(.center)
                .lineSpacing(RLineSpacing.body)
                .padding(.horizontal, RSpacing.xl)

            // 서브 문구
            Text(slide.subText)
                .rTextStyle(.body, color: .rDarkTextSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(RLineSpacing.body)
                .padding(.horizontal, RSpacing.xl)
                .padding(.top, RSpacing.md)

            Spacer()
        }
    }
}

#if DEBUG
#Preview {
    OnboardingView()
        .environmentObject(AppRouter())
}
#endif
