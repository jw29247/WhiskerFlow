import Foundation

/// Pure state machine that turns raw key/modifier events into push-to-talk
/// pressed/released transitions for a given `KeyCombo`. Kept free of AppKit so
/// the matching rules — including the tricky release edge cases — are unit
/// testable; `HotkeyMonitor` is the thin `NSEvent` adapter around it.
public struct HotkeyMatcher {
    public private(set) var combo: KeyCombo
    public private(set) var isPressed = false

    public init(combo: KeyCombo) {
        self.combo = combo
    }

    /// Swap in a new combo. Returns `false` if an in-flight press had to be
    /// released because the trigger changed, otherwise `nil`.
    public mutating func update(combo: KeyCombo) -> Bool? {
        guard combo != self.combo else { return nil }
        self.combo = combo
        return reset()
    }

    /// Force the matcher back to released (e.g. when monitoring is suspended).
    public mutating func reset() -> Bool? {
        isPressed ? transition(to: false) : nil
    }

    /// Feed a modifier-flags-changed event. `modifiers` is the full, unmasked
    /// device-independent modifier state. Returns the new pressed state if it
    /// changed, else `nil`.
    public mutating func handleFlags(keyCode: UInt16, modifiers: KeyModifiers) -> Bool? {
        if combo.isModifierOnly {
            if keyCode == combo.keyCode {
                return transition(to: modifiers.contains(combo.modifiers))
            }
            // The shared flag (e.g. ⌘ exists on both sides) cleared via the
            // mirror key while we were held — treat that as a release so the
            // trigger can't get stuck on.
            if isPressed, !modifiers.contains(combo.modifiers) {
                return transition(to: false)
            }
            return nil
        }

        // Regular-key combo: macOS suppresses keyUp for ordinary keys while ⌘ is
        // held, so a required modifier going up is our reliable release signal.
        guard isPressed else { return nil }
        let required = combo.modifiers.intersection(.comboMask)
        if !modifiers.intersection(.comboMask).isSuperset(of: required) {
            return transition(to: false)
        }
        return nil
    }

    /// Feed a key-down/up event. Returns the new pressed state if it changed.
    public mutating func handleKey(
        keyCode: UInt16,
        modifiers: KeyModifiers,
        isKeyDown: Bool,
        isRepeat: Bool
    ) -> Bool? {
        guard !combo.isModifierOnly, keyCode == combo.keyCode else { return nil }
        if isKeyDown {
            guard !isRepeat else { return nil }
            // All required modifiers — and no others — must be held on press.
            let required = combo.modifiers.intersection(.comboMask)
            guard modifiers.intersection(.comboMask) == required else { return nil }
            return transition(to: true)
        }
        // Release only needs the key itself, so letting go of modifiers first
        // (or the key first) both end the press.
        return transition(to: false)
    }

    private mutating func transition(to pressed: Bool) -> Bool? {
        guard pressed != isPressed else { return nil }
        isPressed = pressed
        return pressed
    }
}
