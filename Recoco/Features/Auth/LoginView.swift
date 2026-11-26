import SwiftUI
import AuthenticationServices
import Photos
import UIKit

// MARK: - S-03 로그인
// 명세서 §8 S-03
// - 흰 배경, 기존 물범과 브랜드 컬러 유지
// - 선택형 Sign in with Apple, 기기 내 데이터는 계정과 분리
// - 약관 링크
// - 로그인 설정 및 실패 원인을 화면 안에서 안내

struct LoginView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var router: AppRouter
    @StateObject private var vm = AuthViewModel()
    private let onCompleted: (() -> Void)?

    init(onCompleted: (() -> Void)? = nil) {
        self.onCompleted = onCompleted
    }

    private let termsURL = URL(
        string: "https://github.com/iiinsujang/recoco/blob/main/TERMS_OF_SERVICE.md"
    )!
    private let privacyURL = URL(
        string: "https://github.com/iiinsujang/recoco/blob/main/PRIVACY_POLICY.md"
    )!

    var body: some View {
        ZStack {
            Color.rBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                ZStack {
                    RWordmarkHeader()
                    if let onCompleted {
                        HStack {
                            Spacer()
                            Button("닫기", action: onCompleted)
                                .rTextStyle(.subLabel, color: .rTextSecondary)
                                .frame(minWidth: RSize.minTouchTarget, minHeight: RSize.minTouchTarget)
                                .disabled(vm.isLoading)
                                .accessibilityIdentifier("auth.close")
                        }
                        .padding(.horizontal, RLayout.screenInset)
                    }
                }
                GeometryReader { geometry in
                    ScrollView {
                        VStack(spacing: RSpacing.xl) {
                            Spacer(minLength: RSpacing.md)
                            brandSection(illustrationWidth: geometry.size.height < 600 ? RCharacterSize.state : RCharacterSize.hero)
                            if let message = vm.errorMessage {
                                Text(message)
                                    .rTextStyle(.subLabel, color: .rTextSecondary)
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("auth.status")
                                    .accessibilityElement(children: .combine)
                            }
                            authSection
                            if vm.isLoading {
                                ProgressView {
                                    Text("로그인 확인 중…")
                                        .rTextStyle(.caption, color: .rTextSecondary)
                                }
                                .tint(.rTextSecondary)
                                .accessibilityLabel("로그인 확인 중")
                                .accessibilityIdentifier("auth.progress")
                            }
                            RButton(title: onCompleted == nil ? String(localized: "로그인 없이 시작하기") : String(localized: "로그인 없이 계속하기"),
                                    variant: vm.configuration.appleIssue == nil ? .secondary : .primary,
                                    isDisabled: vm.isLoading) {
                                if vm.startLocalSession() { continueAfterLogin() }
                            }
                            .accessibilityIdentifier("auth.local")
                            termsSection
                            Spacer(minLength: RSpacing.md)
                        }
                        .padding(.horizontal, RLayout.screenInset)
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                    }.scrollIndicators(.hidden)
                }
            }
        }
        .interactiveDismissDisabled(vm.isLoading)
    }

    // MARK: - 브랜드 영역

    private func brandSection(illustrationWidth: CGFloat) -> some View {
        VStack(spacing: RSpacing.md) {
            RSealIllustration(pose: .hello, width: illustrationWidth)

            Text("사진 정리,\n가볍게 시작해요.")
                .rTextStyle(.headlineLarge, color: .rTextPrimary)
                .multilineTextAlignment(.center)
                .lineSpacing(RLineSpacing.body)
                .padding(.top, RSpacing.xs)

            Text("사진과 비움 내역은 이 기기에 저장돼요.\n로그인 없이도 모든 기능을 이용할 수 있어요.")
                .rTextStyle(.body, color: .rTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, RSpacing.xxs)
        }
    }

    // MARK: - 인증 버튼 영역

    private var authSection: some View {
        VStack(spacing: RLayout.actionGap) {
            if vm.configuration.appleIssue == nil {
                SignInWithAppleButton(.continue) { request in
                    vm.configureAppleRequest(request)
                } onCompletion: { result in
                    Task {
                        if await vm.signInWithApple(result: result) {
                            continueAfterLogin()
                        }
                    }
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: RSize.buttonHeight)
                .cornerRadius(RRadius.md)
                .disabled(vm.isLoading)
                .accessibilityIdentifier("auth.apple")
            } else if let message = vm.configuration.message {
                Text(message)
                    .rTextStyle(.caption, color: .rTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("auth.configurationStatus")
            }
        }
    }

    // MARK: - 약관 영역

    private var termsSection: some View {
        VStack(spacing: RSpacing.xxs) {
            Text("시작하면 아래 약관에 동의하게 됩니다.")
                .rTextStyle(.caption, color: .rTextSecondary)

            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: RSpacing.xxs))
                : AnyLayout(HStackLayout(spacing: RSpacing.xxs))
            layout {
                Link("서비스 이용약관", destination: termsURL)
                    .rTextStyle(.caption, color: .rTextSecondary)
                    .underline()
                    .frame(minHeight: RSize.minTouchTarget)

                Text("및")
                    .rTextStyle(.caption, color: .rTextSecondary)

                Link("개인정보처리방침", destination: privacyURL)
                    .rTextStyle(.caption, color: .rTextSecondary)
                    .underline()
                    .frame(minHeight: RSize.minTouchTarget)
            }
        }
    }

    private func continueAfterLogin() {
        if let onCompleted {
            onCompleted()
            return
        }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        router.navigateTo(status == .notDetermined ? .photoPermission : .main)
    }
}

#if DEBUG
#Preview {
    LoginView()
        .environmentObject(AppRouter())
}
#endif
