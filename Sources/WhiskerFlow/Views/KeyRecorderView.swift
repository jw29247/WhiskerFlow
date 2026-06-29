import AppKit
import SwiftUI
import WhiskerFlowCore

/// A shortcut-recorder control. Click to arm it, then press any key (with at
/// least one modifier, or a function key on its own) or tap a single modifier
/// key. Escape cancels.
struct KeyRecorderView: View {
    @Binding var combo: KeyCombo
    /// Called after a new combo is committed, so callers can reload the monitor.
    var onChange: () -> Void
    /// Called when recording starts/stops, so the caller can suspend the live
    /// hotkey while keys are being captured.
    var onRecordingChange: (Bool) -> Void = { _ in }

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var showHint = false
    /// The modifier key currently held alone, if any, while recording — used to
    /// commit a modifier-only shortcut when it is released without another key.
    @State private var pendingModifier: (keyCode: UInt16, flag: KeyModifiers)?

    private static let escapeKeyCode: UInt16 = 53

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: toggle) {
                HStack {
                    Text(isRecording ? "Press keys… (Esc to cancel)" : combo.displayName)
                        .foregroundStyle(isRecording ? .secondary : .primary)
                    Spacer()
                    Image(systemName: isRecording ? "record.circle" : "pencil")
                        .foregroundStyle(isRecording ? .red : .secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)

            if isRecording && showHint {
                Text("Add a modifier (⌘/⌥/⌃/⇧) or use a function key.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func toggle() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        isRecording = true
        showHint = false
        pendingModifier = nil
        onRecordingChange(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event)
            // Swallow the event so it doesn't type into the focused field or beep.
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if isRecording { onRecordingChange(false) }
        isRecording = false
        showHint = false
        pendingModifier = nil
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            let mods = KeyModifiers(rawValue: UInt(event.modifierFlags.rawValue))
                .intersection(.comboMask)
            // Plain Escape cancels; Escape with modifiers is a valid shortcut.
            if event.keyCode == Self.escapeKeyCode, mods.isEmpty {
                stopRecording()
                return
            }
            let candidate = KeyCombo(keyCode: event.keyCode, modifiers: mods, isModifierOnly: false)
            guard candidate.isUsableAsGlobalHotkey else {
                // Bare key without a modifier would fire on every keystroke —
                // keep recording and prompt for a safer combination.
                showHint = true
                return
            }
            commit(candidate)
        case .flagsChanged:
            guard let entry = KeyCombo.modifierKeys[event.keyCode], !entry.flag.isEmpty else { return }
            let flags = KeyModifiers(rawValue: UInt(event.modifierFlags.rawValue))
            if flags.contains(entry.flag) {
                // Only a single modifier held alone can become a modifier-only
                // shortcut; a chord of modifiers is ambiguous, so clear it.
                let others = flags.intersection(.all).subtracting(entry.flag)
                pendingModifier = others.isEmpty ? (event.keyCode, entry.flag) : nil
            } else if pendingModifier?.keyCode == event.keyCode {
                // Released on its own → modifier-only shortcut.
                commit(KeyCombo(keyCode: event.keyCode, modifiers: entry.flag, isModifierOnly: true))
            }
        default:
            break
        }
    }

    private func commit(_ newCombo: KeyCombo) {
        combo = newCombo
        stopRecording()
        onChange()
    }
}
