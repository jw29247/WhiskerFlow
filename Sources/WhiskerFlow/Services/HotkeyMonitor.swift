import AppKit
import WhiskerFlowCore

/// Watches for the configured push-to-talk key globally and locally, reporting
/// pressed/released transitions. Mode (hold vs toggle) is interpreted by the caller.
///
/// All matching logic lives in `HotkeyMatcher`; this type just translates
/// `NSEvent`s into matcher calls and emits the resulting transitions.
@MainActor
final class HotkeyMonitor {
    private let onChange: (Bool) -> Void
    private var matcher: HotkeyMatcher
    private var isSuspended = false
    private var flagsLocalMonitor: Any?
    private var flagsGlobalMonitor: Any?
    private var keyLocalMonitor: Any?
    private var keyGlobalMonitor: Any?

    init(combo: KeyCombo, onChange: @escaping (Bool) -> Void) {
        self.matcher = HotkeyMatcher(combo: combo)
        self.onChange = onChange
    }

    func update(combo: KeyCombo) {
        emitIfChanged(matcher.update(combo: combo))
    }

    /// Pause matching while the user records a new shortcut, so the keys they
    /// press to record can't also trigger a real dictation session.
    func setSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        if suspended { emitIfChanged(matcher.reset()) }
    }

    func start() {
        flagsLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlags(event)
            return event
        }
        flagsGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in self?.handleFlags(event) }
        }
        keyLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.handleKey(event)
            return event
        }
        keyGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            Task { @MainActor in self?.handleKey(event) }
        }
    }

    func stop() {
        for monitor in [flagsLocalMonitor, flagsGlobalMonitor, keyLocalMonitor, keyGlobalMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        flagsLocalMonitor = nil
        flagsGlobalMonitor = nil
        keyLocalMonitor = nil
        keyGlobalMonitor = nil
    }

    private func handleFlags(_ event: NSEvent) {
        guard !isSuspended else { return }
        let modifiers = KeyModifiers(rawValue: UInt(event.modifierFlags.rawValue))
        emitIfChanged(matcher.handleFlags(keyCode: event.keyCode, modifiers: modifiers))
    }

    private func handleKey(_ event: NSEvent) {
        guard !isSuspended else { return }
        let modifiers = KeyModifiers(rawValue: UInt(event.modifierFlags.rawValue))
        emitIfChanged(matcher.handleKey(
            keyCode: event.keyCode,
            modifiers: modifiers,
            isKeyDown: event.type == .keyDown,
            isRepeat: event.isARepeat
        ))
    }

    private func emitIfChanged(_ pressed: Bool?) {
        if let pressed { onChange(pressed) }
    }
}
