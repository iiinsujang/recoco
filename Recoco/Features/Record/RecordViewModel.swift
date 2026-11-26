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

struct RecordDraft: Codable {
    // Optional for drafts created before retry-safe saving was introduced.
    var recordID: UUID? = nil
    var photoThumbnailData: Data? = nil
    var meaning: String = ""
    var narrative: String = ""
    var hasPreparedNarrative: Bool? = nil
    var wasNarrativeEdited: Bool? = nil
    var hasMeaningChangesAfterEditing: Bool? = nil
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
    @Published private(set) var savedRecord: SavedMemoryRecord?
    @Published private(set) var saveError: String?
    @Published var showToast: Bool = false
    @Published var toastMessage: String = ""
    @Published var usedLocalFallback: Bool = false
    @Published var photoLocationHint: String?
    @Published private(set) var photoPreviewUnavailable = false

    let unit: DecisionUnit
    private let onCompleted: (SavedMemoryRecord) -> Void
    private let defaults: UserDefaults
    private let recordStore: SavedRecordStore
    private let narrativeService: any NarrativeGenerating
    private let photoMetadata: @MainActor (String?) async -> String?
    private let photoPreview: @MainActor (String) async -> UIImage?
    private var photoPreviewTask: Task<Data?, Never>?
    private var photoPreviewRequestID: UUID?
    private var didLoadPhotoMetadata = false
    private var generationRequestID: UUID?
    private var canWriteDraft = true

    init(
        unit: DecisionUnit,
        selectedImage: UIImage? = nil,
        defaults: UserDefaults = .standard,
        narrativeService: any NarrativeGenerating = FirebaseNarrativeService(),
        photoMetadata: @escaping @MainActor (String?) async -> String? = {
            await PhotoMetadataService().locationName(for: $0)
        },
        photoPreview: @escaping @MainActor (String) async -> UIImage? = {
            await RecordPhotoPreviewService.image(for: $0)
        },
        onCompleted: @escaping (SavedMemoryRecord) -> Void
    ) {
        self.unit = unit
        self.defaults = defaults
        self.recordStore = SavedRecordStore(defaults: defaults)
        self.narrativeService = narrativeService
        self.photoMetadata = photoMetadata
        self.photoPreview = photoPreview
        self.onCompleted = onCompleted
        loadDraft()
        // Older drafts did not distinguish generated text from manual edits.
        // Preserve every prepared legacy preview rather than risk erasing it.
        if draft.wasNarrativeEdited == nil {
            draft.wasNarrativeEdited = hasPreparedNarrative
        }
        // Picker access can outlive PhotoKit access to its identifier. Keep only a
        // bounded local preview so the selected photo remains visible in the record.
        if let selectedImage, let data = Self.thumbnailData(for: selectedImage) {
            draft.photoThumbnailData = data
        }
        if draft.recordID == nil { draft.recordID = UUID() }
        if draft.capturedDate == nil {
            draft.capturedDate = unit.capturedDateDescription
        }
        saveDraftLocally()
    }

    // MARK: - 초안 로드 (로컬 자동 저장된 것)

    private func loadDraft() {
        guard defaults.object(forKey: draftStorageKey) != nil else { return }
        guard let data = defaults.data(forKey: draftStorageKey),
              let savedDraft = try? JSONDecoder().decode(RecordDraft.self, from: data) else {
            canWriteDraft = false
            showToastMessage(String(localized: "이전 초안을 읽지 못했어요. 원본은 그대로 보관하고 있어요."))
            return
        }
        draft = savedDraft
    }

    // MARK: - Meaning 입력 시 자동 저장

    func onMeaningChanged(_ text: String) {
        guard !isSaved, !isSaving else { return }
        if draft.meaning != text {
            generationRequestID = nil
            generationState = .idle
            if draft.wasNarrativeEdited == true {
                draft.hasMeaningChangesAfterEditing = true
            } else {
                draft.narrative = ""
                draft.hasPreparedNarrative = false
                draft.keywords = []
                usedLocalFallback = false
            }
        }
        draft.meaning = text
        saveDraftLocally()
    }

    var hasPreparedNarrative: Bool {
        draft.hasPreparedNarrative == true || !draft.narrative.isEmpty
    }

    var canOpenPreview: Bool {
        hasPreparedNarrative || !draft.meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasPhotoPreview: Bool {
        draft.photoThumbnailData.flatMap { UIImage(data: $0) } != nil
    }

    var hasSavedPhotoPreview: Bool {
        savedRecord?.photoThumbnailData.flatMap { UIImage(data: $0) } != nil
    }

    /// Both Home and the photo picker persist the same bounded preview. Loading
    /// starts while writing, and saving joins it rather than racing past it.
    func loadPhotoPreview() async {
        guard !isSaved, canWriteDraft, !hasPhotoPreview,
              let identifier = unit.displayIdentifier else { return }
        let request: Task<Data?, Never>
        let requestID: UUID
        if let running = photoPreviewTask, let runningID = photoPreviewRequestID {
            request = running
            requestID = runningID
        } else {
            requestID = UUID()
            request = Task { [photoPreview] in
                guard let image = await photoPreview(identifier), !Task.isCancelled else { return nil }
                return Self.thumbnailData(for: image)
            }
            photoPreviewTask = request
            photoPreviewRequestID = requestID
        }
        let data = await request.value
        // A saved record is immutable, including after a late preview response.
        guard !Task.isCancelled, !isSaved, photoPreviewRequestID == requestID else { return }
        photoPreviewTask = nil
        photoPreviewRequestID = nil
        if let data, UIImage(data: data) != nil {
            draft.photoThumbnailData = data
            photoPreviewUnavailable = false
            saveDraftLocally()
        } else if !hasPhotoPreview {
            photoPreviewUnavailable = true
        }
    }

    /// Leaving an unfinished editor must invalidate responses owned by it, so a
    /// reopened editor cannot have its newer draft overwritten by the old view.
    func cancelPendingWork() {
        guard !isSaving else { return }
        generationRequestID = nil
        if case .generating = generationState { generationState = .idle }
        photoPreviewTask?.cancel()
        photoPreviewTask = nil
        photoPreviewRequestID = nil
    }

    func loadPhotoMetadata() async {
        guard !didLoadPhotoMetadata, !isSaved else { return }
        didLoadPhotoMetadata = true

        let locationName = await photoMetadata(unit.displayIdentifier)
        guard !isSaved, !Task.isCancelled else { return }
        photoLocationHint = locationName

        if let locationName,
           draft.cityName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            draft.cityName = locationName
            saveDraftLocally()
        }
    }

    // MARK: - AI 내러티브 생성 요청

    func generateNarrative() async {
        guard generationRequestID == nil, !isSaved else { return }
        // Previewing again must not replace edits, including an intentionally
        // emptied preview. Older drafts infer readiness from their saved text.
        if hasPreparedNarrative {
            generationState = .success(narrative: draft.narrative, keywords: draft.keywords)
            return
        }
        guard !draft.meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let meaning = draft.meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestID = UUID()
        generationRequestID = requestID
        defer {
            if generationRequestID == requestID { generationRequestID = nil }
        }
        generationState = .generating

        do {
            let generated = try await narrativeService.generate(
                meaning: meaning,
                capturedAt: draft.capturedDate,
                cityName: draft.cityName,
                locale: Locale.current.identifier,
                clues: unit.reasonCodes.map(\.displayText)
            )
            guard generationRequestID == requestID, !isSaved else { return }
            applyGeneratedNarrative(generated, usedLocalFallback: false)
        } catch NarrativeServiceError.firebaseNotConfigured, NarrativeServiceError.unauthenticated {
            guard generationRequestID == requestID, !isSaved else { return }
            // Device-only use is a complete local path, not a failed connection.
            applyGeneratedNarrative(GeneratedNarrative(narrative: meaning, keywords: []), usedLocalFallback: true)
        } catch {
            guard generationRequestID == requestID, !isSaved else { return }
            let fallback = GeneratedNarrative(narrative: meaning, keywords: [])
            applyGeneratedNarrative(fallback, usedLocalFallback: true)
            showToastMessage(String(localized: "연결이 어려워 작성한 글을 그대로 준비했어요."))
        }
    }

    // MARK: - 내러티브 직접 수정

    func updateNarrative(_ text: String) {
        guard !isSaved, !isSaving else { return }
        generationRequestID = nil
        draft.narrative = text
        draft.hasPreparedNarrative = true
        draft.wasNarrativeEdited = true
        draft.hasMeaningChangesAfterEditing = false
        generationState = .success(narrative: text, keywords: draft.keywords)
        saveDraftLocally()
    }

    // MARK: - 저장

    func saveRecord(allowTextOnly: Bool = false) async {
        guard !Task.isCancelled else { return }
        guard canWriteDraft else {
            saveError = String(localized: "이전 초안을 읽지 못해 저장을 멈췄어요. 작성한 글을 선택해 따로 복사해주세요.")
            return
        }
        guard !shareText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !isSaving, !isSaved else { return }

        isSaving = true
        generationRequestID = nil
        saveError = nil
        defer { isSaving = false }

        if !allowTextOnly {
            await loadPhotoPreview()
            guard !Task.isCancelled else { return }
            if unit.displayIdentifier != nil && !hasPhotoPreview {
                saveError = String(localized: "사진 미리보기를 보관하지 못했어요. 다시 시도하거나 글만 저장할 수 있어요.")
                return
            }
        }
        guard !Task.isCancelled else { return }

        do {
            let record = try saveCompletedRecord()
            savedRecord = record
            isSaved = true
            onCompleted(record)
            defaults.removeObject(forKey: draftStorageKey)
        } catch {
            saveError = String(localized: "기록을 저장하지 못했어요. 작성한 글은 화면에 그대로 있어요. 다시 저장해주세요.")
        }
    }

    // MARK: - 재시도

    func retryGeneration() async {
        await generateNarrative()
    }

    // MARK: - 문구 복사

    func copyNarrative() {
        UIPasteboard.general.string = shareText
        showToastMessage(String(localized: "복사되었어요."))
    }

    var shareText: String {
        if let savedRecord { return savedRecord.text }
        let narrative = draft.narrative.trimmingCharacters(in: .whitespacesAndNewlines)
        return hasPreparedNarrative ? narrative : draft.meaning
    }

    // MARK: - Private

    private func saveDraftLocally() {
        guard canWriteDraft, !isSaved else { return }
        guard let data = try? JSONEncoder().encode(draft) else { return }
        defaults.set(data, forKey: draftStorageKey)
    }

    private var draftStorageKey: String {
        UserScopedStorage.draftKey(photoID: unit.displayIdentifier ?? unit.id.uuidString)
    }

    private func saveCompletedRecord() throws -> SavedMemoryRecord {
        try recordStore.save(
            id: draft.recordID ?? UUID(),
            text: shareText,
            photoLocalIdentifier: unit.displayIdentifier,
            capturedDateDescription: unit.capturedDateDescription,
            photoThumbnailData: draft.photoThumbnailData
        )
    }

    static func thumbnailData(for image: UIImage) -> Data? {
        let edge = max(image.size.width, image.size.height)
        guard edge > 0 else { return nil }
        let ratio = min(1, 320 / edge)
        let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }.jpegData(compressionQuality: 0.75)
    }

    private func applyGeneratedNarrative(
        _ generated: GeneratedNarrative,
        usedLocalFallback: Bool
    ) {
        draft.narrative = generated.narrative
        draft.hasPreparedNarrative = true
        draft.wasNarrativeEdited = false
        draft.hasMeaningChangesAfterEditing = false
        draft.keywords = generated.keywords
        self.usedLocalFallback = usedLocalFallback
        saveDraftLocally()
        generationState = .success(
            narrative: generated.narrative,
            keywords: generated.keywords
        )
    }

    private func showToastMessage(_ message: String) {
        toastMessage = message
        showToast = true
    }
}
