import SwiftUI
import Photos
import PhotosUI
import UIKit

// MARK: - S-04 홈
// 명세서 §8 S-04

/// Home uses the shared web/native decision layout without changing other screens.
private enum HomeStyle {
    static let headerHeight: CGFloat = 52
    static let titleSize: CGFloat = 21
    static let labelSize: CGFloat = 15
    static let primaryActionSize: CGFloat = 17
    static let captionSize: CGFloat = 12
    static let actionRadius: CGFloat = 10
    static let photoContextGap: CGFloat = 8
    static let sectionGap = RSpacing.sm
    // The photo shares the same content edges as the summary and the decision.
    // Short screens and larger text scroll instead of shrinking this square.
    static func photoSide(in size: CGSize) -> CGFloat {
        max(0, size.width - RLayout.screenInset * 2)
    }
}

struct HomeView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .headline) private var titleSize = HomeStyle.titleSize
    @ScaledMetric(relativeTo: .body) private var labelSize = HomeStyle.labelSize
    @ScaledMetric(relativeTo: .body) private var primaryActionSize = HomeStyle.primaryActionSize
    @ScaledMetric(relativeTo: .caption) private var captionSize = HomeStyle.captionSize
    @ObservedObject private var vm: HomeViewModel
    @ObservedObject private var subscriptions = SubscriptionStore.shared
    private let onOpenReport: () -> Void
    private let onOpenRecords: () -> Void

    // 하위 화면 네비게이션
    @StateObject private var batchDeletion = PhotoDeletionController.forPresentation()
    @State private var cleanupUnit: DecisionUnit?
    @State private var singleDeleteUnit: DecisionUnit?
    @State private var selectionUnit: DecisionUnit?
    @State private var recordUnit: DecisionUnit? = nil
    @State private var openRecordsAfterRecord = false
    @State private var pendingDecisionFeedback: String?
    @State private var pendingUnit: DecisionUnit? = nil
    @StateObject private var photoPicker = HomeLimitedPhotoPicker()
    @State private var showPhotoAccessHelp = false
    @State private var photoFocusRequest = 0
    @GestureState private var sealDragOffset: CGFloat = 0
    @State private var foregroundRefreshTask: Task<Void, Never>?

    init(viewModel: HomeViewModel, onOpenReport: @escaping () -> Void = {},
         onOpenRecords: @escaping () -> Void = {}) {
        self.vm = viewModel
        self.onOpenReport = onOpenReport
        self.onOpenRecords = onOpenRecords
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.rBackground.ignoresSafeArea()
                VStack(spacing: 0) {
                    RWordmarkHeader(height: HomeStyle.headerHeight)

                    mainContent(photoSide: HomeStyle.photoSide(in: geometry.size))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                }
            }
        }
        .rToast(isPresented: $vm.showToast, message: vm.toastMessage, duration: 3.5,
                alignment: .top, inset: HomeStyle.headerHeight)
        .task {
            if subscriptions.salesEnabled { await subscriptions.start() }
            guard !Task.isCancelled else { return }
            await vm.onAppear(reuseValidatedQueue: true)
            await vm.prepareHomeRecommendations()
        }
        // MainTabView cancels the shared VM at navigation intent. A fading-out
        // Home must cancel only its own foreground task, not a newer Home's scan.
        .onDisappear { foregroundRefreshTask?.cancel() }
        .background(PhotoPickerWindowAnchor(picker: photoPicker).allowsHitTesting(false).accessibilityHidden(true))
        .alert(String(localized: "사진 접근 관리"), isPresented: $showPhotoAccessHelp) {
            Button("설정으로 이동하기", action: openPhotoSettings)
            Button("취소", role: .cancel) {}
        } message: {
            Text("사진 선택창을 열지 못했어요. 설정에서 사진을 추가할 수 있어요.")
        }
        .sheet(isPresented: $vm.showSubscription, onDismiss: { Task { await vm.onAppear() } }) {
            SubscriptionView()
        }
        .onChange(of: subscriptions.isActive) { _ in
            guard cleanupUnit == nil, singleDeleteUnit == nil, recordUnit == nil else { return }
            Task { await vm.onAppear() }
        }
        .onChange(of: scenePhase) { phase in
            foregroundRefreshTask?.cancel()
            if phase == .background { vm.pauseCuration(resumingAutomatically: true) }
            guard phase == .active, !vm.isCommittingSelection, !photoPicker.isOpen, cleanupUnit == nil, singleDeleteUnit == nil, recordUnit == nil, selectionUnit == nil else { return }
            foregroundRefreshTask = Task {
                if subscriptions.salesEnabled { await subscriptions.refreshEntitlements() }
                guard !Task.isCancelled, scenePhase == .active else { return }
                await vm.onAppear(reuseValidatedQueue: true)
                await vm.prepareHomeRecommendations()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            guard scenePhase == .active, !photoPicker.isOpen,
                  cleanupUnit == nil, singleDeleteUnit == nil, recordUnit == nil, selectionUnit == nil else { return }
            Task {
                await vm.refreshForNewDay()
                await vm.prepareHomeRecommendations()
            }
        }
        // Clear the prior confirmation when another decision starts, so two
        // quick successes with identical copy each receive their full feedback.
        .onChange(of: cleanupUnit?.id) { if $0 != nil { vm.cancelBackgroundTopUp(); vm.showToast = false } }
        .onChange(of: singleDeleteUnit?.id) { if $0 != nil { vm.cancelBackgroundTopUp(); vm.showToast = false } }
        .onChange(of: recordUnit?.id) { if $0 != nil { vm.cancelBackgroundTopUp(); vm.showToast = false } }
        // Item-driven presentation keeps the content and presentation state in sync.
        .sheet(item: $cleanupUnit, onDismiss: presentDecisionFeedback) { unit in
            CleanupConfirmSheet(unit: unit, returnsAfterSuccess: true) { deletedCount in
                completeDecision(unit, deletedCount: deletedCount, savedRecord: false)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $singleDeleteUnit, onDismiss: presentDecisionFeedback) { unit in
            SinglePhotoDeleteSheet(unit: unit, returnsAfterSuccess: true) { deletedCount in
                completeDecision(unit, deletedCount: deletedCount, savedRecord: false)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $selectionUnit, onDismiss: {
            if let selected = pendingUnit {
                pendingUnit = nil
                cleanupUnit = selected
            }
        }) { unit in
            PhotoSelectorView(unit: unit) { updatedUnit in
                pendingUnit = updatedUnit
                selectionUnit = nil
            }
        }
        // S-07 Record
        .fullScreenCover(item: $recordUnit, onDismiss: {
            presentDecisionFeedback()
            guard openRecordsAfterRecord else { return }
            openRecordsAfterRecord = false
            onOpenRecords()
        }) { unit in
            RecordView(unit: unit, onOpenRecords: {
                openRecordsAfterRecord = true
            }, returnsAfterSave: true) { _ in
                completeDecision(unit, deletedCount: 0, savedRecord: true)
            }
        }
    }

    // Queue mutation happens only after the store/Photos confirms success. Feedback
    // starts after the covering screen closes, so it cannot expire underneath it.
    private func completeDecision(_ unit: DecisionUnit, deletedCount: Int, savedRecord: Bool) {
        guard vm.markTodayCompleted(unit: unit, deletedCount: deletedCount, savedRecord: savedRecord) else { return }
        pendingDecisionFeedback = savedRecord ? String(localized: "기록을 저장했어요.")
            : String(localized: "사진 \(deletedCount)장 비웠어요. 최근 삭제된 항목에서 복구할 수 있어요.")
    }

    private func presentDecisionFeedback() {
        guard let message = pendingDecisionFeedback else { return }
        pendingDecisionFeedback = nil
        vm.toastMessage = message
        vm.showToast = true
    }

    // MARK: - 주간 배너

    private var weeklyBanner: some View {
        Button(action: onOpenReport) {
            HStack(spacing: RSpacing.sm) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: RSpacing.xxs) {
                        weeklyCaption
                        weeklyCount
                    }
                    Spacer(minLength: 0)
                } else {
                    weeklyCaption
                    Spacer(minLength: RSpacing.xs)
                    weeklyCount
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.rTextSecondary)
            }
            .padding(.horizontal, RSpacing.md)
            .padding(.vertical, RSpacing.xs)
            .frame(minHeight: RSize.minTouchTarget)
            .background(Color.rSurface)
            .clipShape(RoundedRectangle(cornerRadius: RRadius.lg))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.weeklySummary")
    }

    private var weeklyCaption: some View {
        Text("이번 주는")
            .font(.system(size: captionSize, weight: .medium))
            .foregroundColor(.rTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var weeklyCount: some View {
        Text("사진 \(vm.weeklyProgress.deletedPhotoCount)장 비웠어요")
            .font(.system(size: labelSize, weight: .medium))
            .foregroundColor(.rTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("home.clearedCount")
    }

    // MARK: - 상태별 메인 콘텐츠

    @ViewBuilder
    private func mainContent(photoSide: CGFloat) -> some View {
        switch vm.state {
        case .loading:
            loadingView(photoSide: photoSide)

        case .scanPaused:
            HomeSurface {
                VStack(spacing: RSpacing.lg) {
                    RSealIllustration(pose: .nap, width: RCharacterSize.state)
                    Text("잠시 멈췄어요.").rTextStyle(.headline)
                        .accessibilityIdentifier("home.scanPaused")
                    Text("사진은 그대로예요. 원할 때 추천 찾기를 이어갈 수 있어요.")
                        .rTextStyle(.body, color: .rTextSecondary).multilineTextAlignment(.center)
                }
            } actions: {
                RButton(title: String(localized: "이어서 추천 찾기"), variant: .primary) { Task { await vm.resumeCuration() } }
                    .accessibilityIdentifier("home.resumeScan")
                RButton(title: String(localized: "리포트 보기"), variant: .ghost, size: .compact, action: onOpenReport)
            }

        case .noPermission:
            noPermissionView

        case .subscriptionRequired:
            HomeSurface {
                VStack(spacing: RSpacing.lg) {
                    RSealIllustration(pose: .heart, width: RCharacterSize.state)
                    Text("나의 속도로, 이어서.").rTextStyle(.headline)
                    Text("다음 사진도 함께 살펴볼까요? 구독하면 새로운 후보와 이유를 계속 확인할 수 있어요.")
                        .rTextStyle(.body, color: .rTextSecondary).multilineTextAlignment(.center)
                }
            } actions: {
                RButton(title: String(localized: "추가 추천 이용 안내"), variant: .primary) { vm.showSubscription = true }
                    .accessibilityIdentifier("home.subscription")
                RButton(title: String(localized: "리포트 보기"), variant: .ghost, size: .compact, action: onOpenReport)
                    .accessibilityIdentifier("home.openRecords")
            }

        case .ready(let unit):
            HomeSurface(centered: false, photoFocusRequest: photoFocusRequest) {
                VStack(alignment: .leading, spacing: 0) {
                    weeklyBanner
                        .padding(.bottom, unit.type == .cleanupCluster ? HomeStyle.sectionGap : 0)
                    if unit.type != .cleanupCluster { curationHeading(for: unit) }

                    // Decision Unit 카드
                    switch unit.type {
                    case .cleanupSingle, .recallMoment:
                        let previewGeneration = vm.photoPreviewGeneration
                        SinglePhotoDecisionCard(
                            identifiers: vm.photoIdentifiers,
                            focusedIndex: Binding(get: { vm.currentDecisionIndex }, set: { vm.browsePhoto(at: $0) }),
                            photoHeight: photoSide,
                            rolesByIdentifier: vm.photoIdentifiers.reduce(into: [:]) { $0[$1] = .photo },
                            previewGeneration: previewGeneration,
                            onPreviewStateChange: { identifier, requestID, state in
                                vm.updateHomePhotoPreview(identifier: identifier, generation: previewGeneration,
                                                          requestID: requestID, state: state)
                            }
                        )
                        .id(previewGeneration)
                        .simultaneousGesture(sealFollowingDrag)
                        .frame(width: photoSide, height: photoSide)
                        .frame(maxWidth: .infinity)
                        .id("home.photoAnchor")
                        .allowsHitTesting(!vm.isCommittingSelection)
                        .padding(.bottom, HomeStyle.photoContextGap)

                    case .cleanupCluster:
                        CleanupClusterCard(unit: unit, showsActions: false) {
                            cleanupUnit = unit
                        } onSelectPhoto: {
                            selectionUnit = unit
                        } onDefer: {
                            vm.deferDecision(unit)
                        }

                    }
                }
            } actions: {
                switch unit.type {
                case .cleanupSingle, .recallMoment:
                    actionDock(for: unit)
                case .cleanupCluster:
                    RButton(title: String(localized: "추천대로 정리하기"), variant: .primary) { cleanupUnit = unit }
                    homeSecondaryRow {
                        RButton(title: String(localized: "다른 사진 고르기"), variant: .ghost, size: .compact) { selectionUnit = unit }
                        RButton(title: String(localized: "나중에"), variant: .ghost, size: .compact) { vm.deferDecision(unit) }
                    }
                    if vm.hasDeletedPhotosInSession { PhotoRecoveryGuide() }
                }
            }

        case .completed(let summary):
            completedView(summary: summary)

        case .searchPending, .noCandidate:
            // An exhausted foreground budget is still Home. Keep the report
            // summary and a truthful retry/access action together; never ask
            // the user to leave and re-enter just to continue the same search.
            ScrollView {
                VStack(spacing: RSpacing.xxl) {
                    weeklyBanner
                    noCandidateView
                    if vm.hasDeletedPhotosInSession { PhotoRecoveryGuide() }
                }
                .padding(.horizontal, RLayout.screenInset)
                .padding(.top, RSpacing.sm)
                .padding(.bottom, RSpacing.xl)
            }
        }
    }

    /// Keep the selected set and one primary action together in the photo scroll.
    private func actionDock(for unit: DecisionUnit) -> some View {
        VStack(spacing: RSpacing.xs) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: RSpacing.xs) {
                    selectionToggle(for: unit)
                    selectedPhotoPreviews(for: unit)
                }
            } else {
                HStack(alignment: .center, spacing: RSpacing.xs) {
                    selectionToggle(for: unit)
                    selectedPhotoPreviews(for: unit)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            if let recovery = vm.cleanupRecovery { cleanupRecoveryView(recovery) }
            decisionActions(for: unit)
            if vm.selectedCleanupCount > 0 && !vm.selectedPhotosReadyForCleanup {
                Text("선택한 사진을 불러오면 비울 수 있어요.")
                    .rTextStyle(.subLabel, color: .rTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("home.previewUnavailable")
            }
            if let message = vm.cleanupResultMessage {
                Text(message)
                    .rTextStyle(.subLabel, color: .rTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("home.cleanupResult")
            }
            if vm.isLimitedAccess {
                selectMorePhotosButton(primary: false)
            }
            if vm.hasDeletedPhotosInSession { PhotoRecoveryGuide() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.actionDock")
    }

    private func selectionToggle(for unit: DecisionUnit) -> some View {
        Button { vm.toggleCleanupSelection(unit) } label: {
            HStack(spacing: RSpacing.xs) {
                Image(systemName: vm.isSelectedForCleanup(unit) ? "checkmark.square.fill" : "square")
                    .font(.system(size: 23, weight: .regular))
                    .foregroundColor(vm.isSelectedForCleanup(unit) ? .rAccent : .rTextSecondary)
                Text("비울 사진으로 선택")
                    .font(.system(size: labelSize, weight: .medium))
                    .foregroundColor(.rTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(RPressFeedbackStyle())
        .disabled(vm.isCommittingSelection || unit.removalCount != 1
                  || (!vm.isSelectedForCleanup(unit) && !vm.isPhotoPreviewReady(unit.displayIdentifier ?? "")))
        .accessibilityLabel("비울 사진으로 선택")
        .accessibilityValue(vm.isSelectedForCleanup(unit) ? String(localized: "선택됨") : String(localized: "선택 안 됨"))
        .accessibilityIdentifier("home.selectPhoto")
    }

    @ViewBuilder
    private func selectedPhotoPreviews(for unit: DecisionUnit) -> some View {
        if !vm.selectedCleanupUnits.isEmpty {
            HStack(spacing: RSpacing.xxs) {
                ForEach(vm.selectedCleanupUnits, id: \.persistenceKey) { selected in
                    if let identifier = selected.displayIdentifier {
                        Button {
                            vm.focusSelectedPhoto(selected)
                            photoFocusRequest += 1
                        } label: {
                            PHAssetImageView(localIdentifier: identifier,
                                targetSize: CGSize(width: 132, height: 132), scalesToFit: true)
                                .frame(width: 44, height: 44)
                                .background(Color.rSurface)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(
                                    selected.persistenceKey == unit.persistenceKey ? Color.rAccent : Color.clear, lineWidth: 1.5))
                                .frame(width: 46, height: 46)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(RPressFeedbackStyle())
                        .disabled(vm.isCommittingSelection)
                        .accessibilityLabel("선택한 사진 보기")
                        .accessibilityIdentifier("home.selectedPhoto.\(selected.persistenceKey)")
                    }
                }
            }
        }
    }

    private func decisionActions(for unit: DecisionUnit?) -> some View {
        RButton(title: String(localized: "선택한 \(vm.selectedCleanupCount)장 비우기"), variant: .primary,
                isLoading: vm.isCommittingSelection,
                isDisabled: unit == nil || vm.selectedCleanupCount == 0 || vm.cleanupRecovery != nil
                    || !vm.selectedPhotosReadyForCleanup,
                font: .system(size: primaryActionSize, weight: .semibold), cornerRadius: RRadius.md) {
            guard let snapshots = vm.beginSelectedCleanup() else { return }
            Task { @MainActor in
                defer { vm.endSelectedCleanup() }
                do {
                    let didDelete = try await batchDeletion.deleteBatch(snapshots) { count in
                        vm.completeSelectedCleanup(snapshots)
                        if let message = vm.cleanupResultMessage {
                            vm.showToast = false
                            UIAccessibility.post(notification: .announcement, argument: message)
                        } else {
                            vm.toastMessage = String(localized: "사진 \(count)장 비웠어요. 최근 삭제된 항목에서 복구할 수 있어요.")
                            vm.showToast = true
                        }
                    }
                    if !didDelete {
                        vm.toastMessage = String(localized: "비우기를 취소했어요. 선택한 사진은 그대로예요.")
                        vm.showToast = true
                    }
                } catch {
                    vm.reportCleanupFailure(error)
                }
            }
        }
        .accessibilityHint("선택한 사진만 삭제합니다. iOS 확인창에서 한 번 더 확인할 수 있습니다.")
        .accessibilityIdentifier("home.deleteSelected")
    }

    private func cleanupRecoveryView(_ recovery: HomeCleanupRecovery) -> some View {
        VStack(alignment: .leading, spacing: RSpacing.xxs) {
            Text(recovery.title)
                .rTextStyle(.subLabel, color: .rTextPrimary)
                .accessibilityIdentifier("home.cleanupFailureTitle")
            Text(recovery.message)
                .rTextStyle(.caption, color: .rTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            switch recovery {
            case .changedPhotos, .unconfirmed:
                RButton(title: String(localized: "사진 다시 확인하기"), variant: .ghost, size: .compact) {
                    Task { await vm.recheckCleanupPhotos() }
                }.accessibilityIdentifier("home.recheckCleanup")
            case .accessDenied:
                RButton(title: String(localized: "설정에서 사진 접근 변경"), variant: .ghost, size: .compact) {
                    openPhotoSettings()
                }.accessibilityIdentifier("home.cleanupPhotoSettings")
            case .accessRestricted:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.cleanupFailure")
    }

    // MARK: - 현재 사진의 선정 이유

    private func curationHeading(for unit: DecisionUnit) -> some View {
        homeHeading(unit.shortReason, identifier: "home.curationReason")
    }

    private var sealFollowingDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .updating($sealDragOffset) { movement, offset, _ in
                let delta = movement.translation
                guard !reduceMotion, vm.photoIdentifiers.count > 1,
                      abs(delta.width) > abs(delta.height) else { return }
                offset = max(-5, min(5, delta.width * 0.04))
            }
    }

    private func homeHeading(_ title: String, identifier: String, showsCharacter: Bool = true) -> some View {
        HStack(spacing: RSpacing.sm) {
            Text(title)
                .font(.system(size: titleSize, weight: .semibold))
                .foregroundColor(.rTextPrimary)
                .tracking(-0.5)
                .lineSpacing(titleSize * 0.2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(identifier)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showsCharacter {
                // The transparent PNG margins let the visible seal fill this slot.
                CarouselSealCompanion(index: vm.currentDecisionIndex, dragOffset: sealDragOffset)
                    .frame(width: RCharacterSize.homeSlot.width, height: RCharacterSize.homeSlot.height)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: RSize.buttonHeight)
        .padding(.top, RSpacing.lg)
        .padding(.bottom, RSpacing.md)
    }

    // MARK: - 로딩

    private func loadingView(photoSide: CGFloat) -> some View {
        HomeSurface(centered: false) {
            VStack(alignment: .leading, spacing: 0) {
                weeklyBanner
                homeHeading(String(localized: "사진을 불러오고 있어요."), identifier: "home.loadingTitle", showsCharacter: false)
                ZStack {
                    if let identifier = vm.preparingPhotoIdentifier {
                        // A local preview is not a recommendation until restoration validates it.
                        PHAssetImageView(localIdentifier: identifier,
                            targetSize: CGSize(width: 800, height: 800), allowsNetworkAccess: false,
                            showsLoadingIndicator: false, backgroundColor: .clear)
                            .frame(width: photoSide, height: photoSide)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: RRadius.photo))
                            .accessibilityHidden(true)
                    }
                    RLoadingIndicator(size: min(260, photoSide * 0.8), accessibilityLabel: String(localized: "추천 사진 준비 중"))
                }
                // Reserve the photo's footprint without framing the waiting motion.
                // Only an available photo preview needs the normal photo crop.
                .frame(width: photoSide, height: photoSide)
                .accessibilityIdentifier("home.preparingPhoto")
                .frame(maxWidth: .infinity)
                .padding(.bottom, HomeStyle.photoContextGap)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: RSpacing.xs) {
                        if vm.scanIsTakingLong(at: context.date) {
                            Text("조금 더 걸리고 있어요. 잠시 멈춰도 괜찮아요.")
                                .rTextStyle(.subLabel, color: .rTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("home.slowScan")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } actions: {
            VStack(spacing: HomeStyle.sectionGap) {
                decisionActions(for: nil)
                RButton(title: String(localized: "잠시 멈추기"), variant: .ghost, size: .compact,
                        isDisabled: !vm.canPauseCuration,
                        font: .system(size: labelSize, weight: .semibold)) { vm.pauseCuration() }
                    .accessibilityIdentifier("home.pauseScan")
            }
        }
    }

    // MARK: - 권한 없음

    private var noPermissionView: some View {
        HomeSurface {
            VStack(spacing: RSpacing.lg) {
                RSealIllustration(pose: .curious, width: RCharacterSize.state)
                Text(vm.permissionStatus == .restricted ? String(localized: "이 기기에서는 사진 접근이 제한되어 있어요.") : String(localized: "내 사진을 살펴보려면 접근이 필요해요."))
                    .rTextStyle(.headline).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(vm.permissionStatus == .restricted
                     ? String(localized: "기기의 사용 제한이나 관리 설정을 확인해주세요. 비움 내역은 리포트에서 볼 수 있어요.")
                     : String(localized: "선택한 사진만 허용해도 괜찮아요. 허용한 범위 안에서만 추천을 찾아요."))
                    .rTextStyle(.body, color: .rTextSecondary).multilineTextAlignment(.center)
            }
        } actions: {
            if vm.permissionStatus == .notDetermined {
                RButton(title: String(localized: "다음"), variant: .primary) { Task { await vm.requestPhotoPermission() } }
                    .accessibilityIdentifier("home.requestPhotoPermission")
            } else if vm.permissionStatus != .restricted {
                RButton(title: String(localized: "설정에서 사진 접근 변경"), variant: .primary) { openPhotoSettings() }
                    .accessibilityIdentifier("home.openPhotoSettings")
            }
            if vm.permissionStatus != .notDetermined {
                RButton(title: String(localized: "리포트 보기"), variant: .ghost, size: .compact, action: onOpenReport)
                    .accessibilityIdentifier("home.openRecords")
            }
        }
    }

    private var scanRecoveryHelp: some View {
        DisclosureGroup("사진을 확인하는 방법") {
            VStack(alignment: .leading, spacing: RSpacing.sm) {
                if vm.inaccessiblePhotoCount > 0 {
                    Text("‘사진 더 선택하기’에서 접근할 사진을 추가하거나, ‘다른 사진부터 살펴보기’로 지금 접근 가능한 사진에서 추천을 찾아보세요.")
                    Text("선택 상태와 남긴 기록은 유지돼요. 사진을 비운 것으로 처리하지 않아요.")
                } else {
                    Text(vm.cloudPhotoCount > 0
                         ? String(localized: "인터넷에 연결한 뒤 ‘iCloud에서 사진 불러오기’를 누르면 원본을 받아 다시 확인해요. 사진 앱에서 따로 찾지 않아도 돼요.")
                         : String(localized: "‘사진 다시 확인하기’를 누르면 읽지 못한 사진을 다시 확인해요. 사진을 따로 고를 필요는 없어요."))
                    if vm.cloudPhotoCount > 0 {
                        Text("데이터가 사용될 수 있어요. 원본은 리코코 서버로 보내지 않아요.")
                    }
                }
            }.rTextStyle(.subLabel, color: .rTextSecondary)
                .fixedSize(horizontal: false, vertical: true).padding(.top, RSpacing.sm)
        }
        .rTextStyle(.subLabel, color: .rTextSecondary).tint(.rTextSecondary)
        .frame(minHeight: RSize.minTouchTarget)
        .accessibilityIdentifier("home.scanHelp")
    }

    private func openPhotoSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    // MARK: - 오늘 완료

    private func completedView(summary: CompletionSummary) -> some View {
        HomeSurface {
            VStack(spacing: RSpacing.xl) {
                VStack(spacing: RSpacing.md) {
                    RSealIllustration(
                        pose: .neutral,
                        width: RCharacterSize.state
                    )
                    Text(vm.stoppedReviewingEarly && summary.deletedCount == 0
                         ? String(localized: "사진은 그대로 두었어요.")
                         : (vm.hasBlockingScanIssue ? summary.partialTitle : summary.title))
                        .rTextStyle(.headline)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("home.completionTitle")
                    if summary.deletedCount > 0 || summary.savedRecordCount > 0 {
                        VStack(spacing: RSpacing.xs) {
                            if summary.deletedCount > 0 {
                                statRow(value: String(localized: "\(summary.deletedCount)장"), label: String(localized: "비운 사진"))
                            }

                        }
                    }
                }
                if summary.deletedCount > 0 { PhotoRecoveryGuide() }
                VStack(spacing: RLayout.actionGap) {
                    if vm.hasBlockingScanIssue {
                        Text(vm.scanIssueTitle).rTextStyle(.subLabel)
                            .accessibilityIdentifier("home.nextSessionStatus")
                    }
                    Text(vm.completionMessage)
                        .rTextStyle(.body, color: .rTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("home.nextStepMessage")
                    if vm.hasBlockingScanIssue { scanRecoveryHelp }
                }
                .multilineTextAlignment(.center)
            }
        } actions: {
            completionActions
        }
    }

    /// A completed batch is a natural stopping point, not another task to finish.
    @ViewBuilder private var completionActions: some View {
        finishButton(completed: true, primary: false)
        if let secondary = vm.completionSecondaryAction {
            switch secondary {
            case .findMore, .subscription:
                RButton(title: String(localized: "조금 더 살펴보기"), variant: .ghost, size: .compact) {
                    Task { await vm.loadMoreDecisions() }
                }
                .accessibilityIdentifier("home.morePhotos")
                .accessibilityHint(secondary == .subscription
                    ? String(localized: "추가 추천을 위한 구독 안내를 엽니다.")
                    : String(localized: "아직 살펴보지 않은 사진에서 추천을 찾습니다."))
            case .selectPhotos:
                selectMorePhotosButton(primary: false)
            case .retry:
                RButton(title: vm.scanRetryTitle, variant: .ghost, size: .compact) {
                    Task { await vm.retryCuration() }
                }.accessibilityIdentifier("home.retryScan")
            case .findOtherPhotos:
                findOtherPhotosButton(primary: false)
            case .refresh, .finish:
                EmptyView()
            }
        }
    }

    @ViewBuilder private var emptyPrimaryButton: some View {
        let primary = vm.emptyPrimaryAction
        switch primary {
        case .findMore, .subscription:
            RButton(title: primary == .subscription ? String(localized: "추가 추천 이용 안내") : String(localized: "이어서 찾아보기"), variant: .primary) {
                Task { await vm.loadMoreDecisions() }
            }.accessibilityIdentifier("home.morePhotos")
        case .retry:
            RButton(title: vm.scanRetryTitle, variant: .primary) { Task { await vm.retryCuration() } }
                .accessibilityIdentifier("home.retryScan")
        case .refresh:
            RButton(title: String(localized: "사진 다시 확인하기"), variant: .primary) { Task { await vm.refreshPhotoSelection() } }
                .accessibilityIdentifier("home.refreshPhotos")
        case .selectPhotos:
            selectMorePhotosButton(primary: true)
        case .findOtherPhotos:
            findOtherPhotosButton(primary: true)
        case .finish:
            finishButton(completed: false, primary: true)
        }
    }

    private func selectMorePhotosButton(primary: Bool) -> some View {
        RButton(title: String(localized: "사진 더 선택하기"), variant: primary ? .primary : .ghost,
                size: primary ? .regular : .compact, isDisabled: vm.isCommittingSelection || photoPicker.isOpen) {
            photoPicker.open { result in
                switch result {
                case .changed: Task { await vm.refreshPhotoSelection() }
                case .permissionChanged: Task { await vm.onAppear() }
                case .unavailable: showPhotoAccessHelp = true
                case .unchanged: break
                }
            }
        }
            .accessibilityIdentifier("home.selectMorePhotos")
    }

    private func findOtherPhotosButton(primary: Bool) -> some View {
        RButton(title: String(localized: "다른 사진부터 살펴보기"), variant: primary ? .primary : .ghost,
                size: primary ? .regular : .compact) { Task { await vm.findOtherPhotos() } }
            .accessibilityIdentifier("home.findOtherPhotos")
    }

    private func finishButton(completed: Bool, primary: Bool) -> some View {
        RButton(title: String(localized: "리포트 보기"),
                variant: primary ? .primary : .ghost, size: primary ? .regular : .compact,
                action: onOpenReport)
            .accessibilityIdentifier(completed ? "home.finishSession" : "home.openRecords")
            .accessibilityHint("비운 사진 수와 비움 캘린더를 확인합니다.")
    }

    private func homeSecondaryRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: RSpacing.xs))
            : AnyLayout(HStackLayout(spacing: RSpacing.xs))
        return layout { content() }
    }

    private func statRow(value: String, label: String) -> some View {
        HStack(spacing: RSpacing.xs) {
            Text(value)
                .rTextStyle(.headline)
            Text(label)
                .rTextStyle(.body, color: .rTextSecondary)
        }
    }

    // MARK: - 후보 없음

    private var noCandidateView: some View {
        VStack(spacing: RSpacing.xl) {
            VStack(spacing: RSpacing.md) {
                RSealIllustration(pose: vm.emptyPrimaryAction == .finish ? .nap : .curious, width: RCharacterSize.homeArtwork)
                VStack(spacing: RSpacing.xs) {
                    Text(vm.scanStatusTitle)
                        .font(.system(size: titleSize, weight: .semibold)).foregroundColor(.rTextPrimary)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("home.scanStatusTitle")
                    Text(vm.scanStatusMessage)
                        .font(.system(size: labelSize)).foregroundColor(.rTextSecondary)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
            }
            if vm.hasBlockingScanIssue { scanRecoveryHelp }
            noCandidateActions
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.emptyState")
    }

    /// The status and its next step stay together, with at most one alternative.
    private var noCandidateActions: some View {
        let primary = vm.emptyPrimaryAction
        return VStack(spacing: RLayout.actionGap) {
            emptyPrimaryButton
            if vm.inaccessiblePhotoCount > 0 && primary != .findOtherPhotos {
                findOtherPhotosButton(primary: false)
            } else if vm.isLimitedAccess && primary != .selectPhotos {
                selectMorePhotosButton(primary: false)
            } else if primary != .finish {
                finishButton(completed: false, primary: false)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.bottomActions")
    }

}

/// Home photos and decisions share one natural scroll and the same content edges.
/// Centered permission/completion screens keep their existing spacious layout.
private struct HomeSurface<Content: View, Actions: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var centered = true
    var photoFocusRequest = 0
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        GeometryReader { geometry in
            if !centered || dynamicTypeSize.isAccessibilitySize || geometry.size.height < 440 {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: centered ? RSpacing.lg : 0) {
                            content().padding(.horizontal, RLayout.screenInset)
                            dock
                        }
                        .padding(.top, centered ? RSpacing.lg : RSpacing.sm)
                    }
                    .onChange(of: photoFocusRequest) { _ in
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                            proxy.scrollTo("home.photoAnchor", anchor: .top)
                        }
                    }
                }
            } else {
                VStack(spacing: 0) {
                    GeometryReader { readingArea in
                        ScrollView {
                            content()
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: centered ? max(0, readingArea.size.height - RSpacing.lg * 2) : 0,
                                       alignment: centered ? .center : .top)
                                .padding(.horizontal, RLayout.screenInset)
                                .padding(.vertical, centered ? RSpacing.lg : RSpacing.xs)
                        }
                    }
                    dock
                }
            }
        }
    }

    private var dock: some View {
        VStack(spacing: RSpacing.sm) { actions() }
            .frame(maxWidth: .infinity, minHeight: centered ? RSize.buttonHeight + RSize.minTouchTarget + RSpacing.sm : 0,
                   alignment: .top)
            .padding(.horizontal, RLayout.screenInset)
            .padding(.top, centered ? RSpacing.sm : RSpacing.xs)
            .padding(.bottom, RSpacing.xs)
            .background(Color.rBackground)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home.bottomActions")
    }
}

/// Keep the system picker in the window that owns Home, without presenting a blank SwiftUI sheet first.
private struct PhotoPickerWindowAnchor: UIViewRepresentable {
    let picker: HomeLimitedPhotoPicker

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        picker.anchor = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { picker.anchor = view }
}

@MainActor
private final class HomeLimitedPhotoPicker: ObservableObject {
    enum Result { case changed, unchanged, permissionChanged, unavailable }

    weak var anchor: UIView?
    @Published private(set) var isOpen = false
    private var currentRequest: UUID?
    private var monitor: Task<Void, Never>?

    func open(onFinish: @escaping (Result) -> Void) {
        guard !isOpen else { return }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited else {
            onFinish(.permissionChanged)
            return
        }
        guard let window = anchor?.window, window.windowScene?.activationState == .foregroundActive,
              let presenter = window.rootViewController, presenter.presentedViewController == nil,
              presenter.viewIfLoaded?.window === window else {
            onFinish(.unavailable)
            return
        }

        // Photos reports additions only. Keep a fetch snapshot so a removal-only edit also triggers a refresh.
        let before = PHAsset.fetchAssets(with: .image, options: nil)
        let request = UUID()
        currentRequest = request
        isOpen = true

        func result(added: Bool) -> Result {
            guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited else { return .permissionChanged }
            if added { return .changed }
            let after = PHAsset.fetchAssets(with: .image, options: nil)
            guard before.count == after.count else { return .changed }
            func identifiers(_ assets: PHFetchResult<PHAsset>) -> Set<String> {
                var ids = Set<String>()
                assets.enumerateObjects { asset, _, _ in ids.insert(asset.localIdentifier) }
                return ids
            }
            return identifiers(before) == identifiers(after) ? .unchanged : .changed
        }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: presenter) { [weak self] additions in
            Task { @MainActor in
                self?.finish(request, result: result(added: !additions.isEmpty), onFinish: onFinish)
            }
        }
        // UIKit has no failure callback for an unsuccessful presentation. Some system cancel gestures
        // also dismiss the picker without reporting a selection. Keep both paths retryable.
        monitor = Task { [weak self, weak presenter] in
            let deadline = ContinuousClock.now + .seconds(4)
            var sawPicker = false
            while !Task.isCancelled {
                if presenter?.presentedViewController != nil {
                    sawPicker = true
                } else if sawPicker {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    self?.finish(request, result: result(added: false), onFinish: onFinish)
                    return
                } else if ContinuousClock.now >= deadline {
                    self?.finish(request, result: .unavailable, onFinish: onFinish)
                    return
                }
                try? await Task.sleep(for: .milliseconds(180))
            }
        }
    }

    private func finish(_ request: UUID, result: Result, onFinish: (Result) -> Void) {
        guard currentRequest == request else { return }
        currentRequest = nil
        monitor?.cancel()
        monitor = nil
        isOpen = false
        onFinish(result)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("로딩") {
    HomeView(viewModel: HomeViewModel())
}

#Preview("완료") {
    HomeView(viewModel: HomeViewModel())
}
#endif

/// Short evidence and one retained copy; the current candidate stays above it.
private struct CleanupEvidenceSummary: View {
    let unit: DecisionUnit
    @State private var context: PhotoContextMetadata?
    var body: some View {
        VStack(alignment: .leading, spacing: RSpacing.sm) {
            Text(unit.selectionDetail).rTextStyle(.subLabel)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("home.evidenceDetail")
            if let reference = unit.comparisonLocalIdentifier {
                PHAssetImageView(localIdentifier: reference, targetSize: CGSize(width: 420, height: 420), scalesToFit: true)
                    .frame(maxWidth: .infinity).frame(height: 140)
                    .background(Color.rBackground)
                    .clipShape(RoundedRectangle(cornerRadius: RRadius.md))
                    .accessibilityLabel("남겨둘 사본")
            }
            if let context, let caption = PhotoContextFormatter.caption(capturedAt: context.capturedAt, place: context.place) {
                Text(caption).rTextStyle(.caption, color: .rTextSecondary)
            }
        }
        .task(id: unit.displayIdentifier) {
            let service = PhotoMetadataService()
            context = service.localContext(for: unit.displayIdentifier, capturedAt: unit.capturedAt)
            let result = await service.context(for: unit.displayIdentifier, capturedAt: unit.capturedAt)
            guard !Task.isCancelled else { return }
            context = result
        }
    }
}

private struct CarouselSealCompanion: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let index: Int
    let dragOffset: CGFloat
    @State private var previousIndex: Int?
    @State private var arrivalOffset: CGFloat = 0

    var body: some View {
        let offset = reduceMotion ? 0 : (dragOffset == 0 ? arrivalOffset : dragOffset)
        RSealIllustration(pose: .curious, width: RCharacterSize.homeArtwork)
            .rotationEffect(.degrees(Double(offset) * 0.6))
            .offset(x: offset, y: -abs(offset) * 0.4)
            .task(id: index) {
                let lastIndex = previousIndex
                previousIndex = index
                guard !reduceMotion, let lastIndex, lastIndex != index else {
                    arrivalOffset = 0
                    return
                }
                withAnimation(.easeOut(duration: 0.2)) { arrivalOffset = index > lastIndex ? -4 : 4 }
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.25)) { arrivalOffset = 0 }
            }
    }
}
