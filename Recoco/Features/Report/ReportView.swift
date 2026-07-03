import SwiftUI

// MARK: - ReportViewModel
// 명세서 §8 S-09

struct WeeklyReportData {
    let weekKey: String              // "2026-W26" 형태
    let completedDays: Int           // 완료한 날짜 수 (0~7)
    let deletedPhotoCount: Int       // 정리한 사진 수
    let keptPhotoCount: Int          // 남긴 사진 수
    let savedRecordCount: Int        // 남긴 기록 수
    let dailyCounts: [Int]           // 요일별 정리 수 (월~일, 7개)

    var isEmpty: Bool {
        completedDays == 0 && deletedPhotoCount == 0
    }

    // 확보 공간은 MVP 미지원 (명세서 §8 S-09)
}

@MainActor
final class ReportViewModel: ObservableObject {
    @Published var reportData: WeeklyReportData? = nil
    @Published var isLoading: Bool = true
    @Published var userName: String = ""

    func onAppear() async {
        isLoading = true
        defer { isLoading = false }

        // TODO: CoreData에서 이번 주 이벤트 집계
        try? await Task.sleep(nanoseconds: 400_000_000)

        userName = "insu"
        reportData = WeeklyReportData(
            weekKey: currentWeekKey(),
            completedDays: 3,
            deletedPhotoCount: 14,
            keptPhotoCount: 3,
            savedRecordCount: 2,
            dailyCounts: [2, 4, 1, 0, 5, 0, 2]  // 월~일
        )
    }

    private func currentWeekKey() -> String {
        let cal = Calendar.current
        let components = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
        return "W\(components.weekOfYear ?? 0)"
    }

    var weekSummaryText: String {
        guard let data = reportData else { return "" }
        return "이번 주 \(data.completedDays)일 동안 사진첩을 돌봤어요."
    }
}

// MARK: - S-09 주간 리포트 뷰
// 명세서 §8 S-09

struct ReportView: View {
    @StateObject private var vm = ReportViewModel()

    var body: some View {
        ZStack {
            Color.rBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // 헤더
                RWordmarkHeader()
                    .padding(.vertical, RSpacing.md)

                RDivider()

                if vm.isLoading {
                    Spacer()
                    ProgressView().tint(.rTextSecondary)
                    Spacer()
                } else if let data = vm.reportData {
                    ScrollView {
                        VStack(alignment: .leading, spacing: RSpacing.xl) {
                            titleSection
                            chartCard(data: data)
                            summaryCards(data: data)
                            tipCard(data: data)
                        }
                        .padding(RSpacing.md)
                        .padding(.bottom, RSpacing.xxxl)
                    }
                } else {
                    emptyState
                }
            }
        }
        .task { await vm.onAppear() }
    }

    // MARK: - 타이틀

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: RSpacing.xs) {
            Text("이번 주 비움 리포트")
                .rTextStyle(.headlineLarge)

            if !vm.weekSummaryText.isEmpty {
                Text(vm.weekSummaryText)
                    .rTextStyle(.body, color: .rTextSecondary)
            }
        }
    }

    // MARK: - 차트 카드

    private func chartCard(data: WeeklyReportData) -> some View {
        RCard {
            VStack(alignment: .leading, spacing: RSpacing.md) {
                HStack {
                    Text("지난 7일간 정리한 사진")
                        .rTextStyle(.subLabel, color: .rTextSecondary)
                    Spacer()
                    Text("\(data.deletedPhotoCount)장")
                        .rTextStyle(.headline)
                }

                // 바 차트
                WeeklyBarChart(dailyCounts: data.dailyCounts)
                    .frame(height: 80)

                // 요일 레이블
                HStack(spacing: 0) {
                    ForEach(["월", "화", "수", "목", "금", "토", "일"], id: \.self) { day in
                        Text(day)
                            .rTextStyle(.caption, color: .rTextTertiary)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    // MARK: - 요약 카드 2열

    private func summaryCards(data: WeeklyReportData) -> some View {
        HStack(spacing: RSpacing.sm) {
            summaryCard(
                icon: "photo.stack",
                label: "정리한 사진",
                value: "\(data.deletedPhotoCount)장"
            )
            summaryCard(
                icon: "text.quote",
                label: "남긴 기록",
                value: "\(data.savedRecordCount)개"
            )
        }
    }

    private func summaryCard(icon: String, label: String, value: String) -> some View {
        RCard {
            VStack(alignment: .leading, spacing: RSpacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(.rTextSecondary)

                Text(label)
                    .rTextStyle(.caption, color: .rTextSecondary)

                Text(value)
                    .rTextStyle(.headline)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 팁 카드

    private func tipCard(data: WeeklyReportData) -> some View {
        RCard {
            HStack(alignment: .top, spacing: RSpacing.sm) {
                Image(systemName: "lightbulb")
                    .font(.system(size: 16))
                    .foregroundColor(.rTextSecondary)

                VStack(alignment: .leading, spacing: RSpacing.xxs) {
                    Text("비움 팁")
                        .rTextStyle(.caption, color: .rTextSecondary)
                    Text(tipText(data: data))
                        .rTextStyle(.subLabel, color: .rTextSecondary)
                        .lineSpacing(RLineSpacing.subLabel)
                }
            }
        }
    }

    private func tipText(data: WeeklyReportData) -> String {
        if data.completedDays == 0 {
            return "오늘부터 시작해보세요. 하루 한 장이면 충분해요."
        } else if data.completedDays < 3 {
            return "꾸준히 하면 한 달에 30장 이상 정리할 수 있어요."
        } else {
            return "이번 주도 잘 하고 있어요. 다음 주에도 가볍게 이어가봐요."
        }
    }

    // MARK: - 빈 상태

    private var emptyState: some View {
        REmptyState(
            title: "아직 기록이 없어요.",
            message: "홈에서 오늘의 사진을\n정리해보세요."
        )
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
            ForEach(Array(dailyCounts.enumerated()), id: \.offset) { _, count in
                VStack(spacing: RSpacing.xxs) {
                    Spacer()
                    RoundedRectangle(cornerRadius: 2)
                        .fill(count > 0 ? Color.rTextPrimary : Color.rBorder)
                        .frame(
                            height: maxCount > 0
                                ? CGFloat(count) / CGFloat(maxCount) * 60
                                : 4
                        )
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    ReportView()
}
#endif
