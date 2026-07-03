import SwiftUI
import AuthenticationServices
import UIKit

// MARK: - S-03 로그인
// 명세서 §8 S-03
// - 다크 배경
// - Sign in with Apple + Google 로그인
// - 약관 링크
// - 로그인 실패 토스트

struct LoginView: View {
    @EnvironmentObject private var router: AppRouter
    @StateObject private var vm = AuthViewModel()

    // 약관 URL (실제 URL로 교체 필요)
    private let termsURL     = URL(string: "https://recoco.app/terms")!
    private let privacyURL   = URL(string: "https://recoco.app/privacy")!

    var body: some View {
        ZStack {
            Color.rDarkBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // 브랜드 영역
                brandSection

                Spacer()

                // 로그인 버튼 영역
                authSection

                // 약관
                termsSection
                    .padding(.bottom, RSpacing.xxxl)
            }
            .padding(.horizontal, RSpacing.md)
        }
        .rToast(
            isPresented: $vm.showToast,
            message: vm.errorMessage ?? "로그인에 실패했습니다. 다시 시도해주세요."
        )
    }

    // MARK: - 브랜드 영역

    private var brandSection: some View {
        VStack(spacing: RSpacing.md) {
            if UIImage(named: "recoco_symbol") != nil {
                Image("recoco_symbol")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 36, height: 36)
            }

            Text("RECOCO")
                .rTextStyle(.wordmark, color: .rDarkTextPrimary)
                .tracking(4)

            Text("하루 한 장을 비우거나\n기록해보세요.")
                .rTextStyle(.headlineLarge, color: .rDarkTextPrimary)
                .multilineTextAlignment(.center)
                .lineSpacing(RLineSpacing.body)
                .padding(.top, RSpacing.xs)

            Text("디지털 미니멀리즘으로 소중한 순간을 기억하세요.")
                .rTextStyle(.body, color: .rDarkTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, RSpacing.xxs)
        }
    }

    // MARK: - 인증 버튼 영역

    private var authSection: some View {
        VStack(spacing: RSpacing.sm) {
            // Sign in with Apple
            SignInWithAppleButton(.continue) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { result in
                Task {
                    await vm.signInWithApple()
                    // 성공 시 라우팅
                    // TODO: 실제 성공 여부를 AuthService 결과로 판단
                    router.navigateTo(.photoPermission)
                }
            }
            .signInWithAppleButtonStyle(.white)
            .frame(height: RSize.buttonHeight)
            .cornerRadius(RRadius.md)
            .disabled(vm.isLoading)

            // Google 로그인
            RGoogleSignInButton(isLoading: vm.isLoading) {
                Task {
                    await vm.signInWithGoogle()
                    // TODO: 실제 성공 여부를 AuthService 결과로 판단
                    router.navigateTo(.photoPermission)
                }
            }
        }
        .padding(.bottom, RSpacing.xl)
    }

    // MARK: - 약관 영역

    private var termsSection: some View {
        VStack(spacing: RSpacing.xxs) {
            Text("계속하면 아래 약관에 동의하게 됩니다.")
                .rTextStyle(.caption, color: .rDarkTextSecondary)

            HStack(spacing: RSpacing.xxs) {
                Link("서비스 이용약관", destination: termsURL)
                    .rTextStyle(.caption, color: .rDarkTextSecondary)
                    .underline()

                Text("및")
                    .rTextStyle(.caption, color: .rDarkTextSecondary)

                Link("개인정보처리방침", destination: privacyURL)
                    .rTextStyle(.caption, color: .rDarkTextSecondary)
                    .underline()
            }
        }
        .padding(.bottom, RSpacing.md)
    }
}

#if DEBUG
#Preview {
    LoginView()
        .environmentObject(AppRouter())
}
#endif
