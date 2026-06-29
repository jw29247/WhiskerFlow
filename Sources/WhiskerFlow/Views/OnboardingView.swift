import AppKit
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
                detail: "Needed to record your voice.",
                systemImage: "mic.fill",
                granted: appState.hasMicrophonePermission
            ) {
                Button("Allow") { Task { await appState.requestMicrophonePermission() } }
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
                title: "Speech Recognition",
                detail: "Used by the built-in Apple Speech fallback (optional).",
                systemImage: "waveform.badge.mic",
                granted: nil
            ) {
                Button("Allow") { Task { _ = await appState.requestSpeechPermission() } }
            }

            Spacer(minLength: 0)

            HStack {
                Text("The first WhisperKit transcription downloads a model (~150 MB).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 540, height: 460)
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
