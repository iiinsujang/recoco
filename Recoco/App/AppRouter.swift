import SwiftUI

// MARK: - AppRouter
// 앱 전체 라우팅 상태 관리
// S-01(스플래시) 이후 분기 기준

enum AppRoute: Equatable {
    case splash
    case onboarding
    case login
    case photoPermission   // S-03A
    case main
}

@MainActor
final class AppRouter: ObservableObject {
    @Published var route: AppRoute

    init(route: AppRoute = .splash) {
        self.route = route
    }

    // MARK: 상태 전이 메서드

    func resolveInitialRoute(
        isLoggedIn: Bool,
        hasCompletedOnboarding: Bool,
        photoAuthStatus: PhotoAuthStatus,
        hasLocalSession: Bool = false
    ) {
        if !hasCompletedOnboarding {
            route = .onboarding
            return
        }
        if !isLoggedIn && !hasLocalSession {
            route = .login
            return
        }
        // The system prompt is useful only before a choice has been made. A denied
        // user must reach Home, where Settings is the only actionable recovery path.
        if photoAuthStatus == .notDetermined {
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
