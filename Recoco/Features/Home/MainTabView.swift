import SwiftUI

// MARK: - MainTabView
// S-04 홈, S-09 리포트, S-10 마이페이지 탭 컨테이너

struct MainTabView: View {
    @State private var selectedTab: RTab = .home

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch selectedTab {
                case .home:
                    HomeView()
                        .transition(.opacity)
                case .report:
                    ReportView()
                        .transition(.opacity)
                case .profile:
                    NavigationStack {
                        ProfileView()
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: selectedTab)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            RTabBar(selectedTab: $selectedTab)
        }
        .background(Color.rBackground)
        .ignoresSafeArea(edges: .bottom)
    }
}

// MARK: - RecordView (S-07 진입점 — RecordInputView로 연결)

struct RecordView: View {
    let unit: DecisionUnit
    let onCompleted: () -> Void

    var body: some View {
        RecordInputView(unit: unit, onCompleted: onCompleted)
    }
}

#if DEBUG
#Preview {
    MainTabView()
        .environmentObject(AppRouter())
}
#endif
