import SwiftUI
import StoreKit

struct SubscriptionView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var store = SubscriptionStore.shared
    @State private var showManagement = false
    @State private var showUsageDetails = false

    var body: some View {
        VStack(spacing: 0) {
            RNavigationBar(title: "리코코 구독", leadingAction: { dismiss() })
            RDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: RSpacing.lg) {
                    VStack(spacing: RSpacing.md) {
                        RSealIllustration(pose: .heart, width: RCharacterSize.companion)
                            .accessibilityHidden(true)
                        Text("정리할 사진,\n찾는 수고를 덜어요.")
                            .rTextStyle(.headlineLarge)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Text("살펴볼 사진과 이유를 추천받고,\n첫 추천 묶음 뒤에도 다음 사진을 살펴봐요.")
                            .rTextStyle(.subLabel, color: .rTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    if store.isActive {
                        Text(store.statusText).rTextStyle(.body)
                            .accessibilityIdentifier("subscription.status")
                        RButton(title: "사진 살펴보러 가기", variant: .primary) { dismiss() }
                        RButton(title: "구독 관리", variant: .secondary) { showManagement = true }
                    } else {
                        VStack(alignment: .leading, spacing: RSpacing.xs) {
                            timelineStep(label: "구독을 신청한 날부터",
                                         title: offersTrial ? "7일 동안 무료 체험" : "월 \(store.price)으로 시작",
                                         icon: "lock.open")
                            Rectangle().fill(Color.rBorder)
                                .frame(width: 2, height: 20).padding(.leading, 21)
                                .accessibilityHidden(true)
                            timelineStep(label: offersTrial ? "무료 체험이 끝나면" : "이후 매월",
                                         title: "월 \(store.price) 자동 결제", icon: "calendar")
                        }.padding(.vertical, RSpacing.sm)
                        VStack(spacing: RSpacing.sm) {
                            Text(purchaseNotice)
                                .rTextStyle(.caption, color: .rTextSecondary)
                                .accessibilityLabel(store.terms)
                                .accessibilityIdentifier("subscription.terms")
                            RButton(title: store.purchaseTitle, variant: .primary, isLoading: store.isPurchasing,
                                    isDisabled: !store.canPurchase) { Task { await store.purchase() } }
                                .accessibilityIdentifier("subscription.purchase")
                            Text(offersTrial
                                 ? "체험 종료 최소 24시간 전까지 Apple 구독 설정에서 취소하면 결제되지 않아요."
                                 : "다음 결제를 원하지 않으면 갱신 최소 24시간 전까지 Apple 구독 설정에서 취소해주세요.")
                                .rTextStyle(.caption, color: .rTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            RButton(title: "나중에 결정하기", variant: .ghost) { dismiss() }
                        }.multilineTextAlignment(.center)
                        if store.salesEnabled && store.product == nil {
                            RButton(title: "구독 정보 다시 불러오기", variant: .secondary, isLoading: store.isLoading) {
                                Task { await store.load() }
                            }
                        }
                    }
                    if !store.message.isEmpty {
                        Text(store.message).rTextStyle(.subLabel, color: .rTextSecondary)
                            .accessibilityIdentifier("subscription.message")
                    }
                    RDivider()
                    DisclosureGroup(isExpanded: $showUsageDetails) {
                        VStack(alignment: .leading, spacing: RSpacing.md) {
                            Text("첫 추천 묶음은 최대 3장까지 무료예요. 모두 살펴본 뒤 추가 추천을 요청하면 구독을 안내해요. 다음 날 무료로 초기화되지는 않아요.")
                            Text("무료 체험은 회원가입일이 아닌 구독 신청 시점부터 시작하며, 대상 Apple 계정에 한 번 제공돼요.")
                            Text("직접 기록 남기기와 기존 기록의 열람·공유·복사·삭제는 구독 없이도 이용할 수 있어요.")
                            Text("사진은 선택 후 확인해야 삭제돼요. 추천 근거가 부족하면 새 후보가 없을 수 있어요.")
                        }
                        .rTextStyle(.subLabel, color: .rTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, RSpacing.md)
                    } label: {
                        Text("무료 기능과 이용 안내")
                            .rTextStyle(.subLabel)
                            .frame(minHeight: RSize.minTouchTarget)
                    }.tint(.rTextSecondary)
                    let legalLayout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(spacing: RSpacing.sm))
                        : AnyLayout(HStackLayout(spacing: RSpacing.md))
                    legalLayout {
                        Button { Task { await store.restore() } } label: {
                            Group {
                                if store.isRestoring {
                                    RLoadingIndicator(style: .compact, size: 20, tint: .rAccent,
                                                      accessibilityLabel: "구매 복원 중")
                                }
                                else { Text("구매 복원") }
                            }.frame(minHeight: RSize.minTouchTarget)
                        }
                        .disabled(store.isPurchasing || store.isRestoring)
                        .accessibilityIdentifier("subscription.restore")
                        Link("이용약관", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                            .frame(minHeight: RSize.minTouchTarget)
                        Link("개인정보 안내", destination: URL(string: "https://github.com/iiinsujang/recoco/blob/main/PRIVACY_POLICY.md")!)
                            .frame(minHeight: RSize.minTouchTarget)
                    }
                    .font(.rCaption).foregroundColor(.rTextSecondary).tint(.rTextSecondary)
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, minHeight: RSize.minTouchTarget)
                }.rScreenPadding()
            }
        }
        .background(Color.rBackground)
        .task { await store.start() }
        .onChange(of: scenePhase) { if $0 == .active { Task { await store.load() } } }
        .manageSubscriptionsSheet(isPresented: $showManagement)
    }

    private var offersTrial: Bool { store.product == nil || store.eligibleForTrial }

    private var purchaseNotice: String {
        guard store.salesEnabled, store.product != nil else { return "출시 준비 중 · 아직 구독을 신청하거나 결제할 수 없어요." }
        return offersTrial ? "무료 체험 대상 Apple 계정에 한 번 제공" : "이 Apple 계정에는 무료 체험이 적용되지 않아요."
    }

    private func timelineStep(label: String, title: String, icon: String) -> some View {
        HStack(spacing: RSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .medium))
                .foregroundColor(.rAccent)
                .frame(width: 44, height: 44)
                .background(Color.rBrandMist, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: RSpacing.xs) {
                Text(label).rTextStyle(.caption, color: .rTextSecondary)
                Text(title).rTextStyle(.body).fontWeight(.semibold)
            }.fixedSize(horizontal: false, vertical: true)
        }
    }
}
