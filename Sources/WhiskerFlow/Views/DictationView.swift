import SwiftUI
import WhiskerFlowCore

struct DictationView: View {
    @Bindable var appState: AppState
    var openSetup: () -> Void
    var openHistory: (TranscriptRecord?) -> Void
    private var presentation: DictationPresentation { DictationPresentation(appState: appState) }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    HStack {
                        Text("Dictate").font(.system(size: 15, weight: .medium))
                        Spacer()
                        FlowStatus(title: presentation.statusTitle, color: presentation.statusColor)
                    }
                    .padding(.top, 28)

                    VStack(spacing: 23) {
                        FlowWaveform(level: appState.audioLevel, recording: appState.isRecording, size: 67)
                        Text(presentation.heading)
                            .font(.system(size: 36, weight: .semibold, design: .rounded))
                            .tracking(-1.1)
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)
                        HStack(spacing: 12) {
                            Text(appState.isRecording ? presentation.finish : presentation.gesture)
                            FlowKeycap(title: appState.settings.hotkeyDisplayName)
                            Text(appState.isRecording ? "to finish" : "to dictate")
                        }
                        .font(.system(size: 22, weight: .regular))
                        .accessibilityElement(children: .combine)

                        Text(presentation.deliveryDescription)
                            .font(.system(size: 14))
                            .foregroundStyle(FlowStyle.muted)
                            .multilineTextAlignment(.center)

                        if presentation.needsSetup {
                            Button("Set up dictation", action: openSetup)
                                .buttonStyle(FlowPrimaryButtonStyle())
                        } else if let failure = presentation.failure {
                            VStack(spacing: 10) {
                                Text(failure).font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center)
                                HStack {
                                    Button("Check setup", action: openSetup)
                                    Button("Reload transcription") { appState.warmUpEngine() }
                                }
                            }
                        } else if appState.isTranscribing || appState.modelState == .preparing {
                            ProgressView().controlSize(.small)
                        } else {
                            SettingsLink { Text("Change shortcut") }
                                .buttonStyle(.plain).foregroundStyle(FlowStyle.accent)
                        }

                        if appState.isRecording && !appState.liveText.isEmpty {
                            Text(appState.liveText).font(.body).lineLimit(3)
                                .foregroundStyle(FlowStyle.muted)
                                .frame(maxWidth: 520)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, max(35, min(80, geometry.size.height * 0.09)))

                    recentSection
                    Spacer(minLength: 24)
                }
                .frame(maxWidth: 780)
                .padding(.horizontal, 42)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
            }
        }
    }

    private var recentSection: some View {
        VStack(spacing: 0) {
            Divider().overlay(FlowStyle.line)
            HStack {
                Text("Recent dictation").font(.system(size: 13, weight: .medium))
                Spacer()
                Button("View history") { openHistory(nil) }
                    .buttonStyle(.plain).foregroundStyle(FlowStyle.accent)
            }.padding(.vertical, 23)

            let recent = Array(appState.records.filter { $0.status == .transcribed }.prefix(3))
            if recent.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "text.alignleft").foregroundStyle(FlowStyle.muted)
                    Text("Your words will appear here after your first dictation.")
                        .font(.system(size: 13)).foregroundStyle(FlowStyle.muted)
                    Spacer()
                }.padding(.vertical, 20)
            } else {
                ForEach(recent) { record in
                    HStack(spacing: 16) {
                        Button { openHistory(record) } label: {
                            Text(record.text.isEmpty ? "Empty transcript" : record.text)
                                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Text(record.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .font(.system(size: 11)).foregroundStyle(FlowStyle.muted)
                        FlowCopyButton(text: record.text, compact: true, copy: appState.copy)
                            .buttonStyle(.plain).foregroundStyle(FlowStyle.muted)
                    }
                    .font(.system(size: 13)).padding(.vertical, 19)
                    if record.id != recent.last?.id { Divider().opacity(0.5) }
                }
            }
            if !appState.retryQueue.isEmpty {
                HStack {
                    Label(appState.retryQueue.count == 1 ? "1 recording needs another try" : "\(appState.retryQueue.count) recordings need another try", systemImage: "exclamationmark.circle")
                        .foregroundStyle(FlowStyle.muted)
                    Spacer()
                    Button("Review") { openHistory(appState.retryQueue.first) }
                        .buttonStyle(.plain).foregroundStyle(FlowStyle.accent)
                }.font(.caption).padding(.top, 16)
            }
        }
    }
}
