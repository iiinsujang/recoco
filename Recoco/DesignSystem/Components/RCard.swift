import SwiftUI
import UIKit

// MARK: - recoco Design System: Cards & Badges
// 명세서 §11.3 기반

// MARK: - 기본 카드 컨테이너

struct RCard<Content: View>: View {
    var padding: CGFloat = RLayout.cardInset
    var showsBorder: Bool = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .background(Color.rSurface)
            .cornerRadius(RRadius.lg)
            .overlay(RoundedRectangle(cornerRadius: RRadius.lg).strokeBorder(showsBorder ? Color.rBorder : .clear, lineWidth: 1))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                    .animation(animated && !reduceMotion ? RMotion.transition : nil, value: progress)
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
    var alignment: Alignment = .bottom
    var inset: CGFloat = RSpacing.xxxl
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        ZStack(alignment: alignment) {
            content

            if isPresented {
                RToast(message: message)
                    .padding(alignment == .top ? .top : .bottom, inset)
                    .padding(.horizontal, RLayout.screenInset)
                    .transition(.opacity)
                    .accessibilityElement(children: .combine)
                    .allowsHitTesting(false)
            }
        }
        .animation(reduceMotion ? nil : RMotion.feedback, value: isPresented)
        .task(id: isPresented ? message : nil) {
            guard isPresented else { return }
            UIAccessibility.post(notification: .announcement, argument: message)
            let visibleDuration = UIAccessibility.isVoiceOverRunning ? max(duration, 5) : duration
            do {
                try await Task.sleep(for: .seconds(visibleDuration))
                guard !Task.isCancelled else { return }
                isPresented = false
            } catch { /* A newer message or a dismissed view cancels this timer. */ }
        }
    }
}

extension View {
    func rToast(isPresented: Binding<Bool>, message: String, duration: Double = 2.0,
                alignment: Alignment = .bottom, inset: CGFloat = RSpacing.xxxl) -> some View {
        modifier(RToastModifier(isPresented: isPresented, message: message, duration: duration,
                               alignment: alignment, inset: inset))
    }
}

// MARK: - 입력창

struct RTextField: View {
    let placeholder: String
    @Binding var text: String
    var axis: Axis = .horizontal
    var minLines: Int = 1
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $text, axis: axis)
            .focused($isFocused)
            .lineLimit(axis == .vertical ? minLines...max(minLines, 6) : 1...1)
            .accessibilityLabel(placeholder)
            .rTextStyle(.body, color: .rTextPrimary)
            .padding(RSpacing.md)
            .background(Color.rSurface)
            .cornerRadius(RRadius.md)
            .overlay(
                RoundedRectangle(cornerRadius: RRadius.md)
                    .strokeBorder(isFocused ? Color.rAccent : Color.rBorder, lineWidth: isFocused ? 2 : 1)
            )
            .tint(.rAccent)
    }
}

// MARK: - 빈 상태 뷰

struct REmptyState: View {
    let title: String
    let message: String
    var pose: RSealIllustration.Pose = .neutral
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: RSpacing.md) {
            RSealIllustration(pose: pose, width: RCharacterSize.state)

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

// Shared media and feedback surfaces; copy remains selectable and scales with Dynamic Type.
extension View {
    func rPhotoPreview(height: CGFloat = RSize.photoPreview) -> some View {
        frame(maxWidth: .infinity)
            .frame(height: height)
            .background(Color.rSurface)
            .clipShape(RoundedRectangle(cornerRadius: RRadius.photo))
    }
}

struct RInlineFeedback: View {
    enum Tone { case information, error, success }
    let message: String
    var tone: Tone = .information
    var body: some View {
        Label(message, systemImage: tone == .error ? "exclamationmark.circle" : tone == .success ? "checkmark.circle" : "info.circle")
            .rTextStyle(.subLabel, color: tone == .error ? .rDestructive : .rTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
    }
}
