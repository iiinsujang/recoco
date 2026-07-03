import Foundation

// MARK: - DecisionUnit
// 명세서 §3 핵심 도메인

enum DecisionUnitType: String, Codable {
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

    // MARK: - 계산 프로퍼티

    /// 사용자에게 보여줄 대표 사진 식별자
    var displayIdentifier: String? {
        selectedLocalIdentifier ?? recommendedLocalIdentifier
    }

    /// 삭제 대상 식별자 (대표 사진 제외)
    var removalIdentifiers: [String] {
        guard let kept = displayIdentifier else { return [] }
        return candidateLocalIdentifiers.filter { $0 != kept }
    }

    var candidateCount: Int {
        candidateLocalIdentifiers.count
    }

    var removalCount: Int {
        removalIdentifiers.count
    }
}

// MARK: - CurationReasonCode
// 추천 근거 코드 → UI에서 한국어 문자열로 변환

enum CurationReasonCode: String, Codable {
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

    var displayText: String {
        switch self {
        case .sharpness:       return "가장 선명해요."
        case .exposure:        return "노출이 가장 적절해요."
        case .composition:     return "구도가 안정적이에요."
        case .faceExpression:  return "표정이 자연스러워요."
        case .eyesOpen:        return "눈 감김이 없어요."
        case .noNoise:         return "노이즈가 적어요."
        case .duplicate:       return "중복 사진이에요."
        case .burstPhoto:      return "연속 촬영 사진이에요."
        case .screenshot:      return "스크린샷이에요."
        case .oldUnopened:     return "오랫동안 보지 않은 사진이에요."
        }
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
        "\(completedDays) / \(totalDays)일"
    }
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

    static let empty = WeeklyProgress(
        completedDays: 0,
        deletedPhotoCount: 0,
        savedRecordCount: 0
    )
}
#endif
