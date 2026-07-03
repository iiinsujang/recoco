import SwiftUI
import UIKit

// MARK: - S-01 스플래시
// 명세서 §8 S-01
// - 다크 배경
// - RECOCO 워드마크 중앙 표시
// - 최대 1.5초, 초기화 완료 시 즉시 분기

struct SplashView: View {
    @EnvironmentObject private var router: AppRouter

    // Mock: 실제 구현에서는 AuthService, PhotoKitService로 교체
    var isLoggedIn: Bool = false
    var hasCompletedOnboarding: Bool = false
    var photoAuthStatus: PhotoAuthStatus = .notDetermined

    @State private var opacity: Double = 0

    var body: some View {
        ZStack {
            Color.rDarkBackground.ignoresSafeArea()

            VStack(spacing: RSpacing.sm) {
                // 브랜드 심볼: 에셋 없으면 공백 유지 (SF Symbol 임의 사용 금지)
                if UIImage(named: "recoco_symbol") != nil {
                    Image("recoco_symbol")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 32, height: 32)
                }

                Text("RECOCO")
                    .rTextStyle(.wordmark, color: .rDarkTextPrimary)
                    .tracking(4)
            }
            .opacity(opacity)
        }
        .onAppear {
            // 페이드인
            withAnimation(.easeIn(duration: 0.4)) {
                opacity = 1
            }
            // 초기화 완료 후 즉시 분기 (최대 1.5초)
            resolveRoute()
        }
    }

    private func resolveRoute() {
        // TODO: 실제 구현에서는 async/await로 AuthService 상태 확인
        let delay = hasCompletedOnboarding && isLoggedIn ? 0.6 : 1.0

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            withAnimation(.easeOut(duration: 0.3)) {
                router.resolveInitialRoute(
                    isLoggedIn: isLoggedIn,
                    hasCompletedOnboarding: hasCompletedOnboarding,
                    photoAuthStatus: photoAuthStatus
                )
            }
        }
    }
}

#if DEBUG
#Preview("첫 실행") {
    SplashView(
        isLoggedIn: false,
        hasCompletedOnboarding: false,
        photoAuthStatus: .notDetermined
    )
    .environmentObject(AppRouter())
}

#Preview("재실행 (로그인 유지)") {
    SplashView(
        isLoggedIn: true,
        hasCompletedOnboarding: true,
        photoAuthStatus: .authorized
    )
    .environmentObject(AppRouter())
}
#endif
