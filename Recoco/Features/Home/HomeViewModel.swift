import SwiftUI
import Photos

// MARK: - HomeViewModel
// 명세서 §8 S-04

enum HomeState {
    case loading                      // 분석 준비 중
    case noPermission                 // 사진 접근 권한 없음
    case ready(DecisionUnit)          // 오늘의 Decision Unit 존재
    case completed(summary: CompletionSummary) // 오늘 완료
    case noCandidate                  // 정리 후보 없음
}

struct CompletionSummary {
    let deletedCount: Int
    let savedRecordCount: Int
}

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var state: HomeState = .loading
    @Published var weeklyProgress: WeeklyProgress = .init(
        completedDays: 0,
        deletedPhotoCount: 0,
        savedRecordCount: 0
    )
    @Published var userName: String = ""
    @Published var showToast: Bool = false
    @Published var toastMessage: String = ""

    // MARK: - 초기화

    func onAppear() async {
        await checkPermissionAndLoad()
    }

    // MARK: - 권한 확인 및 로드

    private func checkPermissionAndLoad() async {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)

        switch status {
        case .denied, .restricted:
            state = .noPermission

        case .notDetermined:
            // PhotoPermissionView에서 이미 요청했어야 하지만 방어 처리
            state = .noPermission

        case .authorized, .limited:
            await loadTodayDecision()

        @unknown default:
            state = .noPermission
        }
    }

    func loadTodayDecision() async {
        state = .loading

        // TODO: CurationService.shared.fetchTodayDecision() 호출
        // 현재는 Mock 데이터로 시뮬레이션
        try? await Task.sleep(nanoseconds: 800_000_000)

        // Mock: 실제 구현에서 교체
        weeklyProgress = .mock
        userName = "insu"

        // 시뮬레이션: cleanupCluster 제안
        state = .ready(.mockCluster)
    }

    // MARK: - 액션

    /// 나중에 — deferred 상태로 전환
    func deferDecision(_ unit: DecisionUnit) {
        // TODO: CurationRepository에 deferred 상태 저장
        // deferredUntil = 오늘 자정
        state = .noCandidate
        showToastMessage("나중에 다시 보여드릴게요.")
    }

    /// 오늘 완료 처리
    func markTodayCompleted(deletedCount: Int, savedRecord: Bool) {
        weeklyProgress = WeeklyProgress(
            completedDays: weeklyProgress.completedDays + 1,
            deletedPhotoCount: weeklyProgress.deletedPhotoCount + deletedCount,
            savedRecordCount: weeklyProgress.savedRecordCount + (savedRecord ? 1 : 0)
        )
        state = .completed(summary: CompletionSummary(
            deletedCount: deletedCount,
            savedRecordCount: savedRecord ? 1 : 0
        ))
    }

    /// Recall — 남기기 완료
    func keepRecallMoment(_ unit: DecisionUnit) {
        markTodayCompleted(deletedCount: 0, savedRecord: false)
    }

    private func showToastMessage(_ message: String) {
        toastMessage = message
        showToast = true
    }
}
