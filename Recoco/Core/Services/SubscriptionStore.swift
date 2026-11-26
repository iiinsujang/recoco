import Foundation
import StoreKit
import SwiftUI

/// A verified entitlement, never a locally selected Free/Premium preference.
struct RecocoEntitlement: Equatable {
    var expiresAt: Date
    var isTrial: Bool
    var willAutoRenew: Bool? = nil
    var inGracePeriod: Bool = false

    func isActive(at date: Date) -> Bool { expiresAt > date }
}

struct RecocoSubscriptionPolicy {
    static func canStartCuration(enabled: Bool, firstExperienceCompleted: Bool,
                                 entitlement: RecocoEntitlement?, now: Date) -> Bool {
        !enabled || entitlement?.isActive(at: now) == true || !firstExperienceCompleted
    }
    // A person's existing memories and manual writing never depend on payment.
    static let canUseSavedRecords = true
}

@MainActor
final class SubscriptionStore: ObservableObject {
    static let shared = SubscriptionStore()
    static let monthlyProductID = "app.recoco.ios.premium.monthly"
    static let previewKey = "recoco_first_curation_completed_v1"

    @Published private(set) var product: Product?
    @Published private(set) var entitlement: RecocoEntitlement?
    @Published private(set) var eligibleForTrial = false
    @Published private(set) var isLoading = false
    @Published private(set) var isPurchasing = false
    @Published private(set) var isRestoring = false
    @Published private(set) var message = ""
    @Published private(set) var revision = 0
    private let configuredSalesEnabled: Bool
    var salesEnabled: Bool { configuredSalesEnabled }
    private let defaults: UserDefaults
    private let now: () -> Date
    private var updatesTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var refreshID = UUID()

    init(defaults: UserDefaults = .standard, enabled: Bool? = nil, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        #if DEBUG
        let localTesting = ProcessInfo.processInfo.arguments.contains("-subscription-testing")
        #else
        let localTesting = false
        #endif
        configuredSalesEnabled = enabled ?? (localTesting || Bundle.main.object(forInfoDictionaryKey: "RECOCO_SUBSCRIPTIONS_ENABLED") as? Bool == true)
    }

    deinit { updatesTask?.cancel(); expiryTask?.cancel() }

    var firstExperienceCompleted: Bool { defaults.bool(forKey: UserScopedStorage.key(Self.previewKey)) }
    var isActive: Bool { entitlement?.isActive(at: now()) == true }
    var canStartCuration: Bool {
        RecocoSubscriptionPolicy.canStartCuration(enabled: salesEnabled,
            firstExperienceCompleted: firstExperienceCompleted, entitlement: entitlement, now: now())
    }
    var canPurchase: Bool { salesEnabled && product != nil && !isActive && !isLoading && !isPurchasing && !isRestoring }
    var price: String { product?.displayPrice ?? "₩4,900" }
    var purchaseTitle: String {
        guard salesEnabled, product != nil else { return "구독 준비 중" }
        return eligibleForTrial ? "7일 무료로 시작하기" : "월 \(price)으로 구독하기"
    }
    var terms: String {
        guard salesEnabled, product != nil else {
            return "7일 무료 체험 후 월 4,900원으로 이용하는 구독을 준비하고 있어요. 아직 구독을 신청하거나 결제할 수 없어요."
        }
        return eligibleForTrial
            ? "신청한 날부터 7일 무료. 이후 매월 \(price)이 자동 결제돼요."
            : "신청 시 \(price)이 결제되고, 이후 매월 자동 결제돼요. 이 Apple 계정에는 무료 체험이 적용되지 않아요."
    }
    var statusText: String {
        guard let entitlement, entitlement.isActive(at: now()) else {
            return firstExperienceCompleted ? "첫 정리를 마쳤어요" : "첫 정리는 무료로"
        }
        let date = entitlement.expiresAt.formatted(date: .abbreviated, time: .shortened)
        if entitlement.inGracePeriod { return "결제 정보를 확인해주세요. \(date)까지 이용할 수 있어요." }
        if entitlement.willAutoRenew == false { return "다음 자동 결제를 해제했어요. \(date)까지 계속 이용할 수 있어요." }
        return "\(entitlement.isTrial ? "무료 체험" : "구독") 이용 중 · \(date)\(entitlement.willAutoRenew == true ? " 갱신 예정" : "까지 이용 가능")"
    }

    func finishFirstExperience() {
        defaults.set(true, forKey: UserScopedStorage.key(Self.previewKey))
        revision += 1
    }

    func start() async {
        // The free release has no StoreKit dependency, including transaction
        // listeners. A store connection must never delay photo access.
        guard salesEnabled else { return }
        if updatesTask == nil {
            updatesTask = Task { [weak self] in
                for await result in StoreKit.Transaction.updates {
                    guard !Task.isCancelled else { return }
                    guard case .verified(let transaction) = result,
                          transaction.productID == Self.monthlyProductID else { continue }
                    await self?.refreshEntitlements()
                    await transaction.finish()
                }
            }
        }
        await load()
    }

    func load() async {
        guard salesEnabled, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        // Enabled subscriptions still read entitlements when merchandising is
        // unavailable/offline; the free release never enters this path.
        await refreshEntitlements()
        do {
            let products = try await Product.products(for: [Self.monthlyProductID])
            product = products.first { $0.id == Self.monthlyProductID && $0.type == .autoRenewable
                && $0.subscription?.subscriptionPeriod.unit == .month && $0.subscription?.subscriptionPeriod.value == 1 }
            guard let product, let subscription = product.subscription else {
                message = "현재 구독 상품을 불러올 수 없어요. 잠시 후 다시 확인해주세요."
                eligibleForTrial = false
                return
            }
            let offer = subscription.introductoryOffer
            let sevenDays = offer?.period.unit == .week && offer?.period.value == 1
                || offer?.period.unit == .day && offer?.period.value == 7
            guard offer?.paymentMode == .freeTrial, offer?.periodCount == 1, sevenDays else {
                self.product = nil
                eligibleForTrial = false
                message = "구독 상품의 무료 체험 설정을 확인하고 있어요. 지금은 결제가 진행되지 않아요."
                return
            }
            let eligible = await subscription.isEligibleForIntroOffer
            eligibleForTrial = offer?.paymentMode == .freeTrial && offer?.periodCount == 1 && sevenDays && eligible
            message = ""
            await refreshEntitlements()
        } catch {
            product = nil
            eligibleForTrial = false
            message = "구독 정보를 불러오지 못했어요. 연결을 확인하고 다시 시도해주세요."
        }
    }

    func refreshEntitlements() async {
        guard salesEnabled else { return }
        let request = UUID(); refreshID = request
        var next: RecocoEntitlement?
        var sawSubscription = false
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.productID == Self.monthlyProductID else { continue }
            sawSubscription = true
            guard transaction.revocationDate == nil, !transaction.isUpgraded,
                  let expiration = transaction.expirationDate, expiration > now() else { continue }
            let trial: Bool
            if #available(iOS 17.2, *) { trial = transaction.offer?.type == .introductory && transaction.offer?.paymentMode == .freeTrial }
            else { trial = transaction.offerType == .introductory }
            next = RecocoEntitlement(expiresAt: expiration, isTrial: trial)
        }
        if let statuses = try? await product?.subscription?.status {
            for status in statuses {
                guard case .verified(let transaction) = status.transaction,
                      transaction.productID == Self.monthlyProductID,
                      case .verified(let renewal) = status.renewalInfo,
                      transaction.revocationDate == nil, !transaction.isUpgraded else { continue }
                if status.state == .inGracePeriod, let end = renewal.gracePeriodExpirationDate, end > now() {
                    next = RecocoEntitlement(expiresAt: end, isTrial: false, willAutoRenew: renewal.willAutoRenew, inGracePeriod: true)
                } else if status.state == .subscribed, next != nil {
                    next?.willAutoRenew = renewal.willAutoRenew
                }
            }
        }
        // Prevent an expired previous subscriber from receiving another first session.
        if case .verified(let previous)? = await StoreKit.Transaction.latest(for: Self.monthlyProductID) { sawSubscription = previous.productID == Self.monthlyProductID }
        guard refreshID == request else { return }
        if sawSubscription { defaults.set(true, forKey: UserScopedStorage.key(Self.previewKey)) }
        entitlement = next
        revision += 1
        expiryTask?.cancel()
        if let next {
            let seconds = max(0.1, min(next.expiresAt.timeIntervalSince(now()), 32 * 86_400))
            expiryTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
                catch { return }
                await self?.refreshEntitlements()
            }
        }
    }

    func purchase() async {
        guard canPurchase, let product else { return }
        isPurchasing = true; message = ""
        defer { isPurchasing = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                guard case .verified(let transaction) = result, transaction.productID == Self.monthlyProductID else {
                    message = "구매 정보를 확인하지 못했어요. 구매 복원을 눌러 다시 확인해주세요."
                    return
                }
                await refreshEntitlements()
                await transaction.finish()
                message = isActive ? "이제 이어서 사진을 살펴볼 수 있어요." : "구매 상태를 확인 중이에요. 잠시 후 구매 복원을 눌러주세요."
                eligibleForTrial = false
            case .userCancelled:
                message = "신청을 취소했어요. 기존 기록은 그대로 있어요."
            case .pending:
                message = "구매 승인을 기다리고 있어요. 승인되면 이용 권한이 반영돼요."
            @unknown default:
                message = "구매 상태를 확인하지 못했어요. 잠시 후 다시 시도해주세요."
            }
        } catch { message = "결제를 완료하지 못했어요. 다시 시도하거나 구매 복원으로 확인해주세요." }
    }

    func restore() async {
        guard salesEnabled, !isPurchasing, !isRestoring else { return }
        isRestoring = true; message = ""
        defer { isRestoring = false }
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            message = isActive ? "구독을 복원했어요." : "현재 이용 가능한 구독이 없어요. 기존 기록은 계속 이용할 수 있어요."
        } catch { message = "구매 내역을 복원하지 못했어요. 연결과 Apple 계정을 확인해주세요." }
    }
}
