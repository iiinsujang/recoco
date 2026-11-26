import Foundation

enum RecocoPlan: String, Codable {
    case free
    case premium
}

struct FeatureAccess {
    static let planStorageKey = "recoco_plan_v1"
    static let premiumFeatureFlagKey = "RECOCO_PREMIUM_FEATURES_ENABLED"

    let plan: RecocoPlan
    let isSimilarPhotoCleanupEnabled: Bool

    var canUseSimilarPhotoCleanup: Bool {
        plan == .premium && isSimilarPhotoCleanupEnabled
    }

    @MainActor
    static func current(
        defaults: UserDefaults = .standard,
        bundle: Bundle = .main,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> FeatureAccess {
        #if DEBUG
        let debugPremium = arguments.contains("-premium-testing")
        let debugFeatureEnabled = arguments.contains("-enable-premium-features")
        #else
        let debugPremium = false
        let debugFeatureEnabled = false
        #endif

        let verifiedPlan: RecocoPlan = SubscriptionStore.shared.isActive ? .premium : .free
        let configuredFeatureFlag = bundle.object(
            forInfoDictionaryKey: premiumFeatureFlagKey
        ) as? Bool ?? false

        return FeatureAccess(
            plan: debugPremium ? .premium : verifiedPlan,
            isSimilarPhotoCleanupEnabled: debugFeatureEnabled || configuredFeatureFlag
        )
    }
}

// MARK: - DecisionUnit
// 명세서 §3 핵심 도메인

enum DecisionUnitType: String, Codable {
    case cleanupSingle   // 오늘 한 장씩 검토
    case cleanupCluster  // 유사·연속 촬영 묶음 정리
    case recallMoment    // 회상 제안
}

enum DecisionStatus: String, Codable {
    case pending      // 오늘 제안 가능
    case completed    // 완료
    case deferred     // 나중에 (자정 기준 다음 날 재제안)
    case unavailable  // 사진 삭제됨 또는 접근 불가
}

// MARK: - DecisionUnit

struct DecisionUnit: Identifiable {
    let id: UUID
    let type: DecisionUnitType
    var status: DecisionStatus

    // cleanupCluster 전용
    let candidateLocalIdentifiers: [String]   // PHAsset localIdentifier (로컬 전용)
    let recommendedLocalIdentifier: String?   // AI 추천 대표 사진
    var selectedLocalIdentifier: String?      // 사용자가 직접 선택한 경우
    let reasonCodes: [CurationReasonCode]     // 추천 근거

    // recallMoment 전용
    let capturedDateDescription: String?      // "2년 전 오늘" 같은 표시용 문자열

    // 공통
    let createdAt: Date
    var completedAt: Date?
    var deferredUntil: Date?                  // 자정 기준 다음 날
    var comparisonLocalIdentifier: String? = nil // 삭제 후보와 비교할, 남아 있는 다른 사진
    var evidence: CurationEvidence? = nil
    var capturedAt: Date? = nil

    var requiresReview: Bool {
        evidence?.requiresReview ?? !reasonCodes.contains(where: { [.exactDuplicate, .duplicateScreenshot].contains($0) })
    }

    var shortReason: String {
        evidence?.summary ?? reasonCodes.first?.displayText ?? String(localized: "아직 필요한 사진인지 살펴보세요.")
    }

    var photoDescription: String {
        evidence?.photoDescription ?? capturedDateDescription.map { String(localized: "\($0)의 사진") } ?? String(localized: "오늘 다시 만난 사진")
    }

    var selectionDetail: String {
        if reasonCodes.contains(.anniversaryReflection) || evidence?.reason == .anniversaryReflection {
            return String(localized: "지난해 같은 날짜에서 앞뒤 7일 안에 찍은 사진이에요.")
        }
        if reasonCodes.contains(where: \.isReflection) || evidence?.reason.isReflection == true {
            return evidence?.detail ?? String(localized: "다시 살펴볼 사진을 골랐어요.")
        }
        return evidence?.detail ?? shortReason
    }

    /// Name the evidence the user can actually inspect, without promising a missing copy.
    var evidenceActionTitle: String {
        let reason = evidence?.reason ?? reasonCodes.first
        if comparisonLocalIdentifier != nil {
            return reason == .exactDuplicate || reason == .duplicateScreenshot
                ? String(localized: "남길 사진과 비교") : String(localized: "두 사진 비교")
        }
        return String(localized: "고른 이유")
    }

    // MARK: - 계산 프로퍼티

    /// 사용자에게 보여줄 대표 사진 식별자
    var displayIdentifier: String? {
        selectedLocalIdentifier ?? recommendedLocalIdentifier
    }

    /// The one visible recall photo the user may explicitly choose to delete.
    /// This never makes it a recommended cleanup candidate.
    var userSelectedPhotoIdentifier: String? {
        guard type == .recallMoment, comparisonLocalIdentifier == nil,
              candidateLocalIdentifiers.count == 1,
              let identifier = displayIdentifier, !identifier.isEmpty,
              candidateLocalIdentifiers.first == identifier else { return nil }
        return identifier
    }

    /// 삭제 대상 식별자 (대표 사진 제외)
    var removalIdentifiers: [String] {
        guard type != .recallMoment, !reasonCodes.contains(where: \.isReflection),
              evidence?.reason.isReflection != true else { return [] }
        if type == .cleanupSingle {
            return candidateLocalIdentifiers
        }
        guard let kept = displayIdentifier else { return [] }
        return candidateLocalIdentifiers.filter { $0 != kept }
    }

    var candidateCount: Int {
        candidateLocalIdentifiers.count
    }

    var removalCount: Int {
        removalIdentifiers.count
    }

    var persistenceKey: String {
        candidateLocalIdentifiers.sorted().joined(separator: "|")
    }
}

/// Calendar-day matching avoids fixed 24-hour arithmetic around DST and leap days.
enum PhotoAnniversaryPolicy {
    /// The upper bound is exclusive; both seven-day boundary dates are included.
    static func window(relativeTo now: Date, calendar: Calendar = .current) -> DateInterval? {
        let today = calendar.startOfDay(for: now)
        guard let anniversary = calendar.date(byAdding: .year, value: -1, to: today),
              let year = calendar.dateInterval(of: .year, for: anniversary),
              let lower = calendar.date(byAdding: .day, value: -7, to: anniversary),
              let upper = calendar.date(byAdding: .day, value: 8, to: anniversary) else { return nil }
        let start = max(calendar.startOfDay(for: lower), year.start)
        let end = min(calendar.startOfDay(for: upper), year.end)
        guard start < end else { return nil }
        return DateInterval(start: start, end: end)
    }

    static func matches(_ capturedAt: Date?, relativeTo now: Date, calendar: Calendar = .current) -> Bool {
        guard let capturedAt, let window = window(relativeTo: now, calendar: calendar) else { return false }
        return capturedAt >= window.start && capturedAt < window.end
    }
}

// MARK: - CurationReasonCode
// 추천 근거 코드 → UI에서 한국어 문자열로 변환

enum CurationReasonCode: String, Codable {
    case dailyReflection
    case anniversaryReflection
    case exactDuplicate
    case duplicateScreenshot
    case expiredScreen
    case temporaryReference
    case shoppingScreen
    case lowDetail
    case reviewDateReached
    case visuallySimilar
    case sharpness        // 가장 선명해요
    case exposure         // 노출이 가장 적절해요
    case composition      // 구도가 안정적이에요
    case faceExpression   // 표정이 자연스러워요
    case eyesOpen         // 눈 감김이 없어요
    case noNoise          // 노이즈가 적어요
    case duplicate        // 중복 사진이에요
    case burstPhoto       // 연속 촬영 사진이에요
    case screenshot       // 스크린샷이에요
    case oldUnopened      // recoco에서 오랫동안 보지 않은 사진이에요

    var isReflection: Bool { self == .dailyReflection || self == .anniversaryReflection }

    var displayText: String {
        switch self {
        case .dailyReflection: return String(localized: "다시 살펴볼 사진을 골랐어요.")
        case .anniversaryReflection: return String(localized: "지난해 이맘때 찍은 사진이에요.")
        case .exactDuplicate: return String(localized: "같은 사진이 한 장 더 있어요.")
        case .duplicateScreenshot: return String(localized: "같은 스크린샷이 한 장 더 있어요.")
        case .expiredScreen: return String(localized: "화면에서 읽은 기한이 지났어요.")
        case .temporaryReference: return String(localized: "위치·이용 안내 문구가 담겨 있어요.")
        case .shoppingScreen: return String(localized: "구매·배송 관련 문구가 보여요.")
        case .lowDetail: return String(localized: "윤곽과 밝기 차이가 작은 사진이에요.")
        case .reviewDateReached: return String(localized: "직접 정한 확인 날짜가 되었어요.")
        case .visuallySimilar: return String(localized: "가까운 시간에 찍은 비슷한 사진이 있어요.")
        case .sharpness:       return String(localized: "가장 선명해요.")
        case .exposure:        return String(localized: "노출이 가장 적절해요.")
        case .composition:     return String(localized: "구도가 안정적이에요.")
        case .faceExpression:  return String(localized: "표정이 자연스러워요.")
        case .eyesOpen:        return String(localized: "눈 감김이 없어요.")
        case .noNoise:         return String(localized: "노이즈가 적어요.")
        case .duplicate:       return String(localized: "중복 사진이에요.")
        case .burstPhoto:      return String(localized: "연속 촬영 사진이에요.")
        case .screenshot:      return String(localized: "스크린샷이에요.")
        case .oldUnopened:     return String(localized: "오랫동안 보지 않은 사진이에요.")
        }
    }
}

/// Observations describe evidence, never the personal value of a photo.
struct CurationEvidence: Codable, Equatable {
    let reason: CurationReasonCode
    let photoDescription: String
    let detail: String
    var observedDate: Date? = nil
    /// The actual selection path may differ even when both use a neutral review reason.
    /// Older evidence without this field keeps the non-assumptive reason text.
    var selectionSummary: String? = nil

    var summary: String {
        guard reason.isReflection,
              let text = selectionSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return reason.displayText }
        return text
    }
    var requiresReview: Bool {
        ![CurationReasonCode.exactDuplicate, .duplicateScreenshot].contains(reason)
    }
    var label: String {
        reason.isReflection ? String(localized: "기억 돌아보기") : (requiresReview ? String(localized: "필요 확인") : String(localized: "정리 후보"))
    }
}

// MARK: - WeeklyProgress
// 주간 진행 상태 (완료 일수 기준, 명세서 §3.3)

struct WeeklyProgress {
    let completedDays: Int    // 완료한 날짜 수 (0~7)
    let totalDays: Int = 7
    let deletedPhotoCount: Int   // 보조 지표: 삭제한 사진 수
    let savedRecordCount: Int    // 보조 지표: 작성한 기록 수

    var progressRatio: Double {
        guard totalDays > 0 else { return 0 }
        return Double(completedDays) / Double(totalDays)
    }

    var displayText: String {
        String(localized: "\(completedDays) / \(totalDays)일")
    }

    static let empty = WeeklyProgress(
        completedDays: 0,
        deletedPhotoCount: 0,
        savedRecordCount: 0
    )
}

// MARK: - Mock 데이터 (Debug/Preview용)

#if DEBUG
extension DecisionUnit {
    static let mockCluster = DecisionUnit(
        id: UUID(),
        type: .cleanupCluster,
        status: .pending,
        candidateLocalIdentifiers: Array(repeating: "mock-id", count: 8),
        recommendedLocalIdentifier: "mock-recommended",
        selectedLocalIdentifier: nil,
        reasonCodes: [.sharpness, .faceExpression, .composition],
        capturedDateDescription: nil,
        createdAt: Date()
    )

    static let mockRecall = DecisionUnit(
        id: UUID(),
        type: .recallMoment,
        status: .pending,
        candidateLocalIdentifiers: ["mock-recall-id"],
        recommendedLocalIdentifier: "mock-recall-id",
        selectedLocalIdentifier: nil,
        reasonCodes: [.oldUnopened],
        capturedDateDescription: "2년 전 오늘",
        createdAt: Date()
    )
}

extension WeeklyProgress {
    static let mock = WeeklyProgress(
        completedDays: 3,
        deletedPhotoCount: 14,
        savedRecordCount: 2
    )
}
#endif
