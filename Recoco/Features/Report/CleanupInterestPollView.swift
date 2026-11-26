import SwiftUI

struct CleanupInterestPollView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = CleanupInterestPollModel()
    @AccessibilityFocusState private var headingFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            RNavigationBar(title: model.showingResults ? String(localized: "투표 결과") : String(localized: "다음 정리 투표"), leadingAction: {
                if model.showingResults { model.openChoices() } else { dismiss() }
            })
            ScrollView {
                VStack(alignment: .leading, spacing: RSpacing.lg) {
                    Text(model.showingResults ? String(localized: "함께 고른 정리 고민") : String(localized: "다음엔 어떤 정리를\n미루지 않고 싶나요?"))
                        .rTextStyle(.headlineLarge)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($headingFocused)
                    if model.showingResults {
                        results
                    } else {
                        Text("하나를 골라주세요. 같은 고민에도 다시 투표할 수 있어요.")
                            .rTextStyle(.body, color: .rTextSecondary)
                        choices
                    }
                    if let message = model.message {
                        Text(message).rTextStyle(.subLabel, color: .rTextSecondary)
                        if model.showingResults {
                            RButton(title: String(localized: "다시 불러오기"), variant: .ghost) {
                                Task { await model.refreshResults() }
                            }
                        }
                    }
                    actions
                        .padding(.top, RSpacing.sm)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .rScreenPadding()
            }
            .id(model.showingResults)
        }
        .background(Color.rBackground.ignoresSafeArea())
        .onChange(of: model.showingResults) { _ in headingFocused = true }
        .task(id: model.showingResults && scenePhase == .active) {
            guard model.showingResults, scenePhase == .active else { return }
            while !Task.isCancelled {
                await model.refreshResults()
                do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                catch { return }
            }
        }
    }

    private var choices: some View {
        VStack(spacing: 0) {
            Divider()
            ForEach(CleanupInterest.allCases) { interest in
                let selected = model.choice == interest
                Button {
                    model.select(interest)
                } label: {
                    HStack(spacing: RSpacing.sm) {
                        Text(interest.title).font(.rBody)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected ? Color.rAccent : .rTextTertiary)
                            .imageScale(.large)
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(selected ? Color.rAccent : .rTextPrimary)
                    .padding(.vertical, RSpacing.sm)
                    .frame(minHeight: RLayout.rowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RPressFeedbackStyle())
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                .accessibilityIdentifier("poll.choice." + interest.rawValue)
                .disabled(model.isSubmitting || model.pending != nil)
                Divider()
            }
        }
    }

    @ViewBuilder private var results: some View {
        if let tally = model.tally {
            if tally.total == 0 {
                VStack(spacing: RSpacing.md) {
                    RSealIllustration(pose: .heart, width: RCharacterSize.companion)
                    Text("아직 모인 표가 없어요.").rTextStyle(.body, color: .rTextSecondary)
                }
                .frame(maxWidth: .infinity)
            } else {
                Text("총 \(tally.total)표").rTextStyle(.section)
                ForEach(CleanupInterest.allCases) { interest in
                    let fraction = tally.fraction(for: interest)
                    VStack(spacing: RSpacing.xs) {
                        HStack {
                            Text(interest.shortTitle)
                            Spacer()
                            Text(tally.total < 5 ? String(localized: "\(tally[interest])표") : fraction.formatted(.percent.precision(.fractionLength(0))))
                                .monospacedDigit()
                        }
                        .font(.rBody)
                        ProgressView(value: fraction).tint(.rAccent).accessibilityHidden(true)
                    }
                    .foregroundStyle(Color.rTextPrimary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(interest.shortTitle), \(tally[interest])표")
                }
            }
        } else if model.message == nil {
            RLoadingIndicator(style: .compact, size: 28, accessibilityLabel: String(localized: "투표 결과를 불러오는 중"))
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private var actions: some View {
        VStack(spacing: RLayout.actionGap) {
            if model.showingResults {
                RButton(title: model.hasVoted ? String(localized: "다시 투표하기") : String(localized: "투표하러 가기"), variant: .secondary) { model.openChoices() }
                RButton(title: String(localized: "리포트로 돌아가기"), variant: .ghost) { dismiss() }
            } else {
                RButton(title: model.isSubmitting ? String(localized: "투표하는 중…") : model.pending == nil ? String(localized: "투표하기") : String(localized: "이 표 다시 확인하기"),
                        variant: .primary, isLoading: model.isSubmitting, isDisabled: model.choice == nil) {
                    Task { await model.submit() }
                }
                .accessibilityIdentifier("poll.submit")
                RButton(title: String(localized: "결과만 보기"), variant: .ghost, isDisabled: model.isSubmitting) { model.openResults() }
                    .accessibilityIdentifier("poll.showResults")
            }
        }
    }
}
