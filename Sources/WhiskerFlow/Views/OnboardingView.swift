import AppKit
import SwiftUI

struct OnboardingView: View {
    @Bindable var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    private var permissionsReady: Bool { appState.hasMicrophonePermission && appState.hasAccessibilityPermission }

    var body: some View {
        VStack(spacing: 26) {
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<3) { index in Capsule().fill(index <= step ? FlowStyle.accent : FlowStyle.line).frame(width: 23, height: 4) }
                }.accessibilityLabel("Setup step \(step + 1) of 3")
                Spacer()
                Button("Set up later") { dismiss() }.buttonStyle(.plain).foregroundStyle(FlowStyle.muted)
            }
            Spacer(minLength: 0)
            FlowWaveform(size: 52)
            Text(heading).font(.system(size: 30, weight: .semibold, design: .rounded)).tracking(-0.6)
            Text(detail).font(.system(size: 14)).foregroundStyle(FlowStyle.muted)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)

            if step == 0 {
                HStack(spacing: 12) {
                    Text(DictationPresentation(appState: appState).gesture)
                    FlowKeycap(title: appState.settings.hotkeyDisplayName)
                    Text("to dictate")
                }.font(.system(size: 19))
            } else if step == 1 {
                VStack(spacing: 12) {
                    permissionRow("Microphone", detail: "So WhiskerFlow can hear you.", symbol: "mic", granted: appState.hasMicrophonePermission) {
                        switch appState.microphonePermission.recoveryAction {
                        case .request: Task { await appState.requestMicrophonePermission() }
                        case .openSettings: Self.openSettings("Privacy_Microphone")
                        case nil: break
                        }
                    }
                    permissionRow("Accessibility", detail: "For your shortcut and pasting at the cursor.", symbol: "keyboard", granted: appState.hasAccessibilityPermission) {
                        appState.requestAccessibilityPermission()
                        Self.openSettings("Privacy_Accessibility")
                    }
                    Button("Check again") {
                        appState.refreshMicrophonePermission()
                        appState.refreshAccessibilityPermission()
                    }.buttonStyle(.plain).foregroundStyle(FlowStyle.accent).font(.caption).padding(.top, 4)
                }
            } else {
                FlowStatus(title: DictationPresentation(appState: appState).statusTitle,
                           color: DictationPresentation(appState: appState).statusColor)
                Text(DictationPresentation(appState: appState).deliveryDescription)
                    .font(.callout).foregroundStyle(FlowStyle.muted).multilineTextAlignment(.center)
            }
            Spacer(minLength: 0)
            HStack {
                if step > 0 { Button("Back") { step -= 1 }.buttonStyle(.plain).foregroundStyle(FlowStyle.muted) }
                Spacer()
                Button(step == 2 ? "Start using WhiskerFlow" : "Continue") {
                    if step == 2 {
                        dismiss()
                    } else {
                        step += 1
                    }
                }.buttonStyle(FlowPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(step == 1 && !permissionsReady)
            }
        }
        .padding(32).frame(width: 550, height: 560)
        .background(FlowStyle.canvas).foregroundStyle(FlowStyle.ink).tint(FlowStyle.accent)
    }

    private var heading: String {
        switch step {
        case 0: return "A little less typing."
        case 1: return "Two small permissions."
        default: return appState.modelState == .ready ? "Your words can go anywhere." : "Almost ready for your voice."
        }
    }
    private var detail: String {
        switch step {
        case 0: return "Speak naturally in any app. WhiskerFlow turns your voice into text, right where you’re working."
        case 1: return "Enable access below, then come back here. You can set up meeting recording separately."
        default: return appState.modelState == .ready ? "Open an app, place your cursor, and try your shortcut." : "You can use the app while transcription finishes preparing. Check Dictate for its status."
        }
    }

    private func permissionRow(_ title: String, detail: String, symbol: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 21)).frame(width: 28).foregroundStyle(FlowStyle.accent)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(FlowStyle.muted)
            }
            Spacer()
            if granted { Label("Enabled", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
            else { Button("Enable", action: action) }
        }.padding(17).background(FlowStyle.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    static func openSettings(_ anchor: String) {
        guard !UIPreview.isEnabled else { return }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(url) }
    }
}
