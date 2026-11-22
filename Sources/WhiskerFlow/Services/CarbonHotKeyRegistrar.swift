import Carbon.HIToolbox
import Foundation
import Logging
import WhiskerFlowCore

/// Registers WhiskerFlow's shortcuts as system hot keys with Carbon's
/// `RegisterEventHotKey`. macOS then consumes exactly those key combinations
/// and sends WhiskerFlow `kEventHotKeyPressed` / `kEventHotKeyReleased`;
/// every other key press goes straight to the front app and never passes
/// through WhiskerFlow. There is no event tap.
///
/// What is registered when is decided by `RegisteredShortcutController`; this
/// type only makes the Carbon calls. Hot keys are registered non-exclusively
/// (`kEventHotKeyNoOptions`), so WhiskerFlow never takes a key away from
/// another app that registered it too.
///
/// The event handler is installed on the application event target, so it runs
/// on the main thread as part of normal event dispatch, with no extra hop.
@MainActor
final class CarbonHotKeyRegistrar: ShortcutRegistrar {
    /// Called for every hot key event: the shortcut, whether it was pressed,
    /// and the key press's time in seconds since boot.
    var onEvent: ((RegisteredShortcut, Bool, TimeInterval) -> Void)?

    /// "WFHK", so events for another component's hot keys are ignored.
    private static let signature: OSType = 0x5746_484B
    private var hotKeys: [RegisteredShortcut: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private let logger = Logging.Logger(label: "agency.thatworks.WhiskerFlow.DictationLifecycle")

    func register(_ shortcut: RegisteredShortcut, combo: KeyCombo) -> Bool {
        unregister(shortcut)
        guard installHandlerIfNeeded() else { return false }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(combo.keyCode),
            Self.carbonModifiers(combo.modifiers),
            EventHotKeyID(signature: Self.signature, id: shortcut.rawValue),
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyNoOptions),
            &ref
        )
        guard status == noErr, let ref else {
            logger.info("Shortcut not registered; observing it instead", metadata: [
                "event": "shortcut_registration", "shortcut": "\(shortcut)", "status": "\(status)"
            ])
            return false
        }
        hotKeys[shortcut] = ref
        return true
    }

    func unregister(_ shortcut: RegisteredShortcut) {
        guard let ref = hotKeys.removeValue(forKey: shortcut) else { return }
        UnregisterEventHotKey(ref)
    }

    /// Unregisters every hot key and removes the event handler, which holds
    /// an unretained pointer to this object. Call before releasing it.
    func invalidate() {
        for shortcut in Array(hotKeys.keys) { unregister(shortcut) }
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        onEvent = nil
    }

    /// Carbon's modifier bits. There is no fn bit, which is why a combination
    /// with fn/Globe is never registered.
    static func carbonModifiers(_ modifiers: KeyModifiers) -> UInt32 {
        var carbon = 0
        if modifiers.contains(.command) { carbon |= cmdKey }
        if modifiers.contains(.shift) { carbon |= shiftKey }
        if modifiers.contains(.option) { carbon |= optionKey }
        if modifiers.contains(.control) { carbon |= controlKey }
        return UInt32(carbon)
    }

    private func installHandlerIfNeeded() -> Bool {
        guard handler == nil else { return true }
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let status = InstallEventHandler(
            GetApplicationEventTarget(), carbonHotKeyHandler, types.count, &types,
            Unmanaged.passUnretained(self).toOpaque(), &handler
        )
        guard status == noErr else {
            logger.info("Hot key handler not installed; observing shortcuts instead", metadata: [
                "event": "shortcut_registration", "status": "\(status)"
            ])
            handler = nil
            return false
        }
        return true
    }

    fileprivate func handle(_ event: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
        )
        guard status == noErr, hotKeyID.signature == Self.signature,
              let shortcut = RegisteredShortcut(rawValue: hotKeyID.id) else {
            return OSStatus(eventNotHandledErr)
        }
        onEvent?(shortcut, GetEventKind(event) == UInt32(kEventHotKeyPressed), GetEventTime(event))
        return noErr
    }
}

private func carbonHotKeyHandler(
    _: EventHandlerCallRef?, event: EventRef?, userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    // Installed on the application event target, so this runs on the main thread.
    return MainActor.assumeIsolated {
        Unmanaged<CarbonHotKeyRegistrar>.fromOpaque(userData).takeUnretainedValue().handle(event)
    }
}
