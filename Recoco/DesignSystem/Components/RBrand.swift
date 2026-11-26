import SwiftUI

/// Artwork canvas sizes. Pose conveys context; the adjacent copy conveys status.
enum RCharacterSize {
    static let companion: CGFloat = 96
    static let state: CGFloat = 184
    static let hero: CGFloat = 260
    static let homeArtwork: CGFloat = 132
    static let homeSlot = CGSize(width: 88, height: 52)
}

// Short whiskers are the everyday baseline; shape and gesture carry emotion.
// Decorative artwork is hidden from VoiceOver; the adjacent text conveys state.
struct RSealIllustration: View {
    enum Pose: String {
        case floating = "recoco_seal_float"
        case resting = "recoco_seal_rest"
        case hello = "recoco_moment_hello"
        case choose = "recoco_moment_choose"
        case letGo = "recoco_moment_letgo"
        case heart = "recoco_moment_heart"
        case writing = "recoco_moment_writing"
        case nap = "recoco_moment_nap"
        case neutral = "recoco_moment_neutral"
        case curious = "recoco_moment_curious"
        case joy = "recoco_moment_joy"
        case daydream = "recoco_moment_daydream"

        static func completion(deletedCount: Int, savedRecordCount: Int) -> Self {
            if savedRecordCount > 0 { return .heart }
            if deletedCount > 0 { return .letGo }
            return .nap
        }
    }

    var pose: Pose = .neutral
    var width: CGFloat = RCharacterSize.state

    var body: some View {
        Image(pose.rawValue)
            .resizable()
            .scaledToFit()
            .frame(width: width, height: width * 0.75)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// A single quiet entrance at pauses in the flow, with no idle animation loop.
struct RSealScene: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    var pose: RSealIllustration.Pose
    var width: CGFloat = RCharacterSize.state

    var body: some View {
        RSealIllustration(pose: pose, width: width)
            .padding(RSpacing.md)
            .background(Color.rBrandMist)
            .clipShape(RoundedRectangle(cornerRadius: RRadius.xl))
            .opacity(appeared || reduceMotion ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 5)
            .onAppear {
                withAnimation(reduceMotion ? nil : RMotion.transition) {
                    appeared = true
                }
            }
    }
}

/// The approved swimming motion, shown only while real work is in progress.
/// Compact instances keep the same breathing orbit without adding another seal.
struct RLoadingIndicator: View {
    enum Style {
        case scene
        case compact
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var appeared = false
    @State private var inViewport = true
    @State private var started = Date()

    var style: Style = .scene
    var size: CGFloat = RCharacterSize.state
    var tint: Color = Color(hex: "ADD5EB")
    var accessibilityLabel = String(localized: "불러오는 중")

    private var animates: Bool {
        appeared && inViewport && scenePhase == .active && !reduceMotion
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animates)) { context in
            let seconds = reduceMotion ? 0 : max(0, context.date.timeIntervalSince(started))
            ZStack {
                bubbles(at: seconds)
                if style == .scene {
                    swimmingSeal(at: seconds)
                    // Show mouth emission briefly, then protect the face as bubbles grow.
                    bubbles(at: seconds, foreground: true)
                }
            }
            .frame(width: size, height: size)
        }
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: RLoadingFrameKey.self, value: geometry.frame(in: .global))
            }
        }
        .onPreferenceChange(RLoadingFrameKey.self) { frame in
            inViewport = frame.intersects(UIScreen.main.bounds)
        }
        .onAppear {
            started = Date()
            appeared = true
        }
        .onDisappear { appeared = false }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private func bubbles(at seconds: TimeInterval, foreground: Bool = false) -> some View {
        if style == .scene {
            let scale = size / 260
            ZStack {
                ForEach(0..<8) { index in
                    let bubble = RLoadingMotion.sceneBubble(at: seconds, index: index)
                    if (bubble.progress < 0.04) == foreground {
                        bubbleMark(diameter: bubble.diameter * scale, scale: scale)
                            .opacity(bubble.opacity)
                            .offset(x: (bubble.x - 130) * scale, y: (bubble.y - 130) * scale)
                    }
                }
            }
        } else {
            let scale = size / 20
            ZStack {
                ForEach(0..<8) { index in
                    let angle = Double(-140 + index * 43) * .pi / 180
                    let pulse = RLoadingMotion.bubble(at: seconds, index: index)
                    let diameter = (2.6 + Double(index) * 0.15) * scale
                    let distance = size * 0.34 + pulse.drift * 0.45 * scale
                    bubbleMark(diameter: diameter, scale: scale)
                        .scaleEffect(pulse.scale)
                        .opacity(pulse.opacity)
                        .offset(x: cos(angle) * distance, y: sin(angle) * distance)
                }
            }
            .rotationEffect(.degrees(seconds / 3.6 * 360))
        }
    }

    private func bubbleMark(diameter: CGFloat, scale: CGFloat) -> some View {
        ZStack {
            if style == .scene {
                Circle()
                    .fill(tint.opacity(0.14))
                    .frame(width: diameter + 2 * scale, height: diameter + 2 * scale)
                    .blur(radius: scale)
            }
            Circle()
                .fill(tint)
                .frame(width: diameter, height: diameter)
            if style == .scene {
                Ellipse()
                    .fill(Color.rBackground.opacity(0.34))
                    .frame(width: diameter * 0.29, height: diameter * 0.25)
                    .offset(x: -diameter * 0.135, y: -diameter * 0.195)
                    .blur(radius: 0.65 * scale)
            }
        }
        .blur(radius: style == .scene ? 0.45 * scale : 0)
    }

    private func swimmingSeal(at seconds: TimeInterval) -> some View {
        let scale = size / 260
        let swim = RLoadingMotion.swim(at: seconds)
        // The reference crops transparent margins; the original bitmap is unchanged.
        let imageScale = 174.0 / 1325 * scale
        return Image(RSealIllustration.Pose.floating.rawValue)
            .resizable()
            .frame(width: 1448 * imageScale, height: 1086 * imageScale)
            .offset(x: -61 * imageScale, y: -32 * imageScale)
            .frame(width: 174 * scale, height: 135 * scale, alignment: .topLeading)
            .clipped()
            .scaleEffect(1 + 0.015 * swim, anchor: UnitPoint(x: 0.48, y: 0.54))
            .rotationEffect(.degrees(-4 + 3 * swim), anchor: UnitPoint(x: 0.48, y: 0.54))
            .offset(x: -swim * scale, y: (3.5 + 3 - 6 * swim) * scale)
    }
}

private struct RLoadingFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private enum RLoadingMotion {
    struct Bubble {
        let scale: Double
        let opacity: Double
        let drift: Double
    }

    struct SceneBubble {
        let progress: Double
        let x: Double
        let y: Double
        let diameter: Double
        let opacity: Double
    }

    static func swim(at seconds: TimeInterval) -> Double {
        let phase = easeInOut(positiveModulo(seconds, 2.4) / 2.4)
        return phase < 0.5 ? phase * 2 : (1 - phase) * 2
    }

    /// The emission point follows the unchanged seal bitmap's mouth and swim pose.
    static func mouth(at seconds: TimeInterval) -> (x: Double, y: Double) {
        let u = swim(at: seconds)
        let scale = 1 + 0.015 * u
        let angle = (-4 + 3 * u) * .pi / 180
        let x = (43 + (535.0 - 61) * 174 / 1325 - 126.52) * scale
        let y = (66 + (680.0 - 32) * 174 / 1325 - 138.9) * scale
        return (
            126.52 + cos(angle) * x - sin(angle) * y - u,
            138.9 + sin(angle) * x + cos(angle) * y + 3 - 6 * u
        )
    }

    /// Each bubble leaves the mouth at birth and follows its own expanding spiral.
    static func sceneBubble(at seconds: TimeInterval, index: Int) -> SceneBubble {
        let age = positiveModulo(seconds + Double(index) * 3.6 / 8, 3.6)
        let p = age / 3.6
        let origin = mouth(at: seconds - age)
        let r0 = hypot(origin.x - 130, origin.y - 130)
        let a0 = atan2(origin.y - 130, origin.x - 130)
        let radius = r0 + (110 - r0) * (1 - pow(1 - p, 2))
        let angle = a0 + 2 * .pi * p
        return SceneBubble(
            progress: p,
            x: 130 + cos(angle) * radius,
            y: 130 + sin(angle) * radius,
            diameter: (5 + 19 * pow(p, 0.8)) * (0.9 + 0.05 * Double(index % 3)),
            opacity: 0.68 * min(1, p / 0.06) * min(1, (1 - p) / 0.18)
        )
    }

    private static func positiveModulo(_ value: Double, _ divisor: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: divisor)
        return remainder < 0 ? remainder + divisor : remainder
    }

    static func bubble(at seconds: TimeInterval, index: Int) -> Bubble {
        let duration = (4.2 + Double(index) * 0.22) / 1.5
        let delay = Double(index) * 0.67 / 1.5
        let phase = easeInOut((seconds + delay).truncatingRemainder(dividingBy: duration) / duration)
        let peak = 0.58 + Double(index % 3) * 0.1
        if phase < 0.48 {
            let t = phase / 0.48
            return Bubble(scale: mix(0.55, 1.2475, t), opacity: peak * mix(0.34, 1, t), drift: t)
        } else if phase < 0.76 {
            let t = (phase - 0.48) / 0.28
            return Bubble(scale: mix(1.2475, 0.8875, t), opacity: peak * mix(1, 0.7, t), drift: mix(1, 0.25, t))
        } else {
            let t = (phase - 0.76) / 0.24
            return Bubble(scale: mix(0.8875, 0.55, t), opacity: peak * mix(0.7, 0.34, t), drift: mix(0.25, 0, t))
        }
    }

    /// CSS ease-in-out: cubic-bezier(0.42, 0, 0.58, 1).
    static func easeInOut(_ progress: Double) -> Double {
        guard progress > 0, progress < 1 else { return progress }
        var low = 0.0
        var high = 1.0
        for _ in 0..<12 {
            let t = (low + high) / 2
            let x = 3 * (1 - t) * (1 - t) * t * 0.42 + 3 * (1 - t) * t * t * 0.58 + t * t * t
            if x < progress { low = t } else { high = t }
        }
        let t = (low + high) / 2
        return 3 * (1 - t) * t * t + t * t * t
    }

    private static func mix(_ start: Double, _ end: Double, _ t: Double) -> Double {
        start + (end - start) * t
    }
}

struct RBrandWordmark: View {
    @ScaledMetric(relativeTo: .title2) private var fontSize: CGFloat = 26

    var body: some View {
        Text("recoco")
            .font(.system(size: min(fontSize, 32), weight: .semibold, design: .rounded))
            .tracking(-1)
            .foregroundColor(.rTextPrimary)
            .accessibilityLabel("리코코")
    }
}
