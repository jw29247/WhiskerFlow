import AppKit
import ApplicationServices
import WhiskerFlowCore

/// Reads where dictation is going: the frontmost app and, for a browser, the
/// active tab's URL or window title. The URL and title stay in memory only —
/// never log, persist or send them.
enum AppContextReader {
    /// Sized so a lookup started at key press is done well before a normal
    /// release; a slow browser just resolves as Other.
    static let readBudgetSeconds: TimeInterval = 0.4
    static let nodeBudget = 300
    static let maximumDepth = 14
    static let callTimeoutSeconds: Float = 0.1

    /// The current destination, for features outside dictation. Blocking AX IPC
    /// runs off the main actor.
    static func current() async -> AppContext {
        let target = await MainActor.run { NSWorkspace.shared.frontmostApplication }
        guard let target else { return AppContext(bundleIdentifier: nil) }
        let bundleIdentifier = target.bundleIdentifier
        let pid = target.processIdentifier
        guard AppCategoryRules.isBrowser(bundleIdentifier) else { return AppContext(bundleIdentifier: bundleIdentifier) }
        return await Task.detached(priority: .userInitiated) {
            readBrowser(bundleIdentifier: bundleIdentifier, pid: pid)
        }.value
    }

    /// Synchronous AX IPC. Must not run on the main actor.
    static func readBrowser(bundleIdentifier: String?, pid: pid_t) -> AppContext {
        var context = AppContext(bundleIdentifier: bundleIdentifier)
        guard AXIsProcessTrusted() else { return context }
        var walk = Walk(deadline: ProcessInfo.processInfo.systemUptime + readBudgetSeconds)
        let app = AXUIElementCreateApplication(pid)
        guard let window = walk.element(app, kAXFocusedWindowAttribute) ?? walk.element(app, kAXMainWindowAttribute) else {
            return context
        }
        context.windowTitle = walk.string(window, kAXTitleAttribute)
        context.pageURL = walk.url(window, kAXDocumentAttribute) ?? walk.webAreaURL(under: window)
        return context
    }

    private struct Walk {
        let deadline: TimeInterval
        var remaining = AppContextReader.nodeBudget

        private func prepare(_ element: AXUIElement) -> Bool {
            let left = deadline - ProcessInfo.processInfo.systemUptime
            guard left > 0 else { return false }
            AXUIElementSetMessagingTimeout(element, min(AppContextReader.callTimeoutSeconds, Float(left)))
            return true
        }

        private func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            guard prepare(element) else { return nil }
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
        }

        func element(_ element: AXUIElement, _ key: String) -> AXUIElement? {
            guard let raw = value(element, key), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
            return (raw as! AXUIElement)
        }

        func string(_ element: AXUIElement, _ key: String) -> String? {
            (value(element, key) as? String).flatMap { $0.isEmpty ? nil : $0 }
        }

        func url(_ element: AXUIElement, _ key: String) -> String? {
            let raw = value(element, key)
            let text = (raw as? URL)?.absoluteString ?? (raw as? String)
            guard let text, text.hasPrefix("http") else { return nil }
            return text
        }

        /// Breadth-first, so the page's web area is found before deep page content.
        mutating func webAreaURL(under root: AXUIElement) -> String? {
            var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
            var index = 0
            while index < queue.count, remaining > 0, ProcessInfo.processInfo.systemUptime < deadline {
                let (node, depth) = queue[index]; index += 1
                remaining -= 1
                let role = string(node, kAXRoleAttribute)
                if role == "AXWebArea" { return url(node, "AXURL") }
                // Text fields hold what the user typed; never read or descend into them.
                guard depth < AppContextReader.maximumDepth, role != "AXTextField", role != "AXTextArea",
                      let children = value(node, kAXChildrenAttribute) as? [AXUIElement] else { continue }
                queue.append(contentsOf: children.prefix(remaining).map { ($0, depth + 1) })
            }
            return nil
        }
    }
}
