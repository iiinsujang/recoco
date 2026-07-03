import SwiftUI

// MARK: - OnboardingViewModel
// 명세서 §8 S-02

struct OnboardingSlide: Identifiable {
    let id = UUID()
    let headline: String
    let subText: String
}

@MainActor
final class OnboardingViewModel: ObservableObject {
    @Published var currentIndex: Int = 0

    let slides: [OnboardingSlide] = [
        OnboardingSlide(
            headline: "비움으로 선명해지는\n당신의 기록",
            subText: "사진이 많아질수록, 기억은 더 쉽게 묻힐 수 있어요."
        ),
        OnboardingSlide(
            headline: "하루 하나의 결정이면\n충분해요",
            subText: "복잡한 사진첩을 한 번에 정리할 필요는 없어요."
        ),
        OnboardingSlide(
            headline: "남길 순간은\n기록으로 남겨요",
            subText: "사진을 비우고, 정말 소중한 순간은 더 또렷하게 남겨보세요."
        )
    ]

    var isLastSlide: Bool {
        currentIndex == slides.count - 1
    }

    func next() {
        if !isLastSlide {
            currentIndex += 1
        }
    }

    func markCompleted() {
        UserDefaults.standard.set(true, forKey: "recoco_onboarding_completed")
    }
}
