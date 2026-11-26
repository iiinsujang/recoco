import SwiftUI
import UIKit
import Network
import Photos

// MARK: - MainTabView
// S-04 홈, S-09 리포트, S-10 마이페이지 탭 컨테이너

struct MainTabView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedTab: RTab = CurationReadOnlyProbe.isRequested ? .report : .home
    @State private var showSavedRecords = false
    @State private var didRunCurationProbe = false
    @StateObject private var homeViewModel = HomeViewModel()

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch selectedTab {
                case .home:
                    HomeView(viewModel: homeViewModel, onOpenReport: {
                        selectedTab = .report
                    }, onOpenRecords: {
                        showSavedRecords = true
                        selectedTab = .report
                    })
                        .transition(.opacity)
                case .report:
                    ReportView(showSavedRecords: $showSavedRecords)
                        .transition(.opacity)
                case .profile:
                    NavigationStack {
                        ProfileView()
                    }
                    .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : RMotion.transition, value: selectedTab)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            RTabBar(selectedTab: $selectedTab)
        }
        .background(Color.rBackground.ignoresSafeArea())
        .task {
            guard CurationReadOnlyProbe.isRequested, !didRunCurationProbe else { return }
            didRunCurationProbe = true
            await CurationReadOnlyProbe.run()
        }
        .onChange(of: selectedTab) { tab in
            // Stop at navigation intent, even if a rapid return interrupts the fade.
            if tab != .home { homeViewModel.pauseCuration(resumingAutomatically: true) }
        }
    }
}

/// Connected-device timing only. Normal launches do not enter this path.
/// Start away from Home so its live queue is never replaced or scanned in parallel.
/// The service receives the current exclusions, but no result is committed to
/// activity, recommendation history, or cleanup selection. Only scalar timing
/// information is written locally; no photo identifiers or content are exported.
private enum CurationReadOnlyProbe {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-recoco-curation-read-only-probe")
    }

    @MainActor
    static func run() async {
        guard isRequested else { return }
        // Keep only this explicitly requested connected-device observation
        // awake; ordinary app launches retain the user's normal idle behavior.
        let previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer }
        let network = NWPathMonitor()
        network.start(queue: DispatchQueue(label: "recoco.read-only-network-observation", qos: .utility))
        defer { network.cancel() }
        // Store getters can migrate legacy sessions or rotate a day. Run those
        // reads against an isolated snapshot, never the live app preferences.
        let suiteName = "recoco.curation-probe." + UUID().uuidString
        guard let snapshot = UserDefaults(suiteName: suiteName),
              let bundle = Bundle.main.bundleIdentifier else { return }
        let arguments = ProcessInfo.processInfo.arguments
        #if targetEnvironment(simulator)
        // Repeat synthetic first-use measurements without clearing the test
        // app's records. This option cannot bypass real-device exclusions.
        let emptySnapshot = arguments.contains("-recoco-curation-probe-empty-snapshot")
        #else
        let emptySnapshot = false
        #endif
        if !emptySnapshot {
            snapshot.register(defaults: UserDefaults.standard.persistentDomain(forName: bundle) ?? [:])
        }
        defer { snapshot.removePersistentDomain(forName: suiteName) }
        let activity = LocalActivityStore(defaults: snapshot)
        let session = activity.dailySessionProgress()
        let visited = activity.scannedPhotoIdentifiers()
        let protected = CurationProtectionStore(defaults: snapshot).identifiers()
            .union(activity.recommendationExcludedIdentifiers())
            .union(session.curatedPhotoIdentifiers)
            .union(session.processedDecisionKeys)
            .union(session.comparisonReferences.values)
        let reviewDates = CurationReviewStore(defaults: snapshot).dates()
        let coldCuration = arguments.contains("-recoco-curation-probe-cold")
        let extendedDiagnostic = arguments.contains("-recoco-curation-probe-extended")
        let limit = arguments.contains("-recoco-curation-probe-three") ? 3 : 1
        // A cold probe excludes Recoco's saved proofs, not PhotoKit's OS cache.
        // The live Home queue and recommendation history remain untouched.
        let service = PhotoCurationService(usePersistentProofs: !coldCuration)
        let started = ProcessInfo.processInfo.systemUptime
        var firstCandidateSeconds: Double?
        var threeCandidatesSeconds: Double?
        var candidateCount = 0
        var reasonGroups: [String] = []
        var previewTasks: [String: Task<Void, Never>] = [:]
        var readyPreviews = Set<String>()
        defer { previewTasks.values.forEach { $0.cancel() } }
        var payload: [String: Any] = ["schema": 2, "mode": "read-only-new-service",
                                     "status": "running", "limit": limit,
                                     "persistentProofsEnabled": !coldCuration,
                                     "snapshotSource": emptySnapshot ? "isolated-empty-simulator" : "live-read-only-copy",
                                     "diagnosticBudgetSeconds": extendedDiagnostic ? 92 : 12,
                                     "photoKitCacheReset": false,
                                     "existingQueueCount": session.curatedPhotoIdentifiers.count]

        func save() {
            // Diagnostic scalars only: no SSID, addresses, photo identifiers,
            // request URLs or account data are recorded.
            let path = network.currentPath
            payload["networkSatisfied"] = path.status == .satisfied
            payload["networkWiFi"] = path.usesInterfaceType(.wifi)
            payload["networkCellular"] = path.usesInterfaceType(.cellular)
            payload["networkConstrained"] = path.isConstrained
            payload["lowPowerMode"] = ProcessInfo.processInfo.isLowPowerModeEnabled
            payload["thermalState"] = ProcessInfo.processInfo.thermalState.rawValue
            guard let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
                  let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: directory.appendingPathComponent("recoco-curation-read-only-probe.json"), options: .atomic)
        }

        func checkCarouselPreview(_ identifier: String) {
            guard previewTasks[identifier] == nil else { return }
            previewTasks[identifier] = Task { @MainActor in
                // Use the Home presenter's actual size and readiness rules,
                // without replacing the user's queue or changing a checkbox.
                await HomePhotoPreviewCache.prepare([identifier], preserving: session.curatedPhotoIdentifiers,
                    canContinue: { UIApplication.shared.applicationState == .active })
                guard !Task.isCancelled, let asset = HomePhotoPreviewCache.accessibleAsset(identifier) else { return }
                let size = CGSize(width: 800, height: 800)
                let fit = asset.mediaSubtypes.contains(.photoScreenshot)
                let key = HomePhotoPreviewCache.Key(asset: asset, size: size, fit: fit)
                guard let image = HomePhotoPreviewCache.image(for: key), HomePhotoPreviewQuality.isUsable(image.image,
                    minimum: HomePhotoPreviewQuality.minimumSize(
                        original: CGSize(width: asset.pixelWidth, height: asset.pixelHeight), target: size, fit: fit)) else { return }
                readyPreviews.insert(identifier)
                if payload["firstCarouselPreviewReadySeconds"] == nil {
                    payload["firstCarouselPreviewReadySeconds"] = ProcessInfo.processInfo.systemUptime - started
                }
                payload["carouselPreviewsReady"] = readyPreviews.count
                if readyPreviews.count == 3 {
                    payload["threeCarouselPreviewsReadySeconds"] = ProcessInfo.processInfo.systemUptime - started
                }
                save()
            }
        }

        save()
        let result = await HomeCurationSearch.curatedContinuing(
            excluding: visited, protectedIdentifiers: protected, initialDecisions: [], limit: limit,
            diversityTimeLimit: extendedDiagnostic ? 92 : HomeCurationSearch.foregroundDiversityTimeLimit,
            maximumSlices: extendedDiagnostic ? 23 : 3,
            onUpdate: { batch in
                guard !batch.decisions.isEmpty else { return }
                if firstCandidateSeconds == nil {
                    firstCandidateSeconds = ProcessInfo.processInfo.systemUptime - started
                }
                candidateCount = batch.decisions.count
                if candidateCount >= 3 && threeCandidatesSeconds == nil {
                    threeCandidatesSeconds = ProcessInfo.processInfo.systemUptime - started
                }
                reasonGroups = batch.decisions.compactMap { $0.reasonCodes.first?.rawValue }
                payload["firstCandidateSeconds"] = firstCandidateSeconds
                payload["threeCandidatesSeconds"] = threeCandidatesSeconds
                payload["candidateCount"] = candidateCount
                payload["reasons"] = reasonGroups
                save()
                for identifier in batch.decisions.compactMap(\.displayIdentifier) { checkCarouselPreview(identifier) }
            }) { excluded, protectedIDs, remaining, represented in
                await service.fetchNextBatch(excluding: excluded, protectedIdentifiers: protectedIDs,
                    reviewDates: reviewDates, limit: remaining, firstResult: true,
                    excludingReasonGroups: represented)
            }
        for preview in previewTasks.values { await preview.value }
        payload["status"] = Task.isCancelled ? "cancelled" : "finished"
        payload["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started
        payload["candidateCount"] = candidateCount
        payload["reasons"] = reasonGroups
        payload["hasMore"] = result?.hasMore
        payload["hasFreshPhotos"] = result?.hasFreshPhotos
        payload["retryableReads"] = result?.retryableFailureCount
        save()
        CurationTimingDiagnostics.flush()
    }
}

// MARK: - RecordView (S-07 진입점 — RecordInputView로 연결)

struct RecordView: View {
    let unit: DecisionUnit
    var selectedImage: UIImage? = nil
    var onOpenRecords: (() -> Void)? = nil
    var returnsAfterSave = false
    let onCompleted: (SavedMemoryRecord) -> Void

    var body: some View {
        RecordInputView(unit: unit, selectedImage: selectedImage,
                        onOpenRecords: onOpenRecords, returnsAfterSave: returnsAfterSave,
                        onCompleted: onCompleted)
    }
}

#if DEBUG
#Preview {
    MainTabView()
        .environmentObject(AppRouter())
}
#endif
