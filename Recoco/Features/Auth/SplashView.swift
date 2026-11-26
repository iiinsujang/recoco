import FirebaseAuth
import FirebaseCore
import Photos
import SwiftUI
import UIKit

// MARK: - S-01 스플래시
// 명세서 §8 S-01
// - 흰 배경, 기존 물범과 브랜드 컬러 유지
// - RECOCO 워드마크 중앙 표시
// - 최대 1.5초, 초기화 완료 시 즉시 분기

struct SplashView: View {
    @EnvironmentObject private var router: AppRouter

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var opacity: Double = 0

    var body: some View {
        ZStack {
            Color.rBackground.ignoresSafeArea()

            VStack(spacing: RSpacing.xl) {
                RBrandWordmark()
                RSealIllustration(pose: .hello, width: 250)
                Text("쌓인 사진, 세 장부터 가볍게.")
                    .rTextStyle(.body, color: .rTextPrimary)
            }
            .opacity(opacity)
        }
        .onAppear {
            // 페이드인
            withAnimation(reduceMotion ? nil : RMotion.transition) {
                opacity = 1
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await resolveRoute()
        }
    }

    @MainActor
    private func resolveRoute() async {
        let completedOnboarding = UserDefaults.standard.bool(
            forKey: "recoco_onboarding_completed"
        )
        let signedIn = FirebaseApp.app() != nil && Auth.auth().currentUser != nil
        let delay: UInt64 = completedOnboarding && (signedIn || LocalSession.isActive)
            ? 300_000_000 : 700_000_000

        // Cancel when the scene becomes inactive or Splash leaves the tree.
        // A delayed callback must not overwrite a newer route after returning.
        do { try await Task.sleep(nanoseconds: delay) }
        catch { return }
        guard !Task.isCancelled, scenePhase == .active, router.route == .splash else { return }

        // Permission and session state can change while the app is inactive.
        withAnimation(reduceMotion ? nil : RMotion.transition) {
            router.resolveInitialRoute(
                isLoggedIn: FirebaseApp.app() != nil && Auth.auth().currentUser != nil,
                hasCompletedOnboarding: UserDefaults.standard.bool(forKey: "recoco_onboarding_completed"),
                photoAuthStatus: PhotoAuthStatus(PHPhotoLibrary.authorizationStatus(for: .readWrite)),
                hasLocalSession: LocalSession.isActive
            )
        }
    }
}

private extension PhotoAuthStatus {
    init(_ status: PHAuthorizationStatus) {
        switch status {
        case .authorized:
            self = .authorized
        case .limited:
            self = .limited
        case .notDetermined:
            self = .notDetermined
        case .denied, .restricted:
            self = .denied
        @unknown default:
            self = .denied
        }
    }
}

#if DEBUG
#Preview("첫 실행") {
    SplashView()
        .environmentObject(AppRouter())
}

#Preview("재실행 (로그인 유지)") {
    SplashView()
        .environmentObject(AppRouter())
}
#endif
