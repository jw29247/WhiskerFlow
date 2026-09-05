import SwiftUI

struct MeetingAssistantSection: View {
    @Bindable var appState: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
MeetingCoachView(controller: appState.meetingAssistant,
    requestPreparation: {
        await appState.assistant.requestCoach(phase: "premeeting", goal: appState.meetingAssistant.goal, agenda: appState.meetingAssistant.agenda)
    }, requestReview: {
        await appState.assistant.requestCoach(phase: "postmeeting", goal: appState.meetingAssistant.goal,
            meetingReference: appState.meetingAssistant.latestFinalizedMeetingReference)
    })
Toggle("Use Atlas AI for preparation and reviews I request", isOn: Binding(
    get: { appState.assistant.saved.cloudEnabled }, set: { appState.assistant.setCloudEnabled($0) }))
    .font(.callout).disabled(appState.assistant.busy)
Text("When enabled, preparation sends your goal and agenda to Atlas and its AI provider. Reviews use your owned meeting transcript. Coaching is private to you.")
    .font(.caption).foregroundStyle(FlowStyle.muted)
if appState.assistant.busy {
    HStack {
        ProgressView("Preparing your private coaching…")
        if appState.assistant.saved.pendingJob != nil { Button("Stop waiting") { appState.assistant.pauseWaiting() } }
    }
}
if let message = appState.assistant.message { Text(message).font(.callout).textSelection(.enabled) }
if appState.assistant.saved.pendingJob != nil {
    Button("Resume coaching request") { Task { await appState.assistant.resumeJob() } }
        .disabled(appState.assistant.busy)
}
if let result = appState.assistant.coachResult {
    VStack(alignment: .leading, spacing: 14) {
        Text(result.title).font(.headline)
        if result.phase == "postmeeting", result.incomplete { Text("The transcript is incomplete. Treat this as a limited review.").font(.caption).foregroundStyle(.orange) }
        ForEach(Array(result.suggestions.enumerated()), id: \.offset) { _, suggestion in
            VStack(alignment: .leading, spacing: 6) {
                Text(suggestion.text).textSelection(.enabled)
                ForEach(Array(suggestion.evidence.enumerated()), id: \.offset) { _, evidence in
                    Text("\(Int(evidence.startMs / 1000) / 60):\(String(format: "%02d", Int(evidence.startMs / 1000) % 60)) · \(evidence.quote)")
                        .font(.caption).foregroundStyle(FlowStyle.muted).textSelection(.enabled)
                }
            }
        }
        Button("Dismiss review") { appState.assistant.coachResult = nil }
    }.padding(18).background(FlowStyle.surface, in: RoundedRectangle(cornerRadius: 12))
}
        }
    }
}
