import SwiftUI

// MARK: - recoco Design System: Navigation & Tab Bar

// MARK: - 상단 네비게이션 바

struct RNavigationBar: View {
    enum Theme { case light, dark, inverse }

    let title: String
    var theme: Theme = .light
    var leadingAction: (() -> Void)? = nil
    var trailingTitle: String? = nil
    var trailingAction: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: RSpacing.xs) {
            if let leadingAction {
                Button(action: leadingAction) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: RSize.minTouchTarget, height: RSize.minTouchTarget)
                }
                .accessibilityLabel("뒤로")
            } else {
                Color.clear.frame(width: RSize.minTouchTarget, height: RSize.minTouchTarget)
                    .accessibilityHidden(true)
            }

            Text(title)
                .font(.rButton)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)

            if let trailingTitle, let trailingAction {
                Button(trailingTitle, action: trailingAction)
                    .font(.rSubLabel.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minWidth: RSize.minTouchTarget, minHeight: RSize.minTouchTarget)
            } else {
                Color.clear.frame(width: RSize.minTouchTarget, height: RSize.minTouchTarget)
                    .accessibilityHidden(true)
            }
        }
        .foregroundColor(textColor)
        .buttonStyle(RPressFeedbackStyle())
        .padding(.horizontal, RSpacing.sm)
        .padding(.vertical, RSpacing.xxs)
        .frame(minHeight: RLayout.navigationHeight)
    }

    private var textColor: Color {
        theme == .inverse ? .white : .rTextPrimary
    }
}

// MARK: - RECOCO 워드마크 헤더 (홈, 리포트용)

struct RWordmarkHeader: View {
    var theme: RNavigationBar.Theme = .light
    var height: CGFloat = RLayout.headerHeight
    var trailingContent: AnyView? = nil

    var body: some View {
        ZStack {
            RBrandWordmark()
            if let trailing = trailingContent {
                HStack {
                    Spacer()
                    trailing
                        .frame(width: RSize.minTouchTarget, height: RSize.minTouchTarget)
                }
            }
        }
        .padding(.horizontal, RLayout.screenInset)
        .frame(minHeight: height)
    }
}

// MARK: - 탭 아이템 정의

enum RTab: Int, CaseIterable {
    case home    = 0
    case report  = 1
    case profile = 2

    var title: String {
        switch self {
        case .home:    return String(localized: "홈")
        case .report:  return String(localized: "리포트")
        case .profile: return String(localized: "내 정보")
        }
    }

    var accessibilityID: String {
        switch self {
        case .home: return "tab.home"
        case .report: return "tab.report"
        case .profile: return "tab.profile"
        }
    }

    /// 접근성 레이블
    var accessibilityLabel: String {
        switch self {
        case .home:    return String(localized: "홈 탭")
        case .report:  return String(localized: "리포트 탭")
        case .profile: return String(localized: "마이페이지 탭")
        }
    }
}

// MARK: - 커스텀 탭바

struct RTabBar: View {
    @Binding var selectedTab: RTab
    @ScaledMetric(relativeTo: .caption) private var labelSize: CGFloat = 12

    var body: some View {
        VStack(spacing: 0) {
            RDivider()

            HStack(spacing: 0) {
                ForEach(RTab.allCases, id: \.rawValue) { tab in
                    tabItem(tab)
                }
            }
            .padding(.horizontal, RSpacing.xxs)
            .frame(minHeight: RSize.tabBarHeight)
            .background(Color.rBackground)
        }
    }

    private func tabItem(_ tab: RTab) -> some View {
        Button {
            selectedTab = tab
        } label: {
            VStack(spacing: RSpacing.xxs) {
                RTabGlyph(tab: tab)
                    .stroke(style: StrokeStyle(lineWidth: 1.75 * 21 / 24, lineCap: .round, lineJoin: .round))
                    .frame(width: 21, height: 21)
                    .frame(width: 46, height: 28)
                    .background(selectedTab == tab ? Color.rBrandMist : Color.clear, in: Capsule())
                    .foregroundColor(selectedTab == tab ? .rAccent : .rTextTertiary)

                Text(tab.title)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .font(.system(size: min(labelSize, 18), weight: selectedTab == tab ? .bold : .medium))
                    .foregroundColor(selectedTab == tab ? .rAccent : .rTextTertiary)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: RSize.tabBarHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(RPressFeedbackStyle())
        .accessibilityIdentifier(tab.accessibilityID)
        .accessibilityLabel(tab.accessibilityLabel)
        .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
    }
}

/// The same 24-unit outline paths as the web v32 navigation, rendered natively.
private struct RTabGlyph: Shape {
    let tab: RTab

    func path(in rect: CGRect) -> Path {
        var path = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x / 24 * rect.width, y: rect.minY + y / 24 * rect.height)
        }
        func line(_ coordinates: [(CGFloat, CGFloat)]) {
            guard let first = coordinates.first else { return }
            path.move(to: point(first.0, first.1))
            for coordinate in coordinates.dropFirst() {
                path.addLine(to: point(coordinate.0, coordinate.1))
            }
        }
        switch tab {
        case .home:
            line([(3,11), (12,3), (21,11)])
            line([(5,10), (5,20), (19,20), (19,10)])
            line([(9,20), (9,14), (15,14), (15,20)])
        case .report:
            line([(4,20), (4,10)])
            line([(10,20), (10,4)])
            line([(16,20), (16,13)])
            line([(22,20), (2,20)])
        case .profile:
            path.addEllipse(in: CGRect(x: point(7,3).x, y: point(7,3).y,
                                       width: rect.width * 10 / 24, height: rect.height * 10 / 24))
            path.move(to: point(20,21))
            path.addCurve(to: point(12,13), control1: point(20,16.582), control2: point(16.418,13))
            path.addCurve(to: point(4,21), control1: point(7.582,13), control2: point(4,16.582))
        }
        return path
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
