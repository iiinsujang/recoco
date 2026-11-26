import AuthenticationServices
import FirebaseAuth
import FirebaseCore
import Photos
import SwiftUI
import UIKit
import UserNotifications

// MARK: - S-10 마이페이지

struct ProfileView: View {
    @EnvironmentObject private var router: AppRouter
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var vm = ProfileViewModel()

    var body: some View {
        ZStack {
            Color.rBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                RWordmarkHeader()

                RDivider()

                ScrollView {
                    VStack(spacing: 0) {
                        // 프로필
                        profileSection
                            .padding(.bottom, RSpacing.xl)

                        // 메뉴
                        menuSection

                        // 버전 + 로그아웃
                        footerSection
                            .padding(.top, RSpacing.xl)
                    }
                    .rScreenPadding()
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $vm.showNotification) {
            NotificationSettingsView()
        }
        .navigationDestination(isPresented: $vm.showPhotoAccess) {
            PhotoAccessManageView()
        }
        .navigationDestination(isPresented: $vm.showDeletion) {
            AccountDeletionView {
                vm.showDeletion = false
                Task { await vm.onAppear() }
            }
        }
        .sheet(isPresented: $vm.showLogin) {
            LoginView(onCompleted: {
                vm.showLogin = false
                Task { await vm.onAppear() }
            })
            .environmentObject(router)
        }
        .alert("로그아웃", isPresented: $vm.showLogoutConfirm) {
            Button("로그아웃", role: .destructive) {
                if vm.logout() { Task { await vm.onAppear() } }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("이 기기의 사진과 비움 내역은 그대로 남아요.")
        }
        .task { await vm.onAppear() }
        .onDisappear { vm.stopObservingAuthentication() }
        .onChange(of: vm.showPhotoAccess) { showing in
            if !showing { Task { await vm.refreshSettingsSummary() } }
        }
        .onChange(of: vm.showNotification) { showing in
            if !showing { Task { await vm.refreshSettingsSummary() } }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { Task { await vm.onAppear() } }
        }
    }

    // MARK: - 프로필

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: RSpacing.md) {
            HStack(spacing: RSpacing.md) {
                avatarView
                VStack(alignment: .leading, spacing: RSpacing.xxs) {
                    Text(vm.displayName.isEmpty ? String(localized: "나의 리코코") : vm.displayName)
                        .rTextStyle(.section)
                    if !vm.email.isEmpty {
                        Text(vm.email).rTextStyle(.subLabel, color: .rTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            if vm.isLocalSession {
                RButton(title: String(localized: "Apple로 로그인"), variant: .secondary) {
                    vm.showLogin = true
                }
                .accessibilityIdentifier("profile.login")
            } else {
                Text("사진과 비움 내역은 이 기기에 저장돼요.")
                    .rTextStyle(.caption, color: .rTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(RSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.rSurface, in: RoundedRectangle(cornerRadius: RRadius.lg))
    }

    @ViewBuilder
    private var avatarView: some View {
        if let url = vm.photoURL {
            AsyncImage(url: url) { image in image.resizable().scaledToFill() }
                placeholder: { brandAvatar }
                .frame(width: 80, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: RRadius.md))
        } else { brandAvatar }
    }

    private var brandAvatar: some View {
        RSealIllustration(pose: .neutral, width: 80)
            .frame(width: 80, height: 64)
            .background(Color.rBrandMist, in: RoundedRectangle(cornerRadius: RRadius.md))
    }

    // MARK: - 메뉴

    private var menuSection: some View {
        VStack(spacing: 0) {
            menuRow(title: String(localized: "사진 접근 관리"), value: vm.photoAccessSummary,
                    identifier: "profile.photoAccess") {
                vm.showPhotoAccess = true
            }
            RDivider()

            menuRow(title: String(localized: "알림 설정"), value: vm.notificationSummary,
                    identifier: "profile.notifications") {
                vm.showNotification = true
            }
            RDivider()

            menuRow(title: String(localized: "개인정보 안내"), value: String(localized: "사진·계정 정보"),
                    identifier: "profile.privacy") {
                if let url = URL(
                    string: "https://github.com/iiinsujang/recoco/blob/main/PRIVACY_POLICY.md"
                ) {
                    UIApplication.shared.open(url)
                }
            }
            RDivider()
        }
    }

    private func menuRow(
        title: String,
        value: String,
        identifier: String,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: RSpacing.md) {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: RSpacing.xxs))
                    : AnyLayout(HStackLayout(spacing: RSpacing.md))
                layout {
                    Text(title)
                        .font(.rButton)
                        .foregroundColor(isDestructive ? .rDestructive : .rTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(value)
                        .rTextStyle(.subLabel, color: .rTextSecondary)
                        .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isDestructive ? .rDestructive : .rTextTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, RSpacing.lg)
            .frame(minHeight: RLayout.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(RPressFeedbackStyle())
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityIdentifier(identifier)
    }

    // MARK: - 푸터

    private var footerSection: some View {
        VStack(spacing: RSpacing.md) {
            if !vm.isLocalSession {
                VStack(spacing: 0) {
                    menuRow(title: String(localized: "로그아웃"), value: String(localized: "기기 내역 유지"),
                            identifier: "profile.logout") {
                        vm.showLogoutConfirm = true
                    }
                    RDivider()
                    menuRow(title: String(localized: "회원탈퇴"), value: String(localized: "계정 삭제"),
                            identifier: "profile.deleteAccount", isDestructive: true) {
                        vm.showDeletion = true
                    }
                }
            }
            Text("recoco v\(vm.appVersion)")
                .rTextStyle(.caption, color: .rTextTertiary)
                .accessibilityIdentifier("profile.appVersion")

            if let message = vm.logoutErrorMessage {
                Text(message)
                    .rTextStyle(.caption, color: .rDestructive)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("profile.logoutError")
            }
        }
        .padding(.bottom, RSpacing.xxxl)
    }
}

// MARK: - ProfileViewModel

struct ProfileAccountClient {
    struct Identity {
        let displayName: String?
        let email: String?
        let photoURL: URL?
    }

    let current: () -> Identity?
    let observe: (@escaping () -> Void) -> (() -> Void)?

    static func live() -> Self {
        Self(current: {
            guard FirebaseApp.app() != nil, let user = Auth.auth().currentUser else { return nil }
            return Identity(displayName: user.displayName, email: user.email, photoURL: user.photoURL)
        }, observe: { changed in
            guard FirebaseApp.app() != nil else { return nil }
            let auth = Auth.auth()
            let handle = auth.addStateDidChangeListener { _, _ in changed() }
            return { auth.removeStateDidChangeListener(handle) }
        })
    }
}

private final class ProfileAuthObservation {
    private var cancellation: (() -> Void)?
    init(_ cancellation: @escaping () -> Void) { self.cancellation = cancellation }
    func cancel() {
        let action = cancellation
        cancellation = nil
        action?()
    }
    deinit { cancellation?() }
}

@MainActor
final class ProfileViewModel: ObservableObject {
    @Published var displayName: String = ""
    @Published var email: String = ""
    @Published var photoURL: URL? = nil
    @Published private(set) var isLocalSession = true
    @Published var showNotification: Bool = false
    @Published var showPhotoAccess: Bool = false
    @Published var showLogin: Bool = false
    @Published var showDeletion: Bool = false
    @Published var showLogoutConfirm: Bool = false
    @Published private(set) var logoutErrorMessage: String?
    @Published private(set) var photoAccessSummary = String(localized: "확인 중")
    @Published private(set) var notificationSummary = String(localized: "확인 중")

    private let signOut: () throws -> Void
    private let finishSignOut: () -> Void
    private let localDefaults: UserDefaults
    private let accountClient: ProfileAccountClient
    private var authObservation: ProfileAuthObservation?
    private var authObservationID = UUID()

    init(signOut: @escaping () throws -> Void = {
        if FirebaseApp.app() != nil { try Auth.auth().signOut() }
    }, localDefaults: UserDefaults = .standard, finishSignOut: @escaping () -> Void = {},
         accountClient: ProfileAccountClient = .live()) {
        self.signOut = signOut
        self.localDefaults = localDefaults
        self.finishSignOut = finishSignOut
        self.accountClient = accountClient
    }

    var initials: String {
        displayName.isEmpty ? "R" : displayName.prefix(1).uppercased()
    }

    var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        guard let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String else { return version }
        return "\(version) (\(build))"
    }

    func onAppear() async {
        startObservingAuthentication()
        refreshAccountProfile()
        await refreshSettingsSummary()
    }

    func startObservingAuthentication() {
        guard authObservation == nil else { return }
        let generation = UUID()
        authObservationID = generation
        if let cancellation = accountClient.observe({ [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.authObservationID == generation else { return }
                // Query the current identity rather than applying an old callback's user.
                self.refreshAccountProfile()
            }
        }) {
            authObservation = ProfileAuthObservation(cancellation)
        }
    }

    func stopObservingAuthentication() {
        authObservationID = UUID()
        authObservation?.cancel()
        authObservation = nil
    }

    private func refreshAccountProfile() {
        guard let user = accountClient.current() else {
            isLocalSession = true
            displayName = String(localized: "나의 리코코")
            email = String(localized: "비움 내역은 이 기기에 남아요.")
            photoURL = nil
            return
        }

        isLocalSession = false
        displayName = user.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if displayName.isEmpty {
            displayName = user.email?.components(separatedBy: "@").first ?? String(localized: "recoco 사용자")
        }
        email = user.email ?? ""
        photoURL = user.photoURL
    }

    func refreshSettingsSummary(notificationClient: NotificationSettingsClient = .live()) async {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: photoAccessSummary = String(localized: "전체 접근")
        case .limited: photoAccessSummary = String(localized: "선택한 사진")
        case .denied: photoAccessSummary = String(localized: "접근 꺼짐")
        case .restricted: photoAccessSummary = String(localized: "접근 제한")
        case .notDetermined: photoAccessSummary = String(localized: "설정 전")
        @unknown default: photoAccessSummary = String(localized: "확인 필요")
        }

        let authorization = await notificationClient.authorizationStatus()
        let scheduledTime = await notificationClient.scheduledTime()
        let permitted = [UNAuthorizationStatus.authorized, .provisional, .ephemeral].contains(authorization)
        // iPhone Settings can change permission without opening our notification
        // screen. Keep this summary and the saved flag aligned with the real schedule.
        notificationClient.persist(permitted && scheduledTime != nil, scheduledTime ?? notificationClient.savedTime())
        if let scheduledTime {
            notificationSummary = permitted ? scheduledTime.label : String(localized: "권한 꺼짐")
        } else {
            notificationSummary = String(localized: "꺼짐")
        }
    }

    func logout() -> Bool {
        logoutErrorMessage = nil
        guard LocalSession.begin(defaults: localDefaults) else {
            logoutErrorMessage = String(localized: "기기 저장 상태를 확인하지 못했어요. 다시 시도해주세요.")
            return false
        }
        do {
            // Firebase must release its session before provider cleanup or navigation.
            try signOut()
            finishSignOut()
            isLocalSession = true
            displayName = String(localized: "나의 리코코")
            email = String(localized: "비움 내역은 이 기기에 남아요.")
            photoURL = nil
            return true
        } catch {
            logoutErrorMessage = String(localized: "로그아웃을 완료하지 못했어요. 다시 시도해주세요.")
            return false
        }
    }
}

// MARK: - S-11 알림 설정

struct NotificationSettingsView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var vm = NotificationSettingsViewModel()

    var body: some View {
        ZStack {
            Color.rBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: RSpacing.xl) {
                        toggleSection.disabled(vm.isBusy)

                        if vm.isEnabled {
                            timePickerSection.disabled(vm.isBusy)
                            previewSection
                            RButton(
                                title: vm.isSavingTime ? String(localized: "저장 중…") : vm.didSaveTime ? String(localized: "저장했어요") : String(localized: "알림 시간 저장하기"),
                                variant: .primary,
                                isLoading: vm.isSavingTime,
                                isDisabled: vm.isBusy || !vm.hasTimeChanges
                            ) {
                                vm.saveTime()
                            }
                            .accessibilityIdentifier("notifications.saveTime")
                        }
                    }
                    .rScreenPadding()
                }
            }
        }
        .navigationTitle("알림 설정")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(Color.rBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .tint(.rTextPrimary)
        .alert("알림 권한이 꺼져 있어요.", isPresented: $vm.showPermissionAlert) {
            Button("설정으로 이동") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("iPhone 설정에서 알림을 허용한 뒤 다시 켜주세요.")
        }
        .alert("알림 설정을 변경하지 못했어요.", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(vm.errorMessage ?? String(localized: "잠시 후 다시 시도해주세요."))
        }
        .task { await vm.refresh() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { Task { await vm.refresh() } }
        }
    }

    private var toggleSection: some View {
        RCard {
            HStack {
                VStack(alignment: .leading, spacing: RSpacing.xxs) {
                    Text("알림 켜기").rTextStyle(.body)
                    Text(vm.toggleDescription)
                        .rTextStyle(.caption, color: .rTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { vm.isEnabled }, set: vm.setEnabled))
                    .labelsHidden()
                    .accessibilityLabel("정리 시간 알림")
                    .accessibilityIdentifier("notifications.enabled")
                    .tint(.rAccent)
            }
        }
    }

    private var timePickerSection: some View {
        RCard {
            VStack(alignment: .leading, spacing: RSpacing.sm) {
                Text("매일 \(vm.committedTime.label)에 알려드려요.")
                    .rTextStyle(.subLabel, color: .rTextSecondary)

                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(spacing: RSpacing.sm))
                    : AnyLayout(HStackLayout(spacing: RSpacing.sm))
                layout {
                    Picker("시", selection: $vm.selectedHour) {
                        ForEach(0..<24, id: \.self) { hour in
                            Text("\(hour.formatted(.number.precision(.integerLength(2))))시").tag(hour)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity)

                    Picker("분", selection: $vm.selectedMinute) {
                        Text("00분").tag(0)
                        Text("30분").tag(30)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: vm.selectedHour) { _ in vm.clearSavedFeedback() }
                .onChange(of: vm.selectedMinute) { _ in vm.clearSavedFeedback() }
            }
        }
    }

    private var previewSection: some View {
        DisclosureGroup {
            Text(NotificationSettingsClient.previewMessage).rTextStyle(.body)
                .padding(.top, RSpacing.xs)
        } label: {
            Text("알림 미리보기").rTextStyle(.subLabel, color: .rTextSecondary)
                .frame(minHeight: RSize.minTouchTarget)
        }
        .tint(.rAccent)
    }
}

struct NotificationReminderTime: Equatable {
    let hour: Int
    let minute: Int

    init(hour: Int, minute: Int) {
        self.hour = min(23, max(0, hour))
        self.minute = minute < 30 ? 0 : 30
    }

    var label: String {
        // Retain the existing Korean 24-hour display; elsewhere respect the device’s hour cycle.
        if Locale.autoupdatingCurrent.language.languageCode == "ko" {
            return String(format: "%02d:%02d", hour, minute)
        }
        let date = Calendar.current.date(from: DateComponents(hour: hour, minute: minute)) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}

/// The system scheduler is the source of truth. Inject these operations to test
/// permission denial, delayed scheduling, and failures without sending alerts.
struct NotificationSettingsClient {
    static let previewMessage = String(localized: "잠깐, 사진을 살펴볼까요?")
    var authorizationStatus: () async -> UNAuthorizationStatus
    var requestAuthorization: () async throws -> Bool
    var scheduledTime: () async -> NotificationReminderTime?
    var schedule: (NotificationReminderTime) async throws -> Void
    var remove: () -> Void
    var savedTime: () -> NotificationReminderTime
    var persist: (Bool, NotificationReminderTime) -> Void
    var announce: (String) -> Void

    private static let reminderCopyVersion = "recoco.localizedReminder.v1"

    // A request scheduled by the Korean-only version already lives in iOS.
    // Reuse its trigger (including time zone) so only the displayed copy changes.
    static func localizedReplacement(for request: UNNotificationRequest) -> UNNotificationRequest? {
        guard request.identifier == "recoco.daily",
              let trigger = request.trigger as? UNCalendarNotificationTrigger, trigger.repeats,
              request.content.userInfo[reminderCopyVersion] == nil,
              request.content.body == "잠깐, 사진을 살펴볼까요?",
              let content = request.content.mutableCopy() as? UNMutableNotificationContent else { return nil }
        setLocalizedReminderBody(on: content)
        return UNNotificationRequest(identifier: request.identifier, content: content, trigger: trigger)
    }

    private static func setLocalizedReminderBody(on content: UNMutableNotificationContent) {
        content.body = NSString.localizedUserNotificationString(forKey: "잠깐, 사진을 살펴볼까요?", arguments: nil)
        content.userInfo[reminderCopyVersion] = true
    }

    static let migrateLegacyReminder = Task<Void, Never> {
        let center = UNUserNotificationCenter.current()
        let authorization = await center.notificationSettings().authorizationStatus
        guard [.authorized, .provisional, .ephemeral].contains(authorization) else { return }
        let pending = await center.pendingNotificationRequests()
        if let existing = pending.first(where: { $0.identifier == "recoco.daily" }),
           let replacement = localizedReplacement(for: existing) {
            try? await center.add(replacement)
        }
    }

    static func live(defaults: UserDefaults = .standard) -> Self {
        let center = UNUserNotificationCenter.current()
        return Self(
            authorizationStatus: {
                // A settings edit must never race a legacy reschedule.
                await Self.migrateLegacyReminder.value
                let settings = await center.notificationSettings()
                return settings.authorizationStatus
            },
            requestAuthorization: { try await center.requestAuthorization(options: [.alert, .sound, .badge]) },
            scheduledTime: {
                let requests = await center.pendingNotificationRequests()
                guard let request = requests.first(where: { $0.identifier == "recoco.daily" }),
                      let trigger = request.trigger as? UNCalendarNotificationTrigger,
                      let hour = trigger.dateComponents.hour,
                      let minute = trigger.dateComponents.minute else { return nil }
                return NotificationReminderTime(hour: hour, minute: minute)
            },
            schedule: { time in
                let content = UNMutableNotificationContent()
                content.title = "RECOCO"
                Self.setLocalizedReminderBody(on: content)
                content.sound = .default
                var components = DateComponents()
                components.hour = time.hour
                components.minute = time.minute
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
                try await center.add(UNNotificationRequest(identifier: "recoco.daily", content: content, trigger: trigger))
            },
            remove: { center.removePendingNotificationRequests(withIdentifiers: ["recoco.daily"]) },
            savedTime: {
                NotificationReminderTime(
                    hour: defaults.object(forKey: "recoco_notification_hour") == nil ? 9 : defaults.integer(forKey: "recoco_notification_hour"),
                    minute: defaults.integer(forKey: "recoco_notification_minute"))
            },
            persist: { enabled, time in
                defaults.set(enabled, forKey: "recoco_notification_enabled")
                defaults.set(time.hour, forKey: "recoco_notification_hour")
                defaults.set(time.minute, forKey: "recoco_notification_minute")
            },
            announce: { UIAccessibility.post(notification: .announcement, argument: $0) }
        )
    }
}

@MainActor
final class NotificationSettingsViewModel: ObservableObject {
    private enum Operation: Equatable { case refreshing, changingEnabled, savingTime }
    private enum UpdateError: Error { case scheduleNotApplied }
    private struct Snapshot {
        let authorization: UNAuthorizationStatus
        let time: NotificationReminderTime?
        var permitsNotifications: Bool { [.authorized, .provisional, .ephemeral].contains(authorization) }
        var isEnabled: Bool { permitsNotifications && time != nil }
    }

    @Published private(set) var isEnabled = false
    @Published var selectedHour: Int
    @Published var selectedMinute: Int
    @Published private(set) var committedTime: NotificationReminderTime
    @Published private(set) var didSaveTime = false
    @Published var showPermissionAlert = false
    @Published var errorMessage: String?
    @Published private var operation: Operation?
    @Published private var hasLoaded = false
    private let client: NotificationSettingsClient

    init(client: NotificationSettingsClient = .live()) {
        self.client = client
        let time = client.savedTime()
        committedTime = time
        selectedHour = time.hour
        selectedMinute = time.minute
    }

    var isBusy: Bool { !hasLoaded || operation != nil }
    var isSavingTime: Bool { operation == .savingTime }
    var hasTimeChanges: Bool { NotificationReminderTime(hour: selectedHour, minute: selectedMinute) != committedTime }
    var toggleDescription: String {
        if operation == .changingEnabled { return isEnabled ? String(localized: "알림을 켜고 있어요…") : String(localized: "알림을 끄고 있어요…") }
        return String(localized: "켜기·끄기는 바로 적용돼요. 시간만 바꾸면 저장해주세요.")
    }

    func clearSavedFeedback() {
        if hasTimeChanges { didSaveTime = false }
    }

    func refresh() async {
        guard operation == nil else { return }
        let preserveDraft = hasLoaded && hasTimeChanges
        operation = .refreshing
        apply(await snapshot(), preserveDraft: preserveDraft)
        client.persist(isEnabled, committedTime)
        hasLoaded = true
        operation = nil
    }

    func setEnabled(_ enabled: Bool) {
        guard !isBusy, enabled != isEnabled else { return }
        // Lock synchronously before starting the task so queued fast taps cannot
        // issue overlapping add/remove requests. Leaving the view does not cancel it.
        operation = .changingEnabled
        isEnabled = enabled
        didSaveTime = false
        errorMessage = nil
        Task { await changeEnabled(to: enabled) }
    }

    private func changeEnabled(to enabled: Bool) async {
        defer { operation = nil }
        do {
            if enabled {
                let status = await client.authorizationStatus()
                if status == .notDetermined {
                    guard try await client.requestAuthorization() else {
                        await handlePermissionDenied(showSettings: false)
                        return
                    }
                } else if ![UNAuthorizationStatus.authorized, .provisional, .ephemeral].contains(status) {
                    await handlePermissionDenied(showSettings: true)
                    return
                }
                // Toggling does not commit an unfinished time edit.
                try await client.schedule(committedTime)
                let actual = await snapshot()
                guard actual.isEnabled, actual.time == committedTime else { throw UpdateError.scheduleNotApplied }
                apply(actual, preserveDraft: false)
            } else {
                client.remove()
                let actual = await snapshot()
                guard actual.time == nil else { throw UpdateError.scheduleNotApplied }
                apply(actual, preserveDraft: false)
            }
            client.persist(isEnabled, committedTime)
            client.announce(isEnabled ? String(localized: "매일 \(committedTime.label) 알림을 켰어요.") : String(localized: "알림을 껐어요."))
        } catch {
            await recoverAfterFailure(preserveDraft: false)
        }
    }

    func saveTime() {
        guard !isBusy, isEnabled, hasTimeChanges else { return }
        let desired = NotificationReminderTime(hour: selectedHour, minute: selectedMinute)
        operation = .savingTime
        didSaveTime = false
        errorMessage = nil
        Task {
            defer { operation = nil }
            do {
                let before = await snapshot()
                guard before.permitsNotifications else {
                    await handlePermissionDenied(showSettings: true)
                    return
                }
                try await client.schedule(desired)
                let actual = await snapshot()
                guard actual.isEnabled, actual.time == desired else { throw UpdateError.scheduleNotApplied }
                apply(actual, preserveDraft: false)
                client.persist(true, committedTime)
                didSaveTime = true
                client.announce(String(localized: "알림 시간을 \(committedTime.label)으로 저장했어요."))
            } catch {
                // Keep the time draft available for retry while showing the real
                // scheduled time, not the attempted value, above the controls.
                await recoverAfterFailure(preserveDraft: true)
            }
        }
    }

    private func snapshot() async -> Snapshot {
        let authorization = await client.authorizationStatus()
        return Snapshot(authorization: authorization, time: await client.scheduledTime())
    }

    private func apply(_ actual: Snapshot, preserveDraft: Bool) {
        isEnabled = actual.isEnabled
        if let time = actual.time { committedTime = time }
        if !preserveDraft {
            selectedHour = committedTime.hour
            selectedMinute = committedTime.minute
        }
    }

    private func handlePermissionDenied(showSettings: Bool) async {
        // Do not leave a dormant request that could reactivate after Settings.
        client.remove()
        apply(await snapshot(), preserveDraft: false)
        client.persist(isEnabled, committedTime)
        showPermissionAlert = showSettings
        client.announce(String(localized: "알림은 꺼져 있어요."))
    }

    private func recoverAfterFailure(preserveDraft: Bool) async {
        var actual = await snapshot()
        if !actual.permitsNotifications, actual.time != nil {
            client.remove()
            actual = await snapshot()
        }
        apply(actual, preserveDraft: preserveDraft && actual.isEnabled)
        client.persist(isEnabled, committedTime)
        errorMessage = isEnabled
            ? String(localized: "알림은 매일 \(committedTime.label)로 설정돼 있어요. 다시 시도해주세요.")
            : String(localized: "알림은 꺼져 있어요. 다시 시도해주세요.")
    }
}

// MARK: - S-12 사진 접근 관리

struct PhotoAccessManageView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var authStatus: String = String(localized: "확인 중...")

    var body: some View {
        ZStack {
            Color.rBackground.ignoresSafeArea()

            ScrollView {
              VStack(spacing: RSpacing.md) {
                RCard {
                    VStack(alignment: .leading, spacing: RSpacing.sm) {
                        Text("사진 접근 상태")
                            .rTextStyle(.subLabel, color: .rTextSecondary)
                        Text(authStatus)
                            .rTextStyle(.body)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                RButton(title: String(localized: "설정으로 이동하기"), variant: .primary) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
              .rScreenPadding()
            }
        }
        .navigationTitle("사진 접근 관리")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(Color.rBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .tint(.rTextPrimary)
        .onAppear { updateStatus() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { updateStatus() }
        }
    }

    private func updateStatus() {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized:  authStatus = String(localized: "전체 사진첩에 접근할 수 있어요.")
        case .limited:     authStatus = String(localized: "현재 선택한 사진만 보고 있어요.")
        case .denied, .restricted: authStatus = String(localized: "사진 접근 권한이 없어요.")
        default:           authStatus = String(localized: "권한이 설정되지 않았어요.")
        }
    }
}

// MARK: - S-13 회원탈퇴

struct AccountDeletionView: View {
    let onDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = AccountDeletionViewModel()

    var body: some View {
        ZStack {
            Color.rBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: RSpacing.xl) {
                        // 안내
                        warningSection

                        // 삭제 항목 안내
                        deletionInfoSection

                        // 버튼
                        actionButtons
                    }
                    .rScreenPadding()
                }
            }
        }
        .navigationTitle("회원탈퇴")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(vm.isDeleting)
        .interactiveDismissDisabled(vm.isDeleting)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(Color.rBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .tint(.rTextPrimary)
        .alert("정말 탈퇴하시겠어요?", isPresented: $vm.showConfirm) {
            Button("탈퇴하기", role: .destructive) {
                Task { await vm.deleteAccount(onDeleted: onDeleted) }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("계정 정보가 삭제돼요. 이 기기의 사진과 비움 내역은 그대로 남아요.")
        }
        .rToast(isPresented: $vm.showToast, message: vm.toastMessage)
    }

    private var warningSection: some View {
        VStack(alignment: .leading, spacing: RSpacing.sm) {
            Text("탈퇴 전 확인해주세요.")
                .rTextStyle(.headline)
            Text("계정 정보는 삭제되며 복구할 수 없어요.\n이 기기의 사진과 이용 내역은 유지돼요.")
                .rTextStyle(.body, color: .rTextSecondary)
            if SubscriptionStore.shared.salesEnabled {
                Text("계정을 삭제해도 Apple 구독은 자동 취소되지 않아요. 구독 중이라면 먼저 Apple 구독 설정에서 취소해주세요.")
                    .rTextStyle(.caption, color: .rTextSecondary)
                    .lineSpacing(RLineSpacing.body)
            }
        }
    }

    private var deletionInfoSection: some View {
        RCard {
            VStack(alignment: .leading, spacing: RSpacing.sm) {
                Text("삭제되는 항목")
                    .rTextStyle(.subLabel, color: .rTextSecondary)

                deletionRow(String(localized: "로그인 계정과 이메일"))

                RDivider()

                HStack(spacing: RSpacing.xs) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 13))
                        .foregroundColor(.rTextTertiary)
                    Text("사진·비움 내역·기존 기록은 이 기기에 남아요.")
                        .rTextStyle(.caption, color: .rTextTertiary)
                }
            }
        }
    }

    private func deletionRow(_ text: String) -> some View {
        HStack(spacing: RSpacing.xs) {
            Circle()
                .fill(Color.rTextTertiary)
                .frame(width: 4, height: 4)
            Text(text)
                .rTextStyle(.subLabel, color: .rTextSecondary)
        }
    }

    private var actionButtons: some View {
        VStack(spacing: RLayout.actionGap) {
            RButton(
                title: String(localized: "탈퇴하기"),
                variant: .destructive,
                isLoading: vm.isDeleting
            ) {
                vm.showConfirm = true
            }

            RButton(title: String(localized: "취소"), variant: .secondary, isDisabled: vm.isDeleting) {
                dismiss()
            }
        }
    }
}

// MARK: - AccountDeletionViewModel

@MainActor
final class AccountDeletionViewModel: NSObject, ObservableObject {
    @Published var isDeleting: Bool = false
    @Published var showConfirm: Bool = false
    @Published var showToast: Bool = false
    @Published var toastMessage: String = ""

    private var currentNonce: String?
    private var pendingUser: FirebaseAuth.User?
    private var pendingScope: AccountDeletionScope?
    private var pendingOnDeleted: (() -> Void)?
    private var appleAuthorizationController: ASAuthorizationController?
    private var deletionCoordinationToken: AccountDeletionCoordination.Token?

    deinit {
        if let token = deletionCoordinationToken {
            Task { @MainActor in AccountDeletionCoordination.shared.end(token) }
        }
    }

    func deleteAccount(onDeleted: @escaping () -> Void) async {
        guard !isDeleting else { return }
        isDeleting = true
        showToast = false

        do {
            guard FirebaseApp.app() != nil, let user = Auth.auth().currentUser else {
                throw AccountDeletionError.notSignedIn
            }
            guard AppleAccountPolicy.canDelete(providerIDs: Set(user.providerData.map(\.providerID))) else {
                throw AccountDeletionError.unsupportedProvider
            }
            guard LocalSession.begin() else { throw AccountDeletionError.localSessionUnavailable }
            let scope = try AccountDeletionScope(userID: user.uid)
            deletionCoordinationToken = AccountDeletionCoordination.shared.begin(userID: user.uid)
            pendingUser = user
            pendingScope = scope
            pendingOnDeleted = onDeleted

            try startAppleDeletion()
        } catch {
            handleDeletionError(error)
        }
    }

    private func startAppleDeletion() throws {
        guard UIApplication.shared.recocoTopViewController != nil else {
            throw AccountDeletionError.presentationUnavailable
        }

        let nonce = AuthCrypto.randomNonceString()
        currentNonce = nonce

        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.email]
        request.nonce = AuthCrypto.sha256(nonce)

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        appleAuthorizationController = controller
        controller.performRequests()
    }

    private func deleteVerifiedAccount(user: FirebaseAuth.User, scope: AccountDeletionScope,
                                       onDeleted: @escaping () -> Void) async throws {
        defer { resetDeletionRequest() }
        try await scope.deleteAccountOnly(
            currentUserID: { UserScopedStorage.currentUserID },
            deleteRemote: { try await user.delete() },
            finishSession: {
                onDeleted()
            }
        )
    }

    private func resetDeletionRequest() {
        let token = deletionCoordinationToken
        deletionCoordinationToken = nil
        currentNonce = nil
        pendingUser = nil
        pendingScope = nil
        pendingOnDeleted = nil
        appleAuthorizationController = nil
        isDeleting = false
        if let token { AccountDeletionCoordination.shared.end(token) }
    }

    private func handleDeletionError(_ error: Error) {
        resetDeletionRequest()

        if let authorizationError = error as? ASAuthorizationError,
           authorizationError.code == .canceled {
            return
        }

        toastMessage = (error as? LocalizedError)?.errorDescription
            ?? String(localized: "탈퇴를 완료하지 못했어요. 다시 시도해주세요.")
        showToast = true
    }

}

extension AccountDeletionViewModel: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        Task { @MainActor in
            guard controller === appleAuthorizationController else { return }
            defer { resetDeletionRequest() }
            do {
                guard
                    let user = pendingUser,
                    let scope = pendingScope,
                    let appleCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
                    let nonce = currentNonce,
                    let tokenData = appleCredential.identityToken,
                    let idToken = String(data: tokenData, encoding: .utf8),
                    let codeData = appleCredential.authorizationCode,
                    let authorizationCode = String(data: codeData, encoding: .utf8),
                    let onDeleted = pendingOnDeleted
                else {
                    throw AccountDeletionError.invalidCredential
                }

                let credential = OAuthProvider.appleCredential(
                    withIDToken: idToken,
                    rawNonce: nonce,
                    fullName: appleCredential.fullName
                )
                try scope.validate(currentUserID: UserScopedStorage.currentUserID)
                _ = try await user.reauthenticate(with: credential)
                try scope.validate(currentUserID: UserScopedStorage.currentUserID)
                try await Auth.auth().revokeToken(withAuthorizationCode: authorizationCode)
                try await deleteVerifiedAccount(user: user, scope: scope, onDeleted: onDeleted)
            } catch {
                handleDeletionError(error)
            }
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        Task { @MainActor in
            guard controller === appleAuthorizationController else { return }
            handleDeletionError(error)
        }
    }
}

extension AccountDeletionViewModel: ASAuthorizationControllerPresentationContextProviding {
    @MainActor
    func presentationAnchor(
        for controller: ASAuthorizationController
    ) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}

private enum AccountDeletionError: LocalizedError {
    case notConfigured
    case notSignedIn
    case invalidCredential
    case presentationUnavailable
    case localSessionUnavailable
    case unsupportedProvider

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return String(localized: "로그인 설정을 확인해주세요.")
        case .notSignedIn:
            return String(localized: "로그인 상태를 확인한 뒤 다시 시도해주세요.")
        case .invalidCredential:
            return String(localized: "계정 정보를 확인하지 못했어요. 다시 시도해주세요.")
        case .presentationUnavailable:
            return String(localized: "계정 확인 화면을 열지 못했어요. 잠시 후 다시 시도해주세요.")
        case .localSessionUnavailable:
            return String(localized: "기기 저장 상태를 확인하지 못했어요. 기존 데이터는 그대로예요. 다시 시도해주세요.")
        case .unsupportedProvider:
            return String(localized: "이 계정의 로그인 방식을 지원하지 않아 탈퇴하지 않았어요. 고객지원으로 문의해주세요.")
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("마이페이지") {
    NavigationStack {
        ProfileView()
            .environmentObject(AppRouter())
    }
}

#Preview("알림 설정") {
    NavigationStack {
        NotificationSettingsView()
    }
}

#Preview("회원탈퇴") {
    NavigationStack {
        AccountDeletionView {}
    }
}
#endif
