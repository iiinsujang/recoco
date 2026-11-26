import SwiftUI
import UIKit

// MARK: - recoco Design System: Buttons
// 명세서 §11.3 기반

// MARK: - Button Style 열거

enum RButtonVariant {
    case primary      // rAccent 배경, rAccentText 텍스트
    case secondary    // rSurface 배경, rBorder 테두리, rTextPrimary 텍스트
    case destructive  // rDestructive 배경, rAccentText 텍스트
    case ghost        // 배경 없음, rTextPrimary 텍스트
}

// MARK: - RButton

enum RButtonSize {
    case regular, compact

    var height: CGFloat { self == .regular ? RSize.buttonHeight : RSize.minTouchTarget }
    var radius: CGFloat { self == .regular ? RRadius.md : RRadius.compact }
    var font: Font { self == .regular ? .rButton : .rSubLabel.weight(.semibold) }
}

struct RPressFeedbackStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.72 : 1)
    }
}

struct RButton: View {
    let title: String
    let variant: RButtonVariant
    var size: RButtonSize = .regular
    var isLoading: Bool = false
    var isDisabled: Bool = false
    var font: Font? = nil
    var cornerRadius: CGFloat? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: RSpacing.xs) {
                if isLoading {
                    RLoadingIndicator(style: .compact, size: 20,
                                      tint: variant == .primary || variant == .destructive ? .rAccentText : .rAccent)
                        .accessibilityHidden(true)
                }
                Text(title)
            }
            .rButtonSurface(variant, size: size, font: font, cornerRadius: cornerRadius)
        }
        .buttonStyle(RPressFeedbackStyle())
        .accessibilityLabel(title)
        .accessibilityValue(isLoading ? String(localized: "처리 중") : "")
        .disabled(isDisabled || isLoading)
        .opacity((isDisabled && !isLoading) ? 0.4 : 1.0)
        // 접근성: 최소 터치 영역 보장
        .contentShape(Rectangle())
    }

}

/// Buttons and ShareLink share one surface, including multiline and loading geometry.
private struct RButtonSurface: ViewModifier {
    let variant: RButtonVariant
    let size: RButtonSize
    var font: Font? = nil
    var cornerRadius: CGFloat? = nil

    func body(content: Content) -> some View {
        content
            .font(font ?? size.font)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundColor(variant == .primary || variant == .destructive ? .rAccentText : (variant == .ghost ? .rTextSecondary : .rTextPrimary))
            .padding(.horizontal, RLayout.cardInset)
            .padding(.vertical, RSpacing.sm)
            .frame(maxWidth: .infinity, minHeight: size.height)
            .background(backgroundColor, in: RoundedRectangle(cornerRadius: cornerRadius ?? size.radius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius ?? size.radius)
                .strokeBorder(variant == .secondary ? Color.rBorder : .clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius ?? size.radius))
    }

    private var backgroundColor: Color {
        switch variant {
        case .primary: return .rAccent
        case .secondary: return .rSurface
        case .destructive: return .rDestructive
        case .ghost: return .clear
        }
    }
}

extension View {
    func rButtonSurface(_ variant: RButtonVariant, size: RButtonSize = .regular,
                        font: Font? = nil, cornerRadius: CGFloat? = nil) -> some View {
        modifier(RButtonSurface(variant: variant, size: size, font: font, cornerRadius: cornerRadius))
    }
}

/// The right action has greater width; accessibility text uses a vertical layout.
struct RActionPair<Secondary: View, Primary: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ViewBuilder let secondary: () -> Secondary
    @ViewBuilder let primary: () -> Primary

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: RLayout.actionGap) {
                primary()
                secondary()
            }
        } else {
            RActionPairLayout {
                secondary()
                primary()
            }
        }
    }
}

private struct RActionPairLayout: Layout {
    private func widths(_ width: CGFloat) -> (CGFloat, CGFloat) {
        let available = max(0, width - RLayout.actionGap)
        let secondary = available / (1 + RLayout.primaryActionRatio)
        return (secondary, available - secondary)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        let (left, right) = widths(width)
        let heights = zip(subviews, [left, right]).map { view, width in
            view.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }
        return CGSize(width: width, height: heights.max() ?? RSize.buttonHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (left, right) = widths(bounds.width)
        var x = bounds.minX
        for (view, width) in zip(subviews, [left, right]) {
            view.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                       proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + RLayout.actionGap
        }
    }
}

// MARK: - 브랜드 소개 화면 버튼 (S-01, S-02, S-03)

struct RDarkButton: View {
    let title: String
    var isLoading: Bool = false
    let action: () -> Void

    var body: some View {
        RButton(title: title, variant: .primary, isLoading: isLoading, action: action)
    }
}

// MARK: - Google 로그인 버튼

struct RGoogleSignInButton: View {
    var isLoading: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: RSpacing.sm) {
                // Google G 아이콘 (Assets에 "google_logo" 추가 필요)
                if let _ = UIImage(named: "google_logo") {
                    Image("google_logo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                } else {
                    // 폴백: 텍스트 G
                    Text("G")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.blue)
                        .frame(width: 20, height: 20)
                }

                if isLoading {
                    RLoadingIndicator(style: .compact, size: 20, tint: .rAccent)
                        .accessibilityHidden(true)
                }
                Text(isLoading ? String(localized: "로그인 중…") : String(localized: "Google 계정으로 계속하기"))
                        .font(.rButton)
                        .foregroundColor(.rTextPrimary)
                        .multilineTextAlignment(.center)
            }
            .padding(.horizontal, RLayout.cardInset)
            .padding(.vertical, RSpacing.sm)
            .frame(maxWidth: .infinity, minHeight: RSize.buttonHeight)
            .background(Color.rBackground)
            .cornerRadius(RRadius.md)
            .overlay(
                RoundedRectangle(cornerRadius: RRadius.md)
                    .strokeBorder(Color.rBorder, lineWidth: 1)
            )
        }
        .buttonStyle(RPressFeedbackStyle())
        .disabled(isLoading)
        .accessibilityLabel(isLoading ? String(localized: "Google 로그인 중") : String(localized: "Google 계정으로 계속하기"))
        .contentShape(Rectangle())
    }
}

// MARK: - Apple 로그인 버튼 래퍼
// SignInWithAppleButton은 AuthView에서 직접 사용

// MARK: - Preview

#if DEBUG
#Preview("Buttons") {
    VStack(spacing: RSpacing.md) {
        RButton(title: "추천대로 정리하기", variant: .primary) {}
        RButton(title: "다른 사진 고르기", variant: .secondary) {}
        RButton(title: "탈퇴하기", variant: .destructive) {}
        RButton(title: "나중에", variant: .ghost) {}
        RButton(title: "로딩 중", variant: .primary, isLoading: true) {}
        RButton(title: "비활성", variant: .primary, isDisabled: true) {}
        RGoogleSignInButton {}
    }
    .padding()
    .background(Color.rBackground)
}

#Preview("Dark Buttons") {
    VStack(spacing: RSpacing.md) {
        RDarkButton(title: "다음") {}
        RDarkButton(title: "로딩", isLoading: true) {}
    }
    .padding()
    .background(Color.rDarkBackground)
}
#endif
