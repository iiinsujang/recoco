import SwiftUI

// MARK: - OnboardingViewModel
// 명세서 §8 S-02

struct OnboardingSlide {
    enum Scene { case floating, choosing, cherishing }

    let scene: Scene
    let headline: String
    let subText: String
    let actionTitle: String
}

@MainActor
final class OnboardingViewModel: ObservableObject {
    @Published var currentIndex: Int = 0
    @Published private(set) var errorMessage: String?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    let slides: [OnboardingSlide] = [
        OnboardingSlide(
            scene: .floating,
            headline: String(localized: "쌓인 사진,\n정리할 것부터 골라드려요."),
            subText: String(localized: "비슷한 여행 사진과 오래된 캡처가 쌓여도,\n앨범을 처음부터 훑을 필요는 없어요."),
            actionTitle: String(localized: "어떻게 골라주나요?")
        ),
        OnboardingSlide(
            scene: .choosing,
            headline: String(localized: "오늘은 제가\n최대 세 장 골라볼게요."),
            subText: String(localized: "같은 사진이나 연달아 찍은\n비슷한 장면을 찾아요."),
            actionTitle: String(localized: "다음")
        ),
        OnboardingSlide(
            scene: .cherishing,
            headline: String(localized: "남기고 싶은 사진은\n그대로 두세요."),
            subText: String(localized: "내가 고른 사진만 마지막 확인 뒤에 비워요.\n마음이 안 서면 오늘은 모두 남겨도 괜찮아요."),
            actionTitle: String(localized: "사진 정리 시작하기")
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

    func skipToLastSlide() {
        currentIndex = slides.count - 1
    }

    /// New users choose Apple sign-in or device-only use after the introduction.
    /// Existing local sessions still use the returning-user route unchanged.
    func finishIntroduction() -> AppRoute? {
        errorMessage = nil
        defaults.set(true, forKey: "recoco_onboarding_completed")
        guard defaults.bool(forKey: "recoco_onboarding_completed") else {
            errorMessage = String(localized: "시작 상태를 저장하지 못했어요. 다시 시도해주세요.")
            return nil
        }
        return .login
    }

    /// Complete the introduction only once a usable local session exists.
    /// A failed start stays on the final slide, with the user's data untouched.
    func startLocalExperience(startLocalSession: () -> Bool,
                              photoAuthStatus: PhotoAuthStatus) -> AppRoute? {
        errorMessage = nil
        guard startLocalSession() else { return nil }
        defaults.set(true, forKey: "recoco_onboarding_completed")
        guard defaults.bool(forKey: "recoco_onboarding_completed") else {
            errorMessage = String(localized: "시작 상태를 저장하지 못했어요. 다시 시도해주세요.")
            return nil
        }
        return photoAuthStatus == .notDetermined ? .photoPermission : .main
    }
}
