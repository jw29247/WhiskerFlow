import AppKit
import CoreGraphics
import SwiftUI

struct OnboardingView: View {
    @Bindable var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to WhiskerFlow")
                    .font(.largeTitle.bold())
                Text("Hold \(appState.settings.hotkeyDisplayName) anywhere to dictate. Release to transcribe and paste at your cursor. Grant a couple of permissions to get going.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PermissionRow(
                title: "Microphone",
                detail: appState.microphonePermissionDetail,
                systemImage: "mic.fill",
                granted: appState.hasMicrophonePermission
            ) {
                switch appState.microphonePermission.recoveryAction {
                case .request:
                    Button("Request") {
                        Task { await appState.requestMicrophonePermission() }
                    }
                case .openSettings:
                    Button("Open Microphone Settings") {
                        Self.openSettings("Privacy_Microphone")
                    }
                case nil:
                    EmptyView()
                }
            }

            PermissionRow(
                title: "Accessibility",
                detail: "Lets WhiskerFlow paste transcripts at your cursor.",
                systemImage: "keyboard.badge.eye",
                granted: appState.hasAccessibilityPermission
            ) {
                HStack {
                    Button("Open Settings") {
                        appState.requestAccessibilityPermission()
                        Self.openSettings("Privacy_Accessibility")
                    }
                    Button("Re-check") { appState.refreshAccessibilityPermission() }
                }
            }

            PermissionRow(
                title: "Screen Recording",
                detail: "Required to capture Mac system output. WhiskerFlow retains audio only, never screen frames.",
                systemImage: "rectangle.inset.filled.and.person.filled",
                granted: appState.hasScreenRecordingPermission
            ) {
                HStack {
                    Button("Open Settings") {
                        appState.requestScreenRecordingPermission()
                        Self.openSettings("Privacy_ScreenCapture")
                    }
                    Button("Re-check") { appState.refreshScreenRecordingPermission() }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("Atlas Meeting Capture", systemImage: "person.2.wave.2")
                    .font(.headline)
                Text("Sign in with Atlas so scheduled calls can be recorded locally and uploaded as encrypted chunks. The connection token is stored securely in Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Atlas HTTPS URL", text: $appState.settings.atlasBaseURL)
                    .textFieldStyle(.roundedBorder)
                Button {
                    appState.signInToAtlas()
                } label: {
                    Label(
                        appState.isSigningInToAtlas ? "Opening Atlas…" : "Sign in with Atlas",
                        systemImage: "person.crop.circle.badge.checkmark"
                    )
                }
                .disabled(appState.isSigningInToAtlas)
                if let error = appState.atlasSignInError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Image(systemName: appState.isAtlasPaired ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(appState.isAtlasPaired ? .green : .orange)
                    Text(appState.isAtlasPaired ? "Paired" : "Pairing required")
                        .font(.caption)
                    Spacer()
                    Button("Re-check") { appState.refreshMeetingConfiguration() }
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))

            HStack(spacing: 14) {
                Label(
                    appState.isMeetingStorageAvailable ? "Local storage ready" : "At least 500 MB local storage is required",
                    systemImage: appState.isMeetingStorageAvailable ? "internaldrive.fill" : "externaldrive.badge.xmark"
                )
                .font(.caption)
                .foregroundStyle(appState.isMeetingStorageAvailable ? .green : .orange)
                Spacer()
                Label(
                    appState.meetingModelState == .ready
                        ? "Meeting transcription and diarization ready"
                        : "WhisperKit + SpeakerKit meeting model preparing",
                    systemImage: appState.meetingModelState == .ready
                        ? "checkmark.circle"
                        : "arrow.down.circle"
                )
                .font(.caption)
                .foregroundStyle(appState.meetingModelState == .ready ? .green : .secondary)
            }

            PermissionRow(
                title: "Speech Recognition",
                detail: "Used by the built-in Apple Speech fallback (optional).",
                systemImage: "waveform.badge.mic",
                granted: nil
            ) {
                Button("Allow") { Task { _ = await appState.requestSpeechPermission() } }
            }

            Spacer(minLength: 0)

            HStack {
                Text("Meeting Mode downloads a larger local WhisperKit model and SpeakerKit assets; processing stays on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 560, height: 700)
    }

    static func openSettings(_ anchor: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
        if let url { NSWorkspace.shared.open(url) }
    }
}

private struct PermissionRow<Actions: View>: View {
    let title: String
    let detail: String
    let systemImage: String
    let granted: Bool?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title2)
                .frame(width: 32)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let granted, granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.iconOnly)
                    .font(.title2)
            } else {
                actions()
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }
}
