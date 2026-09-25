import AppKit
@preconcurrency import ApplicationServices
import WhiskerFlowCore

/// A short-lived transaction snapshot. Document text never leaves memory.
@MainActor
struct TextFieldSnapshot {
    let application: NSRunningApplication
    let element: AXUIElement
    let before: String
    let selection: NSRange

    var selectedText: String { (before as NSString).substring(with: selection) }
    var isFocused: Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier,
              let focused = Self.focusedElement(application) else { return false }
        return CFEqual(focused, element)
    }
    var isUnchanged: Bool { readValue()?.utf16.elementsEqual(before.utf16) == true }

    static func capture(requireSelection: Bool = false) -> Self? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let field = readFocusedField(app.processIdentifier, requireSelection: requireSelection) else { return nil }
        return Self(application: app, element: field.element, before: field.before, selection: field.selection)
    }

    /// Same capture, with the AX round trips on a worker so a slow destination
    /// (Electron, Chrome, large documents) cannot hold the main actor.
    static func captureOffMain(requireSelection: Bool = false) async -> Self? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let pid = app.processIdentifier
        guard let field = await AccessibilityWorker.run({ Self.readFocusedField(pid, requireSelection: requireSelection) }),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        return Self(application: app, element: field.element, before: field.before, selection: field.selection)
    }

    private struct FocusedField: @unchecked Sendable {
        let element: AXUIElement
        let before: String
        let selection: NSRange
    }

    private nonisolated static func readFocusedField(_ pid: pid_t, requireSelection: Bool) -> FocusedField? {
        guard let element = focusedElement(pid), let before = value(element),
              let raw = attribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cfRange, &range) else { return nil }
        let selection = NSRange(location: range.location, length: range.length)
        guard PastedTextScope(before: before, selection: selection, pasted: "x") != nil,
              !requireSelection || (selection.length > 0 && selection.length <= 8_000) else { return nil }
        return FocusedField(element: element, before: before, selection: selection)
    }

    func readValue() -> String? { Self.value(element) }
    func scope(for replacement: String) -> PastedTextScope? {
        PastedTextScope(before: before, selection: selection, pasted: replacement)
    }
    /// Called only after an explicit Replace/Retry, never to repair a stale document.
    func restoreSelection() -> Bool {
        guard isFocused, isUnchanged else { return false }
        var range = CFRange(location: selection.location, length: selection.length)
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    /// `restoreSelection()` for a destination that was just activated. On a slow
    /// Mac the window may still be coming forward (another Space, full screen),
    /// so an unfocused or unanswered field is retried briefly off the main actor.
    /// A document that answered with different text is never retried.
    func restoreSelectionWhenReady(attempts: Int = 6) async -> Bool {
        let pid = application.processIdentifier
        let target = FocusedField(element: element, before: before, selection: selection)
        for attempt in 0..<max(1, attempts) {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 200_000_000) }
            guard !Task.isCancelled, !application.isTerminated else { return false }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { continue }
            switch await AccessibilityWorker.run({ Self.restore(target, in: pid) }) {
            case .restored: return true
            case .changed: return false
            case .notReady: continue
            }
        }
        return false
    }

    private enum RestoreOutcome: Sendable { case restored, changed, notReady }

    private nonisolated static func restore(_ target: FocusedField, in pid: pid_t) -> RestoreOutcome {
        // One-shot reads while the destination is activating get a longer
        // timeout than the polling probes do.
        AXUIElementSetMessagingTimeout(target.element, 0.6)
        guard let focused = focusedElement(pid, timeout: 0.6), CFEqual(focused, target.element),
              let current = value(target.element) else { return .notReady }
        guard current.utf16.elementsEqual(target.before.utf16) else { return .changed }
        var range = CFRange(location: target.selection.location, length: target.selection.length)
        guard let value = AXValueCreate(.cfRange, &range) else { return .changed }
        return AXUIElementSetAttributeValue(target.element, kAXSelectedTextRangeAttribute as CFString, value) == .success
            ? .restored : .notReady
    }

    private nonisolated static func value(_ element: AXUIElement) -> String? {
        guard let role = attribute(element, kAXRoleAttribute) as? String,
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role),
              attribute(element, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole,
              let value = attribute(element, kAXValueAttribute) as? String,
              value.utf16.count <= 65_536 else { return nil }
        return value
    }
    private static func focusedElement(_ app: NSRunningApplication) -> AXUIElement? {
        focusedElement(app.processIdentifier)
    }
    private nonisolated static func focusedElement(_ pid: pid_t, timeout: Float = 0.2) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, timeout)
        guard let value = attribute(application, kAXFocusedUIElementAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }
    private nonisolated static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}

/// Runs a blocking AX read on a utility worker rather than the main actor or
/// the cooperative pool. Each read is bounded by its AX messaging timeout.
enum AccessibilityWorker {
    static func run<T>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<UncheckedBox<T>, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: UncheckedBox(value: work()))
            }
        }.value
    }

    struct UncheckedBox<T>: @unchecked Sendable { let value: T }
}

struct PasteDeliveryReceipt {
    enum State: String { case verified, unverified, failed, copied }
    let state: State
    let text: String
    let message: String
    var retrySelection: TextFieldSnapshot?
}

/// Immutable AX handles used solely by the verification worker. No AppKit or
/// observable application state is accessed on that worker.
struct PasteVerificationTarget: @unchecked Sendable {
    private let application: AXUIElement
    private let element: AXUIElement
    private let scope: PastedTextScope

    @MainActor
    init(context: TextFieldSnapshot, scope: PastedTextScope) {
        self.application = AXUIElementCreateApplication(context.application.processIdentifier)
        self.element = context.element
        self.scope = scope
        AXUIElementSetMessagingTimeout(application, 0.2)
        AXUIElementSetMessagingTimeout(element, 0.2)
    }

    func confirmsInsertion() -> Bool {
        guard attribute(application, kAXFrontmostAttribute) as? Bool == true,
              let focused = attribute(application, kAXFocusedUIElementAttribute),
              CFEqual(focused, element),
              let role = attribute(element, kAXRoleAttribute) as? String,
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role),
              attribute(element, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole,
              let value = attribute(element, kAXValueAttribute) as? String,
              value.utf16.count <= 65_536 else { return false }
        return scope.confirmsInsertion(value)
    }

    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }
}
