import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var router: AppRouter
    @StateObject private var vm = OnboardingViewModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 0) {
            header

            TabView(selection: $vm.currentIndex) {
                ForEach(vm.slides.indices, id: \.self) { index in
                    OnboardingSlideView(slide: vm.slides[index], isCurrent: index == vm.currentIndex)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            VStack(spacing: RSpacing.xs) {
                if let message = vm.errorMessage {
                    Text(message)
                        .rTextStyle(.subLabel, color: .rTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("onboarding.startError")
                }
                RButton(title: vm.slides[vm.currentIndex].actionTitle, variant: .primary) {
                    withAnimation(reduceMotion ? nil : RMotion.transition) {
                        if vm.isLastSlide {
                            if let destination = vm.finishIntroduction() {
                                router.navigateTo(destination)
                            }
                        } else {
                            vm.next()
                        }
                    }
                }
                .accessibilityIdentifier("onboarding.next")
                if vm.isLastSlide && !dynamicTypeSize.isAccessibilitySize {
                    OnboardingLegalNotice()
                }
            }
            .padding(.horizontal, RLayout.screenInset)
            .padding(.vertical, RSpacing.md)
        }
        .background(Color.rBackground.ignoresSafeArea())
    }

    private var header: some View {
        HStack(spacing: RSpacing.sm) {
            if vm.currentIndex == 0 {
                RBrandWordmark()
            } else {
                Button {
                    withAnimation(reduceMotion ? nil : RMotion.transition) { vm.currentIndex -= 1 }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.rButton)
                        .frame(minWidth: RSize.minTouchTarget, minHeight: RSize.minTouchTarget)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(Color.rTextPrimary)
                .accessibilityLabel("이전 소개")
                .accessibilityIdentifier("onboarding.previous")
            }

            Spacer()

            if !vm.isLastSlide {
                Button("건너뛰기") {
                    withAnimation(reduceMotion ? nil : RMotion.transition) { vm.skipToLastSlide() }
                }
                .rTextStyle(.subLabel, color: .rTextSecondary)
                .frame(minWidth: RSize.minTouchTarget, minHeight: RSize.minTouchTarget)
                .accessibilityIdentifier("onboarding.skip")
            }
            HStack(spacing: RSpacing.xxs) {
                ForEach(vm.slides.indices, id: \.self) { index in
                    Capsule()
                        .fill(index == vm.currentIndex ? Color.rAccent : Color.rBorderStrong)
                        .frame(width: index == vm.currentIndex ? 19 : 6, height: 6)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("소개 \(vm.currentIndex + 1)/\(vm.slides.count)페이지")
        }
        .padding(.horizontal, RLayout.screenInset)
        .frame(minHeight: RLayout.navigationHeight)
    }
}

private struct OnboardingSlideView: View {
    let slide: OnboardingSlide
    let isCurrent: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RSpacing.sm) {
                OnboardingIllustration(scene: slide.scene, isCurrent: isCurrent)
                    .padding(.bottom, RSpacing.sm)

                Text(slide.headline)
                    .rTextStyle(.headlineLarge)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(slide.subText)
                    .rTextStyle(.body, color: .rTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if slide.scene == .cherishing && dynamicTypeSize.isAccessibilitySize {
                    OnboardingLegalNotice()
                        .padding(.top, RSpacing.md)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: 500, alignment: .leading)
            .padding(.horizontal, RLayout.screenInset)
            .padding(.vertical, RSpacing.sm)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct OnboardingIllustration: View {
    let scene: OnboardingSlide.Scene
    let isCurrent: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var floating = false
    @Environment(\.locale) private var locale

    @ViewBuilder var body: some View {
        switch scene {
        case .floating:
            Image("recoco_intro_water")
                .resizable()
                .scaledToFit()
                .overlay {
                    GeometryReader { geometry in
                        let size = geometry.size
                        Image(RSealIllustration.Pose.floating.rawValue)
                            .resizable()
                            .scaledToFit()
                            .frame(width: size.width * 0.43, height: size.height * 0.54)
                            .rotationEffect(.degrees(floating ? 0 : -4))
                            .offset(y: floating ? -5 : 0)
                            .position(x: size.width * 0.495, y: size.height * 0.50)
                    }
                }
                .onChange(of: isCurrent && !reduceMotion) { enabled in
                    floatIfNeeded(enabled: enabled)
                }
                .onAppear { floatIfNeeded(enabled: isCurrent && !reduceMotion) }
                .accessibilityHidden(true)

        case .choosing:
            VStack(spacing: RSpacing.xxs) {
                Image(RSealIllustration.Pose.choose.rawValue)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1.8, contentMode: .fit)
                    .accessibilityHidden(true)
                Text(verbatim: (locale.quotationBeginDelimiter ?? "“") + CurationReasonCode.exactDuplicate.displayText + (locale.quotationEndDelimiter ?? "”"))
                    .rTextStyle(.caption, color: .rTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(RSpacing.sm)
            .frame(maxWidth: .infinity)
            .background(Color.rBrandMist, in: RoundedRectangle(cornerRadius: RRadius.photo))

        case .cherishing:
            Image("recoco_intro_cherish")
                .resizable()
                .scaledToFit()
                .accessibilityHidden(true)
        }
    }

    private func floatIfNeeded(enabled: Bool) {
        floating = false
        if enabled {
            withAnimation(.easeInOut(duration: 2.15).repeatCount(4, autoreverses: true)) {
                floating = true
            }
        }
    }
}

private struct OnboardingLegalNotice: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: RSpacing.xxs) {
            Text("로그인 없이도 모든 기능을 이용할 수 있어요.")
                .rTextStyle(.caption, color: .rTextSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 0))
                : AnyLayout(HStackLayout(spacing: RSpacing.sm))
            layout {
                Link("서비스 이용약관", destination: URL(string: "https://github.com/iiinsujang/recoco/blob/main/TERMS_OF_SERVICE.md")!)
                    .accessibilityIdentifier("onboarding.terms")
                Link("개인정보처리방침", destination: URL(string: "https://github.com/iiinsujang/recoco/blob/main/PRIVACY_POLICY.md")!)
                    .accessibilityIdentifier("onboarding.privacy")
            }
            .rTextStyle(.caption, color: .rTextSecondary)
            .underline()
            .buttonStyle(OnboardingLegalLinkStyle())
        }
    }
}

private struct OnboardingLegalLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: RSize.minTouchTarget, minHeight: RSize.minTouchTarget)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

#if DEBUG
#Preview {
    OnboardingView()
        .environmentObject(AppRouter())
}
#endif
