import SwiftUI

// MARK: - AuthViewModel
// 명세서 §8 S-03
// Firebase Auth + Sign in with Apple + Google Sign-In 연동 준비
// MVP에서는 Mock 구현 포함

enum AuthError: LocalizedError {
    case signInFailed
    case networkError
    case unknown

    var errorDescription: String? {
        switch self {
        case .signInFailed:  return "로그인에 실패했습니다. 다시 시도해주세요."
        case .networkError:  return "인터넷 연결을 확인해주세요."
        case .unknown:       return "알 수 없는 오류가 발생했습니다."
        }
    }
}

@MainActor
final class AuthViewModel: ObservableObject {
    @Published var isLoading: Bool = false
    @Published var errorMessage: String? = nil
    @Published var showToast: Bool = false

    // MARK: Apple 로그인
    func signInWithApple() async {
        isLoading = true
        defer { isLoading = false }

        do {
            // TODO: ASAuthorizationController + Firebase Auth 연동
            // try await AuthService.shared.signInWithApple()
            try await Task.sleep(nanoseconds: 1_000_000_000) // Mock 딜레이
        } catch {
            showError(AuthError.signInFailed)
        }
    }

    // MARK: Google 로그인
    func signInWithGoogle() async {
        isLoading = true
        defer { isLoading = false }

        do {
            // TODO: GoogleSignIn SDK + Firebase Auth 연동
            // try await AuthService.shared.signInWithGoogle()
            try await Task.sleep(nanoseconds: 1_000_000_000) // Mock 딜레이
        } catch {
            showError(AuthError.signInFailed)
        }
    }

    // MARK: 에러 처리
    private func showError(_ error: AuthError) {
        errorMessage = error.errorDescription
        showToast = true
    }
}
