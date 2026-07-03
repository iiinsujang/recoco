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
    /// 버튼, 입력창 4pt
    static let sm: CGFloat = 4
    /// 버튼, 입력창 8pt
    static let md: CGFloat = 8
    /// 카드 12pt
    static let lg: CGFloat = 12
    /// 바텀시트 상단 16pt
    static let xl: CGFloat = 16
}

enum RSize {
    /// 기본 버튼 높이 48pt (접근성 §12.2)
    static let buttonHeight: CGFloat   = 48
    /// 최소 터치 영역 44pt (접근성 §12.2)
    static let minTouchTarget: CGFloat = 44
    /// 프로그레스 바 높이 3pt
    static let progressBarHeight: CGFloat = 3
    /// 탭바 높이
    static let tabBarHeight: CGFloat = 49
    /// 프로필 아바타 크기
    static let avatarSize: CGFloat = 64
}
