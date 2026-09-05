import AppKit
import Observation
import SwiftUI

/// AppKit supplies macOS 14 nonactivating panel behavior; the capture controller
/// remains the single source of truth and the only activity-analysis owner.
@MainActor
final class MeetingCoachHUDController {
    private let controller: MeetingAssistantController
    private var panel: PrivateCoachPanel?

    init(controller: MeetingAssistantController) {
        self.controller = controller
        observeVisibility()
    }

    private func observeVisibility() {
        let visible = withObservationTracking {
            controller.shouldShowHUD
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeVisibility() }
        }
        if visible {
            if panel == nil { createPanel() }
            panel?.orderFrontRegardless()
        } else {
            panel?.orderOut(nil)
            panel = nil
        }
    }

    private func createPanel() {
        let panel = PrivateCoachPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 280),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.title = "Private meeting coach"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.sharingType = .none
        panel.contentView = NSHostingView(rootView: MeetingCoachHUDView(controller: controller) { [weak panel] size in
            guard let panel, size.height > 0 else { return }
            let top = panel.frame.maxY
            panel.setContentSize(size)
            panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: top - panel.frame.height))
        })
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let bounds = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: bounds.maxX - 360, y: bounds.maxY - 310))
        }
        self.panel = panel
    }
}

private final class PrivateCoachPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct MeetingCoachHUDView: View {
    @Bindable var controller: MeetingAssistantController
    let sizeChanged: (CGSize) -> Void
    @State private var bookmarkFeedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Private coach").font(.headline)
                Spacer()
                Text(MeetingCoachView.duration(controller.elapsedSeconds)).monospacedDigit()
                Button { controller.isCoachVisible = false } label: {
                    Image(systemName: "xmark")
                }.buttonStyle(.plain).accessibilityLabel("Hide coach")
            }
            Text(controller.activeTitle ?? "Meeting").font(.subheadline).lineLimit(1)
            if !controller.goal.isEmpty {
                Text(controller.goal).font(.callout).lineLimit(2)
            }
            if !controller.agenda.isEmpty {
                Text(controller.agenda).font(.caption).lineLimit(2).foregroundStyle(FlowStyle.muted)
            }
            if let end = controller.plannedEndAt {
                Text("Planned end: \(end.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(FlowStyle.muted)
            }
            if controller.isCoachPaused {
                Text("Coaching paused · recording continues").font(.caption)
            } else {
                Text("Own-mic estimate: \(Int(controller.activity.ownMicActiveSeconds))s / \(Int(controller.activity.windowDurationSeconds))s")
                    .font(.caption)
                Text(MeetingCoachView.certaintyLabel(controller.activity.certainty))
                    .font(.caption2).foregroundStyle(FlowStyle.muted)
                if let prompt = controller.livePrompt {
                    Text(prompt).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Button("Dismiss reminder") { controller.dismissPrompt() }.font(.caption)
                }
            }
            HStack {
                Button(controller.isCoachPaused ? "Resume" : "Pause") { controller.isCoachPaused.toggle() }
                Button("Bookmark") {
                    do {
                        let bookmark = try controller.addBookmark(label: nil)
                        bookmarkFeedback = "Bookmarked at \(MeetingCoachView.duration(Double(bookmark.elapsedMilliseconds) / 1_000))"
                    } catch { bookmarkFeedback = "Bookmark could not be saved" }
                }
                Spacer()
                Button("Hide") { controller.isCoachVisible = false }
            }.controlSize(.small)
            if let bookmarkFeedback { Text(bookmarkFeedback).font(.caption).foregroundStyle(FlowStyle.muted) }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
        .foregroundStyle(FlowStyle.ink)
        .background(FlowStyle.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(FlowStyle.line))
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { proxy in
            Color.clear.onAppear { sizeChanged(proxy.size) }
                .onChange(of: proxy.size) { _, size in sizeChanged(size) }
        })
    }
}
