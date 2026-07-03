import SwiftUI

// MARK: - recoco Design System: Cards & Badges
// 명세서 §11.3 기반

// MARK: - 기본 카드 컨테이너

struct RCard<Content: View>: View {
    var padding: CGFloat = RSpacing.md
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .background(Color.rSurface)
            .cornerRadius(RRadius.lg)
    }
}

// MARK: - 배지

struct RBadge: View {
    enum Variant {
        case detox    // HIGH DETOX — #1A1A1A 배경
        case keyword  // 감정 키워드 — #F0EFEC 배경
    }

    let text: String
    var variant: Variant = .keyword

    var body: some View {
        Text(text)
            .rTextStyle(.caption, color: foregroundColor)
            .padding(.horizontal, RSpacing.xs)
            .padding(.vertical, RSpacing.xxs)
            .background(backgroundColor)
            .cornerRadius(RRadius.sm)
    }

    private var backgroundColor: Color {
        switch variant {
        case .detox:   return .rTextPrimary
        case .keyword: return .rHighlight
        }
    }

    private var foregroundColor: Color {
        switch variant {
        case .detox:   return .rAccentText
        case .keyword: return .rTextPrimary
        }
    }
}

// MARK: - 프로그레스 바

struct RProgressBar: View {
    /// 0.0 ~ 1.0
    let progress: Double
    var animated: Bool = true

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // 트랙
                Capsule()
                    .fill(Color.rProgressTrack)
                    .frame(height: RSize.progressBarHeight)

                // fill
                Capsule()
                    .fill(Color.rProgressFill)
                    .frame(
                        width: geo.size.width * min(max(progress, 0), 1),
                        height: RSize.progressBarHeight
                    )
                    .animation(animated ? .easeInOut(duration: 0.4) : nil, value: progress)
            }
        }
        .frame(height: RSize.progressBarHeight)
    }
}

// MARK: - 구분선

struct RDivider: View {
    var color: Color = .rBorder

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: 0.5)
    }
}

// MARK: - 토스트

struct RToast: View {
    let message: String

    var body: some View {
        Text(message)
            .rTextStyle(.subLabel, color: .rAccentText)
            .padding(.horizontal, RSpacing.md)
            .padding(.vertical, RSpacing.sm)
            .background(Color.rTextPrimary.opacity(0.92))
            .cornerRadius(RRadius.md)
            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
    }
}

// MARK: - 토스트 표시 ViewModifier

struct RToastModifier: ViewModifier {
    @Binding var isPresented: Bool
    let message: String
    var duration: Double = 2.0

    func body(content: Content) -> some View {
        ZStack(alignment: .bottom) {
            content

            if isPresented {
                RToast(message: message)
                    .padding(.bottom, RSpacing.xxxl)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                            withAnimation(.easeOut(duration: 0.3)) {
                                isPresented = false
                            }
                        }
                    }
            }
        }
        .animation(.spring(response: 0.4), value: isPresented)
    }
}

extension View {
    func rToast(isPresented: Binding<Bool>, message: String, duration: Double = 2.0) -> some View {
        modifier(RToastModifier(isPresented: isPresented, message: message, duration: duration))
    }
}

// MARK: - 입력창

struct RTextField: View {
    let placeholder: String
    @Binding var text: String
    var axis: Axis = .horizontal
    var minLines: Int = 1

    var body: some View {
        TextField(placeholder, text: $text, axis: axis)
            .rTextStyle(.body, color: .rTextPrimary)
            .padding(RSpacing.md)
            .background(Color.rSurface)
            .cornerRadius(RRadius.md)
            .overlay(
                RoundedRectangle(cornerRadius: RRadius.md)
                    .strokeBorder(Color.rBorder, lineWidth: 1)
            )
            .tint(.rTextPrimary)
    }
}

// MARK: - 빈 상태 뷰

struct REmptyState: View {
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: RSpacing.md) {
            Text(title)
                .rTextStyle(.headline)
                .multilineTextAlignment(.center)

            Text(message)
                .rTextStyle(.body, color: .rTextSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(RLineSpacing.body)

            if let actionTitle, let action {
                RButton(title: actionTitle, variant: .secondary, action: action)
                    .padding(.top, RSpacing.sm)
            }
        }
        .padding(.horizontal, RSpacing.xl)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Components") {
    ScrollView {
        VStack(alignment: .leading, spacing: RSpacing.md) {

            // 배지
            HStack {
                RBadge(text: "HIGH DETOX", variant: .detox)
                RBadge(text: "고요함")
                RBadge(text: "따뜻함")
                RBadge(text: "여유")
            }

            // 프로그레스 바
            VStack(alignment: .leading, spacing: RSpacing.xs) {
                Text("3 / 7일").rTextStyle(.subLabel)
                RProgressBar(progress: 3/7)
            }

            // 카드
            RCard {
                VStack(alignment: .leading, spacing: RSpacing.sm) {
                    Text("오늘의 정리").rTextStyle(.subLabel, color: .rTextSecondary)
                    Text("사진 8장 중 이 한 장을 남기길 추천해요.").rTextStyle(.headline)
                }
            }

            // 입력창
            RTextField(placeholder: "이 순간은 당신에게 어떤 의미인가요?", text: .constant(""), axis: .vertical)

            // 빈 상태
            REmptyState(
                title: "오늘은 정리할 사진이 없어요.",
                message: "사진첩이 이미 꽤 가벼운 편이에요.\n새로운 사진이 쌓이면 다시 알려드릴게요."
            )

            RDivider()

            // 구분선
            RDivider(color: .rBorderStrong)
        }
        .padding()
    }
    .background(Color.rBackground)
}
#endif
