import SwiftUI
import Photos
import UIKit

// Photos performs a single transaction. Only its successful completion is evidence
// of deletion; missing assets after an error can also mean revoked/limited access.
@MainActor
final class PhotoDeletionController: ObservableObject {
    enum DeletionError: Error { case changedPhotos }
    @Published private(set) var isDeleting = false
    private let validate: (DecisionUnit) async throws -> Bool
    private let commit: (DecisionUnit) async throws -> Void
    private let validateSelection: (String) async throws -> Bool
    private let commitSelection: (String) async throws -> Void
    private let validateBatch: ([DecisionUnit]) async throws -> Bool
    private let commitBatch: ([DecisionUnit]) async throws -> Void

    init(
        validate: @escaping (DecisionUnit) async throws -> Bool = { unit in
            let protection = try CurationProtectionStore.shared.validatedIdentifiers()
            return await PhotoCurationService().canDelete(unit, protectedIdentifiers: protection,
                                                         reviewDates: CurationReviewStore.shared.dates())
        },
        commit: @escaping (DecisionUnit) async throws -> Void = PhotoDeletionController.commitToPhotos,
        validateSelection: @escaping (String) async throws -> Bool = { identifier in
            await PhotoCurationService().canDeleteSelectedPhoto(identifier)
        },
        commitSelection: @escaping (String) async throws -> Void = PhotoDeletionController.commitSelectedPhotoToPhotos,
        validateBatch: (([DecisionUnit]) async throws -> Bool)? = nil,
        commitBatch: @escaping ([DecisionUnit]) async throws -> Void = PhotoDeletionController.commitBatchToPhotos
    ) {
        self.validate = validate
        self.commit = commit
        self.validateSelection = validateSelection
        self.commitSelection = commitSelection
        self.validateBatch = validateBatch ?? { units in
            for unit in units {
                guard try await validate(unit) else { return false }
            }
            return true
        }
        self.commitBatch = commitBatch
    }

    @discardableResult
    func delete(_ unit: DecisionUnit, onCompleted: (Int) -> Void) async throws -> Bool {
        try await performDeletion(identifiers: unit.removalIdentifiers,
                                  validate: { try await self.validate(unit) },
                                  commit: { try await self.commit(unit) }, onCompleted: onCompleted)
    }

    @discardableResult
    func deleteChosenPhoto(_ unit: DecisionUnit, onCompleted: (Int) -> Void) async throws -> Bool {
        guard let identifier = unit.userSelectedPhotoIdentifier else { throw DeletionError.changedPhotos }
        return try await performDeletion(identifiers: [identifier],
                                         validate: { try await self.validateSelection(identifier) },
                                         commit: { try await self.commitSelection(identifier) }, onCompleted: onCompleted)
    }

    /// Delete only the checked one-photo recommendations in one Photos transaction.
    /// The caller holds these immutable snapshots until completion; no callback is
    /// delivered for cancellation, stale evidence, or a failed transaction.
    @discardableResult
    func deleteBatch(_ units: [DecisionUnit], onCompleted: (Int) -> Void) async throws -> Bool {
        guard !isDeleting else { return false }
        let identifiers = try Self.batchIdentifiers(units)
        return try await performDeletion(identifiers: identifiers,
                                         validate: { try await self.validateBatch(units) },
                                         commit: { try await self.commitBatch(units) }, onCompleted: onCompleted)
    }

    private static func batchIdentifiers(_ units: [DecisionUnit]) throws -> [String] {
        guard !units.isEmpty, Set(units.map(\.persistenceKey)).count == units.count else {
            throw DeletionError.changedPhotos
        }
        var identifiers: [String] = []
        for unit in units {
            guard unit.type == .cleanupSingle, unit.status == .pending,
                  unit.candidateLocalIdentifiers.count == 1,
                  unit.removalIdentifiers.count == 1,
                  let identifier = unit.displayIdentifier, !identifier.isEmpty,
                  unit.removalIdentifiers.first == identifier else { throw DeletionError.changedPhotos }
            identifiers.append(identifier)
        }
        let references = units.compactMap(\.comparisonLocalIdentifier)
        guard Set(identifiers).count == identifiers.count,
              references.allSatisfy({ !$0.isEmpty }),
              Set(identifiers).isDisjoint(with: references) else { throw DeletionError.changedPhotos }
        return identifiers
    }

    private func performDeletion(identifiers: [String], validate: () async throws -> Bool,
                                 commit: () async throws -> Void, onCompleted: (Int) -> Void) async throws -> Bool {
        guard !isDeleting else { return false }
        isDeleting = true
        defer { isDeleting = false }
        // Identity and the local photo-data namespace are intentionally separate.
        // A login change while validating must not authorize a stale operation.
        let accountID = UserScopedStorage.currentUserID
        guard !identifiers.isEmpty, Set(identifiers).count == identifiers.count,
              try await validate(), accountID == UserScopedStorage.currentUserID else {
            throw DeletionError.changedPhotos
        }
        try Task.checkCancellation()
        do {
            try await commit()
        } catch {
            let photoError = error as NSError
            if photoError.domain == PHPhotosErrorDomain,
               photoError.code == PHPhotosError.Code.userCancelled.rawValue { return false }
            throw error
        }
        // Do not check task cancellation after Photos succeeds: commit the result even
        // when the screen disappears while the system confirmation is open.
        onCompleted(identifiers.count)
        return true
    }

    static func forPresentation() -> PhotoDeletionController {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-ui-testing") {
            if arguments.contains("-ui-testing-delete-success") {
                return PhotoDeletionController(validate: { _ in true }, commit: { _ in },
                                               validateSelection: { _ in true }, commitSelection: { _ in },
                                               commitBatch: { _ in })
            }
            if arguments.contains("-ui-testing-delete-cancel") {
                return PhotoDeletionController(validate: { _ in true }, commit: { _ in
                    throw NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.Code.userCancelled.rawValue)
                }, validateSelection: { _ in true }, commitSelection: { _ in
                    throw NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.Code.userCancelled.rawValue)
                }, commitBatch: { _ in
                    throw NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.Code.userCancelled.rawValue)
                })
            }
            if arguments.contains("-ui-testing-delete-failure") {
                return PhotoDeletionController(validate: { _ in false }, commit: { _ in },
                                               validateSelection: { _ in false }, commitSelection: { _ in },
                                               commitBatch: { _ in })
            }
        }
        #endif
        return PhotoDeletionController()
    }

    private static func commitToPhotos(_ unit: DecisionUnit) async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { throw DeletionError.changedPhotos }
        let identifiers = unit.removalIdentifiers
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        let protected = try CurationProtectionStore.shared.validatedIdentifiers()
        var available = Set<String>()
        var unsafe = false
        assets.enumerateObjects { asset, _, _ in
            available.insert(asset.localIdentifier)
            unsafe = unsafe || asset.isFavorite || asset.isHidden || protected.contains(asset.localIdentifier)
        }
        guard !unsafe, available == Set(identifiers) else { throw DeletionError.changedPhotos }
        if let kept = unit.type == .cleanupSingle ? unit.comparisonLocalIdentifier : unit.displayIdentifier {
            guard !available.contains(kept),
                  PHAsset.fetchAssets(withLocalIdentifiers: [kept], options: nil).count == 1 else {
                throw DeletionError.changedPhotos
            }
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }

    private static func commitBatchToPhotos(_ units: [DecisionUnit]) async throws {
        let identifiers = try batchIdentifiers(units)
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { throw DeletionError.changedPhotos }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        let protected = try CurationProtectionStore.shared.validatedIdentifiers()
        var available = Set<String>()
        var unsafe = false
        assets.enumerateObjects { asset, _, _ in
            available.insert(asset.localIdentifier)
            unsafe = unsafe || asset.mediaType != .image || !asset.canPerform(.delete)
                || asset.isFavorite || asset.isHidden || protected.contains(asset.localIdentifier)
        }
        guard !unsafe, available == Set(identifiers) else { throw DeletionError.changedPhotos }
        let references = Set(units.compactMap(\.comparisonLocalIdentifier))
        let keptAssets = PHAsset.fetchAssets(withLocalIdentifiers: Array(references), options: nil)
        var availableReferences = Set<String>()
        keptAssets.enumerateObjects { asset, _, _ in availableReferences.insert(asset.localIdentifier) }
        guard availableReferences == references else { throw DeletionError.changedPhotos }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }

    private static func commitSelectedPhotoToPhotos(_ identifier: String) async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard !identifier.isEmpty, status == .authorized || status == .limited else {
            throw DeletionError.changedPhotos
        }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard assets.count == 1, let asset = assets.firstObject,
              asset.localIdentifier == identifier, asset.mediaType == .image,
              !asset.isHidden, asset.canPerform(.delete) else { throw DeletionError.changedPhotos }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }
}

// MARK: - S-05 정리 확인 바텀시트
// 명세서 §8 S-05
// - 삭제 대상 개수, 대표 사진, 삭제 후보 썸네일, 추천 근거
// - 정리하기 → PHPhotoLibrary 삭제 → 완료
// - 시스템에서 확인된 성공만 완료 처리; 취소/실패는 원래 큐 유지
// - 자동 삭제 없음 (명세서 §15.4)

enum SavedRecordDeletionNotice {
    static func message(records: [SavedMemoryRecord], identifier: String) -> String? {
        let matching = records.filter { $0.photoLocalIdentifier == identifier }
        guard !matching.isEmpty else { return nil }
        let previews = matching.filter { record in
            guard let data = record.photoThumbnailData, let image = UIImage(data: data) else { return false }
            return image.size.width > 0 && image.size.height > 0
        }.count
        if previews == matching.count {
            return String(localized: "남긴 글과 작은 사진 미리보기는 기록에 남아요.")
        }
        if previews == 0 {
            return String(localized: "남긴 글은 유지되지만, 기록의 사진은 보이지 않을 수 있어요.")
        }
        return String(localized: "남긴 글과 저장된 작은 미리보기는 남아요. 미리보기가 없는 기록에서는 사진이 보이지 않을 수 있어요.")
    }
}

struct SinglePhotoDeleteSheet: View {
    let unit: DecisionUnit
    var returnsAfterSuccess = false
    let onCompleted: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var deletion = PhotoDeletionController.forPresentation()
    @State private var completedCount: Int?
    @State private var cancellationNotice = ""
    @State private var showError: Bool = false
    @State private var errorMessage = String(localized: "사진 접근 권한을 확인한 뒤 다시 시도해주세요.")
    @State private var savedRecordNotice: String?
    @State private var isFavorite = false

    var body: some View {
        Group {
            if let completedCount {
                PhotoDeletionResultView(count: completedCount) { dismiss() }
            } else {
                confirmationContent
            }
        }
        .task(id: unit.id) { loadSelectionNotices() }
    }

    private var confirmationContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: RSpacing.xl) {
                    VStack(alignment: .leading, spacing: RSpacing.xs) {
                        Text("이 사진을 비울까요?")
                            .rTextStyle(.headline)
                        Text("사진 앱의 최근 삭제된 항목으로 이동해요.")
                            .rTextStyle(.body, color: .rTextSecondary)
                    }

                    if let reference = unit.comparisonLocalIdentifier, let candidate = unit.displayIdentifier {
                        CurationComparisonView(candidateIdentifier: candidate, referenceIdentifier: reference)
                    } else {
                        PHAssetImageView(
                            localIdentifier: unit.displayIdentifier ?? "",
                            targetSize: CGSize(width: 500, height: 500),
                            scalesToFit: true
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: RSize.photoPreview)
                        .clipShape(RoundedRectangle(cornerRadius: RRadius.lg))
                    }

                    if unit.type == .recallMoment {
                        if isFavorite {
                            Text("즐겨찾기에 둔 사진이에요.")
                                .rTextStyle(.body, color: .rTextSecondary)
                        }
                    } else {
                        Text(unit.shortReason)
                            .rTextStyle(.body, color: .rTextSecondary)
                        if let evidence = unit.evidence, evidence.requiresReview {
                            Text(evidence.detail)
                                .rTextStyle(.caption, color: .rTextSecondary)
                        }
                    }
                    if let savedRecordNotice {
                        Text(savedRecordNotice)
                            .rTextStyle(.body, color: .rTextSecondary)
                    }
                }
                .rScreenPadding()
            }

            VStack(spacing: RLayout.actionGap) {
                cancellationFeedback
                RButton(
                    title: String(localized: "비우기"),
                    variant: .destructive,
                    isLoading: deletion.isDeleting
                ) {
                    Task { await deletePhoto() }
                }

                RButton(title: String(localized: "취소"), variant: .secondary) {
                    dismiss()
                }
                .disabled(deletion.isDeleting)
            }
            .padding(.horizontal, RLayout.screenInset)
            .padding(.top, RSpacing.sm)
            .padding(.bottom, RSpacing.xs)
        }
        .background(Color.rBackground)
        .interactiveDismissDisabled(deletion.isDeleting)
        .alert("사진을 비우지 못했어요.", isPresented: $showError) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    @ViewBuilder
    private var cancellationFeedback: some View {
        if !cancellationNotice.isEmpty {
            Text(cancellationNotice)
                .rTextStyle(.body, color: .rTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("deletion.cancelled")
        }
    }

    private func deletePhoto() async {
        cancellationNotice = ""
        do {
            let completed: (Int) -> Void = { count in
                onCompleted(count)
                if returnsAfterSuccess { dismiss() }
                else { completedCount = count }
            }
            let didDelete: Bool
            if unit.type == .recallMoment {
                didDelete = try await deletion.deleteChosenPhoto(unit, onCompleted: completed)
            } else {
                didDelete = try await deletion.delete(unit, onCompleted: completed)
            }
            if !didDelete {
                cancellationNotice = String(localized: "비우기를 취소했어요. 사진은 그대로예요.")
                UIAccessibility.post(notification: .announcement, argument: cancellationNotice)
            }
        } catch is CancellationError {
            cancellationNotice = String(localized: "비우기를 취소했어요. 사진은 그대로예요.")
        } catch {
            errorMessage = String(localized: "삭제 완료를 확인하지 못해 비운 수에 반영하지 않았어요. 사진 상태와 접근 권한을 확인한 뒤 다시 시도해주세요.")
            showError = true
        }
    }

    private func loadSelectionNotices() {
        savedRecordNotice = nil
        guard let identifier = unit.displayIdentifier else { return }
        do {
            savedRecordNotice = SavedRecordDeletionNotice.message(
                records: try SavedRecordStore.shared.readRecords(), identifier: identifier)
        } catch {
            savedRecordNotice = String(localized: "이 사진으로 남긴 글이 있다면 글은 유지되지만, 기록의 사진은 보이지 않을 수 있어요.")
        }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        if let asset = assets.firstObject, asset.localIdentifier == identifier, !asset.isHidden {
            isFavorite = asset.isFavorite
        }
    }

}

struct CleanupConfirmSheet: View {
    let unit: DecisionUnit
    var returnsAfterSuccess = false
    let onCompleted: (Int) -> Void  // 삭제된 장수 전달

    @Environment(\.dismiss) private var dismiss
    @StateObject private var deletion = PhotoDeletionController.forPresentation()
    @State private var completedCount: Int?
    @State private var cancellationNotice = ""
    @State private var showFailure: Bool = false
    @State private var failureMessage: String = ""

    var body: some View {
        Group {
            if let completedCount {
                PhotoDeletionResultView(count: completedCount) { dismiss() }
            } else {
                confirmationContent
            }
        }
    }

    private var confirmationContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: RSpacing.xl) {
                    // 헤더
                    headerSection

                    // 대표 사진 + 삭제 후보 썸네일
                    photoSection

                    // 추천 근거
                    reasonSection

                    // 안내 문구
                    infoText

                    // 버튼
                    actionButtons
                }
                .rScreenPadding()
            }
        }
        .background(Color.rBackground)
        .interactiveDismissDisabled(deletion.isDeleting)
        .alert("사진을 정리하지 못했어요.", isPresented: $showFailure) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(failureMessage)
        }
    }

    // MARK: - 헤더

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: RSpacing.xs) {
            Text("이 사진들을 정리할까요?")
                .rTextStyle(.headline)
            Text("남길 사진 한 장은 그대로 두어요.")
                .rTextStyle(.body, color: .rTextSecondary)
        }
    }

    // MARK: - 사진 섹션

    private var photoSection: some View {
        VStack(alignment: .leading, spacing: RSpacing.lg) {
            VStack(alignment: .leading, spacing: RSpacing.xs) {
                Label("남길 사진", systemImage: "checkmark.circle")
                    .rTextStyle(.subLabel)
                PHAssetImageView(
                    localIdentifier: unit.displayIdentifier ?? "",
                    targetSize: CGSize(width: 360, height: 240),
                    scalesToFit: true
                )
                .frame(maxWidth: .infinity)
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: RRadius.md))
                .accessibilityLabel("사진첩에 남길 사진")
            }

            VStack(alignment: .leading, spacing: RSpacing.xs) {
                Text("비울 후보 \(unit.removalCount)장")
                    .rTextStyle(.subLabel, color: .rTextSecondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72, maximum: 112), spacing: RSpacing.xs)], spacing: RSpacing.xs) {
                    ForEach(unit.removalIdentifiers.prefix(6), id: \.self) { id in
                        PHAssetImageView(localIdentifier: id, targetSize: CGSize(width: 160, height: 160))
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: RRadius.compact))
                            .accessibilityLabel("비울 후보")
                    }
                    if unit.removalCount > 6 {
                        Text("+\(unit.removalCount - 6)")
                            .rTextStyle(.subLabel, color: .rTextSecondary)
                            .frame(maxWidth: .infinity)
                            .aspectRatio(1, contentMode: .fit)
                            .background(Color.rSurface, in: RoundedRectangle(cornerRadius: RRadius.compact))
                            .accessibilityLabel("비울 후보 \(unit.removalCount - 6)장 더 있음")
                    }
                }
            }
        }
    }

    // MARK: - 추천 근거

    private var reasonSection: some View {
        VStack(alignment: .leading, spacing: RSpacing.xs) {
            Text("추천 근거")
                .rTextStyle(.caption, color: .rTextTertiary)

            VStack(alignment: .leading, spacing: RSpacing.xxs) {
                ForEach(unit.reasonCodes, id: \.rawValue) { code in
                    HStack(spacing: RSpacing.xs) {
                        Circle()
                            .fill(Color.rTextTertiary)
                            .frame(width: 4, height: 4)
                        Text(code.displayText)
                            .rTextStyle(.subLabel, color: .rTextSecondary)
                    }
                }
            }
        }
        .padding(RSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.rSurface)
        .cornerRadius(RRadius.md)
    }

    // MARK: - 안내 문구

    private var infoText: some View {
        HStack(spacing: RSpacing.xs) {
            Image(systemName: "info.circle")
                .font(.system(size: 13))
                .foregroundColor(.rTextTertiary)
            Text("사진 앱의 최근 삭제된 항목으로 이동해요.")
                .rTextStyle(.caption, color: .rTextTertiary)
        }
    }

    // MARK: - 버튼

    private var actionButtons: some View {
        VStack(spacing: RLayout.actionGap) {
            cancellationFeedback
            RButton(
                title: String(localized: "사진 \(unit.removalCount)장 비우기"),
                variant: .destructive,
                isLoading: deletion.isDeleting
            ) {
                Task { await performDeletion() }
            }

            RButton(title: String(localized: "취소"), variant: .secondary) {
                dismiss()
            }
            .disabled(deletion.isDeleting)
        }
    }

    // MARK: - 삭제 실행

    @ViewBuilder
    private var cancellationFeedback: some View {
        if !cancellationNotice.isEmpty {
            Text(cancellationNotice)
                .rTextStyle(.body, color: .rTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("deletion.cancelled")
        }
    }

    private func performDeletion() async {
        cancellationNotice = ""
        do {
            if try await deletion.delete(unit, onCompleted: { count in
                onCompleted(count)
                if returnsAfterSuccess { dismiss() }
                else { completedCount = count }
            }) == false {
                cancellationNotice = String(localized: "비우기를 취소했어요. 사진은 그대로예요.")
                UIAccessibility.post(notification: .announcement, argument: cancellationNotice)
            }
        } catch is CancellationError {
            cancellationNotice = String(localized: "비우기를 취소했어요. 사진은 그대로예요.")
        } catch {
            failureMessage = String(localized: "삭제 완료를 확인하지 못해 비운 수에 반영하지 않았어요. 사진 상태와 접근 권한을 확인한 뒤 다시 시도해주세요.")
            showFailure = true
        }
    }

}

// Completion is shown only after Photos confirms the transaction.
private struct PhotoDeletionResultView: View {
    let count: Int
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: RSpacing.xl) {
                    RSealIllustration(pose: .letGo, width: RCharacterSize.state)
                    Text("사진 \(count)장 비웠어요.")
                        .rTextStyle(.headlineLarge)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("deletion.success")
                    Text("사진 앱의 ‘최근 삭제된 항목’으로 이동했어요.")
                        .rTextStyle(.body, color: .rTextSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    PhotoRecoveryGuide()
                }
                .rScreenPadding()
            }
            RButton(title: String(localized: "홈으로 돌아가기"), variant: .primary, action: onContinue)
                .accessibilityIdentifier("deletion.continue")
                .padding(RLayout.screenInset)
        }
        .background(Color.rBackground)
    }
}

struct PhotoRecoveryGuide: View {
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: RSpacing.sm) {
                Text("사진 앱에서 ‘최근 삭제된 항목’을 열고, 사진을 선택한 뒤 ‘복구’를 눌러주세요.")
                Text("삭제 후 30일 안에 복구할 수 있어요. 그곳에서 영구 삭제한 사진은 복구할 수 없어요.")
                Text("리포트에는 리코코에서 비운 이력이 남아요.")
                    .rTextStyle(.caption, color: .rTextSecondary)
            }
            .rTextStyle(.body, color: .rTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, RSpacing.sm)
            .accessibilityIdentifier("deletion.recoverySteps")
        } label: {
            Text("마음이 바뀌었다면 · 복구 방법")
                .rTextStyle(.subLabel, color: .rAccent)
                .frame(minHeight: RSize.minTouchTarget)
        }
        .tint(.rAccent)
        .padding(RSpacing.md)
        .background(Color.rSurface)
        .clipShape(RoundedRectangle(cornerRadius: RRadius.md))
        .accessibilityIdentifier("deletion.recovery")
    }
}

// MARK: - S-06 대표 사진 선택
// 명세서 §8 S-06

struct PhotoSelectorView: View {
    let unit: DecisionUnit
    let onSelected: (DecisionUnit) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedIdentifier: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: RSpacing.xs), count: dynamicTypeSize.isAccessibilitySize ? 2 : 3)
    }

    var body: some View {
        ZStack {
            Color.rBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // 네비게이션
                RNavigationBar(
                    title: String(localized: "남길 사진 선택"),
                    leadingAction: { dismiss() }
                )

                RDivider()

                // 사진 그리드
                ScrollView {
                    LazyVGrid(columns: columns, spacing: RSpacing.xs) {
                        ForEach(unit.candidateLocalIdentifiers, id: \.self) { id in
                            photoCell(id)
                        }
                    }
                    .rScreenPadding()
                }
                RButton(title: String(localized: "선택 완료"), variant: .primary, isDisabled: selectedIdentifier == nil) {
                    var updated = unit
                    updated.selectedLocalIdentifier = selectedIdentifier
                    onSelected(updated)
                }
                .accessibilityIdentifier("photoSelection.confirm")
                .padding(RLayout.screenInset)

            }
        }
        .onAppear {
            selectedIdentifier = unit.recommendedLocalIdentifier
        }
    }

    private func photoCell(_ id: String) -> some View {
        let isSelected = selectedIdentifier == id
        let isRecommended = id == unit.recommendedLocalIdentifier

        return Button {
            withAnimation(reduceMotion ? nil : RMotion.feedback) {
                selectedIdentifier = id
            }
        } label: {
            ZStack(alignment: .topLeading) {
                PHAssetImageView(
                    localIdentifier: id,
                    targetSize: CGSize(width: 150, height: 150)
                )
                .aspectRatio(1, contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: RRadius.compact))
                .overlay(
                    RoundedRectangle(cornerRadius: RRadius.compact)
                        .strokeBorder(isSelected ? Color.rAccent : .clear, lineWidth: 2)
                )

                if isRecommended {
                    RBadge(text: String(localized: "추천"), variant: .detox)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .padding(RSpacing.xs)
                        .accessibilityHidden(true)
                }
                if isSelected {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: RSize.icon))
                                .foregroundColor(.rAccent)
                                .background(Circle().fill(Color.rBackground))
                                .padding(RSpacing.xs)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(RPressFeedbackStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("이 사진을 남길 대표 사진으로 선택해요.")
        .accessibilityLabel([
            String(localized: "사진 \(unit.candidateLocalIdentifiers.firstIndex(of: id).map { $0 + 1 } ?? 0)번"),
            isRecommended ? String(localized: "추천") : nil
        ].compactMap { $0 }.joined(separator: ", "))
    }
}

// MARK: - Preview

#if DEBUG
#Preview("정리 확인") {
    CleanupConfirmSheet(unit: .mockCluster) { _ in }
}

#Preview("사진 선택") {
    PhotoSelectorView(unit: .mockCluster) { _ in }
}
#endif
