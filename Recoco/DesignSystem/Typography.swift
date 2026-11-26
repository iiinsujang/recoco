import SwiftUI
import UIKit

/// Native counterpart of the web's -apple-system stack. Never reference an
/// unbundled font: Korean and Latin text must resolve through the same system.
enum RTypography {
    static func font(size: CGFloat, weight: UIFont.Weight = .regular,
                     relativeTo style: UIFont.TextStyle = .body) -> Font {
        Font(UIFontMetrics(forTextStyle: style).scaledFont(
            for: UIFont.systemFont(ofSize: size, weight: weight)))
    }
}

extension Font {
    static var rWordmark: Font { RTypography.font(size: 26, weight: .semibold, relativeTo: .title2) }
    static var rHeadlineLarge: Font { RTypography.font(size: 28, weight: .semibold, relativeTo: .title1) }
    static var rHeadline: Font { RTypography.font(size: 22, weight: .semibold, relativeTo: .title2) }
    static var rSection: Font { RTypography.font(size: 18, weight: .semibold, relativeTo: .headline) }
    static var rBody: Font { RTypography.font(size: 16) }
    static var rButton: Font { RTypography.font(size: 16, weight: .semibold) }
    static var rSubLabel: Font { RTypography.font(size: 14, relativeTo: .subheadline) }
    static var rCaption: Font { RTypography.font(size: 12, weight: .medium, relativeTo: .caption1) }
}

struct RTextStyle: ViewModifier {
    enum Style { case wordmark, headlineLarge, headline, section, body, subLabel, caption }
    let style: Style
    let color: Color
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var lineScale: CGFloat = 1

    func body(content: Content) -> some View {
        content.font(resolvedFont).foregroundColor(color)
            .tracking(tracking).lineSpacing(lineSpacing * lineScale)
    }

    private var resolvedFont: Font {
        switch style {
        case .wordmark: return .rWordmark
        case .headlineLarge: return .rHeadlineLarge
        case .headline: return .rHeadline
        case .section: return .rSection
        case .body: return .rBody
        case .subLabel: return .rSubLabel
        case .caption: return .rCaption
        }
    }
    private var tracking: CGFloat {
        switch style {
        case .wordmark: return -1
        case .headlineLarge: return -0.7
        case .headline, .section: return -0.5
        default: return 0
        }
    }
    private var lineSpacing: CGFloat {
        switch style {
        case .headlineLarge, .body: return 6
        case .headline, .section, .subLabel: return 4
        case .caption: return 3
        case .wordmark: return 0
        }
    }
}

extension View {
    func rTextStyle(_ style: RTextStyle.Style, color: Color = .rTextPrimary) -> some View {
        modifier(RTextStyle(style: style, color: color))
    }
}

enum RLineSpacing {
    static let body: CGFloat = 6
    static let subLabel: CGFloat = 4
}
