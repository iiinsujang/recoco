import SwiftUI
import Photos
import UIKit

// MARK: - S-04 홈
// 명세서 §8 S-04

struct HomeView: View {
    @StateObject private var vm = HomeViewModel()

    // 하위 화면 네비게이션
    @State private var showCleanupConfirm: Bool = false
    @State private var showPhotoSelector: Bool = false
    @State private var showRecord: Bool = false
    @State private var pendingUnit: DecisionUnit? = nil

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.rBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // 워드마크 헤더
                RWordmarkHeader()
                    .padding(.top, RSpacing.sm)
                    .padding(.bottom, RSpacing.md)

                // 주간 배너
                weeklyBanner
                    .padding(.horizontal, RSpacing.md)
                    .padding(.bottom, RSpacing.xl)

                // 메인 콘텐츠 (상태별)
                mainContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .rToast(isPresented: $vm.showToast, message: vm.toastMessage)
        .task { await vm.onAppear() }
        // S-05 정리 확인 바텀시트
        .sheet(isPresented: $showCleanupConfirm) {
            if let unit = pendingUnit {
                CleanupConfirmSheet(unit: unit) { deletedCount in
                    vm.markTodayCompleted(deletedCount: deletedCount, savedRecord: false)
                }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
        }
        // S-06 대표 사진 선택
        .fullScreenCover(isPresented: $showPhotoSelector) {
            if let unit = pendingUnit {
                PhotoSelectorView(unit: unit) { updatedUnit in
                    pendingUnit = updatedUnit
                    showPhotoSelector = false
                    showCleanupConfirm = true
                }
            }
        }
        // S-07 Record
        .fullScreenCover(isPresented: $showRecord) {
            if let unit = pendingUnit {
                RecordView(unit: unit) {
                    vm.markTodayCompleted(deletedCount: 0, savedRecord: true)
                }
            }
        }
    }

    // MARK: - 주간 배너

    private var weeklyBanner: some View {
        Button {
            // S-09 리포트로 이동 (탭바에서도 접근 가능)
        } label: {
            RCard(padding: RSpacing.md) {
                VStack(alignment: .leading, spacing: RSpacing.sm) {
                    HStack {
                        Text("이번 주의 작은 비움")
                            .rTextStyle(.caption, color: .rTextTertiary)
                        Spacer()
                        Text("\(vm.userName)님, 함께 정리해요")
                            .rTextStyle(.caption, color: .rTextTertiary)
                    }

                    HStack(alignment: .lastTextBaseline, spacing: RSpacing.xs) {
                        Text(vm.weeklyProgress.displayText)
                            .rTextStyle(.headline)
                        Spacer()
                    }

                    RProgressBar(progress: vm.weeklyProgress.progressRatio)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 상태별 메인 콘텐츠

    @ViewBuilder
    private var mainContent: some View {
        switch vm.state {
        case .loading:
            loadingView

        case .noPermission:
            noPermissionView

        case .ready(let unit):
            ScrollView {
                VStack(alignment: .leading, spacing: RSpacing.xl) {
                    // 인사 텍스트
                    greetingText
                        .padding(.horizontal, RSpacing.md)

                    // Decision Unit 카드
                    switch unit.type {
                    case .cleanupCluster:
                        CleanupClusterCard(unit: unit) {
                            pendingUnit = unit
                            showCleanupConfirm = true
                        } onSelectPhoto: {
                            pendingUnit = unit
                            showPhotoSelector = true
                        } onDefer: {
                            vm.deferDecision(unit)
                        }
                        .padding(.horizontal, RSpacing.md)

                    case .recallMoment:
                        RecallMomentCard(unit: unit) {
                            vm.keepRecallMoment(unit)
                        } onRecord: {
                            pendingUnit = unit
                            showRecord = true
                        } onDefer: {
                            vm.deferDecision(unit)
                        }
                        .padding(.horizontal, RSpacing.md)
                    }
                }
                .padding(.bottom, RSpacing.xxxl)
            }

        case .completed(let summary):
            completedView(summary: summary)

        case .noCandidate:
            noCandidateView
        }
    }

    // MARK: - 인사 텍스트 (시간대별)

    private var greetingText: some View {
        let hour = Calendar.current.component(.hour, from: Date())
        let greeting: String
        switch hour {
        case 5..<12:  greeting = "좋은 아침이에요."
        case 12..<18: greeting = "좋은 오후예요."
        default:      greeting = "좋은 저녁이에요."
        }

        return VStack(alignment: .leading, spacing: RSpacing.xs) {
            Text(greeting)
                .rTextStyle(.headline)
            Text("기기에서 찾아낸 비우기 좋은 기록들이에요.")
                .rTextStyle(.body, color: .rTextSecondary)
        }
    }

    // MARK: - 로딩

    private var loadingView: some View {
        VStack(spacing: RSpacing.md) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.rTextSecondary)
            Text("사진을 분석하고 있어요...")
                .rTextStyle(.body, color: .rTextSecondary)
        }
    }

    // MARK: - 권한 없음

    private var noPermissionView: some View {
        REmptyState(
            title: "사진 접근이 필요해요.",
            message: "사진 접근을 허용하면\n정리를 시작할 수 있어요.",
            actionTitle: "설정으로 이동하기"
        ) {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }
    }

    // MARK: - 오늘 완료

    private func completedView(summary: CompletionSummary) -> some View {
        VStack(spacing: RSpacing.md) {
            Text("오늘의 결정을 마쳤어요.")
                .rTextStyle(.headline)
                .multilineTextAlignment(.center)

            VStack(spacing: RSpacing.xs) {
                if summary.deletedCount > 0 {
                    statRow(value: "\(summary.deletedCount)장", label: "정리한 사진")
                }
                if summary.savedRecordCount > 0 {
                    statRow(value: "\(summary.savedRecordCount)개", label: "남긴 기록")
                }
            }
            .padding(.vertical, RSpacing.sm)

            Text("내일 다시 만나요.")
                .rTextStyle(.body, color: .rTextSecondary)
        }
        .padding(.horizontal, RSpacing.xl)
    }

    private func statRow(value: String, label: String) -> some View {
        HStack(spacing: RSpacing.xs) {
            Text(value)
                .rTextStyle(.headline)
            Text(label)
                .rTextStyle(.body, color: .rTextSecondary)
        }
    }

    // MARK: - 후보 없음

    private var noCandidateView: some View {
        REmptyState(
            title: "오늘은 정리할 사진이 없어요.",
            message: "사진첩이 이미 꽤 가벼운 편이에요.\n새로운 사진이 쌓이면 다시 알려드릴게요."
        )
    }
}

// MARK: - Preview

#if DEBUG
#Preview("로딩") {
    let vm = HomeViewModel()
    return HomeView()
}

#Preview("완료") {
    HomeView()
}
#endif
