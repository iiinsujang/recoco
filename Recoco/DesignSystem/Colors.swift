import SwiftUI

// MARK: - recoco Design System: Colors
// 명세서 §11.1 기반
// S-01, S-02, S-03: 다크 배경 사용
// S-04 이후: 라이트 배경 사용
// 자동 다크모드 미지원 (MVP)

extension Color {

    // MARK: Light (S-04 이후 메인 화면)

    /// 앱 기본 배경 #FFFFFF
    static let rBackground        = Color(hex: "FFFFFF")

    /// 카드·입력창 배경 #F7F7F5
    static let rSurface           = Color(hex: "F7F7F5")

    /// 선택 상태·탭 활성 #EFEEEB
    static let rSurfaceHover      = Color(hex: "EFEEEB")

    /// 구분선 #E3E2DE
    static let rBorder            = Color(hex: "E3E2DE")

    /// 강조 구분선 #C7C6C2
    static let rBorderStrong      = Color(hex: "C7C6C2")

    /// 주요 텍스트 #1A1A1A
    static let rTextPrimary       = Color(hex: "1A1A1A")

    /// 보조 텍스트 #6B6B6B
    static let rTextSecondary     = Color(hex: "6B6B6B")

    /// 힌트·플레이스홀더 #9B9A97
    static let rTextTertiary      = Color(hex: "9B9A97")

    /// 비활성 텍스트 #C7C6C2
    static let rTextDisabled      = Color(hex: "C7C6C2")

    /// 주요 CTA 배경 #1A1A1A
    static let rAccent            = Color(hex: "1A1A1A")

    /// CTA 텍스트 #FFFFFF
    static let rAccentText        = Color(hex: "FFFFFF")

    /// 배지·선택 상태 배경 #F0EFEC
    static let rHighlight         = Color(hex: "F0EFEC")

    /// 삭제·탈퇴 액션 #EB5757
    static let rDestructive       = Color(hex: "EB5757")

    // MARK: Dark (S-01 스플래시, S-02 온보딩, S-03 로그인)

    /// 다크 배경 #0C0D0A
    static let rDarkBackground    = Color(hex: "0C0D0A")

    /// 다크 주요 텍스트 #FFFFFF
    static let rDarkTextPrimary   = Color(hex: "FFFFFF")

    /// 다크 보조 텍스트 #B9B9B5
    static let rDarkTextSecondary = Color(hex: "B9B9B5")

    /// 다크 카드 배경 #1A1B17
    static let rDarkSurface       = Color(hex: "1A1B17")
}

// MARK: - Hex 초기화 헬퍼

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)

        let r, g, b, a: UInt64
        switch hex.count {
        case 6:
            (r, g, b, a) = (int >> 16, int >> 8 & 0xFF, int & 0xFF, 255)
        case 8:
            (r, g, b, a) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (r, g, b, a) = (0, 0, 0, 255)
        }

        self.init(
            .sRGB,
            red:     Double(r) / 255,
            green:   Double(g) / 255,
            blue:    Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - ShapeStyle 확장 (그라디언트 등 향후 확장용)

extension Color {
    /// 라이트 화면에서 구분선으로 사용하는 Divider 색상
    static var rDivider: Color { rBorder }

    /// 프로그레스 바 트랙
    static var rProgressTrack: Color { rBorder }

    /// 프로그레스 바 fill
    static var rProgressFill: Color { rAccent }
}
