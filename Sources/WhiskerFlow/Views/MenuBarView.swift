import AppKit
import SwiftUI
import WhiskerFlowAppSupport
import WhiskerFlowCore

struct MenuBarView: View {
    @Bindable var appState: AppState
    @ObservedObject var updaterService: UpdaterService
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            HStack(spacing: 10) {
                LiveFlowWaveform(appState: appState, recording: appState.isRecording, size: 26)
                Text("WhiskerFlow").font(.system(size: 17, weight: .semibold, design: .rounded))
                Spacer()
                FlowStatus(title: DictationPresentation(appState: appState).statusTitle,
                           color: DictationPresentation(appState: appState).statusColor)
            }
            HStack(spacing: 9) {
                Text(DictationPresentation(appState: appState).gesture)
                FlowKeycap(title: appState.settings.hotkeyDisplayName, compact: true)
                Text("to dictate")
                Spacer()
            }.font(.system(size: 13)).foregroundStyle(FlowStyle.muted)
            if appState.isShortcutPausedBySecureInput {
                SecureInputNotice()
            }
            Divider()
            if let record = appState.latestTranscript {
                HStack {
                    Text("Latest dictation").font(.system(size: 11, weight: .medium)).foregroundStyle(FlowStyle.muted)
                    Spacer()
                    FlowCopyButton(text: record.text, compact: true, copy: appState.copy).buttonStyle(.plain)
                }
                Text(record.text).font(.system(size: 13)).lineLimit(2)
            } else {
                Text("Your latest words will appear here.").font(.callout).foregroundStyle(FlowStyle.muted)
            }
            Divider()
            HStack {
                Label(appState.isMeetingCapturing ? "Meeting is recording" : "Meeting recording", systemImage: "person.2.wave.2")
                    .font(.system(size: 12))
                Spacer()
                Button(appState.isMeetingCapturing ? "Stop" : "Record") { appState.toggleMeetingCapture() }
                    .disabled(appState.isMeetingCaptureTransitioning || (!appState.isAtlasPaired && !appState.isMeetingCapturing))
                    .tint(appState.isMeetingCapturing ? FlowStyle.recording : FlowStyle.accent)
            }
            if !appState.retryQueue.isEmpty {
                Button("Retry \(CountPhrase.of(appState.retryQueue.count, "failed recording"))") { appState.retryAllFailed() }
                    .font(.caption)
            }
            HStack {
                Button("Open WhiskerFlow") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                }.buttonStyle(FlowPrimaryButtonStyle())
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }.help("Settings")
                Menu {
                    CheckForUpdatesButton(updaterService: updaterService)
                    RunSetupAgainButton(appState: appState)
                    Divider()
                    Button("Quit WhiskerFlow") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
            }
        }
        .onAppear { appState.refreshSecureInputNotice() }
        .modifier(OnboardingWindow.Presenter(onboarding: appState.onboarding))
        .padding(21).frame(width: 350)
        .background(FlowStyle.canvas).foregroundStyle(FlowStyle.ink).tint(FlowStyle.accent)
    }
}

/// Why the shortcut does nothing while another app has Secure Event Input on.
struct SecureInputNotice: View {
    var body: some View {
        Label(SecureInputMonitor.notice, systemImage: "lock.fill")
            .font(.callout)
            .foregroundStyle(FlowStyle.warning)
            .fixedSize(horizontal: false, vertical: true)
            .help("Another app, such as a password field or a terminal with Secure Keyboard Entry, is hiding keystrokes from other apps. The shortcut works again when it turns Secure Input off.")
    }
}
