import AppKit
import ApplicationServices
import WhiskerFlowCore

@MainActor
struct PasteService {
    var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibilityPermission() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Copy text to the clipboard without simulating a paste.
    func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text.plainTranscriptText, forType: .string)
    }

    /// Paste `text` into `application` at the cursor, preserving the user's clipboard.
    @discardableResult
    func paste(_ text: String, into application: NSRunningApplication?) -> Bool {
        let pasteboard = NSPasteboard.general
        let saved = Self.snapshot(of: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text.plainTranscriptText, forType: .string)

        guard hasAccessibilityPermission else {
            requestAccessibilityPermission()
            return false
        }

        Task { @MainActor in
            await Self.activateAndConfirm(application)
            Self.sendPasteKeyEvent()
            // Restore the previous clipboard once the paste has been delivered.
            try? await Task.sleep(nanoseconds: 450_000_000)
            Self.restore(saved, to: pasteboard)
        }

        return true
    }

    // MARK: - Activation

    private static func activateAndConfirm(_ application: NSRunningApplication?) async {
        guard let application, !application.isTerminated else {
            try? await Task.sleep(nanoseconds: 80_000_000)
            return
        }

        application.activate()

        // Wait until the target is actually frontmost (max ~600ms) instead of a
        // blind fixed delay — faster on average and avoids pasting into the wrong app.
        for _ in 0..<30 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - Clipboard preservation

    private static func snapshot(of pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        pasteboard.pasteboardItems?.map { item in
            var contents: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    contents[type] = data
                }
            }
            return contents
        } ?? []
    }

    private static func restore(_ snapshot: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        guard !snapshot.isEmpty else { return }
        pasteboard.clearContents()
        let items = snapshot.map { contents -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in contents {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(items)
    }
}

extension PasteService {
    fileprivate static func sendPasteKeyEvent() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)

        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
