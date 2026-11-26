import SwiftUI

// MARK: - recoco Design System: Colors
// 명세서 §11.1 기반
// S-01, S-02, S-03: 하늘색 브랜드 배경 사용
// S-04 이후: 라이트 배경 사용
// 자동 다크모드 미지원 (MVP)

extension Color {

    static let rBrandSky = Color(hex: "91D3F5")
    static let rBrandMist = Color(hex: "E7F2FC")

    // MARK: Light (S-04 이후 메인 화면)

    /// 앱 기본 배경 #FFFFFF
    static let rBackground        = Color(hex: "FFFFFF")

    /// 카드·입력창 배경 #F3F7FB
    static let rSurface           = Color(hex: "F3F7FB")

    /// 선택 상태·탭 활성 #E7F2FC
    static let rSurfaceHover      = Color(hex: "E7F2FC")

    /// 구분선 #DEE8F0
    static let rBorder            = Color(hex: "DEE8F0")

    /// 강조 구분선 #BCCDDC
    static let rBorderStrong      = Color(hex: "BCCDDC")

    /// 주요 텍스트 #20324F
    static let rTextPrimary       = Color(hex: "20324F")

    /// 보조 텍스트 #566B7C
    static let rTextSecondary     = Color(hex: "566B7C")

    /// 힌트·플레이스홀더 #5C7082
    static let rTextTertiary      = Color(hex: "5C7082")

    /// 비활성 텍스트 #BCCDDC
    static let rTextDisabled      = Color(hex: "BCCDDC")

    /// 주요 CTA 배경 #315EDA
    static let rAccent            = Color(hex: "315EDA")

    /// CTA 텍스트 #FFFFFF
    static let rAccentText        = Color(hex: "FFFFFF")

    /// 배지·선택 상태 배경 #E7F2FC
    static let rHighlight         = Color(hex: "E7F2FC")

    /// 삭제·탈퇴 액션 #C84149
    static let rDestructive       = Color(hex: "C84149")

    // MARK: Brand introduction (legacy rDark names retained for existing callers)

    /// 브랜드 하늘색 배경 #91D3F5
    static let rDarkBackground    = Color(hex: "91D3F5")

    /// 브랜드 화면 주요 텍스트 #20324F
    static let rDarkTextPrimary   = Color(hex: "20324F")

    /// 브랜드 화면 보조 텍스트 #35566F
    static let rDarkTextSecondary = Color(hex: "35566F")

    /// 브랜드 화면 카드 배경 #DDEFFC
    static let rDarkSurface       = Color(hex: "DDEFFC")
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
