import SwiftUI
import WhiskerFlowAppSupport

struct MeetingsView: View {
    @Bindable var appState: AppState
    @State private var showSetup = false
    @State private var showPrevious = false

    private var needsSetup: Bool {
        !appState.isAtlasPaired || !appState.hasMicrophonePermission || !appState.hasScreenRecordingPermission
    }
    private var startDisabled: Bool {
        appState.isMeetingCapturing || appState.isMeetingCaptureTransitioning || !appState.isMeetingStorageAvailable
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Meetings").font(.system(size: 28, weight: .semibold, design: .rounded))
                    FlowStatus(title: appState.isAtlasPaired ? "Connected to Atlas" : "Atlas isn’t connected",
                               color: appState.isAtlasPaired ? .green : FlowStyle.muted)
                }
                Spacer()
                if appState.isMeetingCapturing {
                    Button { appState.toggleMeetingCapture() } label: { Label("Stop recording", systemImage: "stop.fill") }
                        .buttonStyle(FlowPrimaryButtonStyle(destructive: true))
                        .disabled(appState.isMeetingCaptureTransitioning)
                } else {
                    Button {
                        if needsSetup { showSetup = true } else { appState.toggleMeetingCapture() }
                    } label: { Label(appState.isMeetingCaptureTransitioning ? "Finishing…" : "Record meeting", systemImage: "record.circle") }
                        .buttonStyle(FlowPrimaryButtonStyle()).disabled(startDisabled)
                }
            }.padding(32)

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if appState.isMeetingCapturing {
                        HStack(spacing: 18) {
                            Image(systemName: "record.circle.fill").font(.system(size: 28)).foregroundStyle(FlowStyle.recording)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(appState.activeMeetingTitle ?? "Meeting in progress").font(.headline)
                                Text(appState.meetingStatusDetail).font(.callout).foregroundStyle(FlowStyle.muted)
                            }
                            Spacer()
                            Text("RECORDING").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(FlowStyle.recording)
                        }.padding(22).background(FlowStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                    }

                    if appState.meetingStatus == .attention || appState.meetingStatus == .uploading || (appState.isAtlasPaired && appState.meetingStatus == .uncovered) || !appState.isMeetingStorageAvailable {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(appState.meetingStatus == .uploading ? "Saving your meeting" : (appState.meetingStatus == .uncovered ? "Meeting status" : "Recording needs attention"),
                                  systemImage: appState.meetingStatus == .uploading ? "arrow.up.circle" : "exclamationmark.circle")
                                .font(.headline)
                            Text(appState.meetingStatusDetail).font(.callout).textSelection(.enabled)
                            if !appState.isMeetingStorageAvailable { Text("Free at least 500 MB on this Mac.").font(.callout) }
                            Button("Check setup") { showSetup = true }
                        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                            .background(FlowStyle.selection, in: RoundedRectangle(cornerRadius: 10))
                    }
                    if !appState.isAtlasPaired {
                        VStack(alignment: .leading, spacing: 18) {
                            Image(systemName: "calendar.badge.plus").font(.system(size: 32, weight: .light)).foregroundStyle(FlowStyle.accent)
                            Text("Be in the conversation.").font(.system(size: 28, weight: .semibold, design: .rounded))
                            Text("Connect Atlas to see your meetings here and save their recordings and transcripts to your workspace.")
                                .font(.system(size: 14)).foregroundStyle(FlowStyle.muted).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: 440, alignment: .leading)
                            Button("Connect Atlas") { showSetup = true }.buttonStyle(FlowPrimaryButtonStyle())
                            Text("Dictation works without an Atlas account.").font(.caption).foregroundStyle(FlowStyle.muted)
                        }.padding(.vertical, 42)
                    } else {
                        if needsSetup {
                            HStack {
                                Label("Enable audio access before recording.", systemImage: "mic.badge.plus")
                                Spacer()
                                Button("Finish setup") { showSetup = true }
                            }.font(.callout).padding(16).background(FlowStyle.selection, in: RoundedRectangle(cornerRadius: 10))
                        }
                        HStack {
                            Text("Upcoming · next 7 days").font(.system(size: 13, weight: .medium))
                            Spacer()
                            Button { appState.refreshMeetingSchedule() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                                .buttonStyle(.plain).foregroundStyle(FlowStyle.accent)
                        }
                        if appState.upcomingMeetings.isEmpty {
                            FlowEmptyState(symbol: "calendar", title: "A little breathing room.", detail: "No upcoming meetings in the next seven days. You can still record a meeting whenever you need.")
                                .frame(minHeight: 190)
                        } else {
                            VStack(spacing: 10) {
                                ForEach(appState.upcomingMeetings, id: \.eventID) { meeting in
                                    meetingRow(meeting, previous: false)
                                }
                            }
                        }
                        if !appState.previousMeetings.isEmpty {
                            DisclosureGroup("Previous · last 7 days", isExpanded: $showPrevious) {
                                VStack(spacing: 10) {
                                    ForEach(appState.previousMeetings, id: \.eventID) { meeting in meetingRow(meeting, previous: true) }
                                }.padding(.top, 16)
                            }.font(.system(size: 13, weight: .medium))
                        }
                    }
                    if appState.isAtlasPaired || appState.isMeetingCapturing {
                        DisclosureGroup("Recording status") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(appState.meetingStatusDetail).textSelection(.enabled)
                                Text(appState.isMeetingStorageAvailable ? "Local storage is available." : "Free at least 500 MB on this Mac before recording.")
                                Text(appState.meetingModelState == .ready ? "Meeting transcription is ready." : "Meeting transcription is preparing or needs attention.")
                                HStack {
                                    Button("Check again") { appState.refreshMeetingConfiguration() }
                                    Button("Retry sending") { appState.retryMeetingDelivery() }
                                    if let url = appState.latestAtlasMeetingURL { Link("Open in Atlas", destination: url) }
                                }
                            }.font(.caption).foregroundStyle(FlowStyle.muted).padding(.top, 12)
                        }.font(.caption).foregroundStyle(FlowStyle.muted)
                    }
                }
                .padding(.horizontal, 32).padding(.bottom, 32)
                .frame(maxWidth: 860, alignment: .leading).frame(maxWidth: .infinity)
            }
            Spacer(minLength: 0)
            Divider()
            HStack {
                Image(systemName: "calendar.badge.clock")
                Text(appState.settings.meetingModeEnabled ? "Automatic recording is on" : "Automatic recording is off")
                Spacer()
                Button("Manage") { showSetup = true }.buttonStyle(.plain).foregroundStyle(FlowStyle.accent)
            }.font(.system(size: 12)).foregroundStyle(FlowStyle.muted).padding(.horizontal, 32).padding(.vertical, 21)
        }
        .sheet(isPresented: $showSetup) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Meeting setup").font(.system(size: 24, weight: .semibold, design: .rounded))
                    Spacer()
                    Button("Done") { showSetup = false }.keyboardShortcut(.cancelAction)
                }.padding(26)
                Form { MeetingSetupView(appState: appState) }.formStyle(.grouped)
            }.frame(width: 570, height: 590).background(FlowStyle.canvas).tint(FlowStyle.accent)
        }
    }

    private func meetingRow(_ meeting: AtlasCaptureScheduleIntent, previous: Bool) -> some View {
        HStack(spacing: 16) {
            let start = Date(timeIntervalSince1970: Double(meeting.startMs) / 1000)
            VStack(spacing: 2) {
                Text(start, format: .dateTime.month(.abbreviated)).font(.system(size: 9, weight: .semibold)).textCase(.uppercase)
                Text(start, format: .dateTime.day()).font(.system(size: 23, weight: .medium, design: .rounded))
            }.foregroundStyle(FlowStyle.muted).frame(width: 42)
            VStack(alignment: .leading, spacing: 7) {
                Text(meeting.title).font(.system(size: 14, weight: .medium)).lineLimit(2)
                HStack(spacing: 4) {
                    Text(start, format: .dateTime.hour().minute())
                    Text("–")
                    Text(Date(timeIntervalSince1970: Double(meeting.endMs) / 1000), format: .dateTime.hour().minute())
                }.font(.system(size: 12)).foregroundStyle(FlowStyle.muted)
            }
            Spacer()
            if previous {
                Text(meeting.existingMeetingID == nil ? "Not recorded" : "In Atlas")
                    .font(.caption).foregroundStyle(FlowStyle.muted)
            } else {
                Button {
                    if needsSetup { showSetup = true } else { appState.recordScheduledMeeting(meeting) }
                } label: { Label("Record", systemImage: "record.circle") }
                    .disabled(startDisabled).controlSize(.large)
            }
        }.padding(17).background(FlowStyle.surface, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(FlowStyle.line, lineWidth: 1))
    }
}

struct MeetingSetupView: View {
    @Bindable var appState: AppState

    var body: some View {
        Section("Atlas") {
            Text("Your calendar, recordings and meeting transcripts, together in Atlas.")
                .font(.callout).foregroundStyle(FlowStyle.muted)
            HStack {
                Label(appState.isAtlasPaired ? "Connected to Atlas" : "Connect this Mac", systemImage: "person.crop.circle")
                Spacer()
                Button(appState.isSigningInToAtlas ? "Connecting…" : (appState.isAtlasPaired ? "Reconnect" : "Connect Atlas")) {
                    appState.signInToAtlas()
                }.disabled(appState.isSigningInToAtlas)
            }
            Text("atlas.thatworks.agency").font(.caption).foregroundStyle(FlowStyle.muted)
            if let error = appState.atlasSignInError { Text(error).font(.caption).foregroundStyle(.orange) }
        }
        Section("Audio access") {
            HStack {
                Label("Microphone", systemImage: "mic")
                Spacer()
                if appState.hasMicrophonePermission { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                else { Button("Enable") { Task { await appState.requestMicrophonePermission() }; OnboardingView.openSettings("Privacy_Microphone") } }
            }
            HStack {
                Label("Mac audio", systemImage: "speaker.wave.2")
                Spacer()
                if appState.hasScreenRecordingPermission { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                else {
                    Button("Enable") {
                        appState.requestScreenRecordingPermission()
                        OnboardingView.openSettings("Privacy_ScreenCapture")
                    }
                }
            }
            Text("macOS calls this Screen Recording access. WhiskerFlow captures audio, never screen images.")
                .font(.caption).foregroundStyle(FlowStyle.muted)
            Button("Check permissions again") {
                appState.refreshMicrophonePermission()
                appState.refreshScreenRecordingPermission()
                appState.refreshMeetingConfiguration()
            }
        }
        Section("Automatic recording") {
            Toggle("Record scheduled meetings automatically", isOn: $appState.settings.meetingModeEnabled)
                .onChange(of: appState.settings.meetingModeEnabled) { _, _ in appState.refreshMeetingConfiguration() }
            Text("Records eligible Atlas calendar meetings with a secure meeting link. You can stop a recording at any time in Meetings.")
                .font(.caption).foregroundStyle(FlowStyle.muted)
        }
    }
}
