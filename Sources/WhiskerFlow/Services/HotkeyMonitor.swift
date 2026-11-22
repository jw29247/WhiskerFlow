import AppKit
import ApplicationServices
import Logging
import WhiskerFlowCore

/// Watches for the configured push-to-talk key globally and locally, reporting
/// pressed/released transitions. Mode (hold vs toggle) is interpreted by the caller.
///
/// All matching logic lives in `HotkeyMatcher`; this type just translates
/// `NSEvent`s into matcher calls and emits the resulting transitions.
@MainActor
final class HotkeyMonitor {
    private let onChange: (Bool) -> Void
    /// Called on a plain Escape press, for discarding a dictation in progress.
    /// The key events are already observed for the shortcut, so this adds a
    /// comparison per key event and no extra monitor.
    var onDiscardKey: (() -> Void)?
    private var matcher: HotkeyMatcher
    private var isSuspended = false
    /// While an event tap swallows this shortcut, the tap is its only source:
    /// a swallowed event may or may not still reach the monitors, and one
    /// source means a press can never be counted twice.
    private var isDrivenByTap = false
    private var flagsLocalMonitor: Any?
    private var flagsGlobalMonitor: Any?
    private var keyLocalMonitor: Any?
    private var keyGlobalMonitor: Any?
    private var trustObserver: NSObjectProtocol?
    private var trustPoll: Timer?
    private let logger = Logging.Logger(label: "agency.thatworks.WhiskerFlow.DictationLifecycle")

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

    /// Hand matching to (or take it back from) `ShortcutEventTap`. The matcher
    /// and any press in progress carry over, so switching never drops a release.
    func setDrivenByTap(_ driven: Bool) {
        isDrivenByTap = driven
    }

    /// An event the tap saw, for a shortcut the tap drives.
    func feed(_ event: ShortcutEventTap.Event) {
        guard isDrivenByTap, !isSuspended else { return }
        let pressed: Bool?
        switch event.kind {
        case .flagsChanged:
            pressed = matcher.handleFlags(keyCode: event.keyCode, modifiers: event.modifiers)
        case .keyDown, .keyUp:
            pressed = matcher.handleKey(keyCode: event.keyCode, modifiers: event.modifiers,
                                        isKeyDown: event.kind == .keyDown, isRepeat: event.isRepeat)
        }
        guard let pressed else { return }
        logger.info("Configured hotkey transition received", metadata: [
            "event": "hotkey_transition", "event_source": "tap", "pressed": "\(pressed)",
            "app_active": "\(NSApp?.isActive ?? false)",
            "elapsed_ms": "\(max(0, ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000)"
        ])
        onChange(pressed)
    }

    func start() {
        stop()
        flagsLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlags(event, source: "local")
            return event
        }
        keyLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.handleKey(event, source: "local")
            return event
        }
        installGlobalMonitors()
        // Global key monitors only receive events if the process was trusted
        // when they were created. Re-create them once Accessibility is granted,
        // so a first-run grant works without relaunching.
        if !AXIsProcessTrusted() { watchForAccessibilityGrant() }
    }

    func stop() {
        for monitor in [flagsLocalMonitor, flagsGlobalMonitor, keyLocalMonitor, keyGlobalMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        flagsLocalMonitor = nil
        flagsGlobalMonitor = nil
        keyLocalMonitor = nil
        keyGlobalMonitor = nil
        stopWatchingAccessibility()
    }

    private func installGlobalMonitors() {
        for monitor in [flagsGlobalMonitor, keyGlobalMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        flagsGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in self?.handleFlags(event, source: "global") }
        }
        keyGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            Task { @MainActor in self?.handleKey(event, source: "global") }
        }
    }

    /// `AXIsProcessTrusted` is a cheap local check. The distributed notification
    /// usually arrives as the user flips the switch; the slow poll covers the
    /// cases where it does not, and both stop as soon as the grant is seen.
    private func watchForAccessibilityGrant() {
        guard trustPoll == nil else { return }
        trustObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            // The trust database is updated just after the notification is posted.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { self?.rearmIfTrusted() }
            }
        }
        trustPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rearmIfTrusted() }
        }
    }

    private func rearmIfTrusted() {
        guard trustPoll != nil, AXIsProcessTrusted() else { return }
        stopWatchingAccessibility()
        installGlobalMonitors()
    }

    private func stopWatchingAccessibility() {
        trustPoll?.invalidate()
        trustPoll = nil
        if let trustObserver { DistributedNotificationCenter.default().removeObserver(trustObserver) }
        trustObserver = nil
    }

    private func handleFlags(_ event: NSEvent, source: String) {
        guard !isSuspended, !isDrivenByTap else { return }
        let modifiers = KeyModifiers(rawValue: UInt(event.modifierFlags.rawValue))
        emitIfChanged(matcher.handleFlags(keyCode: event.keyCode, modifiers: modifiers), event: event, source: source)
    }

    private func handleKey(_ event: NSEvent, source: String) {
        guard !isSuspended else { return }
        let modifiers = KeyModifiers(rawValue: UInt(event.modifierFlags.rawValue))
        let isKeyDown = event.type == .keyDown
        if !isDrivenByTap {
            emitIfChanged(matcher.handleKey(
                keyCode: event.keyCode,
                modifiers: modifiers,
                isKeyDown: isKeyDown,
                isRepeat: event.isARepeat
            ), event: event, source: source)
        }
        // Discarding is idempotent, so seeing an Esc the tap also handled is harmless.
        if let onDiscardKey, HotkeyMatcher.isDiscardPress(
            keyCode: event.keyCode, modifiers: modifiers, isKeyDown: isKeyDown, isRepeat: event.isARepeat
        ) {
            onDiscardKey()
        }
    }

    private func emitIfChanged(_ pressed: Bool?, event: NSEvent? = nil, source: String = "local") {
        guard let pressed else { return }
        if let event {
            logger.info("Configured hotkey transition received", metadata: [
                "event": "hotkey_transition", "event_source": "\(source)", "pressed": "\(pressed)",
                "app_active": "\(NSApp.isActive)",
                "elapsed_ms": "\(max(0, ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000)"
            ])
        }
        onChange(pressed)
    }
}
