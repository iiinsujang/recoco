import Photos
import SwiftUI
import UIKit
import UserNotifications

// MARK: - S-10 마이페이지

struct ProfileView: View {
    @EnvironmentObject private var router: AppRouter
    @StateObject private var vm = ProfileViewModel()

    var body: some View {
        ZStack {
            Color.rBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                RWordmarkHeader()
                    .padding(.vertical, RSpacing.md)

                RDivider()

                ScrollView {
                    VStack(spacing: 0) {
                        // 프로필
                        profileSection
                            .padding(RSpacing.xl)

                        RDivider()

                        // 메뉴
                        menuSection

                        // 버전 + 로그아웃
                        footerSection
                            .padding(.top, RSpacing.xl)
                    }
                }
            }
        }
        .navigationDestination(isPresented: $vm.showNotification) {
            NotificationSettingsView()
        }
        .navigationDestination(isPresented: $vm.showPhotoAccess) {
            PhotoAccessManageView()
        }
        .navigationDestination(isPresented: $vm.showDeletion) {
            AccountDeletionView {
                router.navigateTo(.login)
            }
        }
        .alert("로그아웃", isPresented: $vm.showLogoutConfirm) {
            Button("로그아웃", role: .destructive) {
                vm.logout()
                router.navigateTo(.login)
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("로그아웃하시겠어요?")
        }
        .task { await vm.onAppear() }
    }

    // MARK: - 프로필

    private var profileSection: some View {
        VStack(spacing: RSpacing.md) {
            // 아바타
            avatarView

            VStack(spacing: RSpacing.xxs) {
                Text(vm.displayName)
                    .rTextStyle(.headline)

                Text(vm.email)
                    .rTextStyle(.subLabel, color: .rTextSecondary)
            }
        }
    }

    @ViewBuilder
    private var avatarView: some View {
        if let url = vm.photoURL {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                initialsAvatar
            }
            .frame(width: RSize.avatarSize, height: RSize.avatarSize)
            .clipShape(Circle())
        } else {
            initialsAvatar
        }
    }

    private var initialsAvatar: some View {
        ZStack {
            Circle()
                .fill(Color.rSurface)
                .frame(width: RSize.avatarSize, height: RSize.avatarSize)

            Text(vm.initials)
                .rTextStyle(.headline)
                .foregroundColor(.rTextSecondary)
        }
    }

    // MARK: - 메뉴

    private var menuSection: some View {
        VStack(spacing: 0) {
            menuRow(title: "사진 접근 관리", icon: "photo") {
                vm.showPhotoAccess = true
            }
            RDivider().padding(.leading, RSpacing.md + 24 + RSpacing.sm)

            menuRow(title: "알림 설정", icon: "bell") {
                vm.showNotification = true
            }
            RDivider().padding(.leading, RSpacing.md + 24 + RSpacing.sm)

            menuRow(title: "개인정보 안내", icon: "lock.shield") {
                if let url = URL(string: "https://recoco.app/privacy") {
                    UIApplication.shared.open(url)
                }
            }
            RDivider()

            menuRow(title: "회원탈퇴", icon: "person.slash", isDestructive: true) {
                vm.showDeletion = true
            }
        }
    }

    private func menuRow(
        title: String,
        icon: String,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: RSpacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(isDestructive ? .rDestructive : .rTextSecondary)
                    .frame(width: 24)

                Text(title)
                    .rTextStyle(.body, color: isDestructive ? .rDestructive : .rTextPrimary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13))
                    .foregroundColor(.rTextTertiary)
            }
            .padding(.horizontal, RSpacing.md)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 푸터

    private var footerSection: some View {
        VStack(spacing: RSpacing.md) {
            Text("recoco v\(vm.appVersion)")
                .rTextStyle(.caption, color: .rTextTertiary)

            Button("로그아웃") {
                vm.showLogoutConfirm = true
            }
            .rTextStyle(.subLabel, color: .rTextTertiary)
            .frame(minHeight: RSize.minTouchTarget)
        }
        .padding(.bottom, RSpacing.xxxl)
    }
}

// MARK: - ProfileViewModel

@MainActor
final class ProfileViewModel: ObservableObject {
    @Published var displayName: String = ""
    @Published var email: String = ""
    @Published var photoURL: URL? = nil
    @Published var showNotification: Bool = false
    @Published var showPhotoAccess: Bool = false
    @Published var showDeletion: Bool = false
    @Published var showLogoutConfirm: Bool = false

    var initials: String {
        displayName.prefix(1).uppercased()
    }

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    func onAppear() async {
        // TODO: Firebase Auth currentUser에서 프로필 로드
        displayName = "insu"
        email = "iiinsu23@gmail.com"
    }

    func logout() {
        // TODO: Firebase Auth signOut() + Google SignOut + Apple 세션 제거
        // 로컬 인증 토큰 제거 (Keychain)
        // 기기 내 기록 초안은 삭제하지 않음 (명세서 §8 S-10)
    }
}

// MARK: - S-11 알림 설정

struct NotificationSettingsView: View {
    @State private var isEnabled: Bool = false
    @State private var selectedHour: Int = 9
    @State private var selectedMinute: Int = 0
    @State private var showPermissionAlert: Bool = false
    @State private var isSaved: Bool = false

    private let previewMessage = "오늘의 한 장이 기다리고 있어요."

    var body: some View {
        ZStack {
            Color.rBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: RSpacing.xl) {
                        // 알림 ON/OFF
                        toggleSection

                        if isEnabled {
                            // 시간 선택
                            timePickerSection

                            // 미리보기
                            previewSection
                        }

                        // 저장
                        RButton(
                            title: isSaved ? "저장됨" : "저장하기",
                            variant: .primary,
                            isDisabled: isSaved
                        ) {
                            saveSettings()
                        }
                    }
                    .padding(RSpacing.md)
                }
            }
        }
        .navigationTitle("알림 설정")
        .navigationBarTitleDisplayMode(.inline)
        .alert("알림 권한 필요", isPresented: $showPermissionAlert) {
            Button("설정으로 이동") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("취소", role: .cancel) {
                isEnabled = false
            }
        } message: {
            Text("알림을 받으려면 설정에서 알림 권한을 허용해주세요.")
        }
        .onAppear { loadSettings() }
    }

    private var toggleSection: some View {
        RCard {
            HStack {
                VStack(alignment: .leading, spacing: RSpacing.xxs) {
                    Text("알림 켜기")
                        .rTextStyle(.body)
                    Text("매일 정해진 시간에 알림을 받아요.")
                        .rTextStyle(.caption, color: .rTextSecondary)
                }
                Spacer()
                Toggle("", isOn: $isEnabled)
                    .tint(.rTextPrimary)
                    .onChange(of: isEnabled) { enabled in
                        if enabled { checkNotificationPermission() }
                    }
            }
        }
    }

    private var timePickerSection: some View {
        RCard {
            VStack(alignment: .leading, spacing: RSpacing.sm) {
                Text("알림 시간을 정해주세요.")
                    .rTextStyle(.subLabel, color: .rTextSecondary)

                DatePicker(
                    "",
                    selection: Binding(
                        get: {
                            Calendar.current.date(
                                bySettingHour: selectedHour,
                                minute: selectedMinute,
                                second: 0,
                                of: Date()
                            ) ?? Date()
                        },
                        set: { date in
                            selectedHour = Calendar.current.component(.hour, from: date)
                            selectedMinute = Calendar.current.component(.minute, from: date)
                            isSaved = false
                        }
                    ),
                    displayedComponents: .hourAndMinute
                )
                .labelsHidden()
                .datePickerStyle(.wheel)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var previewSection: some View {
        RCard {
            VStack(alignment: .leading, spacing: RSpacing.xs) {
                Text("알림 미리보기")
                    .rTextStyle(.caption, color: .rTextTertiary)
                Text(previewMessage)
                    .rTextStyle(.body)
            }
        }
    }

    private func checkNotificationPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .notDetermined:
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                        DispatchQueue.main.async {
                            if !granted { isEnabled = false }
                        }
                    }
                case .denied:
                    showPermissionAlert = true
                default:
                    break
                }
            }
        }
    }

    private func loadSettings() {
        isEnabled = UserDefaults.standard.bool(forKey: "recoco_notification_enabled")
        selectedHour = UserDefaults.standard.integer(forKey: "recoco_notification_hour").nonZeroOr(9)
        selectedMinute = UserDefaults.standard.integer(forKey: "recoco_notification_minute")
    }

    private func saveSettings() {
        UserDefaults.standard.set(isEnabled, forKey: "recoco_notification_enabled")
        UserDefaults.standard.set(selectedHour, forKey: "recoco_notification_hour")
        UserDefaults.standard.set(selectedMinute, forKey: "recoco_notification_minute")

        // 로컬 알림 스케줄
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()

        if isEnabled {
            let content = UNMutableNotificationContent()
            content.title = "RECOCO"
            content.body = previewMessage
            content.sound = .default

            var components = DateComponents()
            components.hour = selectedHour
            components.minute = selectedMinute

            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            let request = UNNotificationRequest(identifier: "recoco.daily", content: content, trigger: trigger)

            UNUserNotificationCenter.current().add(request)
        }

        isSaved = true
    }
}

// MARK: - S-12 사진 접근 관리

struct PhotoAccessManageView: View {
    @State private var authStatus: String = "확인 중..."

    var body: some View {
        ZStack {
            Color.rBackground.ignoresSafeArea()

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

                RButton(title: "설정으로 이동하기", variant: .secondary) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
            .padding(RSpacing.md)
        }
        .navigationTitle("사진 접근 관리")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { updateStatus() }
    }

    private func updateStatus() {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized:  authStatus = "전체 사진첩에 접근할 수 있어요."
        case .limited:     authStatus = "현재 선택한 사진만 보고 있어요."
        case .denied, .restricted: authStatus = "사진 접근 권한이 없어요."
        default:           authStatus = "권한이 설정되지 않았어요."
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
                    .padding(RSpacing.md)
                }
            }
        }
        .navigationTitle("회원탈퇴")
        .navigationBarTitleDisplayMode(.inline)
        .alert("정말 탈퇴하시겠어요?", isPresented: $vm.showConfirm) {
            Button("탈퇴하기", role: .destructive) {
                Task { await vm.deleteAccount(onDeleted: onDeleted) }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("저장한 기록과 계정 정보가 삭제돼요.")
        }
        .rToast(isPresented: $vm.showToast, message: vm.toastMessage)
    }

    private var warningSection: some View {
        VStack(alignment: .leading, spacing: RSpacing.sm) {
            Text("탈퇴 전 확인해주세요.")
                .rTextStyle(.headline)
            Text("탈퇴하면 모든 기록과 계정 정보가 삭제되며\n복구할 수 없어요.")
                .rTextStyle(.body, color: .rTextSecondary)
                .lineSpacing(RLineSpacing.body)
        }
    }

    private var deletionInfoSection: some View {
        RCard {
            VStack(alignment: .leading, spacing: RSpacing.sm) {
                Text("삭제되는 항목")
                    .rTextStyle(.subLabel, color: .rTextSecondary)

                deletionRow("저장한 기록 (Narrative)")
                deletionRow("계정 정보 (이름, 이메일)")
                deletionRow("주간 리포트 데이터")

                RDivider()

                HStack(spacing: RSpacing.xs) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 13))
                        .foregroundColor(.rTextTertiary)
                    Text("사진 원본은 recoco 서버에 저장되지 않아요.")
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
        VStack(spacing: RSpacing.sm) {
            RButton(
                title: "탈퇴하기",
                variant: .destructive,
                isLoading: vm.isDeleting
            ) {
                vm.showConfirm = true
            }

            RButton(title: "취소", variant: .secondary) {
                dismiss()
            }
        }
    }
}

// MARK: - AccountDeletionViewModel

@MainActor
final class AccountDeletionViewModel: ObservableObject {
    @Published var isDeleting: Bool = false
    @Published var showConfirm: Bool = false
    @Published var showToast: Bool = false
    @Published var toastMessage: String = ""

    func deleteAccount(onDeleted: @escaping () -> Void) async {
        isDeleting = true
        defer { isDeleting = false }

        do {
            // 1. 재인증 (명세서 §8 S-13)
            // TODO: Apple/Google 재인증

            // 2. Firebase Callable Function "deleteAccount" 호출
            // → Firestore 하위 컬렉션 재귀 삭제
            // → Firebase Auth 계정 삭제
            try await Task.sleep(nanoseconds: 1_500_000_000) // Mock

            // 3. 로컬 데이터 초기화
            clearLocalData()

            // 4. 로그인 화면으로
            onDeleted()

        } catch {
            toastMessage = "탈퇴 처리 중 오류가 발생했어요. 다시 시도해주세요."
            showToast = true
        }
    }

    private func clearLocalData() {
        // CoreData 초기화
        // UserDefaults 초기화
        // Keychain 초기화
        let domain = Bundle.main.bundleIdentifier!
        UserDefaults.standard.removePersistentDomain(forName: domain)
    }
}

// MARK: - Int extension helper

extension Int {
    func nonZeroOr(_ fallback: Int) -> Int {
        self == 0 ? fallback : self
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
