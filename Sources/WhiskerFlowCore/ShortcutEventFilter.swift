import Foundation

/// Decides, for each keyboard event an active event tap sees, whether
/// WhiskerFlow acts on it and whether it is swallowed so the front app never
/// receives it. Pure and free of CoreGraphics so key sequences can be tested
/// without real events; `ShortcutEventTap` is the thin adapter around it.
///
/// Swallowed, in exactly these cases:
/// - a fresh press of the dictation shortcut when it is a key or key
///   combination (F5, ⌃⌥Space). A modifier-only shortcut such as fn/Globe is
///   never given to the filter (`dictationCombo` is nil) and stays on the
///   observing monitors;
/// - a fresh press of the meeting record shortcut;
/// - plain Escape while a dictation is being prepared or recorded.
///
/// The auto-repeats and the release of a swallowed press are swallowed with it,
/// so the front app never sees half of a keystroke. Everything else passes,
/// and everything passes while the shortcut is suspended (the key recorder is
/// capturing a new shortcut).
public struct ShortcutEventFilter: Sendable {
    public enum EventKind: Sendable {
        case keyDown
        case keyUp
        case flagsChanged
    }

    public struct Decision: Equatable, Sendable {
        /// Drop the event so no app receives it.
        public var consume = false
        /// Feed the event to the dictation shortcut's matcher: the tap is that
        /// shortcut's only source while it runs.
        public var forwardToDictation = false
        /// Discard the dictation in progress.
        public var discard = false
        /// Start or stop a meeting recording, as the menu command does.
        public var toggleMeeting = false

        public init(consume: Bool = false, forwardToDictation: Bool = false,
                    discard: Bool = false, toggleMeeting: Bool = false) {
            self.consume = consume
            self.forwardToDictation = forwardToDictation
            self.discard = discard
            self.toggleMeeting = toggleMeeting
        }

        public static let pass = Decision()

        public var needsMainThread: Bool { forwardToDictation || discard || toggleMeeting }
    }

    /// The dictation shortcut when it is a key or combination; nil for a
    /// modifier-only shortcut, which the tap never handles.
    public private(set) var dictationCombo: KeyCombo?
    public var meetingCombo: KeyCombo?
    public var isDictationRecording = false
    public var isSuspended = false
    /// Keys whose press was swallowed, so their repeats and release are too.
    private var consumedKeyCodes: Set<UInt16> = []

    public init(dictationCombo: KeyCombo? = nil, meetingCombo: KeyCombo? = nil) {
        self.meetingCombo = meetingCombo
        setDictationCombo(dictationCombo)
    }

    /// A modifier-only combo is ignored: fn/Globe and friends keep the
    /// observing path, and the tap does not even listen for modifier changes.
    public mutating func setDictationCombo(_ combo: KeyCombo?) {
        dictationCombo = combo.flatMap { $0.isModifierOnly ? nil : $0 }
    }

    /// Whether any case can apply, so a tap is worth installing.
    public var needsTap: Bool {
        dictationCombo != nil || meetingCombo != nil || isDictationRecording
    }

    /// Whether the tap must see modifier changes: only a key-combination
    /// dictation shortcut needs them, to release when a modifier goes up.
    public var needsFlagsChanged: Bool { dictationCombo != nil }

    public mutating func decide(
        kind: EventKind,
        keyCode: UInt16,
        modifiers: KeyModifiers,
        isRepeat: Bool
    ) -> Decision {
        guard !isSuspended else {
            consumedKeyCodes.removeAll()
            return .pass
        }
        let isDictationKey = dictationCombo?.keyCode == keyCode
        switch kind {
        case .flagsChanged:
            return Decision(forwardToDictation: dictationCombo != nil)
        case .keyUp:
            let consume = consumedKeyCodes.remove(keyCode) != nil
            return Decision(consume: consume, forwardToDictation: isDictationKey)
        case .keyDown:
            if isRepeat {
                return Decision(consume: consumedKeyCodes.contains(keyCode), forwardToDictation: isDictationKey)
            }
            consumedKeyCodes.remove(keyCode)
            let held = modifiers.intersection(.comboMask)
            if let combo = dictationCombo, isDictationKey, held == combo.modifiers.intersection(.comboMask) {
                consumedKeyCodes.insert(keyCode)
                return Decision(consume: true, forwardToDictation: true)
            }
            if let combo = meetingCombo, combo != dictationCombo, !combo.isModifierOnly,
               keyCode == combo.keyCode, held == combo.modifiers.intersection(.comboMask) {
                consumedKeyCodes.insert(keyCode)
                return Decision(consume: true, toggleMeeting: true)
            }
            if isDictationRecording, HotkeyMatcher.isDiscardPress(
                keyCode: keyCode, modifiers: modifiers, isKeyDown: true, isRepeat: false
            ) {
                consumedKeyCodes.insert(keyCode)
                return Decision(consume: true, discard: true)
            }
            return Decision(forwardToDictation: isDictationKey)
        }
    }
}
