import XCTest
import StoreKit
import StoreKitTest
@testable import Recoco

@MainActor
final class SubscriptionTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        suite = "Recoco.SubscriptionTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testFirstExperienceAndExpiredEntitlementDoNotResetOnRelaunch() {
        let store = SubscriptionStore(defaults: defaults, enabled: true)
        XCTAssertTrue(store.canStartCuration)
        store.finishFirstExperience()
        XCTAssertFalse(store.canStartCuration)
        XCTAssertFalse(SubscriptionStore(defaults: defaults, enabled: true).canStartCuration)
        defaults.set("premium", forKey: FeatureAccess.planStorageKey)
        XCTAssertFalse(store.canStartCuration, "Legacy/local plan values never grant paid access")
        XCTAssertTrue(RecocoSubscriptionPolicy.canUseSavedRecords)
    }

    func testExpirationBoundaryAndCancellationUntilEnd() {
        let date = Date(timeIntervalSince1970: 1000)
        let cancelled = RecocoEntitlement(expiresAt: date.addingTimeInterval(1), isTrial: true, willAutoRenew: false)
        XCTAssertTrue(RecocoSubscriptionPolicy.canStartCuration(enabled: true, firstExperienceCompleted: true, entitlement: cancelled, now: date))
        XCTAssertFalse(RecocoSubscriptionPolicy.canStartCuration(enabled: true, firstExperienceCompleted: true, entitlement: cancelled, now: date.addingTimeInterval(1)))
        XCTAssertTrue(RecocoSubscriptionPolicy.canStartCuration(enabled: false, firstExperienceCompleted: true, entitlement: nil, now: date))
    }

    func testFirstExperienceDoesNotDependOnCalendarDay() {
        let first = SubscriptionStore(defaults: defaults, enabled: true, now: { Date(timeIntervalSince1970: 1000) })
        first.finishFirstExperience()
        let later = SubscriptionStore(defaults: defaults, enabled: true, now: { Date(timeIntervalSince1970: 1000 + 7 * 86_400) })
        XCTAssertFalse(later.canStartCuration)
    }

    func testManualWritingReadingAndDeletingRemainAvailableAfterFreeExperience() throws {
        let store = SubscriptionStore(defaults: defaults, enabled: true)
        let records = SavedRecordStore(defaults: defaults)
        let before = try records.save(text: "처음 남긴 기억", photoLocalIdentifier: "before", capturedDateDescription: nil)
        store.finishFirstExperience()
        XCTAssertFalse(store.canStartCuration)
        let after = try records.save(text: "구독 없이 직접 남긴 기억", photoLocalIdentifier: "after", capturedDateDescription: nil)
        let restored = SavedRecordStore(defaults: defaults)
        XCTAssertEqual(Set(try restored.readRecords().map(\.id)), Set([before.id, after.id]))
        XCTAssertTrue(try restored.delete(id: before.id))
        XCTAssertEqual(try restored.readRecords().first?.text, after.text)
        XCTAssertFalse(store.canStartCuration)
    }

    private func session() throws -> SKTestSession {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "RecocoSubscriptions", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        session.storefront = "KOR"
        session.locale = Locale(identifier: "ko_KR")
        session.timeRate = .realTime
        return session
    }

    // StoreKit delivers changes asynchronously, after SKTestSession mutations return.
    // Wait for observable app state instead of assuming a synchronous cache update.
    private func waitForState(_ message: String, file: StaticString = #filePath, line: UInt = #line,
                              _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        repeat {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        } while Date() < deadline
        XCTFail(message, file: file, line: line)
    }

    func testStoreKitTrialPurchaseRestoreCancellationAndExpiry() async throws {
        let session = try session()
        defer { session.clearTransactions() }
        let store = SubscriptionStore(defaults: defaults, enabled: true)
        store.finishFirstExperience()
        await store.start()
        let product = try XCTUnwrap(store.product, "StoreKit fixture did not load: \(store.message). Run scripts/test_subscriptions.sh with its supported runtime.")
        XCTAssertEqual(product.price, Decimal(4900))
        XCTAssertTrue(store.eligibleForTrial)
        XCTAssertFalse(store.isActive)
        await store.purchase()
        XCTAssertTrue(store.isActive, store.message)
        XCTAssertTrue(store.entitlement?.isTrial == true)
        XCTAssertTrue(store.canStartCuration)
        let transaction = try XCTUnwrap(session.allTransactions().last)
        try session.disableAutoRenewForTransaction(identifier: transaction.identifier)
        try await waitForState("StoreKit should report disabled automatic renewal") {
            await store.refreshEntitlements()
            return store.entitlement?.willAutoRenew == false
        }
        XCTAssertTrue(store.isActive, "Turning off renewal must not remove remaining access")
        XCTAssertEqual(store.entitlement?.willAutoRenew, false)
        let restored = SubscriptionStore(defaults: defaults, enabled: true)
        await restored.start()
        await restored.restore()
        XCTAssertTrue(restored.isActive, restored.message)
        try session.expireSubscription(productIdentifier: SubscriptionStore.monthlyProductID)
        try await waitForState("The transaction listener should revoke expired access") { !restored.isActive }
        XCTAssertFalse(restored.isActive)
        XCTAssertFalse(restored.canStartCuration)
        await restored.load()
        XCTAssertFalse(restored.eligibleForTrial, "One trial per subscription group")
    }

    func testStoreKitRefundRemovesAccessWithoutRemovingRecords() async throws {
        let session = try session()
        defer { session.clearTransactions() }
        let store = SubscriptionStore(defaults: defaults, enabled: true)
        await store.start()
        _ = try XCTUnwrap(store.product, "StoreKit fixture did not load: \(store.message). Run scripts/test_subscriptions.sh with its supported runtime.")
        await store.purchase()
        XCTAssertTrue(store.isActive, store.message)
        let records = SavedRecordStore(defaults: defaults)
        let record = try records.save(text: "keep this memory", photoLocalIdentifier: "sample-photo", capturedDateDescription: nil)
        let transaction = try XCTUnwrap(session.allTransactions().last)
        try session.refundTransaction(identifier: transaction.identifier)
        try await waitForState("The transaction listener should revoke refunded access") { !store.isActive }
        XCTAssertFalse(store.isActive)
        XCTAssertFalse(store.canStartCuration)
        XCTAssertEqual(try records.readRecords().first, record)
    }

    func testNoSaleConfigurationDoesNotPretendToStartTrial() async {
        let store = SubscriptionStore(defaults: defaults, enabled: false)
        XCTAssertFalse(store.canPurchase)
        await store.purchase()
        XCTAssertFalse(store.isActive)
        XCTAssertEqual(store.purchaseTitle, "구독 준비 중")
        XCTAssertTrue(store.canStartCuration)
    }
}
