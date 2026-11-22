import Foundation

/// The shortcuts WhiskerFlow can register with the system so that macOS
/// consumes them and the front app never receives them.
public enum RegisteredShortcut: UInt32, CaseIterable, Sendable {
    /// The dictation shortcut, when it is a key or key combination.
    case dictation = 1
    /// ⌥⇧⌘R, the same as the "Toggle Meeting Capture" menu command.
    case meeting = 2
    /// Plain Escape, only while a dictation is opening or recording.
    case discard = 3
}

/// Registers and unregisters system hot keys. The app's adapter wraps
/// Carbon's `RegisterEventHotKey`; tests use a fake. Every call is made on the
/// main thread.
@MainActor
public protocol ShortcutRegistrar: AnyObject {
    /// Registers `combo` for `shortcut`. Returns false when the system refuses
    /// it; the caller then keeps observing the key as before.
    func register(_ shortcut: RegisteredShortcut, combo: KeyCombo) -> Bool
    func unregister(_ shortcut: RegisteredShortcut)
}

/// What a registered hot key's pressed or released event means to the app.
public enum RegisteredShortcutAction: Equatable, Sendable {
    /// Feed the dictation shortcut's matcher, which turns it into the same
    /// pressed/released transition the observing monitors produce.
    case dictation(pressed: Bool)
    /// Start or stop a meeting recording, exactly as the menu command does.
    case toggleMeeting
    /// Discard the dictation in progress.
    case discard
}

/// Decides which shortcuts are registered at any moment and what their events
/// mean. Pure apart from the registrar it drives, so every rule is testable
/// without registering a real hot key.
///
/// Registered:
/// - the dictation shortcut, when Carbon can express it (`canRegister`). A
///   modifier-only shortcut such as fn/Globe, and any combination with fn, is
///   never registered and stays on the observing monitors;
/// - the meeting shortcut, unless the dictation shortcut is the same key
///   combination (dictation wins, as it does for the Assistant shortcuts);
/// - plain Escape, only while `isDiscardWindowOpen`.
///
/// Nothing is registered before `start()`, after `stop()` or while suspended
/// (the key recorder is capturing a new shortcut). A refused registration is
/// not retried until what is wanted for that shortcut changes, so the app
/// silently keeps observing that key.
@MainActor
public final class RegisteredShortcutController {
    public static let escape = KeyCombo(keyCode: HotkeyMatcher.escapeKeyCode)

    private let registrar: ShortcutRegistrar
    private let meetingCombo: KeyCombo
    /// Called after the set of registered shortcuts changes.
    public var onChange: (() -> Void)?

    public private(set) var dictationCombo: KeyCombo
    public private(set) var isStarted = false
    public private(set) var isSuspended = false
    public private(set) var isDiscardWindowOpen = false

    private var registered: [RegisteredShortcut: KeyCombo] = [:]
    private var refused: [RegisteredShortcut: KeyCombo] = [:]
    /// Shortcuts whose press has been acted on and whose release has not yet
    /// arrived, so a repeated pressed event never acts twice.
    private var held: Set<RegisteredShortcut> = []

    public init(registrar: ShortcutRegistrar, dictationCombo: KeyCombo, meetingCombo: KeyCombo) {
        self.registrar = registrar
        self.dictationCombo = dictationCombo
        self.meetingCombo = meetingCombo
    }

    /// Whether Carbon can register this combo. It has no fn modifier and no
    /// way to register a modifier key on its own.
    public static func canRegister(_ combo: KeyCombo) -> Bool {
        !combo.isModifierOnly && combo.modifiers.subtracting(.comboMask).isEmpty
    }

    public func isRegistered(_ shortcut: RegisteredShortcut) -> Bool {
        registered[shortcut] != nil
    }

    /// The combo currently registered for each shortcut.
    public var registeredCombos: [RegisteredShortcut: KeyCombo] { registered }

    public func start() {
        isStarted = true
        reconcile()
    }

    /// Unregisters everything, for quitting.
    public func stop() {
        isStarted = false
        reconcile()
    }

    public func setDictationCombo(_ combo: KeyCombo) {
        guard combo != dictationCombo else { return }
        dictationCombo = combo
        reconcile()
    }

    public func setSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        reconcile()
    }

    /// Open while a dictation is opening or recording; Escape is registered
    /// only then, so it is swallowed only when it discards something.
    public func setDiscardWindowOpen(_ open: Bool) {
        guard open != isDiscardWindowOpen else { return }
        isDiscardWindowOpen = open
        reconcile()
    }

    /// What each shortcut should be registered as right now.
    public var desired: [RegisteredShortcut: KeyCombo] {
        guard isStarted, !isSuspended else { return [:] }
        var wanted: [RegisteredShortcut: KeyCombo] = [:]
        if Self.canRegister(dictationCombo) { wanted[.dictation] = dictationCombo }
        if meetingCombo != dictationCombo, Self.canRegister(meetingCombo) { wanted[.meeting] = meetingCombo }
        if isDiscardWindowOpen, Self.escape != dictationCombo { wanted[.discard] = Self.escape }
        return wanted
    }

    /// Maps a registered hot key's event to what the app does. Events for a
    /// shortcut that is no longer registered (already queued when it was
    /// removed) are ignored, as is a pressed event repeated while held.
    public func handle(_ shortcut: RegisteredShortcut, pressed: Bool) -> RegisteredShortcutAction? {
        guard registered[shortcut] != nil else { return nil }
        if pressed {
            guard held.insert(shortcut).inserted else { return nil }
        } else {
            guard held.remove(shortcut) != nil else { return nil }
        }
        switch shortcut {
        case .dictation: return .dictation(pressed: pressed)
        case .meeting: return pressed ? .toggleMeeting : nil
        case .discard: return pressed ? .discard : nil
        }
    }

    private func reconcile() {
        let wanted = desired
        var changed = false
        // Remove everything that is no longer wanted first. The system refuses
        // a combination this app already holds, so a shortcut taking over
        // another's keys (dictation set to the meeting shortcut) could not
        // otherwise register, and the refusal would be remembered.
        for shortcut in RegisteredShortcut.allCases {
            let want = wanted[shortcut]
            if refused[shortcut] != want { refused[shortcut] = nil }
            guard let have = registered[shortcut], have != want else { continue }
            registrar.unregister(shortcut)
            registered[shortcut] = nil
            held.remove(shortcut)
            changed = true
        }
        for shortcut in RegisteredShortcut.allCases {
            guard let want = wanted[shortcut], registered[shortcut] == nil, refused[shortcut] == nil else { continue }
            if registrar.register(shortcut, combo: want) {
                registered[shortcut] = want
                changed = true
            } else {
                refused[shortcut] = want
            }
        }
        if changed { onChange?() }
    }
}

/// The meeting shortcut can arrive twice for one key press while WhiskerFlow
/// is in front: as the registered hot key and as the menu item's key
/// equivalent. Both carry the time of the same hardware key press, so a second
/// arrival within `window` of the last one that acted is the same press.
/// A menu click (no key event) always acts.
public struct ShortcutPressDeduplicator: Sendable {
    public static let window: TimeInterval = 0.5
    private var lastActedAt: TimeInterval?

    public init() {}

    /// `eventTime` is the key press's time in seconds since boot (the base of
    /// `NSEvent.timestamp` and Carbon's `GetEventTime`), or nil for a click.
    public mutating func shouldAct(eventTime: TimeInterval?) -> Bool {
        guard let eventTime else { return true }
        if let lastActedAt, abs(eventTime - lastActedAt) < Self.window { return false }
        lastActedAt = eventTime
        return true
    }
}
