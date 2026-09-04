import AppKit
@preconcurrency import ApplicationServices
import WhiskerFlowCore

/// Observes one verified paste, never general typing or clipboard changes.
@MainActor
final class PasteCorrectionMonitor {
    struct Target {
        let element: AXUIElement
        let application: NSRunningApplication
        let scope: PastedTextScope
    }

    private var task: Task<Void, Never>?
    private var generation = UUID()
    var isEnabled: () -> Bool = { false }
    var onCorrections: ([VocabularyCorrection], UUID, String) -> Void = { _, _, _ in }

    func stop() {
        generation = UUID()
        task?.cancel()
        task = nil
    }

    func prepare(pasted: String) -> Target? {
        stop()
        guard isEnabled(), AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let element = Self.focusedElement(app), Self.isTextInput(element),
              let before = Self.string(element, kAXValueAttribute),
              let rawRange = Self.attribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(rawRange) == AXValueGetTypeID() else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(unsafeBitCast(rawRange, to: AXValue.self), .cfRange, &selection),
              let scope = PastedTextScope(before: before, selection: NSRange(location: selection.location, length: selection.length), pasted: pasted) else { return nil }
        return Target(element: element, application: app, scope: scope)
    }

    func observe(_ target: Target?) {
        guard let target else { return }
        let token = generation
        let sessionID = UUID()
        task = Task { @MainActor [weak self] in
            // Confirm the exact insertion before interpreting any subsequent edits.
            var confirmed = false
            for _ in 0..<12 {
                guard let self, !Task.isCancelled, self.generation == token,
                      self.isEnabled(), Self.stillFocused(target), Self.isTextInput(target.element) else { return }
                if let value = Self.string(target.element, kAXValueAttribute), target.scope.confirmsInsertion(value) {
                    confirmed = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(75))
            }
            guard confirmed else { return }
            let deadline = Date().addingTimeInterval(120)
            var latest = target.scope.original
            var changedAt = Date()
            var lastSaved = latest
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled, self.generation == token, self.isEnabled() else { return }
                guard Self.stillFocused(target), Self.isTextInput(target.element),
                      let value = Self.string(target.element, kAXValueAttribute),
                      let edited = target.scope.editedText(in: value) else { return }
                if edited != latest {
                    latest = edited
                    changedAt = Date()
                }
                if latest != lastSaved, Date().timeIntervalSince(changedAt) >= 1.5 {
                    let changes = VocabularyCorrectionDetector.corrections(original: target.scope.original, edited: latest, maxSuggestions: 20, allowShortCorrections: true)
                    self.onCorrections(changes, sessionID, target.application.localizedName ?? "Another app")
                    lastSaved = latest
                }
            }
        }
    }

    private static func stillFocused(_ target: Target) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.application.processIdentifier,
              let focused = focusedElement(target.application) else { return false }
        return CFEqual(focused, target.element)
    }

    private static func focusedElement(_ app: NSRunningApplication) -> AXUIElement? {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.2)
        guard let value = attribute(application, kAXFocusedUIElementAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.2)
        return element
    }

    private static func isTextInput(_ element: AXUIElement) -> Bool {
        // Check role before value; secure text values must never be read.
        guard let role = string(element, kAXRoleAttribute),
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role),
              string(element, kAXSubroleAttribute) != kAXSecureTextFieldSubrole else { return false }
        return true
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
