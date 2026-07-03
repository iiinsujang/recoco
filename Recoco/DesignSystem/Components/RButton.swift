import SwiftUI
import UIKit

// MARK: - recoco Design System: Buttons
// 명세서 §11.3 기반

// MARK: - Button Style 열거

enum RButtonVariant {
    case primary      // #1A1A1A 배경, #FFFFFF 텍스트
    case secondary    // #F7F7F5 배경, #E3E2DE 테두리, #1A1A1A 텍스트
    case destructive  // #EB5757 배경, #FFFFFF 텍스트
    case ghost        // 배경 없음, #1A1A1A 텍스트
}

// MARK: - RButton

struct RButton: View {
    let title: String
    let variant: RButtonVariant
    var isLoading: Bool = false
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(foregroundColor)
                        .scaleEffect(0.8)
                } else {
                    Text(title)
                        .rTextStyle(.subLabel, color: foregroundColor)
                        .fontWeight(.medium)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: RSize.buttonHeight)
            .background(backgroundColor)
            .cornerRadius(RRadius.md)
            .overlay(
                RoundedRectangle(cornerRadius: RRadius.md)
                    .strokeBorder(borderColor, lineWidth: borderWidth)
            )
        }
        .disabled(isDisabled || isLoading)
        .opacity((isDisabled && !isLoading) ? 0.4 : 1.0)
        // 접근성: 최소 터치 영역 보장
        .contentShape(Rectangle())
    }

    // MARK: 색상 계산

    private var backgroundColor: Color {
        switch variant {
        case .primary:     return .rAccent
        case .secondary:   return .rSurface
        case .destructive: return .rDestructive
        case .ghost:       return .clear
        }
    }

    private var foregroundColor: Color {
        switch variant {
        case .primary:     return .rAccentText
        case .secondary:   return .rTextPrimary
        case .destructive: return .rAccentText
        case .ghost:       return .rTextPrimary
        }
    }

    private var borderColor: Color {
        switch variant {
        case .secondary: return .rBorder
        default:         return .clear
        }
    }

    private var borderWidth: CGFloat {
        switch variant {
        case .secondary: return 1
        default:         return 0
        }
    }
}

// MARK: - Dark 배경 전용 버튼 (S-01, S-02, S-03)

struct RDarkButton: View {
    let title: String
    var isLoading: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.rDarkBackground)
                        .scaleEffect(0.8)
                } else {
                    Text(title)
                        .rTextStyle(.subLabel, color: .rDarkBackground)
                        .fontWeight(.medium)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: RSize.buttonHeight)
            .background(Color.rDarkTextPrimary)
            .cornerRadius(RRadius.md)
        }
        .disabled(isLoading)
        .contentShape(Rectangle())
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
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.8)
                } else {
                    Text("Google 계정으로 계속하기")
                        .rTextStyle(.subLabel, color: .rTextPrimary)
                        .fontWeight(.medium)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: RSize.buttonHeight)
            .background(Color.rBackground)
            .cornerRadius(RRadius.md)
            .overlay(
                RoundedRectangle(cornerRadius: RRadius.md)
                    .strokeBorder(Color.rBorder, lineWidth: 1)
            )
        }
        .disabled(isLoading)
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
