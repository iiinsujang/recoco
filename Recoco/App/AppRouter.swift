import SwiftUI

// MARK: - AppRouter
// 앱 전체 라우팅 상태 관리
// S-01(스플래시) 이후 분기 기준

enum AppRoute {
    case splash
    case onboarding
    case login
    case photoPermission   // S-03A
    case main
}

@MainActor
final class AppRouter: ObservableObject {
    @Published var route: AppRoute = .splash

    // MARK: 상태 전이 메서드

    func resolveInitialRoute(
        isLoggedIn: Bool,
        hasCompletedOnboarding: Bool,
        photoAuthStatus: PhotoAuthStatus
    ) {
        if !hasCompletedOnboarding {
            route = .onboarding
            return
        }
        if !isLoggedIn {
            route = .login
            return
        }
        if photoAuthStatus == .notDetermined || photoAuthStatus == .denied {
            route = .photoPermission
            return
        }
        route = .main
    }

    func navigateTo(_ route: AppRoute) {
        self.route = route
    }
}

// MARK: - Photo Auth Status

enum PhotoAuthStatus {
    case notDetermined
    case authorized
    case limited
    case denied
}
