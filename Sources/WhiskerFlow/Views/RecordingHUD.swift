import AppKit
import SwiftUI

/// The content shown inside the floating HUD panel.
struct RecordingHUDView: View {
    @Bindable var appState: AppState

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                if appState.isRecording, !appState.liveText.isEmpty {
                    // Live transcript, most-recent words kept visible.
                    Text(appState.liveText)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(2)
                        .truncationMode(.head)
                        .frame(maxWidth: 320, alignment: .leading)
                } else if appState.isRecording {
                    TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                        Text(elapsedString)
                            .font(.system(size: 11, weight: .regular).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.7))
                    }
                } else {
                    Text("WhiskerFlow")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            if appState.isRecording {
                LevelMeter(level: appState.audioLevel, tint: .white)
            } else if appState.isTranscribing {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.82))
                .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.12)))
        )
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        .fixedSize()
    }

    private var icon: some View {
        Image(systemName: appState.isRecording ? "waveform" : "ellipsis")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(appState.isRecording ? Color.red : Color.white)
            .symbolEffect(.variableColor.iterative, isActive: appState.isTranscribing)
    }

    private var title: String {
        if appState.isRecording { return "Listening…" }
        if appState.isTranscribing { return "Transcribing…" }
        return appState.statusMessage
    }

    private var elapsedString: String {
        let total = Int(appState.recordingElapsed)
        return String(format: "%01d:%02d", total / 60, total % 60)
    }
}

/// Owns a non-activating floating panel and shows/hides it as recording state changes.
@MainActor
final class RecordingHUDController {
    private unowned let appState: AppState
    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    init(appState: AppState) {
        self.appState = appState
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = appState.isRecording
            _ = appState.isTranscribing
            // Re-fit the panel as the live transcript grows.
            _ = appState.liveText
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateVisibility()
                self?.observe()
            }
        }
        updateVisibility()
    }

    private func updateVisibility() {
        if appState.isRecording || appState.isTranscribing {
            show()
        } else {
            scheduleHide()
        }
    }

    private func makePanelIfNeeded() -> NSPanel {
        if let panel { return panel }

        let hosting = NSHostingView(rootView: RecordingHUDView(appState: appState))
        hosting.frame = NSRect(x: 0, y: 0, width: 260, height: 56)

        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    private func show() {
        hideWorkItem?.cancel()
        let panel = makePanelIfNeeded()
        positionNearBottomCenter(panel)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    private func scheduleHide() {
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.panel?.orderOut(nil)
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
    }

    private func positionNearBottomCenter(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        panel.layoutIfNeeded()
        let size = panel.contentView?.fittingSize ?? NSSize(width: 260, height: 56)
        panel.setContentSize(size)
        let frame = screen.visibleFrame
        let x = frame.midX - size.width / 2
        let y = frame.minY + 90
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
