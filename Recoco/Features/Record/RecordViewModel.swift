import SwiftUI
import UIKit

// MARK: - RecordViewModel
// 명세서 §8 S-07, S-08

enum RecordGenerationState: Equatable {
    case idle
    case generating
    case success(narrative: String, keywords: [String])
    case failed
    case pendingOffline   // 네트워크 없음, 로컬 초안 저장
}

struct RecordDraft {
    var meaning: String = ""
    var narrative: String = ""
    var keywords: [String] = []
    var capturedDate: String? = nil
    var cityName: String? = nil
}

@MainActor
final class RecordViewModel: ObservableObject {
    @Published var draft: RecordDraft = RecordDraft()
    @Published var generationState: RecordGenerationState = .idle
    @Published var isSaving: Bool = false
    @Published var isSaved: Bool = false
    @Published var showToast: Bool = false
    @Published var toastMessage: String = ""

    let unit: DecisionUnit
    private let onCompleted: () -> Void

    init(unit: DecisionUnit, onCompleted: @escaping () -> Void) {
        self.unit = unit
        self.onCompleted = onCompleted
        loadDraft()
    }

    // MARK: - 초안 로드 (로컬 자동 저장된 것)

    private func loadDraft() {
        // TODO: CoreData LocalRecordEntity에서 assetLocalIdentifier 기준으로 초안 로드
        // 현재는 빈 초안으로 시작
    }

    // MARK: - Meaning 입력 시 자동 저장

    func onMeaningChanged(_ text: String) {
        draft.meaning = text
        saveDraftLocally()
    }

    // MARK: - AI 내러티브 생성 요청

    func generateNarrative() async {
        guard !draft.meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        // 네트워크 확인
        guard isNetworkAvailable() else {
            generationState = .pendingOffline
            saveDraftLocally()
            showToastMessage("오프라인 상태예요. 의미는 저장되었어요.")
            return
        }

        generationState = .generating

        do {
            let result = try await callNarrativeAPI()
            draft.narrative = result.narrative
            draft.keywords = result.keywords
            generationState = .success(
                narrative: result.narrative,
                keywords: result.keywords
            )
        } catch {
            generationState = .failed
        }
    }

    // MARK: - 내러티브 직접 수정

    func updateNarrative(_ text: String) {
        draft.narrative = text
    }

    // MARK: - 저장

    func saveRecord() async {
        guard !draft.narrative.isEmpty || !draft.meaning.isEmpty else { return }

        isSaving = true
        defer { isSaving = false }

        do {
            // TODO: FirebaseService에 Record 저장
            // Firestore 저장 대상: meaning, narrative, keywords, capturedAt, cityName
            // 저장 금지: assetLocalIdentifier, 이미지 해시, GPS 좌표
            try await Task.sleep(nanoseconds: 600_000_000) // Mock

            // CoreData 동기화
            saveDraftLocally()

            isSaved = true
            showToastMessage("기억이 기록되었어요.")

            // 완료 콜백 (홈 → 오늘 완료 상태 전환)
            try await Task.sleep(nanoseconds: 800_000_000)
            onCompleted()

        } catch {
            showToastMessage("저장하지 못했어요. 다시 시도해주세요.")
        }
    }

    // MARK: - 재시도

    func retryGeneration() async {
        generationState = .idle
        await generateNarrative()
    }

    // MARK: - 문구 복사

    func copyNarrative() {
        UIPasteboard.general.string = draft.narrative
        showToastMessage("복사되었어요.")
    }

    // MARK: - Private

    private func saveDraftLocally() {
        // TODO: CoreData LocalRecordEntity upsert
        // isPendingGeneration = generationState == .pendingOffline
    }

    private func isNetworkAvailable() -> Bool {
        // TODO: NWPathMonitor 기반 네트워크 상태 확인
        return true // Mock
    }

    // MARK: - API 호출 (Firebase Callable Function 경유)

    private func callNarrativeAPI() async throws -> (narrative: String, keywords: [String]) {
        // TODO: Firebase Callable Function "generateNarrative" 호출
        // 전송 데이터: meaning, capturedAt, cityName, locale
        // 전송 금지: 이미지 원본, 이미지 해시, GPS 좌표

        // Mock 응답
        try await Task.sleep(nanoseconds: 2_000_000_000)
        return (
            narrative: "오래된 사진첩 속에서 다시 꺼낸 이 순간. 잊고 있었던 어느 오후의 온도가 천천히 되살아났다.",
            keywords: ["고요함", "따뜻함", "회상"]
        )
    }

    private func showToastMessage(_ message: String) {
        toastMessage = message
        showToast = true
    }
}
