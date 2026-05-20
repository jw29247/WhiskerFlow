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

    func paste(_ text: String, into application: NSRunningApplication?) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text.plainTranscriptText, forType: .string)

        guard hasAccessibilityPermission else {
            requestAccessibilityPermission()
            return false
        }

        if let application, !application.isTerminated {
            application.activate()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(350)) {
            sendPasteKeyEvent()
            runSystemEventsPasteFallback()
        }

        return true
    }
}

private func sendPasteKeyEvent() {
    let source = CGEventSource(stateID: .combinedSessionState)
    let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
    let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)

    keyDown?.flags = .maskCommand
    keyUp?.flags = .maskCommand
    keyDown?.post(tap: .cghidEventTap)
    keyUp?.post(tap: .cghidEventTap)
}

private func runSystemEventsPasteFallback() {
    let script = """
    tell application "System Events"
        keystroke "v" using command down
    end tell
    """

    var error: NSDictionary?
    NSAppleScript(source: script)?.executeAndReturnError(&error)
}
