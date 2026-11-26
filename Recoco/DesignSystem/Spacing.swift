import SwiftUI

// MARK: - recoco Design System: Spacing & Layout

enum RSpacing {
    /// 4pt — 최소 단위
    static let xxs: CGFloat = 4
    /// 8pt
    static let xs: CGFloat  = 8
    /// 12pt
    static let sm: CGFloat  = 12
    /// 16pt — 카드 padding 기준
    static let md: CGFloat  = 16
    /// 20pt
    static let lg: CGFloat  = 20
    /// 24pt
    static let xl: CGFloat  = 24
    /// 32pt
    static let xxl: CGFloat = 32
    /// 48pt
    static let xxxl: CGFloat = 48
}

enum RRadius {
    /// 작은 배지 4pt
    static let sm: CGFloat = 4
    /// 소형 버튼 12pt
    static let compact: CGFloat = 12
    /// 버튼, 입력창 16pt
    static let md: CGFloat = 16
    /// 카드 20pt
    static let lg: CGFloat = 20
    /// 사진 카드 24pt
    static let photo: CGFloat = 24
    /// 바텀시트 상단 28pt
    static let xl: CGFloat = 28
}

enum RSize {
    /// 기본 버튼 최소 높이. 긴 문구와 큰 글자는 세로로 확장한다.
    static let buttonHeight: CGFloat   = 52
    /// 최소 터치 영역 44pt (접근성 §12.2)
    static let minTouchTarget: CGFloat = 44
    /// 프로그레스 바 높이 3pt
    static let progressBarHeight: CGFloat = 3
    /// 웹 v32 탭의 콘텐츠 높이. 구분선과 iOS 하단 안전 영역은 별도.
    static let tabBarHeight: CGFloat = 55
    /// 프로필 아바타 크기
    static let avatarSize: CGFloat = 64
    static let icon: CGFloat = 24
    static let photoPreview: CGFloat = 220
    static let photoComparison: CGFloat = 120
    static let inputMinHeight: CGFloat = 120
}

/// 화면 바깥 여백과 컴포넌트 안쪽 여백을 구분한다.
enum RLayout {
    static let screenInset: CGFloat = RSpacing.xl
    static let contentInset: CGFloat = RSpacing.xl
    static let cardInset: CGFloat = RSpacing.md
    static let actionGap: CGFloat = RSpacing.xs
    static let headerHeight: CGFloat = 68
    static let navigationHeight: CGFloat = 56
    static let rowHeight: CGFloat = 56
    static let primaryActionRatio: CGFloat = 1.6
}

enum RMotion {
    static let feedback = Animation.easeOut(duration: 0.16)
    static let transition = Animation.easeInOut(duration: 0.25)
}

extension View {
    func rScreenPadding() -> some View {
        padding(.horizontal, RLayout.screenInset)
            .padding(.vertical, RLayout.contentInset)
    }
}
