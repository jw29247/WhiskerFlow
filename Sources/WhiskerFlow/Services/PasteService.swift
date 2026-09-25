import AppKit
@preconcurrency import ApplicationServices
import WhiskerFlowCore
import WhiskerFlowAppSupport
import Logging

@MainActor
protocol TextDeliveryService {
    var hasAccessibilityPermission: Bool { get }
    func requestAccessibilityPermission()
    func copy(_ text: String)
    func paste(_ text: String, into application: NSRunningApplication?, replacing selection: TextFieldSnapshot?) async -> PasteDeliveryReceipt
    /// `onPosted` runs once the paste keystroke reaches the destination, before
    /// insertion is verified, so the UI can report the paste as it lands.
    func paste(_ text: String, into application: NSRunningApplication?, replacing selection: TextFieldSnapshot?,
               onPosted: @escaping @MainActor () -> Void) async -> PasteDeliveryReceipt
}

extension TextDeliveryService {
    func paste(_ text: String, into application: NSRunningApplication?, replacing selection: TextFieldSnapshot?,
               onPosted: @escaping @MainActor () -> Void) async -> PasteDeliveryReceipt {
        await paste(text, into: application, replacing: selection)
    }
}

@MainActor
struct PasteService: TextDeliveryService {
    var correctionMonitor: PasteCorrectionMonitor?
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
        pasteboard.setString(text.normalizedForDelivery, forType: .string)
    }

    /// Returns observed delivery, rather than treating a queued key event as success.
    func paste(_ text: String, into application: NSRunningApplication?, replacing selection: TextFieldSnapshot? = nil) async -> PasteDeliveryReceipt {
        await paste(text, into: application, replacing: selection, onPosted: {})
    }

    func paste(_ text: String, into application: NSRunningApplication?, replacing selection: TextFieldSnapshot?,
               onPosted: @escaping @MainActor () -> Void) async -> PasteDeliveryReceipt {
        correctionMonitor?.stop()
        let normalized = text.normalizedForDelivery
        func receipt(_ state: PasteDeliveryReceipt.State, _ message: String, retry: TextFieldSnapshot? = nil) -> PasteDeliveryReceipt {
            PasteDeliveryReceipt(state: state, text: normalized, message: message, retrySelection: retry)
        }
        guard hasAccessibilityPermission else {
            copy(normalized)
            requestAccessibilityPermission()
            return receipt(.copied, "Copied — allow Accessibility to paste automatically")
        }
        guard let destination = selection?.application ?? application ?? NSWorkspace.shared.frontmostApplication,
              !destination.isTerminated,
              destination.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return receipt(.failed, "Destination unavailable. Your text is ready to copy.")
        }
        await Self.activateAndConfirm(destination)
        guard !Task.isCancelled,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == destination.processIdentifier else {
            return receipt(.failed, "Could not reach the destination. Your text is ready to copy.")
        }
        if let selection, !selection.restoreSelection() {
            return receipt(.failed, "The original selection changed. Copy the preview instead.")
        }
        let context = selection ?? TextFieldSnapshot.capture()
        let scope = context?.scope(for: normalized)
        // Every AX read is a synchronous round trip to the destination app, so
        // the correction target reuses this snapshot instead of re-reading it.
        let correctionTarget = context.flatMap { correctionMonitor?.prepare(pasted: normalized, context: $0) }
        let pasteboard = NSPasteboard.general
        let saved = Self.snapshot(of: pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(normalized, forType: .string) else {
            Self.restore(saved, to: pasteboard, ifUnchangedSince: pasteboard.changeCount)
            return receipt(.failed, "Could not prepare the clipboard. Try Copy or retry the unchanged selection.", retry: context)
        }
        let deliveryChangeCount = pasteboard.changeCount
        defer { Self.restore(saved, to: pasteboard, ifUnchangedSince: deliveryChangeCount) }
        guard Self.sendPasteKeyEvent(to: destination) else {
            return receipt(.failed, "The paste key could not be sent. Retry or copy your text.", retry: context)
        }
        let logger = Logging.Logger(label: "agency.thatworks.WhiskerFlow.DictationLifecycle")
        logger.info("Paste event posted", metadata: ["event": "paste_posted"])
        onPosted()
        let target = context.flatMap { context in scope.map { PasteVerificationTarget(context: context, scope: $0) } }
        let confirmed = await PasteVerification.verify {
            target?.confirmsInsertion() ?? false
        }
        if confirmed {
            correctionMonitor?.observe(correctionTarget)
            return receipt(.verified, "Pasted")
        }
        return receipt(.unverified, "Pasted")
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

    static func restore(_ snapshot: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard, ifUnchangedSince changeCount: Int) {
        // A new Copy action owns the clipboard immediately. An earlier delayed
        // paste must never replace it, forcing the user to copy a second time.
        guard pasteboard.changeCount == changeCount else { return }
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
    fileprivate static func sendPasteKeyEvent(to application: NSRunningApplication?) -> Bool {
        guard let application, !application.isTerminated,
              let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else { return false }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        // A confirmed process target prevents global event-tap replay duplicates.
        keyDown.postToPid(application.processIdentifier)
        keyUp.postToPid(application.processIdentifier)
        return true
    }
}
