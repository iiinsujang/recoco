import FirebaseCore
import SwiftUI

// MARK: - RecocoApp
// 앱 진입점 및 최상위 라우팅

@main
struct RecocoApp: App {
    @StateObject private var router = AppRouter()

    init() {
        if Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil {
            FirebaseApp.configure()
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(router)
        }
    }
}

// MARK: - RootView: 라우트에 따라 화면 전환

struct RootView: View {
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        ZStack {
            switch router.route {
            case .splash:
                SplashView()
                    .transition(.opacity)

            case .onboarding:
                OnboardingView()
                    .transition(.opacity)

            case .login:
                LoginView()
                    .transition(.opacity)

            case .photoPermission:
                PhotoPermissionView()
                    .transition(.opacity)

            case .main:
                // S-04 이후 메인 탭 구조 (다음 단계에서 구현)
                MainTabView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: router.route)
    }
}

// MARK: - 메인 플레이스홀더 (S-04 구현 전 임시)

struct MainPlaceholderView: View {
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        ZStack {
            Color.rBackground.ignoresSafeArea()

            VStack(spacing: RSpacing.md) {
                Text("RECOCO")
                    .rTextStyle(.wordmark)
                    .tracking(2)

                Text("홈 화면 준비 중")
                    .rTextStyle(.body, color: .rTextSecondary)

                // 개발 편의용: 온보딩으로 되돌아가기
                #if DEBUG
                RButton(title: "← 처음으로 (Debug)", variant: .secondary) {
                    UserDefaults.standard.removeObject(forKey: "recoco_onboarding_completed")
                    router.navigateTo(.splash)
                }
                .padding(.horizontal, RSpacing.xl)
                .padding(.top, RSpacing.xl)
                #endif
            }
        }
    }
}

#if DEBUG
#Preview("Splash → Onboarding") {
    RootView()
        .environmentObject({
            let r = AppRouter()
            r.route = .splash
            return r
        }())
}

#Preview("Login") {
    RootView()
        .environmentObject({
            let r = AppRouter()
            r.route = .login
            return r
        }())
}

#Preview("Photo Permission") {
    RootView()
        .environmentObject({
            let r = AppRouter()
            r.route = .photoPermission
            return r
        }())
}
#endif
