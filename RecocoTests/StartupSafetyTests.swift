import AuthenticationServices
import XCTest
@testable import Recoco

@MainActor
final class StartupSafetyTests: XCTestCase {
    private let identity = AppleCredentialMonitor.Identity(firebaseUserID: "firebase-user", appleUserID: "apple-user")

    func testFreeReleaseStartupAndRefreshNeverChangeSubscriptionState() async throws {
        let suite = "Recoco.FreeStartupTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SubscriptionStore(defaults: defaults, enabled: false)
        defaults.set(Data([1, 2, 3]), forKey: "recoco_daily_session_v1")
        let before = defaults.dictionaryRepresentation()

        await store.start()
        await store.load()
        await store.refreshEntitlements()
        await store.restore()

        XCTAssertEqual(store.revision, 0, "Free startup must not start entitlement refreshes")
        XCTAssertNil(store.product)
        XCTAssertNil(store.entitlement)
        XCTAssertFalse(store.isLoading)
        XCTAssertFalse(store.isRestoring)
        XCTAssertEqual(store.message, "")
        XCTAssertTrue(store.canStartCuration)
        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before as NSDictionary)
    }

    func testLocalOrNonAppleSessionDoesNotRequestAppleCredentialState() async {
        var requested = false
        let monitor = AppleCredentialMonitor(currentIdentity: { nil }, credentialState: { _ in
            requested = true
            return .revoked
        }, signOut: { XCTFail("There is no Apple session to sign out") },
           beginLocalSession: { XCTFail("Existing local session must not be rewritten"); return false })
        await monitor.refresh()
        XCTAssertFalse(requested)
    }

    func testAuthorizedOrTransferredAppleCredentialKeepsCurrentSession() async {
        for state: ASAuthorizationAppleIDProvider.CredentialState in [.authorized, .transferred] {
            let monitor = AppleCredentialMonitor(currentIdentity: { self.identity }, credentialState: { userID in
                XCTAssertEqual(userID, "apple-user", "Use the Apple provider UID, not Firebase UID")
                return state
            }, signOut: { XCTFail("Only revoked/notFound may release the identity") },
               beginLocalSession: { XCTFail("Active identity must remain untouched"); return false })
            await monitor.refresh()
        }
    }

    func testRevokedOrMissingAppleCredentialKeepsDeviceDataAndCurrentRoute() async throws {
        for state: ASAuthorizationAppleIDProvider.CredentialState in [.revoked, .notFound] {
            let suite = "Recoco.AppleCredentialTests.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let preservedKeys = ["recoco_saved_records_v1", "recoco_daily_session_v1",
                                 "recoco_cleanup_selection_v1", "recoco_recommendation_history_v1"]
            for key in preservedKeys { defaults.set(Data([1, 2, 3]), forKey: key) }
            let router = AppRouter(route: .main)
            var current: AppleCredentialMonitor.Identity? = identity
            var calls: [String] = []
            let monitor = AppleCredentialMonitor(currentIdentity: { current }, credentialState: { _ in state },
                signOut: { calls.append("signOut"); current = nil }, beginLocalSession: {
                    calls.append("beginLocal")
                    return LocalSession.begin(defaults: defaults)
                })
            await monitor.refresh()
            XCTAssertEqual(calls, ["signOut", "beginLocal"])
            XCTAssertNil(current)
            XCTAssertTrue(LocalSession.isActive(defaults: defaults))
            XCTAssertEqual(router.route, .main)
            for key in preservedKeys { XCTAssertEqual(defaults.data(forKey: key), Data([1, 2, 3])) }
        }
    }

    func testAppleNetworkFailureAndSignOutFailureDoNotStartNewLocalSession() async {
        let networkMonitor = AppleCredentialMonitor(currentIdentity: { self.identity }, credentialState: { _ in
            throw URLError(.notConnectedToInternet)
        }, signOut: { XCTFail("A network failure is not a revocation") },
           beginLocalSession: { XCTFail("A network failure must keep the current session"); return false })
        await networkMonitor.refresh()

        var attemptedSignOut = false
        let keychainMonitor = AppleCredentialMonitor(currentIdentity: { self.identity }, credentialState: { _ in .revoked },
            signOut: { attemptedSignOut = true; throw NSError(domain: "Keychain", code: 1) },
            beginLocalSession: { XCTFail("Failed sign-out must not pretend to change identity"); return false })
        await keychainMonitor.refresh()
        XCTAssertTrue(attemptedSignOut)
    }

    func testChangedAccountIgnoresOldRevocationResult() async {
        var current: AppleCredentialMonitor.Identity? = identity
        var reply: CheckedContinuation<ASAuthorizationAppleIDProvider.CredentialState, Never>?
        let monitor = AppleCredentialMonitor(currentIdentity: { current }, credentialState: { _ in
            await withCheckedContinuation { reply = $0 }
        }, signOut: { XCTFail("A response for an old account must not sign out the new account") },
           beginLocalSession: { XCTFail("The newer session must remain untouched"); return false })
        let task = Task { await monitor.refresh() }
        while reply == nil { await Task.yield() }
        current = .init(firebaseUserID: "another-user", appleUserID: "another-apple-user")
        reply?.resume(returning: .revoked)
        await task.value
    }

    func testCancelledOrSupersededCredentialCheckCannotSignOut() async {
        var replies: [CheckedContinuation<ASAuthorizationAppleIDProvider.CredentialState, Never>] = []
        let monitor = AppleCredentialMonitor(currentIdentity: { self.identity }, credentialState: { _ in
            await withCheckedContinuation { replies.append($0) }
        }, signOut: { XCTFail("Cancelled or superseded verification must not change identity") },
           beginLocalSession: { XCTFail("Current session must remain intact"); return false })
        let cancelled = Task { await monitor.refresh() }
        while replies.count < 1 { await Task.yield() }
        cancelled.cancel()
        replies[0].resume(returning: .revoked)
        await cancelled.value

        let old = Task { await monitor.refresh() }
        while replies.count < 2 { await Task.yield() }
        let latest = Task { await monitor.refresh() }
        while replies.count < 3 { await Task.yield() }
        replies[2].resume(returning: .authorized)
        await latest.value
        replies[1].resume(returning: .revoked)
        await old.value
    }

    func testInAppAccountDeletionDefersOnlyThatAccountsCredentialCheck() async {
        var deletingUserID = identity.firebaseUserID
        var requested = 0
        var signedOut = 0
        let monitor = AppleCredentialMonitor(currentIdentity: { self.identity }, credentialState: { _ in
            requested += 1
            return .revoked
        }, signOut: { signedOut += 1 }, beginLocalSession: { true },
           isAccountDeletionInProgress: { $0 == deletingUserID }, accountDeletionRevision: { _ in 0 })
        await monitor.refresh()
        XCTAssertEqual(requested, 0)
        XCTAssertEqual(signedOut, 0)

        deletingUserID = "another-account"
        await monitor.refresh()
        XCTAssertEqual(requested, 1, "A different account's deletion must not hide actual revocation")
        XCTAssertEqual(signedOut, 1)
    }

    func testAccountDeletionStartedDuringCredentialCheckCannotInterruptDeletion() async {
        var deleting = false
        var revision: UInt64 = 0
        var reply: CheckedContinuation<ASAuthorizationAppleIDProvider.CredentialState, Never>?
        let monitor = AppleCredentialMonitor(currentIdentity: { self.identity }, credentialState: { _ in
            await withCheckedContinuation { reply = $0 }
        }, signOut: { XCTFail("The in-app deletion owns its identity until it finishes") },
           beginLocalSession: { XCTFail("The monitor must not interrupt account deletion"); return false },
           isAccountDeletionInProgress: { _ in deleting }, accountDeletionRevision: { _ in revision })
        let task = Task { await monitor.refresh() }
        while reply == nil { await Task.yield() }
        deleting = true
        revision = 1
        reply?.resume(returning: .revoked)
        await task.value
    }

    func testFinishedDeletionDiscardsOldResultButAllowsFreshRevocationCheck() async {
        var revision: UInt64 = 0
        var firstReply: CheckedContinuation<ASAuthorizationAppleIDProvider.CredentialState, Never>?
        var requests = 0
        var signedOut = 0
        var startedLocalSession = 0
        let monitor = AppleCredentialMonitor(currentIdentity: { self.identity }, credentialState: { _ in
            requests += 1
            if requests == 1 { return await withCheckedContinuation { firstReply = $0 } }
            return .revoked
        }, signOut: { signedOut += 1 }, beginLocalSession: { startedLocalSession += 1; return true },
           isAccountDeletionInProgress: { _ in false }, accountDeletionRevision: { _ in revision })
        let old = Task { await monitor.refresh() }
        while firstReply == nil { await Task.yield() }
        // A complete begin/end pair occurred while Apple was answering the old
        // request. The deletion failed, so this Firebase identity still exists.
        revision = 2
        firstReply?.resume(returning: .revoked)
        await old.value
        XCTAssertEqual(signedOut, 0)
        XCTAssertEqual(startedLocalSession, 0)

        // Root schedules this fresh check on the deletion-finished notification
        // and whenever the scene becomes active again.
        await monitor.refresh()
        XCTAssertEqual(signedOut, 1)
        XCTAssertEqual(startedLocalSession, 1)
    }
}
