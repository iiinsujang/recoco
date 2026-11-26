import AuthenticationServices
import CryptoKit
import FirebaseAuth
import FirebaseCore
import Security
import SwiftUI
import UIKit

/// Validate the Apple/Firebase integration before opening native authentication.
struct LoginConfiguration {
    enum Issue: Equatable { case disabled, missingFirebase, bundleMismatch }
    let appleIssue: Issue?

    init(firebaseConfigured: Bool, firebaseBundleID: String?, bundleID: String?,
         appleEnabled: Bool = true) {
        let common: Issue? = !firebaseConfigured ? .missingFirebase
            : (firebaseBundleID == nil || bundleID == nil || firebaseBundleID != bundleID) ? .bundleMismatch : nil
        appleIssue = appleEnabled ? common : .disabled
    }

    static var current: Self {
        let options = FirebaseApp.app()?.options
        return Self(firebaseConfigured: options != nil, firebaseBundleID: options?.bundleID,
                    bundleID: Bundle.main.bundleIdentifier,
                    appleEnabled: Bundle.main.object(forInfoDictionaryKey: "RECOCO_APPLE_LOGIN_ENABLED") as? Bool == true)
    }

    var message: String? {
        guard appleIssue != nil else { return nil }
        return String(localized: "Apple 로그인 연결이 아직 준비되지 않았어요.")
    }
}

enum AppleAccountPolicy {
    /// Never attempt a provider's remote deletion without its supported reauthentication.
    static func canDelete(providerIDs: Set<String>) -> Bool { providerIDs == ["apple.com"] }
}

enum AuthError: LocalizedError {
    case notConfigured, invalidCredential, presentationUnavailable, signInFailed, network, tooManyAttempts
    var errorDescription: String? {
        switch self {
        case .notConfigured: return String(localized: "앱의 로그인 연결을 확인해야 해요. 계정이나 비밀번호의 문제는 아니에요.")
        case .invalidCredential: return String(localized: "로그인 정보를 확인하지 못했어요. 다시 시도해주세요.")
        case .presentationUnavailable: return String(localized: "로그인 화면을 열지 못했어요. 잠시 후 다시 시도해주세요.")
        case .signInFailed: return String(localized: "로그인을 완료하지 못했어요. 다시 시도해주세요.")
        case .network: return String(localized: "인터넷 연결을 확인한 뒤 다시 시도해주세요.")
        case .tooManyAttempts: return String(localized: "로그인 요청이 많아 잠시 멈췄어요. 조금 뒤 다시 시도해주세요.")
        }
    }
}

enum LoginFailure {
    static func message(for error: Error) -> String? {
        let value = error as NSError
        if value.domain == ASAuthorizationError.errorDomain && value.code == ASAuthorizationError.canceled.rawValue { return nil }
        if let error = error as? AuthError { return error.errorDescription }
        if value.domain == NSURLErrorDomain { return AuthError.network.errorDescription }
        if value.domain == AuthErrorDomain, let code = AuthErrorCode(rawValue: value.code) {
            switch code {
            case .networkError: return AuthError.network.errorDescription
            case .tooManyRequests: return AuthError.tooManyAttempts.errorDescription
            case .operationNotAllowed, .invalidAPIKey, .appNotAuthorized, .invalidClientID:
                return AuthError.notConfigured.errorDescription
            default: break
            }
        }
        return AuthError.signInFailed.errorDescription
    }
}

@MainActor
final class AuthViewModel: ObservableObject {
    enum Provider { case apple }
    @Published private(set) var activeProvider: Provider?
    @Published var errorMessage: String?
    var isLoading: Bool { activeProvider != nil }
    let configuration: LoginConfiguration
    private var currentNonce: String?
    private let signOut: () throws -> Void
    private let localDefaults: UserDefaults
    private let finishProviderSignOut: () -> Void

    init(signOut: @escaping () throws -> Void = {
        if FirebaseApp.app() != nil { try Auth.auth().signOut() }
    }, localDefaults: UserDefaults = .standard, configuration: LoginConfiguration = .current,
         finishProviderSignOut: @escaping () -> Void = {}) {
        self.signOut = signOut
        self.localDefaults = localDefaults
        self.configuration = configuration
        self.finishProviderSignOut = finishProviderSignOut
    }

    func startLocalSession() -> Bool {
        guard !isLoading else { return false }
        errorMessage = nil
        do {
            // A Keychain session can survive reinstall; release its UID first.
            try signOut()
            finishProviderSignOut()
            guard LocalSession.begin(defaults: localDefaults) else {
                errorMessage = String(localized: "시작 상태를 저장하지 못했어요. 기존 기록은 그대로 있어요. 다시 시도해주세요.")
                return false
            }
            return true
        } catch {
            errorMessage = String(localized: "기기 저장으로 전환하지 못했어요. 기존 기록은 그대로 있어요. 다시 시도해주세요.")
            return false
        }
    }

    func configureAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        guard configuration.appleIssue == nil, !isLoading else { return }
        activeProvider = .apple
        errorMessage = nil
        let nonce = AuthCrypto.randomNonceString()
        currentNonce = nonce
        request.requestedScopes = [.email]
        request.nonce = AuthCrypto.sha256(nonce)
    }

    func signInWithApple(result: Result<ASAuthorization, Error>) async -> Bool {
        defer { activeProvider = nil; currentNonce = nil }
        do {
            let authorization = try result.get()
            guard configuration.appleIssue == nil else { throw AuthError.notConfigured }
            guard let apple = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let nonce = currentNonce, let token = apple.identityToken,
                  let idToken = String(data: token, encoding: .utf8) else { throw AuthError.invalidCredential }
            let credential = OAuthProvider.appleCredential(withIDToken: idToken, rawNonce: nonce, fullName: apple.fullName)
            _ = try await Auth.auth().signIn(with: credential)
            // Account identity is optional; the device library never changes owner.
            _ = LocalSession.begin(defaults: localDefaults)
            return true
        } catch { errorMessage = LoginFailure.message(for: error); return false }
    }

}

/// A real device-only session, available in Release without a Firebase identity.
/// Existing development records keep their original nil-UID storage namespace.
enum LocalSession {
    static let storageKey = "recoco_local_session_v1"
    static let legacyStorageKey = "recoco_development_session_v1"

    static var isActive: Bool { isActive(defaults: .standard) }

    static func isActive(defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: storageKey) || defaults.bool(forKey: legacyStorageKey)
    }

    @discardableResult
    static func begin(defaults: UserDefaults = .standard) -> Bool {
        defaults.set(true, forKey: storageKey)
        guard defaults.bool(forKey: storageKey) else { return false }
        defaults.removeObject(forKey: legacyStorageKey)
        return true
    }

    static func end(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
        defaults.removeObject(forKey: legacyStorageKey)
    }

    static func hasLocalRecords(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: "recoco_saved_records_v1") != nil
            || defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("recoco_record_draft_") }
    }
}

enum AuthCrypto {
    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remainingLength = length

        while remainingLength > 0 {
            var randoms = [UInt8](repeating: 0, count: 16)
            guard SecRandomCopyBytes(kSecRandomDefault, randoms.count, &randoms) == errSecSuccess else {
                preconditionFailure("Unable to generate a secure login nonce.")
            }

            for random in randoms where remainingLength > 0 {
                if Int(random) < charset.count {
                    result.append(charset[Int(random)])
                    remainingLength -= 1
                }
            }
        }

        return result
    }
}

extension UIApplication {
    var recocoTopViewController: UIViewController? {
        let root = connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController

        var top = root
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}

extension Notification.Name {
    static let recocoAccountDeletionFinished = Notification.Name("recoco.accountDeletionFinished")
}

/// Apple token revocation is part of account deletion. A credential monitor must
/// not sign Firebase out between that revocation and Firebase's delete request.
/// This coordination is memory-only and never owns or changes user data.
@MainActor
final class AccountDeletionCoordination {
    static let shared = AccountDeletionCoordination()

    struct Token: Equatable, Sendable {
        fileprivate let id: UUID
        fileprivate let userID: String
    }

    private var active: [UUID: String] = [:]
    private var revisions: [String: UInt64] = [:]
    private let notificationCenter: NotificationCenter

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    func begin(userID: String) -> Token {
        let token = Token(id: UUID(), userID: userID)
        active[token.id] = userID
        revisions[userID, default: 0] &+= 1
        return token
    }

    func isDeleting(userID: String) -> Bool { active.values.contains(userID) }

    func revision(userID: String) -> UInt64 { revisions[userID, default: 0] }

    func end(_ token: Token) {
        guard active[token.id] == token.userID else { return }
        active.removeValue(forKey: token.id)
        revisions[token.userID, default: 0] &+= 1
        notificationCenter.post(name: .recocoAccountDeletionFinished, object: nil)
    }
}
