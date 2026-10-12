import SwiftUI
import WhiskerFlowAppSupport
import WhiskerFlowCore

/// Live talk share, current turn and pace, for the coach HUD and panel.
struct MeetingCoachLiveMetrics: View {
    let controller: MeetingAssistantController
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            if let share = controller.talkShare {
                MeetingTalkShareBar(share: share, compact: compact)
                if let recent = controller.recentTalkShare, abs(recent - share) >= 0.1 {
                    Text("Last 5 min: you \(Int((recent * 100).rounded()))%").font(.caption2).foregroundStyle(FlowStyle.muted)
                }
            } else {
                Text("Talk share appears after a minute of conversation.").font(.caption).foregroundStyle(FlowStyle.muted)
            }
            HStack(spacing: 14) {
                if controller.currentTurnSeconds >= 20 {
                    Label("Your turn \(MeetingCoachView.duration(controller.currentTurnSeconds))", systemImage: "person.wave.2")
                        .foregroundStyle(controller.currentTurnSeconds >= MeetingMonologueTracker.alertAfterSeconds
                                         ? Color.orange : FlowStyle.ink)
                }
                if let wpm = controller.wordsPerMinute {
                    let band = MeetingPaceBand.band(wordsPerMinute: wpm)
                    Label("\(Int(wpm.rounded())) wpm · \(band.label)", systemImage: "speedometer")
                        .foregroundStyle(band == .comfortable ? FlowStyle.ink : Color.orange)
                }
            }.font(.caption).labelStyle(.titleAndIcon)
        }
    }
}

struct MeetingTalkShareBar: View {
    let share: Double
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("You \(Int((share * 100).rounded()))%").foregroundStyle(FlowStyle.accent)
                Spacer()
                Text("Others \(Int(((1 - share) * 100).rounded()))%").foregroundStyle(FlowStyle.muted)
            }.font(.system(size: compact ? 11 : 12, weight: .medium)).monospacedDigit()
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    Capsule().fill(share > 0.65 ? Color.orange : FlowStyle.accent)
                        .frame(width: max(4, proxy.size.width * share))
                    Capsule().fill(FlowStyle.line)
                }
            }.frame(height: 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("You \(Int((share * 100).rounded())) percent of the talking")
    }
}

/// The current reminder, labelled when it came from the experimental model.
struct MeetingCoachPromptView: View {
    let controller: MeetingAssistantController

    var body: some View {
        if let prompt = controller.livePrompt {
            VStack(alignment: .leading, spacing: 6) {
                if controller.livePromptIsAI {
                    Label("On-device AI · experimental", systemImage: "sparkles")
                        .font(.caption2).foregroundStyle(FlowStyle.muted)
                }
                Text(prompt).font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    if controller.livePromptIsAI {
                        if controller.didRateSuggestion {
                            Text("Thanks — noted on this Mac.").font(.caption).foregroundStyle(FlowStyle.muted)
                        } else {
                            Button("Helpful") { controller.rateSuggestion(helpful: true) }
                            Button("Not helpful") { controller.rateSuggestion(helpful: false) }
                        }
                    }
                    Spacer()
                    Button("Dismiss") { controller.dismissPrompt() }
                }.font(.caption).buttonStyle(.plain).foregroundStyle(FlowStyle.accent)
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(FlowStyle.selection.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
        }
    }
}

/// Coaching settings and trends across recent meetings.
struct MeetingCoachInsightsSection: View {
    @Bindable var appState: AppState

    var body: some View {
        let trends = appState.meetingCoachTrends
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: Binding(get: { appState.settings.coachLiveAnalysis }, set: { appState.setCoachLiveAnalysis($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Measure my speaking pace")
                    Text("Transcribes only your microphone, on this Mac, while coaching is on. The words are kept in memory and discarded when the meeting ends.")
                        .font(.caption).foregroundStyle(FlowStyle.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            Toggle(isOn: Binding(get: { appState.settings.coachAISuggestions }, set: { appState.setCoachAISuggestions($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("On-device AI suggestions (experimental)")
                    Text(appState.isOnDeviceCoachModelAvailable
                         ? "Apple’s on-device model reads your own recent words and picks one tip at most every three minutes. Nothing is sent anywhere. Rate each tip so we can tell whether it helps."
                         : appState.onDeviceCoachModelUnavailableReason)
                        .font(.caption).foregroundStyle(FlowStyle.muted).fixedSize(horizontal: false, vertical: true)
                }
            }.disabled(!appState.isOnDeviceCoachModelAvailable)

            if trends.meetingCount > 0 {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Your last \(trends.meetingCount) coached meeting\(trends.meetingCount == 1 ? "" : "s")")
                        .font(.system(size: 13, weight: .medium))
                    HStack(alignment: .top, spacing: 24) {
                        stat("Talk share", trends.averageTalkShare.map { "\(Int(($0 * 100).rounded()))%" } ?? "—",
                             detail: direction(trends.talkShareDirection))
                        stat("Pace", trends.averageWordsPerMinute.map { "\(Int($0.rounded())) wpm" } ?? "—", detail: "average")
                        stat("Long turns", String(format: "%.1f", trends.monologuesPerMeeting), detail: "per meeting, over 90 s")
                        stat("Longest turn", MeetingCoachView.duration(trends.longestMonologueSeconds), detail: nil)
                    }
                    Text("Numbers only, kept encrypted with your meetings on this Mac.")
                        .font(.caption).foregroundStyle(FlowStyle.muted)
                }
            }
        }
        .font(.callout)
        .padding(18)
        .background(FlowStyle.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func stat(_ title: String, _ value: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(FlowStyle.muted)
            Text(value).font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
            if let detail { Text(detail).font(.caption2).foregroundStyle(FlowStyle.muted) }
        }
    }

    private func direction(_ direction: MeetingCoachTrends.Direction?) -> String? {
        switch direction {
        case .up: return "rising lately"
        case .down: return "falling lately"
        case .steady: return "steady"
        case nil: return nil
        }
    }
}

/// One meeting's coaching numbers, for the meeting detail view.
struct MeetingCoachSummaryView: View {
    let summary: MeetingCoachSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let share = summary.talkShare { MeetingTalkShareBar(share: share) }
            HStack(spacing: 20) {
                Label("Longest turn \(MeetingCoachView.duration(summary.longestMonologueSeconds))", systemImage: "person.wave.2")
                Label("\(summary.monologueCount) over 90 s", systemImage: "exclamationmark.bubble")
                if let wpm = summary.averageWordsPerMinute {
                    Label("\(Int(wpm.rounded())) wpm", systemImage: "speedometer")
                }
                if summary.aiSuggestionsShown > 0 {
                    Label("AI tips \(summary.aiSuggestionsShown) · 👍 \(summary.aiHelpfulCount) · 👎 \(summary.aiNotHelpfulCount)",
                          systemImage: "sparkles")
                }
            }.font(.caption).foregroundStyle(FlowStyle.muted).labelStyle(.titleAndIcon)
        }
    }
}

extension MeetingPaceBand {
    var label: String {
        switch self {
        case .slow: return "slow"
        case .comfortable: return "comfortable"
        case .fast: return "fast"
        }
    }
}
