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
              let element = focusedElement(app), let before = value(element),
              let raw = attribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cfRange, &range) else { return nil }
        let selection = NSRange(location: range.location, length: range.length)
        guard PastedTextScope(before: before, selection: selection, pasted: "x") != nil,
              !requireSelection || (selection.length > 0 && selection.length <= 8_000) else { return nil }
        return Self(application: app, element: element, before: before, selection: selection)
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

    private static func value(_ element: AXUIElement) -> String? {
        guard let role = attribute(element, kAXRoleAttribute) as? String,
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role),
              attribute(element, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole,
              let value = attribute(element, kAXValueAttribute) as? String,
              value.utf16.count <= 65_536 else { return nil }
        return value
    }
    private static func focusedElement(_ app: NSRunningApplication) -> AXUIElement? {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.2)
        guard let value = attribute(application, kAXFocusedUIElementAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.2)
        return element
    }
    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}

struct PasteDeliveryReceipt {
    enum State { case verified, unverified, failed, copied }
    let state: State
    let text: String
    let message: String
    var retrySelection: TextFieldSnapshot? = nil
}
