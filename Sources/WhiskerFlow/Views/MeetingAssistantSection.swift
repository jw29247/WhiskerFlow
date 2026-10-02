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
MeetingCoachInsightsSection(appState: appState)
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
        HStack {
            Button(appState.assistant.currentCoachRecord?.isSaved == true ? "Saved on this Mac" : "Save on this Mac") {
                appState.assistant.saveCurrentCoach()
            }.disabled(appState.assistant.currentCoachRecord?.isSaved == true)
            Button("Dismiss") { appState.assistant.dismissCoach() }
            if let record = appState.assistant.currentCoachRecord {
                Button(record.jobReference == nil ? "Delete from this Mac" : "Delete from Atlas and this Mac", role: .destructive) {
                    Task { await appState.assistant.deleteCoach(record.id) }
                }.disabled(appState.assistant.busy)
            }
        }
        Text(appState.assistant.currentCoachRecord?.jobReference == nil
             ? "Prepared locally. This coaching has no Atlas copy."
             : "Save keeps a private copy on this Mac. Dismiss only closes the preview; Atlas retains the generated result under its retention policy.")
            .font(.caption).foregroundStyle(FlowStyle.muted)
    }.padding(18).background(FlowStyle.surface, in: RoundedRectangle(cornerRadius: 12))
}
            if !appState.assistant.visibleCoachRecords.isEmpty {
                DisclosureGroup("Coaching on this Mac") {
                    ForEach(appState.assistant.visibleCoachRecords) { record in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(record.result?.title ?? "Coaching deletion pending")
                                Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(FlowStyle.muted)
                                Text(record.deletionRequestID != nil ? "Atlas deletion pending" : (record.isSaved ? "Saved on this Mac" : "Preview · not saved"))
                                    .font(.caption).foregroundStyle(FlowStyle.muted)
                            }
                            Spacer()
                            if record.deletionRequestID == nil {
                                Button("Open") { appState.assistant.openCoach(record.id) }
                            }
                            VStack(alignment: .trailing, spacing: 6) {
                                Button(record.deletionRequestID != nil ? "Retry Atlas deletion" : (record.jobReference == nil ? "Delete locally" : "Delete from Atlas and this Mac"), role: .destructive) {
                                    Task { await appState.assistant.deleteCoach(record.id) }
                                }.disabled(appState.assistant.busy)
                                if record.deletionRequestID != nil {
                                    Button("Forget local deletion request", role: .destructive) {
                                        appState.assistant.forgetPendingCoachDeletion(record.id)
                                    }.disabled(appState.assistant.busy)
                                    Text("Forgetting stops retries. Deletion from Atlas remains unconfirmed.")
                                        .font(.caption).foregroundStyle(FlowStyle.muted)
                                }
                            }
                        }.padding(.vertical, 6)
                    }
                }
            }
        }
    }
}
