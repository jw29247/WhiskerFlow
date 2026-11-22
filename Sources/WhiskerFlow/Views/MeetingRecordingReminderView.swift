import SwiftUI

/// "Tell the others you're recording", with the notice to paste into the
/// meeting chat. Shown in the floating meeting panel and on the Meetings screen.
struct MeetingRecordingReminderView: View {
    let appState: AppState

    var body: some View {
        let copied = appState.recordingReminder.isCopied
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: copied ? "checkmark.circle.fill" : "person.2.wave.2")
                .font(.system(size: 16)).foregroundStyle(copied ? FlowStyle.accent : FlowStyle.recording)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 6) {
                if copied {
                    Text("Copied. Paste it in the meeting chat.").font(FlowStyle.callout.weight(.medium))
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Tell the others you’re recording").font(FlowStyle.callout.weight(.semibold))
                        Spacer()
                        Button { appState.dismissRecordingReminder() } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).foregroundStyle(FlowStyle.muted)
                            .accessibilityLabel("Dismiss").help("Dismiss")
                    }
                    Text("Their voices are being recorded and uploaded to Atlas. Paste a short notice in the meeting chat.")
                        .font(.caption).foregroundStyle(FlowStyle.muted).fixedSize(horizontal: false, vertical: true)
                    Button { appState.copyMeetingRecordingNotice() } label: {
                        Label("Copy recording notice", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(FlowPrimaryButtonStyle()).controlSize(.small).padding(.top, 2)
                    .help(appState.meetingRecordingNoticeText)
                }
            }
        }
        .foregroundStyle(FlowStyle.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
