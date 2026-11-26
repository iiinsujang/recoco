import AuthenticationServices
import FirebaseAuth
import FirebaseCore
import Foundation
import SwiftUI

// MARK: - RecocoApp
// 앱 진입점 및 최상위 라우팅

@main
struct RecocoApp: App {
    @StateObject private var router: AppRouter

    init() {
        #if DEBUG
        let route = Self.uiTestRoute(arguments: ProcessInfo.processInfo.arguments)
        #else
        let route: AppRoute = .splash
        #endif
        _router = StateObject(wrappedValue: AppRouter(route: route))

        // A production configuration must never attach a development/test bundle
        // to the release account service. Guest photo cleanup needs no network.
        if Bundle.main.object(forInfoDictionaryKey: "RECOCO_APPLE_LOGIN_ENABLED") as? Bool == true,
           let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
           let options = FirebaseOptions(contentsOfFile: path),
           options.bundleID == Bundle.main.bundleIdentifier {
            FirebaseApp.configure(options: options)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(router)
                .onAppear {
                    // Connected-device timing must not measure an auto-lock
                    // cancellation as a stalled photo read. Ordinary launches
                    // retain the device's normal idle behavior.
                    if ProcessInfo.processInfo.arguments.contains("-recoco-curation-timing") {
                        UIApplication.shared.isIdleTimerDisabled = true
                    }
                }
                .task { await NotificationSettingsClient.migrateLegacyReminder.value }
        }
    }

    #if DEBUG
    private static func uiTestRoute(arguments: [String]) -> AppRoute {
        guard arguments.contains("-ui-testing") else { return .splash }

        if arguments.contains("-ui-testing-reset"),
           let bundleIdentifier = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
        }

        if arguments.contains("-ui-testing-with-record") {
            let record = SavedMemoryRecord(
                id: UUID(),
                createdAt: Date(),
                text: "테스트로 남긴 기억",
                photoLocalIdentifier: nil,
                capturedDateDescription: "2026. 7. 20."
            )
            if let data = try? JSONEncoder().encode([record]) {
                UserDefaults.standard.set(data, forKey: SavedRecordStore.storageKey)
                if arguments.contains("-ui-testing-with-record-activity") {
                    LocalActivityStore.shared.recordIndependentMemory(recordID: record.id)
                }
            }
        }

        if arguments.contains("-ui-testing-record-library") {
            let records = (0..<80).map { index in
                SavedMemoryRecord(
                    id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
                    createdAt: Calendar.current.date(byAdding: .day, value: -index * 2, to: Date())!,
                    text: String(format: "기억 %03d · %@", index + 1, index.isMultiple(of: 3) ? "바다를 보던 오후" : "카페에서 나눈 이야기"),
                    photoLocalIdentifier: nil, capturedDateDescription: nil
                )
            }
            if let data = try? JSONEncoder().encode(records) {
                UserDefaults.standard.set(data, forKey: SavedRecordStore.storageKey)
            }
        }

        if arguments.contains("-ui-testing-route-onboarding") {
            return .onboarding
        }
        if arguments.contains("-ui-testing-route-photo-permission") {
            return .photoPermission
        }
        if arguments.contains("-ui-testing-route-main") {
            return .main
        }
        return .login
    }
    #endif
}

// MARK: - RootView: 라우트에 따라 화면 전환

struct RootView: View {
    @EnvironmentObject private var router: AppRouter
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var appleCredentialMonitor = AppleCredentialMonitor()

    var body: some View {
        ZStack {
            // Keep the branded surface visible throughout route transitions.
            Color.rBackground.ignoresSafeArea()

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
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            // Optional identity verification never gates rendering or curation.
            await appleCredentialMonitor.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: ASAuthorizationAppleIDProvider.credentialRevokedNotification)) { _ in
            Task { await appleCredentialMonitor.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .recocoAccountDeletionFinished)) { _ in
            // An in-app deletion can itself revoke Apple's authorization. Once
            // that operation ends, verify any remaining identity again.
            Task { await appleCredentialMonitor.refresh() }
        }
    }
}

/// Identity is optional in the free release. A revoked Apple credential clears
/// that identity only; the device library and the current screen stay intact.
@MainActor
final class AppleCredentialMonitor: ObservableObject {
    struct Identity: Equatable {
        let firebaseUserID: String
        let appleUserID: String
    }

    private let currentIdentity: () -> Identity?
    private let credentialState: (String) async throws -> ASAuthorizationAppleIDProvider.CredentialState
    private let signOut: () throws -> Void
    private let beginLocalSession: () -> Bool
    private let isAccountDeletionInProgress: @MainActor (String) -> Bool
    private let accountDeletionRevision: @MainActor (String) -> UInt64
    private var validationID = UUID()

    init(currentIdentity: @escaping () -> Identity? = {
        guard FirebaseApp.app() != nil, let user = Auth.auth().currentUser,
              let appleUserID = user.providerData.first(where: { $0.providerID == "apple.com" })?.uid,
              !appleUserID.isEmpty else { return nil }
        return Identity(firebaseUserID: user.uid, appleUserID: appleUserID)
    }, credentialState: @escaping (String) async throws -> ASAuthorizationAppleIDProvider.CredentialState = { userID in
        try await withCheckedThrowingContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: userID) { state, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: state) }
            }
        }
    }, signOut: @escaping () throws -> Void = {
        guard FirebaseApp.app() != nil else { return }
        try Auth.auth().signOut()
    }, beginLocalSession: @escaping () -> Bool = { LocalSession.begin() },
         isAccountDeletionInProgress: @escaping @MainActor (String) -> Bool = {
             AccountDeletionCoordination.shared.isDeleting(userID: $0)
         }, accountDeletionRevision: @escaping @MainActor (String) -> UInt64 = {
             AccountDeletionCoordination.shared.revision(userID: $0)
         }) {
        self.currentIdentity = currentIdentity
        self.credentialState = credentialState
        self.signOut = signOut
        self.beginLocalSession = beginLocalSession
        self.isAccountDeletionInProgress = isAccountDeletionInProgress
        self.accountDeletionRevision = accountDeletionRevision
    }

    func refresh() async {
        let request = UUID()
        validationID = request
        guard let identity = currentIdentity(),
              !isAccountDeletionInProgress(identity.firebaseUserID) else { return }
        let deletionRevision = accountDeletionRevision(identity.firebaseUserID)
        do {
            let state = try await credentialState(identity.appleUserID)
            guard !Task.isCancelled, validationID == request,
                  currentIdentity() == identity,
                  !isAccountDeletionInProgress(identity.firebaseUserID),
                  accountDeletionRevision(identity.firebaseUserID) == deletionRevision else { return }
            switch state {
            case .revoked, .notFound:
                try signOut()
                _ = beginLocalSession()
            case .authorized, .transferred:
                break
            @unknown default:
                break
            }
        } catch {
            // Offline, transient Apple failures or Keychain failures must not
            // force navigation, erase data or turn into an app-entry failure.
        }
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
