import SwiftUI

struct ControlPanelView: View {
    @Bindable var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if !appState.hasAccessibilityPermission {
                    accessibilitySection
                    Divider()
                }
                Divider()
                inputSection
                Divider()
                retrySection
                Divider()
                whisperSection
                Divider()
                latestSection
                Spacer(minLength: 0)
            }
            .padding(26)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    appState.refreshDevices()
                } label: {
                    Label("Refresh Microphones", systemImage: "arrow.clockwise")
                }
                .help("Refresh Microphones")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WhiskerFlow")
                .font(.system(size: 28, weight: .bold, design: .rounded))

            Label(appState.statusMessage, systemImage: appState.isRecording ? "waveform.circle.fill" : "fn")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundStyle(appState.isRecording ? .red : .primary)

            Text("Hold fn to record. Release fn to transcribe with Whisper and paste at the cursor.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Fast mode uses Whisper tiny by default.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Input")
                .font(.headline)

            Picker("Microphone", selection: $appState.selectedDeviceID) {
                ForEach(appState.devices) { device in
                    Text(device.name).tag(device.id)
                }
            }
            .labelsHidden()

            Button {
                appState.refreshDevices()
            } label: {
                Label("Refresh Microphones", systemImage: "arrow.clockwise")
            }

            if appState.devices.isEmpty {
                ContentUnavailableView(
                    "No Microphones",
                    systemImage: "mic.slash",
                    description: Text("Grant microphone access, connect a mic, then refresh.")
                )
                .frame(minHeight: 140)
            }
        }
    }

    private var accessibilitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Auto-paste needs Accessibility permission", systemImage: "keyboard.badge.eye")
                .font(.headline)
                .foregroundStyle(.orange)

            Text("macOS blocks simulated Cmd+V until WhiskerFlow is allowed in Privacy & Security.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                appState.requestAccessibilityPermission()
            } label: {
                Label("Enable Auto-Paste Permission", systemImage: "lock.open")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var retrySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Retry Queue")
                    .font(.headline)
                Spacer()
                Text("\(appState.retryQueue.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Button {
                appState.retryAllFailed()
            } label: {
                Label("Retry Failed Transcripts", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(appState.retryQueue.isEmpty || appState.isTranscribing)

            if let lastError = appState.lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var whisperSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Whisper CLI")
                .font(.headline)

            TextField("Command", text: $appState.whisperCommand)
                .textFieldStyle(.roundedBorder)

            TextField("Arguments", text: $appState.whisperArguments)
                .textFieldStyle(.roundedBorder)

            Text("Default is tiny model for speed. Use {audio} for the recording path and {output} for a temporary output folder.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var latestSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Latest")
                .font(.headline)

            if let latest = appState.latestTranscript {
                Text(latest.text)
                    .lineLimit(5)
                    .textSelection(.enabled)
            } else {
                Text("No successful transcript yet.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
