import AppKit
import WhiskerFlowCore

/// Watches for the configured push-to-talk key globally and locally, reporting
/// pressed/released transitions. Mode (hold vs toggle) is interpreted by the caller.
@MainActor
final class HotkeyMonitor {
    private let onChange: (Bool) -> Void
    private var trigger: HotkeyTrigger
    private var flagsLocalMonitor: Any?
    private var flagsGlobalMonitor: Any?
    private var keyLocalMonitor: Any?
    private var keyGlobalMonitor: Any?
    private var isPressed = false

    // Virtual key codes.
    private static let fnKey: UInt16 = 63
    private static let rightCommandKey: UInt16 = 54
    private static let rightOptionKey: UInt16 = 61
    private static let f5Key: UInt16 = 96

    init(trigger: HotkeyTrigger, onChange: @escaping (Bool) -> Void) {
        self.trigger = trigger
        self.onChange = onChange
    }

    func update(trigger: HotkeyTrigger) {
        guard trigger != self.trigger else { return }
        self.trigger = trigger
        if isPressed {
            isPressed = false
            onChange(false)
        }
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

    deinit {
        for monitor in [flagsLocalMonitor, flagsGlobalMonitor, keyLocalMonitor, keyGlobalMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }

    private func handleFlags(_ event: NSEvent) {
        let pressed: Bool
        switch trigger {
        case .fn:
            // Require the actual fn/Globe key — the .function flag alone is also
            // set by arrow/F keys, which would cause false triggers.
            guard event.keyCode == Self.fnKey else { return }
            pressed = event.modifierFlags.contains(.function)
        case .rightCommand:
            guard event.keyCode == Self.rightCommandKey else { return }
            pressed = event.modifierFlags.contains(.command)
        case .rightOption:
            guard event.keyCode == Self.rightOptionKey else { return }
            pressed = event.modifierFlags.contains(.option)
        case .f5:
            return
        }
        emit(pressed)
    }

    private func handleKey(_ event: NSEvent) {
        guard trigger == .f5, event.keyCode == Self.f5Key else { return }
        guard !event.isARepeat else { return }
        emit(event.type == .keyDown)
    }

    private func emit(_ pressed: Bool) {
        guard pressed != isPressed else { return }
        isPressed = pressed
        onChange(pressed)
    }
}
