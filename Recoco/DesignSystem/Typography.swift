import SwiftUI

// MARK: - recoco Design System: Typography
// 명세서 §11.2 기반
// 단일 폰트 패밀리: Inter
// Inter가 기기에 없을 경우 시스템 폰트로 자동 폴백

// MARK: - Font 확장

extension Font {

    // MARK: 워드마크 — 18pt SemiBold
    /// RECOCO 로고 텍스트 전용
    static var rWordmark: Font {
        .custom("Inter-SemiBold", size: 18, relativeTo: .headline)
        .weight(.semibold)
    }

    // MARK: 헤드라인 — 22–28pt Medium

    /// 큰 헤드라인 (온보딩, 홈 카드 제목) 28pt
    static var rHeadlineLarge: Font {
        .custom("Inter-Medium", size: 28, relativeTo: .largeTitle)
        .weight(.medium)
    }

    /// 일반 헤드라인 22pt
    static var rHeadline: Font {
        .custom("Inter-Medium", size: 22, relativeTo: .title2)
        .weight(.medium)
    }

    // MARK: 본문 — 15pt Regular
    static var rBody: Font {
        .custom("Inter-Regular", size: 15, relativeTo: .body)
    }

    // MARK: 서브·라벨 — 13pt Regular
    static var rSubLabel: Font {
        .custom("Inter-Regular", size: 13, relativeTo: .subheadline)
    }

    // MARK: 배지·캡션 — 11pt Medium
    static var rCaption: Font {
        .custom("Inter-Medium", size: 11, relativeTo: .caption)
        .weight(.medium)
    }
}

// MARK: - 시스템 폰트 폴백 (Inter 미설치 환경)

extension Font {
    /// Inter 로드 실패 시 사용. 런타임에서 Inter 존재 여부를 확인 후 호출.
    static func rSystemFallback(size: CGFloat, weight: Font.Weight) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
}

// MARK: - TextStyle 모디파이어 헬퍼

struct RTextStyle: ViewModifier {
    enum Style {
        case wordmark
        case headlineLarge
        case headline
        case body
        case subLabel
        case caption
    }

    let style: Style
    let color: Color

    func body(content: Content) -> some View {
        content
            .font(resolvedFont)
            .foregroundColor(color)
    }

    private var resolvedFont: Font {
        switch style {
        case .wordmark:       return .rWordmark
        case .headlineLarge:  return .rHeadlineLarge
        case .headline:       return .rHeadline
        case .body:           return .rBody
        case .subLabel:       return .rSubLabel
        case .caption:        return .rCaption
        }
    }
}

extension View {
    func rTextStyle(_ style: RTextStyle.Style, color: Color = .rTextPrimary) -> some View {
        modifier(RTextStyle(style: style, color: color))
    }
}

// MARK: - 라인 스페이싱 상수

enum RLineSpacing {
    /// 본문 (15pt) 기준 라인 스페이싱
    static let body: CGFloat = 6
    /// 서브라벨 (13pt) 기준
    static let subLabel: CGFloat = 4
}
