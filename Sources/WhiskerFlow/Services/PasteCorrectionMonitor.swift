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

    /// `context` was captured from the focused, non-secure text input moments
    /// before the paste, so its value and selection are the pre-paste state.
    func prepare(pasted: String, context: TextFieldSnapshot) -> Target? {
        stop()
        guard isEnabled(),
              let scope = PastedTextScope(before: context.before, selection: context.selection, pasted: pasted) else { return nil }
        return Target(element: context.element, application: context.application, scope: scope)
    }

    private func isActive(_ token: UUID) -> Bool {
        generation == token && isEnabled()
    }

    private func report(_ changes: [VocabularyCorrection], sessionID: UUID, application: String, token: UUID) {
        guard generation == token else { return }
        onCorrections(changes, sessionID, application)
    }

    func observe(_ target: Target?) {
        guard let target else { return }
        let token = generation
        let sessionID = UUID()
        let probe = CorrectionProbe(target)
        let applicationName = target.application.localizedName ?? "Another app"
        // Every AX read is a synchronous round trip to the destination app, bounded
        // only by its 0.2 s messaging timeout. Poll on a utility worker so a slow
        // destination can never hold the main actor that serves the hotkey and HUD.
        task = Task.detached(priority: .utility) { [weak self] in
            // Confirm the exact insertion before interpreting any subsequent edits.
            var confirmed = false
            for _ in 0..<12 {
                guard !Task.isCancelled, await self?.isActive(token) == true, probe.isFocusedTextInput() else { return }
                if let value = probe.value(), target.scope.confirmsInsertion(value) {
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
                guard !Task.isCancelled, await self?.isActive(token) == true, probe.isFocusedTextInput(),
                      let value = probe.value(),
                      let edited = target.scope.editedText(in: value) else { return }
                if edited != latest {
                    latest = edited
                    changedAt = Date()
                }
                if latest != lastSaved, Date().timeIntervalSince(changedAt) >= 1.5 {
                    let changes = VocabularyCorrectionDetector.corrections(original: target.scope.original, edited: latest, maxSuggestions: 20, allowShortCorrections: true)
                    await self?.report(changes, sessionID: sessionID, application: applicationName, token: token)
                    lastSaved = latest
                }
            }
        }
    }
}

/// Immutable AX handles read by the correction worker; no AppKit state is
/// touched off the main actor.
private struct CorrectionProbe: @unchecked Sendable {
    private let application: AXUIElement
    private let element: AXUIElement

    @MainActor
    init(_ target: PasteCorrectionMonitor.Target) {
        application = AXUIElementCreateApplication(target.application.processIdentifier)
        element = target.element
        AXUIElementSetMessagingTimeout(application, 0.2)
        AXUIElementSetMessagingTimeout(element, 0.2)
    }

    /// The destination is still frontmost with the same non-secure text input focused.
    func isFocusedTextInput() -> Bool {
        guard attribute(application, kAXFrontmostAttribute) as? Bool == true,
              let focused = attribute(application, kAXFocusedUIElementAttribute),
              CFEqual(focused, element),
              let role = attribute(element, kAXRoleAttribute) as? String,
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role),
              attribute(element, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole else { return false }
        return true
    }

    func value() -> String? { attribute(element, kAXValueAttribute) as? String }

    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }
}
