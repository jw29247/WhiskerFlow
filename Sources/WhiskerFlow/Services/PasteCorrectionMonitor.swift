import AppKit
@preconcurrency import ApplicationServices
import Logging
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

    private let logger = Logging.Logger(label: "agency.thatworks.WhiskerFlow.DictationLifecycle")

    private func report(_ changes: [VocabularyCorrection], sessionID: UUID, application: String, token: UUID) {
        guard generation == token else { return }
        logReport(changes)
        onCorrections(changes, sessionID, application)
    }

    /// Counts only; the words themselves never reach the diagnostic log.
    private func logReport(_ changes: [VocabularyCorrection]) {
        logger.info("Correction observed", metadata: ["event": "correction_observed", "corrections": "\(changes.count)"])
    }

    private func logWatchEnded(_ outcome: String) {
        logger.info("Correction watch ended", metadata: ["event": "correction_watch", "outcome": "\(outcome)"])
    }

    /// The session is ending (field sent or cleared, focus moved, next paste or
    /// deadline), so the last observed edit is final even inside the debounce.
    private func flush(_ changes: [VocabularyCorrection], sessionID: UUID, application: String) {
        guard isEnabled(), !changes.isEmpty else { return }
        logReport(changes)
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
            guard confirmed else {
                await self?.logWatchEnded("unconfirmed")
                return
            }
            await self?.logWatchEnded("confirmed")
            let deadline = Date().addingTimeInterval(120)
            var latest = target.scope.original
            var changedAt = Date()
            var lastSaved = latest
            // Only an edit seen unchanged on two consecutive polls is final;
            // a single sample may catch a word mid-typing.
            var latestIsStable = false
            func corrections(_ edited: String) -> [VocabularyCorrection] {
                VocabularyCorrectionDetector.corrections(original: target.scope.original, edited: edited, maxSuggestions: 20, allowShortCorrections: true)
            }
            // Fixing a name and pressing Enter usually happens inside the
            // debounce, so every exit keeps the last settled edit.
            defer {
                if latest != lastSaved, latestIsStable {
                    let changes = corrections(latest)
                    Task { @MainActor in self?.flush(changes, sessionID: sessionID, application: applicationName) }
                }
            }
            while !Task.isCancelled, Date() < deadline {
                // Poll faster while an edit is unsaved to narrow the window
                // between the last observed text and an Enter that clears it.
                try? await Task.sleep(for: .milliseconds(latest != lastSaved ? 200 : 500))
                guard !Task.isCancelled, await self?.isActive(token) == true, probe.isFocusedTextInput(),
                      let value = probe.value(),
                      let edited = target.scope.editedText(in: value) else { return }
                // A chat composer that sends on Enter clears to its old
                // surroundings and keeps focus; the dictation is gone, so the
                // session ends with the last edit rather than overwriting it.
                guard !edited.allSatisfy(\.isWhitespace) else { return }
                if edited != latest {
                    latest = edited
                    changedAt = Date()
                    latestIsStable = false
                } else {
                    latestIsStable = true
                }
                if latest != lastSaved, Date().timeIntervalSince(changedAt) >= 1.5 {
                    await self?.report(corrections(latest), sessionID: sessionID, application: applicationName, token: token)
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
