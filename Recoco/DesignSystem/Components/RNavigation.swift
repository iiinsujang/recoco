import SwiftUI

// MARK: - recoco Design System: Navigation & Tab Bar

// MARK: - 상단 네비게이션 바

struct RNavigationBar: View {
    enum Theme { case light, dark }

    let title: String
    var theme: Theme = .light
    var leadingAction: (() -> Void)? = nil
    var trailingTitle: String? = nil
    var trailingAction: (() -> Void)? = nil

    var body: some View {
        HStack {
            // 뒤로가기 버튼
            if let leadingAction {
                Button(action: leadingAction) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(textColor)
                        .frame(width: RSize.minTouchTarget, height: RSize.minTouchTarget)
                }
            } else {
                Spacer().frame(width: RSize.minTouchTarget)
            }

            Spacer()

            // 제목
            Text(title)
                .rTextStyle(.subLabel, color: textColor)
                .fontWeight(.medium)

            Spacer()

            // 우측 액션
            if let trailingTitle, let trailingAction {
                Button(action: trailingAction) {
                    Text(trailingTitle)
                        .rTextStyle(.subLabel, color: textColor.opacity(0.6))
                        .frame(minWidth: RSize.minTouchTarget, minHeight: RSize.minTouchTarget)
                }
            } else {
                Spacer().frame(width: RSize.minTouchTarget)
            }
        }
        .padding(.horizontal, RSpacing.xs)
    }

    private var textColor: Color {
        theme == .dark ? .rDarkTextPrimary : .rTextPrimary
    }
}

// MARK: - RECOCO 워드마크 헤더 (홈, 리포트용)

struct RWordmarkHeader: View {
    var theme: RNavigationBar.Theme = .light
    var trailingContent: AnyView? = nil

    var body: some View {
        HStack {
            Spacer()
            Text("RECOCO")
                .rTextStyle(.wordmark, color: theme == .dark ? .rDarkTextPrimary : .rTextPrimary)
                .tracking(2)
            Spacer()

            if let trailing = trailingContent {
                trailing
                    .frame(width: RSize.minTouchTarget, height: RSize.minTouchTarget)
            }
        }
        .padding(.horizontal, RSpacing.md)
    }
}

// MARK: - 탭 아이템 정의

enum RTab: Int, CaseIterable {
    case home    = 0
    case report  = 1
    case profile = 2

    var title: String {
        switch self {
        case .home:    return "홈"
        case .report:  return "리포트"
        case .profile: return "마이페이지"
        }
    }

    var icon: String {
        switch self {
        case .home:    return "house"
        case .report:  return "chart.bar"
        case .profile: return "person"
        }
    }

    var selectedIcon: String {
        switch self {
        case .home:    return "house.fill"
        case .report:  return "chart.bar.fill"
        case .profile: return "person.fill"
        }
    }

    /// 접근성 레이블
    var accessibilityLabel: String {
        switch self {
        case .home:    return "홈 탭"
        case .report:  return "주간 리포트 탭"
        case .profile: return "마이페이지 탭"
        }
    }
}

// MARK: - 커스텀 탭바

struct RTabBar: View {
    @Binding var selectedTab: RTab

    var body: some View {
        VStack(spacing: 0) {
            RDivider()

            HStack(spacing: 0) {
                ForEach(RTab.allCases, id: \.rawValue) { tab in
                    tabItem(tab)
                }
            }
            .frame(height: RSize.tabBarHeight)
            .background(Color.rBackground)
        }
    }

    private func tabItem(_ tab: RTab) -> some View {
        Button {
            selectedTab = tab
        } label: {
            VStack(spacing: RSpacing.xxs) {
                Image(systemName: selectedTab == tab ? tab.selectedIcon : tab.icon)
                    .font(.system(size: 22))
                    .foregroundColor(selectedTab == tab ? .rTextPrimary : .rTextTertiary)

                Text(tab.title)
                    .rTextStyle(.caption, color: selectedTab == tab ? .rTextPrimary : .rTextTertiary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: RSize.tabBarHeight)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(tab.accessibilityLabel)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Navigation") {
    VStack(spacing: 0) {
        // 라이트 네비게이션
        RNavigationBar(
            title: "리코코 기록 결과",
            leadingAction: {},
            trailingTitle: "설정",
            trailingAction: {}
        )
        .background(Color.rBackground)

        // 다크 네비게이션 (온보딩)
        RNavigationBar(
            title: "",
            theme: .dark,
            trailingTitle: "Skip",
            trailingAction: {}
        )
        .background(Color.rDarkBackground)

        // 워드마크 헤더
        RWordmarkHeader()
            .background(Color.rBackground)

        Spacer()

        // 탭바
        RTabBar(selectedTab: .constant(.home))
    }
    .background(Color.rBackground)
}
#endif
