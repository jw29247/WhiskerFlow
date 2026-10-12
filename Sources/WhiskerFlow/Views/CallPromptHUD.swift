import AppKit
import Observation
import SwiftUI
import WhiskerFlowAppSupport

/// Shows "Record this meeting?" in a small floating panel when a call starts.
/// Like the coach HUD it never takes focus from the call, and it is excluded
/// from screen sharing.
@MainActor
final class CallPromptHUDController {
    private let appState: AppState
    private var panel: CallPromptPanel?
    static let panelTitle = "Record this meeting?"

    init(appState: AppState) {
        self.appState = appState
        observe()
    }

    private func observe() {
        let prompt = withObservationTracking {
            appState.callPrompt
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }
        if let prompt {
            if panel == nil { createPanel() }
            panel?.contentView = NSHostingView(rootView: CallPromptView(prompt: prompt, appState: appState))
            position()
            panel?.orderFrontRegardless()
        } else {
            panel?.orderOut(nil)
            panel = nil
        }
    }

    private func createPanel() {
        let panel = CallPromptPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 150),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.title = Self.panelTitle
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.sharingType = .none
        self.panel = panel
    }

    private func position() {
        guard let panel, let content = panel.contentView else { return }
        let size = content.fittingSize
        panel.setContentSize(size)
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let bounds = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: bounds.maxX - size.width - 20, y: bounds.maxY - size.height - 20))
        }
    }
}

private final class CallPromptPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct CallPromptView: View {
    let prompt: DetectedCallPrompt
    let appState: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "record.circle")
                .font(.system(size: 22)).foregroundStyle(FlowStyle.recording)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(prompt.call.platform.displayName) call detected").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(FlowStyle.muted)
                    Spacer()
                    Button { appState.declineCallPrompt() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(FlowStyle.muted).accessibilityLabel("Not now")
                }
                if prompt.intent != nil {
                    Text(prompt.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                }
                Text("Record this meeting?").font(.system(size: 14, weight: prompt.intent == nil ? .semibold : .regular))
                HStack(spacing: 8) {
                    Button("Record") { appState.acceptCallPrompt() }
                        .buttonStyle(FlowPrimaryButtonStyle())
                    Button("Not now") { appState.declineCallPrompt() }
                }.controlSize(.small).padding(.top, 2)
                Text("Recorded and transcribed on this Mac. Stops when the call ends.")
                    .font(.caption2).foregroundStyle(FlowStyle.muted)
            }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
        .foregroundStyle(FlowStyle.ink)
        .background(FlowStyle.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(FlowStyle.line))
        .fixedSize(horizontal: false, vertical: true)
    }
}
