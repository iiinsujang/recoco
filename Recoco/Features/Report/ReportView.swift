import SwiftUI
import UIKit
import PhotosUI
import CryptoKit

struct SavedRecordSection: Identifiable {
    let id: String
    let title: String
    var records: [SavedMemoryRecord]
}

enum SavedRecordBrowsing {
    // Group by the date the memory was saved, not the photo's capture date.
    static func sections(_ records: [SavedMemoryRecord], query: String,
                         now: Date = Date(), calendar: Calendar = .current) -> [SavedRecordSection] {
        func normalized(_ text: String) -> String {
            text.precomposedStringWithCanonicalMapping
                .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .autoupdatingCurrent)
        }
        let needle = normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let today = calendar.startOfDay(for: now)
        let recentStart = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        let matching = records.filter { needle.isEmpty || normalized($0.text).contains(needle) }
            .sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt }
        var result: [SavedRecordSection] = []
        for record in matching {
            let date = calendar.dateComponents([.year, .month], from: record.createdAt)
            let recent = record.createdAt >= recentStart && record.createdAt < tomorrow
            let key = recent ? "recent" : "\(date.year ?? 0)-\(date.month ?? 0)"
            let title = recent ? String(localized: "최근 7일") : record.createdAt.formatted(.dateTime.year().month(.wide))
            if let index = result.firstIndex(where: { $0.id == key }) {
                result[index].records.append(record)
            } else {
                result.append(SavedRecordSection(id: key, title: title, records: [record]))
            }
        }
        return result
    }
}

// MARK: - ReportViewModel
// 명세서 §8 S-09

struct WeeklyReportData {
    let weekKey: String              // 기기 날짜 기준 월–일 범위
    let completedDays: Int           // 완료한 날짜 수 (0~7)
    let deletedPhotoCount: Int       // 정리한 사진 수
    let savedRecordCount: Int        // 남긴 기록 수
    let dailyCounts: [Int]           // 요일별 정리 수 (월~일, 7개)

    var isEmpty: Bool {
        completedDays == 0 && deletedPhotoCount == 0 && savedRecordCount == 0
    }

    // 확보 공간은 MVP 미지원 (명세서 §8 S-09)
}

@MainActor
final class ReportViewModel: ObservableObject {
    @Published var reportData: WeeklyReportData? = nil
    @Published var cleanupDailyCounts: [Date: Int] = [:]
    @Published var monthlyDeletedPhotoCount = 0
    @Published var savedRecords: [SavedMemoryRecord] = []
    @Published var recordLoadFailed = false
    @Published var isLoading: Bool = true
    private var reportedDate: Date?

    func onAppear() async {
        isLoading = true
        defer { isLoading = false }

        let now = Date()
        let snapshot = LocalActivityStore.shared.weeklySnapshot(referenceDate: now)
        cleanupDailyCounts = LocalActivityStore.shared.cleanupDailyCounts(referenceDate: now)
        monthlyDeletedPhotoCount = LocalActivityStore.shared.monthlyDeletedPhotoCount(referenceDate: now)
        do {
            savedRecords = try SavedRecordStore.shared.readRecords()
            recordLoadFailed = false
        } catch {
            recordLoadFailed = true
        }
        reportedDate = now
        reportData = WeeklyReportData(
            weekKey: ReportingWeek.label(containing: now),
            completedDays: snapshot.completedDays,
            deletedPhotoCount: snapshot.deletedPhotoCount,
            savedRecordCount: snapshot.savedRecordCount,
            dailyCounts: zip(snapshot.dailyDeletedCounts, snapshot.dailySavedCounts).map { $0 + $1 }
        )
    }

    func refreshForDateChange() async {
        guard reportedDate.map({ !Calendar.current.isDate($0, inSameDayAs: Date()) }) ?? true else { return }
        await onAppear()
    }

}

// MARK: - S-09 주간 리포트 뷰
// 명세서 §8 S-09

struct ReportView: View {
    @StateObject private var vm = ReportViewModel()
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var showToast: Bool = false
    @State private var toastMessage: String = ""
    @State private var selectedRecord: SavedMemoryRecord?
    @State private var recordToDelete: SavedMemoryRecord?
    @Binding var showSavedRecords: Bool
    @State private var showCleanupPoll = false
    @AccessibilityFocusState private var pollEntryFocused: Bool
    @State private var showMemoryPicker = false
    @State private var selectedMemoryPhoto: PhotosPickerItem?
    // Present the photo and its identity atomically. Separate state can let the
    // first cover capture a stale image before its StateObject is initialized.
    private struct MemorySelection: Identifiable {
        let unit: DecisionUnit
        let image: UIImage
        var id: UUID { unit.id }
    }
    @State private var memorySelection: MemorySelection?
    @State private var openRecordsAfterMemory = false
    @State private var loadingMemory = false
    @State private var memoryRequest = UUID()
    @State private var recordQuery = ""
    @FocusState private var recordSearchFocused: Bool

    var body: some View {
        ZStack {
            Color.rBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // 헤더
                RWordmarkHeader()

                RDivider()

                if vm.isLoading {
                    Spacer()
                    VStack(spacing: RSpacing.sm) {
                        RLoadingIndicator()
                            .accessibilityHidden(true)
                        Text("리포트를 불러오고 있어요.")
                            .rTextStyle(.body, color: .rTextSecondary)
                    }
                    Spacer()
                } else if vm.reportData != nil {
                    cleanupReport
                } else {
                    emptyState
                }
            }
        }
        .task { await vm.onAppear() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { Task { await vm.onAppear() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            Task { await vm.onAppear() }
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            Task { await vm.refreshForDateChange() }
        }
        .fullScreenCover(isPresented: $showCleanupPoll, onDismiss: {
            pollEntryFocused = true
        }) {
            CleanupInterestPollView()
        }
        .fullScreenCover(isPresented: $showSavedRecords, onDismiss: {
            // The report stays mounted under the library. Refresh on return even
            // when the date and scene phase have not changed.
            Task { await vm.onAppear() }
        }) { savedRecordsBrowser }
        .photosPicker(isPresented: $showMemoryPicker, selection: $selectedMemoryPhoto, matching: .images)
        .onChange(of: selectedMemoryPhoto) { item in
            guard let item else { return }
            Task { await prepareMemory(item) }
        }
        .fullScreenCover(item: $memorySelection, onDismiss: {
            Task {
                await vm.onAppear()
                guard openRecordsAfterMemory else { return }
                openRecordsAfterMemory = false
                recordQuery = ""
                selectedRecord = nil
                showSavedRecords = true
            }
        }) { selection in
            RecordView(unit: selection.unit, selectedImage: selection.image, onOpenRecords: {
                openRecordsAfterMemory = true
            }) { record in
                LocalActivityStore.shared.recordIndependentMemory(recordID: record.id)
            }
        }
        .rToast(isPresented: $showToast, message: toastMessage)
    }

    private var cleanupReport: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RSpacing.lg + 2) {
                cleanupSummary
                CleanupCalendarView(dailyCounts: vm.cleanupDailyCounts)
                cleanupPollEntry
            }
            .padding(.horizontal, RLayout.screenInset)
            .padding(.top, RSpacing.sm)
            .padding(.bottom, RLayout.contentInset)
        }
        .accessibilityIdentifier("report.scroll")
    }

    private var cleanupPollEntry: some View {
        Button {
            showCleanupPoll = true
        } label: {
            HStack(spacing: RSpacing.xs) {
                Text("다른 것도 정리하기")
                    .font(.rSubLabel.weight(.semibold))
                    .foregroundStyle(Color.rAccent)
                Spacer(minLength: RSpacing.xs)
                Text("투표")
                    .rTextStyle(.caption, color: .rTextSecondary)
                Image(systemName: "chevron.right")
                    .font(.rCaption)
                    .foregroundStyle(Color.rTextSecondary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: RSize.minTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(RPressFeedbackStyle())
        .accessibilityLabel("다른 것도 정리하기, 투표")
        .accessibilityHint("다음에 정리하고 싶은 항목을 고를 수 있어요.")
        .accessibilityFocused($pollEntryFocused)
        .accessibilityIdentifier("report.cleanupPoll")
    }

    private var savedRecordsBrowser: some View {
        VStack(spacing: 0) {
            RNavigationBar(title: String(localized: "남긴 기록"), leadingAction: {
                if selectedRecord != nil { selectedRecord = nil }
                else { showSavedRecords = false }
            })
            RDivider()
            // Keep the list mounted underneath the detail so its exact scroll
            // position and search survive opening and closing a record.
            ZStack {
                savedRecordList
                    .opacity(selectedRecord == nil ? 1 : 0)
                    .allowsHitTesting(selectedRecord == nil)
                    .accessibilityHidden(selectedRecord != nil)
                if let record = selectedRecord {
                    ScrollView { recordDetail(record) }
                        .id(record.id).background(Color.rBackground)
                }
            }
        }
        .background(Color.rBackground)
        .alert("이 기록을 삭제할까요?", isPresented: Binding(get: { recordToDelete != nil }, set: { if !$0 { recordToDelete = nil } }), presenting: recordToDelete) { record in
            Button("기록 삭제", role: .destructive) {
                do {
                    try SavedRecordStore.shared.delete(id: record.id)
                    recordToDelete = nil
                    if selectedRecord?.id == record.id { selectedRecord = nil }
                    toastMessage = String(localized: "기록을 삭제했어요. 원본 사진은 그대로예요.")
                    Task { await vm.onAppear() }
                } catch {
                    toastMessage = String(localized: "기록을 삭제하지 못했어요. 잠시 후 다시 시도해주세요.")
                }
                showToast = true
            }
            Button("취소", role: .cancel) { recordToDelete = nil }
        } message: { _ in Text("사진첩의 원본 사진은 그대로 남아요. 삭제한 기록은 되돌릴 수 없어요.") }
        .rToast(isPresented: $showToast, message: toastMessage)
    }

    private var savedRecordList: some View {
        let sections = SavedRecordBrowsing.sections(vm.savedRecords, query: recordQuery)
        let count = sections.reduce(0) { $0 + $1.records.count }
        let searching = !recordQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(spacing: 0) {
            if !vm.savedRecords.isEmpty {
                HStack(spacing: RSpacing.sm) {
                    Image(systemName: "magnifyingglass").foregroundColor(.rTextSecondary)
                    TextField("기록한 글에서 찾기", text: $recordQuery)
                        .rTextStyle(.body)
                        .accessibilityIdentifier("records.search")
                        .focused($recordSearchFocused)
                        .submitLabel(.search)
                        .onSubmit { recordSearchFocused = false }
                        .autocorrectionDisabled()
                    if !recordQuery.isEmpty {
                        Button { recordQuery = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.rTextSecondary)
                                .frame(width: RSize.minTouchTarget, height: RSize.minTouchTarget)
                        }.accessibilityLabel("검색어 지우기")
                    }
                }
                .padding(.leading, RSpacing.md)
                .frame(minHeight: RSize.minTouchTarget)
                .background(Color.rSurface)
                .clipShape(RoundedRectangle(cornerRadius: RRadius.md))
                .padding(.horizontal, RSpacing.lg)
                .padding(.top, RSpacing.md)
                .padding(.bottom, RSpacing.sm)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: RSpacing.lg) {
                        Text(searching ? String(localized: "검색 결과 \(count)개 · 전체 \(vm.savedRecords.count)개") : String(localized: "남긴 기록 \(vm.savedRecords.count)개"))
                            .rTextStyle(.subLabel, color: .rTextSecondary)
                            .accessibilityIdentifier("records.count")
                            .id("records.top")
                        if vm.savedRecords.isEmpty {
                            Text("아직 남긴 기록이 없어요. 사진에 떠오르는 말을 한 줄 남겨보세요.")
                                .rTextStyle(.body, color: .rTextSecondary)
                        } else if count == 0 {
                            VStack(alignment: .leading, spacing: RSpacing.sm) {
                                Text("일치하는 기록이 없어요.").rTextStyle(.subLabel)
                                Text("기록에 적었던 다른 단어로 찾아보세요. 저장한 기록은 그대로 있어요.")
                                    .rTextStyle(.body, color: .rTextSecondary)
                                RButton(title: String(localized: "전체 기록 보기"), variant: .secondary) {
                                    recordQuery = ""; recordSearchFocused = false
                                }
                            }
                        }
                        ForEach(sections) { section in
                            Section {
                                ForEach(section.records) { record in savedRecordCard(record) }
                            } header: {
                                Text(section.title).rTextStyle(.subLabel, color: .rTextSecondary)
                                    .accessibilityAddTraits(.isHeader)
                            }
                        }
                    }.rScreenPadding()
                }
                .accessibilityIdentifier("records.list")
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: recordQuery) { _ in proxy.scrollTo("records.top", anchor: .top) }
            }
        }
    }

    private func recordDetail(_ record: SavedMemoryRecord) -> some View {
        VStack(alignment: .leading, spacing: RSpacing.lg) {
            SavedRecordPhoto(record: record, detail: true)
                .frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: RRadius.lg))
                .accessibilityIdentifier("records.detailPhoto")
            Text(record.createdAt.formatted(date: .abbreviated, time: .omitted))
                .rTextStyle(.caption, color: .rTextSecondary)
            Text(record.text).rTextStyle(.body).textSelection(.enabled)
                .accessibilityIdentifier("records.detailText")
            VStack(spacing: RSpacing.md) {
                RActionPair {
                    RButton(title: String(localized: "복사하기"), variant: .secondary) { copyRecord(record) }
                } primary: {
                    ShareLink(item: record.text) {
                        Text("공유하기").rButtonSurface(.primary)
                    }.buttonStyle(RPressFeedbackStyle())
                }
                Button("기록 삭제") { recordToDelete = record }
                    .font(.rSubLabel)
                    .foregroundColor(.rTextSecondary)
                    .padding(.horizontal, RSpacing.lg)
                    .frame(minHeight: RSize.minTouchTarget)
                    .frame(maxWidth: .infinity)
            }.padding(.top, RSpacing.sm)
        }.rScreenPadding()
    }


    // The current release reports cleanup only. Legacy records remain stored and
    // their browser stays available to existing navigation without a new creation CTA.
    private var cleanupSummary: some View {
        HStack(alignment: .top, spacing: RSpacing.xs + 2) {
            cleanupMetric(
                title: String(localized: "지금까지 비운 사진"),
                count: vm.cleanupDailyCounts.values.reduce(0, +),
                titleIdentifier: "report.totalTitle",
                countIdentifier: "report.totalDeletedCount"
            )
            cleanupMetric(
                title: String(localized: "이번 달 비운 사진"),
                count: vm.monthlyDeletedPhotoCount,
                titleIdentifier: "report.monthlyTitle",
                countIdentifier: "report.deletedCount"
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func cleanupMetric(title: String, count: Int,
                               titleIdentifier: String, countIdentifier: String) -> some View {
        VStack(alignment: .leading, spacing: RSpacing.xs) {
            Text(title)
                .font(RTypography.font(size: 13, weight: .medium, relativeTo: .subheadline))
                .foregroundColor(.rTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(titleIdentifier)
            Text(styledPhotoCount(count))
                .foregroundColor(.rTextPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .accessibilityLabel("\(count)장")
                .accessibilityIdentifier(countIdentifier)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(RSpacing.sm + 2)
        .background(Color.rSurface, in: RoundedRectangle(cornerRadius: RRadius.lg))
    }

    private func styledPhotoCount(_ count: Int) -> AttributedString {
        var label = AttributedString(localized: "\(count)장", options: .applyReplacementIndexAttribute)
        label.font = RTypography.font(size: 18, weight: .medium, relativeTo: .title2)
        for run in label.runs where run.replacementIndex != nil {
            label[run.range].font = RTypography.font(size: 40, weight: .semibold, relativeTo: .largeTitle)
        }
        return label
    }

    private func chartCard(data: WeeklyReportData) -> some View {
        RCard {
            VStack(alignment: .leading, spacing: RSpacing.sm) {
                Text("요일별 비움·기록 활동")
                    .rTextStyle(.caption, color: .rTextTertiary)
                WeeklyBarChart(dailyCounts: data.dailyCounts)
                    .frame(height: 112)
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { index in
                        Text(Calendar.current.shortStandaloneWeekdaySymbols[(index + 1) % 7]).rTextStyle(.caption, color: .rTextTertiary)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .accessibilityIdentifier("report.weeklyActivity")
    }

    // MARK: - 요약 카드 2열

    private func summaryCards(data: WeeklyReportData) -> some View {
        HStack(spacing: RSpacing.sm) {
            summaryCard(
                label: String(localized: "이번 주 비운 사진"),
                value: String(localized: "\(data.deletedPhotoCount)장"),
                identifier: "report.deletedCount"
            )
            summaryCard(
                label: String(localized: "이번 주 저장한 기록"),
                value: String(localized: "\(data.savedRecordCount)개"),
                identifier: "report.savedCount"
            )
        }
    }

    private func summaryCard(label: String, value: String, identifier: String) -> some View {
        RCard(showsBorder: false) {
            VStack(alignment: .leading, spacing: RSpacing.xxs) {
                Text(label)
                    .rTextStyle(.caption, color: .rTextSecondary)

                Text(value)
                    .rTextStyle(.headline)
                    .accessibilityIdentifier(identifier)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var savedRecordsSection: some View {
        RCard {
            VStack(spacing: RSpacing.lg) {
                Button {
                    selectedRecord = nil
                    showSavedRecords = true
                } label: {
                    let layout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: RSpacing.md))
                        : AnyLayout(HStackLayout(spacing: RSpacing.md))
                    layout {
                        VStack(alignment: .leading, spacing: RSpacing.xs) {
                            Text("보관 중인 전체 기록").rTextStyle(.caption, color: .rTextSecondary)
                            (Text("\(vm.savedRecords.count)").font(RTypography.font(size: 30, weight: .semibold, relativeTo: .title1))
                             + Text(" 개").font(.rBody)).foregroundColor(.rTextPrimary)
                        }
                        if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: RSpacing.sm) }
                        HStack(spacing: RSpacing.xs) {
                            Text("기록 모아보기").rTextStyle(.subLabel, color: .rTextSecondary)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .medium)).foregroundColor(.rTextSecondary)
                        }
                    }.frame(minHeight: RSize.minTouchTarget)
                        .contentShape(Rectangle())
                }.buttonStyle(RPressFeedbackStyle())
                    .accessibilityIdentifier("report.openRecords")
                RButton(title: String(localized: "다른 사진으로 기록하기"), variant: .primary,
                        isLoading: loadingMemory, isDisabled: loadingMemory,
                        font: RTypography.font(size: 15, weight: .semibold)) {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-ui-testing"),
                       ProcessInfo.processInfo.arguments.contains("-ui-testing-report-record"),
                       let image = UIImage(named: "recoco_sample_portrait") {
                        let unit = DecisionUnit(id: UUID(), type: .recallMoment, status: .pending,
                            candidateLocalIdentifiers: ["design-report-record"],
                            recommendedLocalIdentifier: "design-report-record", reasonCodes: [],
                            capturedDateDescription: nil, createdAt: Date())
                        memorySelection = MemorySelection(unit: unit, image: image)
                        return
                    }
                    #endif
                    selectedMemoryPhoto = nil
                    showMemoryPicker = true
                }.accessibilityIdentifier("report.newRecord")
            }
        }
    }

    @MainActor
    private func prepareMemory(_ item: PhotosPickerItem) async {
        let request = UUID()
        memoryRequest = request
        loadingMemory = true
        defer { if memoryRequest == request { loadingMemory = false } }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
            guard memoryRequest == request else { return }
            let identifier = item.itemIdentifier
            // Match Home's draft identity so moving between entry points keeps the same draft.
            let digest = Array(SHA256.hash(data: data).prefix(16))
            let draftID = UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7], digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
            let unit = DecisionUnit(id: draftID, type: .recallMoment, status: .pending,
                candidateLocalIdentifiers: identifier.map { [$0] } ?? [], recommendedLocalIdentifier: identifier,
                reasonCodes: [], capturedDateDescription: nil, createdAt: Date())
            memorySelection = MemorySelection(unit: unit, image: image)
        } catch {
            guard memoryRequest == request else { return }
            toastMessage = String(localized: "사진을 가져오지 못했어요. 다른 사진을 고르거나 다시 시도해주세요.")
            showToast = true
        }
    }

    private func savedRecordCard(_ record: SavedMemoryRecord) -> some View {
        RCard(showsBorder: false) {
            HStack(alignment: .top, spacing: RSpacing.sm) {
                Button { recordSearchFocused = false; selectedRecord = record } label: {
                    HStack(alignment: .top, spacing: RSpacing.md) {
                        SavedRecordPhoto(record: record)
                            .frame(width: 80, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: RRadius.md))
                        VStack(alignment: .leading, spacing: RSpacing.xs) {
                            Text(record.createdAt.formatted(date: .abbreviated, time: .omitted))
                                .rTextStyle(.caption, color: .rTextSecondary)
                            Text(record.text).rTextStyle(.body).lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(record.text), 기록 자세히 보기")
                .accessibilityIdentifier("records.row.\(record.id.uuidString)")
                Menu {
                    ShareLink(item: record.text) { Label("공유하기", systemImage: "square.and.arrow.up") }
                    Button { copyRecord(record) } label: { Label("복사하기", systemImage: "doc.on.doc") }
                    Button(role: .destructive) { recordToDelete = record } label: { Label("기록 삭제", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                        .foregroundColor(.rTextSecondary)
                }
                .accessibilityLabel("기록 메뉴")
            }
        }
    }

    private func copyRecord(_ record: SavedMemoryRecord) {
        UIPasteboard.general.string = record.text
        toastMessage = String(localized: "복사되었어요.")
        showToast = true
    }

    private var countingRules: some View {
        DisclosureGroup("집계 기준") {
            VStack(alignment: .leading, spacing: RSpacing.sm) {
                Text("기기 날짜 기준 월요일부터 일요일까지예요. 사진 1장 비우기와 기록 1개 저장을 각각 1건으로 세어요. 그대로 두기·복사·공유는 그래프에 더하지 않아요.")
                Text("기록을 삭제해도 저장 활동은 남아요. 보관 중인 전체 기록은 현재 남아 있는 기록 수예요.")
                Text("비운 사진은 앱에서 삭제 완료를 확인한 수예요. 확보한 저장 공간이나 최근 삭제된 항목에서의 영구 삭제를 뜻하지 않아요.")
            }.rTextStyle(.caption, color: .rTextSecondary).padding(.top, RSpacing.sm)
        }
        .rTextStyle(.subLabel, color: .rTextSecondary)
        .frame(minHeight: RSize.minTouchTarget)
        .accessibilityIdentifier("report.countingRules")
    }

    // MARK: - 빈 상태

    private var emptyState: some View {
        REmptyState(
            title: String(localized: "아직 기록이 없어요."),
            message: String(localized: "홈에서 오늘의 사진을\n정리해보세요."),
            pose: .daydream
        )
    }
}

private struct SavedRecordPhoto: View {
    let record: SavedMemoryRecord
    var detail = false

    var body: some View {
        Group {
            if let identifier = record.photoLocalIdentifier {
                PHAssetImageView(localIdentifier: identifier, targetSize: CGSize(width: 800, height: 800),
                                 scalesToFit: detail, unavailableMessage: String(localized: "사진을 불러올 수 없어요"),
                                 fallbackImage: record.photoThumbnailData.flatMap { UIImage(data: $0) })
            } else if let data = record.photoThumbnailData, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                VStack(spacing: RSpacing.xs) {
                    Image(systemName: "photo")
                    Text("연결된 사진이 없어요").font(.caption2).multilineTextAlignment(.center)
                }.padding(RSpacing.xs).foregroundColor(.rTextTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.rSurface)
            }
        }.accessibilityLabel("기록한 사진")
    }
}

// MARK: - 주간 바 차트

struct WeeklyBarChart: View {
    let dailyCounts: [Int]

    private var maxCount: Int {
        dailyCounts.max() ?? 1
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: RSpacing.xs) {
            ForEach(Array(dailyCounts.enumerated()), id: \.offset) { index, count in
                VStack(spacing: RSpacing.xxs) {
                    Spacer()
                    Text("\(count)").rTextStyle(.caption, color: .rTextSecondary)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(count > 0 ? Color.rTextPrimary : Color.rBorder)
                        .frame(
                            height: count > 0 && maxCount > 0
                                ? CGFloat(count) / CGFloat(maxCount) * 50
                                : 2
                        )
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(Calendar.current.standaloneWeekdaySymbols[(index + 1) % 7]) \(count)건")
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    ReportView(showSavedRecords: .constant(false))
}
#endif

// MARK: - Cleanup-only report calendar

/// Sunday-first month layout matching the web report. Dates are calculated with
/// the device calendar so DST and month/year boundaries never create fake days.
enum CleanupCalendarLayout {
    static func monthStart(containing date: Date, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    static func days(in month: Date, calendar: Calendar = .current) -> [Date?] {
        let start = monthStart(containing: month, calendar: calendar)
        guard let range = calendar.range(of: .day, in: .month, for: start) else { return [] }
        let leading = calendar.component(.weekday, from: start) - 1
        var cells = Array<Date?>(repeating: nil, count: leading)
        cells += range.map { calendar.date(byAdding: .day, value: $0 - 1, to: start) }
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }
}

/// Measure the laid-out card in the actual scroll view, rather than consuming a
/// SwiftUI preference before ScrollViewReader has registered its destination.
private struct CleanupCalendarResultReveal: UIViewRepresentable {
    let request: UUID?
    let animated: Bool

    func makeUIView(context: Context) -> CalendarResultRevealView {
        CalendarResultRevealView()
    }

    func updateUIView(_ uiView: CalendarResultRevealView, context: Context) {
        uiView.requestReveal(request, animated: animated)
    }
}

enum CalendarRevealDiagnostics {
    static func record(_ event: String, _ values: [String: String] = [:]) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-calendar-reveal-diagnostics") else { return }
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("recoco-calendar-reveal-diagnostics.json")
        var entries = (try? Data(contentsOf: url)).flatMap {
            try? JSONDecoder().decode([[String: String]].self, from: $0)
        } ?? []
        var entry = values
        entry["event"] = event
        entry["time"] = String(Date().timeIntervalSince1970)
        entry["build"] = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        entries.append(entry)
        if let data = try? JSONEncoder().encode(Array(entries.suffix(60))) {
            try? data.write(to: url, options: .atomic)
        }
        #endif
    }
}

final class CalendarResultRevealView: UIView {
    private var pendingRequest: UUID?
    private var handledRequest: UUID?
    private var animated = false
    private var revealScheduled = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { nil }

    func requestReveal(_ request: UUID?, animated: Bool) {
        self.animated = animated
        pendingRequest = request == handledRequest ? nil : request
        CalendarRevealDiagnostics.record("update", ["request": request?.uuidString ?? "nil", "pending": String(pendingRequest != nil), "animated": String(animated), "window": String(window != nil), "bounds": String(describing: bounds)])
        scheduleReveal()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        scheduleReveal()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scheduleReveal()
    }

    private func scheduleReveal() {
        guard pendingRequest != nil, !revealScheduled else { return }
        revealScheduled = true
        // Finish SwiftUI's current update/layout before moving the scroll view.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.revealIfReady()
            self.revealScheduled = false
        }
    }

    private func revealIfReady() {
        guard let request = pendingRequest else { return }
        guard window != nil else {
            CalendarRevealDiagnostics.record("waitWindow")
            return
        }
        var ancestor = superview
        while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
        guard let scroll = ancestor as? UIScrollView else {
            CalendarRevealDiagnostics.record("noScrollAncestor")
            return
        }
        scroll.layoutIfNeeded()
        guard bounds.height > 0, scroll.bounds.height > 0, scroll.contentSize.height > 0 else {
            CalendarRevealDiagnostics.record("waitLayout", ["bounds": String(describing: bounds), "scroll": String(describing: scroll.bounds), "content": String(describing: scroll.contentSize)])
            return
        }

        let rect = convert(bounds, to: scroll)
        let inset = scroll.adjustedContentInset
        let visibleTop = scroll.contentOffset.y + inset.top
        let visibleBottom = scroll.contentOffset.y + scroll.bounds.height - inset.bottom
        CalendarRevealDiagnostics.record("measured", ["rect": String(describing: rect), "scroll": String(describing: scroll.bounds), "windowRect": String(describing: convert(bounds, to: window)), "scrollWindowRect": String(describing: scroll.convert(scroll.bounds, to: window)), "content": String(describing: scroll.contentSize), "inset": String(describing: inset), "tracking": String(scroll.isTracking), "dragging": String(scroll.isDragging), "reduceMotion": String(UIAccessibility.isReduceMotionEnabled)])
        guard visibleBottom > visibleTop else { return }

        let delta: CGFloat
        if rect.height > visibleBottom - visibleTop || rect.minY < visibleTop {
            delta = rect.minY - visibleTop
        } else if rect.maxY > visibleBottom {
            delta = rect.maxY - visibleBottom
        } else {
            delta = 0
        }
        // Consume only after a valid layout. Further scrolling is the user's;
        // it must not snap back until another date is tapped (even the same day).
        handledRequest = request
        pendingRequest = nil
        guard abs(delta) > 0.5 else {
            CalendarRevealDiagnostics.record("alreadyVisible")
            return
        }
        let minY = -inset.top
        let maxY = max(minY, scroll.contentSize.height - scroll.bounds.height + inset.bottom)
        let y = min(maxY, max(minY, scroll.contentOffset.y + delta))
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y),
                                animated: animated && !UIAccessibility.isReduceMotionEnabled)
        CalendarRevealDiagnostics.record("scrollRequested", ["targetY": String(describing: y), "offset": String(describing: scroll.contentOffset)])
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-calendar-reveal-diagnostics") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self, weak scroll] in
                guard let self, let scroll else { return }
                CalendarRevealDiagnostics.record("settled", ["offset": String(describing: scroll.contentOffset), "windowRect": String(describing: self.convert(self.bounds, to: self.window)), "tracking": String(scroll.isTracking)])
            }
        }
        #endif
    }
}

private struct CleanupCalendarView: View {
    let dailyCounts: [Date: Int]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption) private var minimumCellWidth: CGFloat = 44
    @ScaledMetric(relativeTo: .caption) private var cellHeight: CGFloat = 60
    @State private var month = CleanupCalendarLayout.monthStart(containing: Date())
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    @State private var revealRequest: UUID?
    private let calendar = Calendar.current

    private var today: Date { calendar.startOfDay(for: Date()) }
    private var cells: [Date?] { CleanupCalendarLayout.days(in: month, calendar: calendar) }
    private var monthEvents: [Date: Int] {
        dailyCounts.filter { calendar.isDate($0.key, equalTo: month, toGranularity: .month) && $0.value > 0 }
    }
    private var monthTotal: Int { monthEvents.values.reduce(0, +) }
    private var canAdvance: Bool {
        month < CleanupCalendarLayout.monthStart(containing: today, calendar: calendar)
    }
    private func count(on date: Date) -> Int { max(0, dailyCounts[calendar.startOfDay(for: date)] ?? 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: RSpacing.sm) {
            VStack(alignment: .leading, spacing: RSpacing.xxs) {
                Text("비움 캘린더").rTextStyle(.section)
                    .accessibilityAddTraits(.isHeader)
                Text("비운 날을 누르면 사진 수를 볼 수 있어요.")
                    .rTextStyle(.caption, color: .rTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                monthButton(direction: -1)
                Spacer(minLength: RSpacing.xs)
                Text(monthLabel(month))
                    .font(RTypography.font(size: 19, weight: .semibold, relativeTo: .headline))
                    .foregroundStyle(Color.rTextPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("report.calendar.month")
                Spacer(minLength: RSpacing.xs)
                monthButton(direction: 1)
            }
            // At larger text sizes, retain readable dates and 44pt targets by
            // scrolling this grid horizontally instead of shrinking every cell.
            GeometryReader { geometry in
                let width = max(minimumCellWidth, geometry.size.width / 7)
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(spacing: RSpacing.xs) {
                        HStack(spacing: 0) {
                            ForEach(Array(calendar.shortStandaloneWeekdaySymbols.enumerated()), id: \.offset) { _, day in
                                Text(day).rTextStyle(.caption, color: .rTextSecondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                    .frame(width: width)
                            }
                        }.accessibilityHidden(true)
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: 0), count: 7), spacing: RSpacing.xs) {
                            ForEach(Array(cells.enumerated()), id: \.offset) { _, date in
                                if let date { dayButton(date, width: width) }
                                else { Color.clear.frame(width: width, height: cellHeight).accessibilityHidden(true) }
                            }
                        }
                    }
                    .frame(width: width * 7)
                }
            }
            .frame(height: CGFloat(cells.count / 7) * (cellHeight + RSpacing.xs) + minimumCellWidth * 0.65)
            .padding(.horizontal, -RLayout.screenInset + 6)
            .accessibilityIdentifier("report.cleanupCalendar")

            if month != CleanupCalendarLayout.monthStart(containing: today, calendar: calendar) {
                RDivider()
                    .padding(.top, RSpacing.sm)
                Text(monthTotal == 0
                     ? String(localized: "이 달에 비운 사진은 0장이에요.")
                     : String(localized: "\(monthEvents.count)일 동안 사진 \(monthTotal)장을 비웠어요."))
                    .rTextStyle(.subLabel, color: .rTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, RSpacing.md)
                    .accessibilityIdentifier("report.calendar.monthSummary")
            }
            HStack(spacing: RSpacing.sm) {
                ReportSealStamp(width: 32, showsHeartWhiskers: count(on: selectedDay) > 0)
                    .opacity(count(on: selectedDay) > 0 ? 1 : 0.25)
                    .accessibilityHidden(true)
                Text(daySummary)
                    .rTextStyle(.subLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(RSpacing.md)
            .frame(minHeight: 64, alignment: .leading)
            .background(Color.rSurface, in: RoundedRectangle(cornerRadius: RRadius.md))
            .background(CleanupCalendarResultReveal(request: revealRequest, animated: !reduceMotion))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("report.calendar.daySummary")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("report.calendar")
        .onChange(of: today) { newToday in
            // The selected date must never become a future date after a clock change.
            if selectedDay > newToday { selectedDay = newToday }
            let currentMonth = CleanupCalendarLayout.monthStart(containing: newToday, calendar: calendar)
            if month > currentMonth { month = currentMonth }
        }
    }

    private var daySummary: String {
        let label = selectedDay.formatted(.dateTime.month(.wide).day())
        let count = count(on: selectedDay)
        return count > 0 ? String(localized: "\(label) · 사진 \(count)장 비웠어요.") : String(localized: "\(label) · 비운 사진이 없어요.")
    }

    private func dayButton(_ date: Date, width: CGFloat) -> some View {
        let selected = calendar.isDate(date, inSameDayAs: selectedDay)
        let future = date > today
        let count = count(on: date)
        return Button {
            selectedDay = date
            revealRequest = UUID()
            CalendarRevealDiagnostics.record("dayTapped", ["request": revealRequest!.uuidString])
        } label: {
            VStack(spacing: 4) {
                Text("\(calendar.component(.day, from: date))")
                    .rTextStyle(.subLabel, color: future ? .rTextDisabled : .rTextPrimary)
                ReportSealStamp(width: 36, showsHeartWhiskers: count > 0)
                    .saturation(count > 0 ? 1 : 0)
                    .opacity(future ? 0.12 : (count > 0 ? 1 : 0.25))
            }
            .frame(width: width, height: cellHeight)
            .overlay(alignment: .bottom) {
                if selected {
                    Capsule().fill(Color.rAccent).frame(width: 18, height: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(future)
        .accessibilityLabel(future ? String(localized: "\(dateLabel(date)), 아직 오지 않은 날") : String(localized: "\(dateLabel(date)), 사진 \(count)장 비움"))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("report.calendar.day.\(String(format: "%04d-%02d-%02d", calendar.component(.year, from: date), calendar.component(.month, from: date), calendar.component(.day, from: date)))")
    }

    private func monthButton(direction: Int) -> some View {
        Button {
            guard let next = calendar.date(byAdding: .month, value: direction, to: month) else { return }
            revealRequest = nil
            month = CleanupCalendarLayout.monthStart(containing: next, calendar: calendar)
            selectedDay = calendar.isDate(month, equalTo: today, toGranularity: .month) ? today : month
        } label: {
            Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(direction > 0 && !canAdvance ? .rTextDisabled : .rTextPrimary)
                .frame(width: RSize.minTouchTarget, height: RSize.minTouchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(direction > 0 && !canAdvance)
        .accessibilityLabel(direction < 0 ? String(localized: "이전 달") : String(localized: "다음 달"))
        .accessibilityIdentifier(direction < 0 ? "report.calendar.previousMonth" : "report.calendar.nextMonth")
    }

    private func monthLabel(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.wide))
    }

    private func dateLabel(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.wide).day())
    }
}

/// Completed days reuse the approved choose pose: its two upper whiskers form
/// one large heart above the face. Keep the original pixels and close only the
/// neck opening; an inset canvas preserves the heart tips at calendar size.
private struct ReportSealStamp: View {
    var width: CGFloat
    var showsHeartWhiskers = false

    var body: some View {
        Canvas { context, size in
            if showsHeartWhiskers {
                drawChooseFace(in: &context, size: size)
                return
            }
            context.scaleBy(x: size.width / 660, y: size.width / 660)
            context.translateBy(x: -220, y: -250)
            var chin = Path()
            chin.move(to: CGPoint(x: 360, y: 650))
            chin.addCurve(to: CGPoint(x: 577, y: 758), control1: CGPoint(x: 397, y: 740), control2: CGPoint(x: 495, y: 772))
            chin.addCurve(to: CGPoint(x: 788, y: 600), control1: CGPoint(x: 684, y: 755), control2: CGPoint(x: 760, y: 703))
            var fill = chin
            fill.addLine(to: CGPoint(x: 760, y: 580))
            fill.addLine(to: CGPoint(x: 340, y: 630))
            fill.closeSubpath()
            context.fill(fill, with: .color(.white))
            var mask = Path()
            mask.move(to: CGPoint(x: 250, y: 280))
            mask.addLine(to: CGPoint(x: 817, y: 280))
            mask.addLine(to: CGPoint(x: 817, y: 530))
            mask.addLine(to: CGPoint(x: 793, y: 600))
            mask.addCurve(to: CGPoint(x: 755, y: 691), control1: CGPoint(x: 785, y: 640), control2: CGPoint(x: 772, y: 670))
            mask.addLine(to: CGPoint(x: 400, y: 691))
            mask.addLine(to: CGPoint(x: 400, y: 650))
            mask.addLine(to: CGPoint(x: 250, y: 650))
            mask.closeSubpath()
            var face = context
            face.clip(to: mask)
            face.draw(Image("recoco_moment_neutral"), in: CGRect(x: 0, y: 0, width: 1448, height: 1086))
            context.stroke(chin, with: .color(Color(hex: "111111")), style: StrokeStyle(lineWidth: 14, lineCap: .round, lineJoin: .round))
        }
        .frame(width: width, height: width * (showsHeartWhiskers ? 650 / 690 : 580 / 660))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func drawChooseFace(in context: inout GraphicsContext, size: CGSize) {
        context.scaleBy(x: size.width / 690, y: size.width / 690)
        context.translateBy(x: -370, y: -110)
        var chin = Path()
        chin.move(to: CGPoint(x: 602, y: 671))
        chin.addCurve(to: CGPoint(x: 809, y: 693), control1: CGPoint(x: 645, y: 719), control2: CGPoint(x: 738, y: 737))
        chin.addCurve(to: CGPoint(x: 888, y: 579), control1: CGPoint(x: 850, y: 668), control2: CGPoint(x: 877, y: 625))
        var fill = chin
        fill.addLine(to: CGPoint(x: 860, y: 552))
        fill.addLine(to: CGPoint(x: 558, y: 638))
        fill.closeSubpath()
        context.fill(fill, with: .color(.white))

        var mask = Path()
        mask.move(to: CGPoint(x: 375, y: 125))
        mask.addLine(to: CGPoint(x: 1035, y: 125))
        mask.addLine(to: CGPoint(x: 1035, y: 565))
        mask.addLine(to: CGPoint(x: 896, y: 565))
        mask.addLine(to: CGPoint(x: 888, y: 579))
        mask.addCurve(to: CGPoint(x: 809, y: 693), control1: CGPoint(x: 877, y: 625), control2: CGPoint(x: 850, y: 668))
        mask.addCurve(to: CGPoint(x: 602, y: 671), control1: CGPoint(x: 738, y: 737), control2: CGPoint(x: 645, y: 719))
        mask.addLine(to: CGPoint(x: 564, y: 648))
        mask.addLine(to: CGPoint(x: 548, y: 620))
        mask.addLine(to: CGPoint(x: 450, y: 620))
        mask.addLine(to: CGPoint(x: 375, y: 620))
        mask.closeSubpath()
        // Preserve the lower whiskers without including the adjoining body.
        mask.move(to: CGPoint(x: 835, y: 594))
        mask.addLine(to: CGPoint(x: 934, y: 601))
        mask.addLine(to: CGPoint(x: 934, y: 618))
        mask.addLine(to: CGPoint(x: 835, y: 612))
        mask.closeSubpath()
        mask.move(to: CGPoint(x: 487, y: 655))
        mask.addLine(to: CGPoint(x: 589, y: 606))
        mask.addLine(to: CGPoint(x: 597, y: 621))
        mask.addLine(to: CGPoint(x: 497, y: 674))
        mask.closeSubpath()
        var face = context
        face.clip(to: mask)
        face.draw(Image("recoco_moment_choose"), in: CGRect(x: 0, y: 0, width: 1448, height: 1086))
        context.stroke(chin, with: .color(Color(hex: "111111")),
                       style: StrokeStyle(lineWidth: 14, lineCap: .round, lineJoin: .round))
    }
}
