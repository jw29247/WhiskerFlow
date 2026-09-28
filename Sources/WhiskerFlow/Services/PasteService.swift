import AppKit
@preconcurrency import ApplicationServices
import Carbon.HIToolbox
import UniformTypeIdentifiers
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
        func receipt(_ state: PasteDeliveryReceipt.State, _ message: String, retry: TextFieldSnapshot? = nil,
                     _ detail: PasteDeliveryReceipt.Detail = .none) -> PasteDeliveryReceipt {
            PasteDeliveryReceipt(state: state, text: normalized, message: message, retrySelection: retry, detail: detail)
        }
        guard hasAccessibilityPermission else {
            copy(normalized)
            requestAccessibilityPermission()
            return receipt(.copied, "Copied — allow Accessibility to paste automatically", .noPermission)
        }
        guard let destination = selection?.application ?? application ?? NSWorkspace.shared.frontmostApplication,
              !destination.isTerminated,
              destination.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return receipt(.failed, "Destination unavailable. Your text is ready to copy.", .noDestination)
        }
        // One delivery at a time: an overlapping Retry/Replace would otherwise
        // post its Cmd+V while the previous one is still being handled.
        await Self.deliveries.acquire()
        defer { Self.deliveries.release() }
        // An unverified Cmd+V may still be queued in a busy target. It reads the
        // pasteboard when it is finally handled, so writing the next text now
        // would paste that twice and lose the earlier one.
        await Self.waitForUnverifiedPaste()
        let activationStarted = ProcessInfo.processInfo.systemUptime
        await Self.activateAndConfirm(destination)
        let activationSeconds = ProcessInfo.processInfo.systemUptime - activationStarted
        guard !Task.isCancelled, !destination.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == destination.processIdentifier else {
            return receipt(.failed, "Could not reach the destination. Your text is ready to copy.", .notFrontmost)
        }
        if let selection, !(await selection.restoreSelectionWhenReady()) {
            return receipt(.failed, "The original selection changed. Copy the preview instead.", .selectionChanged)
        }
        let context: TextFieldSnapshot?
        if let selection { context = selection } else { context = await TextFieldSnapshot.captureOffMain() }
        guard !Task.isCancelled,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == destination.processIdentifier else {
            return receipt(.failed, "Could not reach the destination. Your text is ready to copy.", retry: selection, .notFrontmost)
        }
        let scope = context?.scope(for: normalized)
        // Every AX read is a synchronous round trip to the destination app, so
        // the correction target reuses this snapshot instead of re-reading it.
        let correctionTarget = context.flatMap { correctionMonitor?.prepare(pasted: normalized, context: $0) }
        let pasteboard = NSPasteboard.general
        Self.clipboard.begin(on: pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(normalized, forType: .string) else {
            Self.clipboard.finish(on: pasteboard, changeCount: pasteboard.changeCount, after: 0)
            return receipt(.failed, "Could not prepare the clipboard. Try Copy or retry the unchanged selection.", retry: context, .clipboardFailed)
        }
        // Clipboard managers skip transient, app-generated items, so private
        // dictation is not added to their history.
        Self.markAppGenerated(pasteboard, transient: true)
        let deliveryChangeCount = pasteboard.changeCount
        Self.clipboard.delivered(changeCount: deliveryChangeCount)
        guard Self.sendPasteKeyEvent(to: destination) else {
            Self.clipboard.finish(on: pasteboard, changeCount: deliveryChangeCount, after: 0)
            return receipt(.failed, "The paste key could not be sent. Retry or copy your text.", retry: context, .keyFailed)
        }
        let logger = Logging.Logger(label: "agency.thatworks.WhiskerFlow.DictationLifecycle")
        logger.info("Paste event posted", metadata: ["event": "paste_posted"])
        onPosted()
        let target = context.flatMap { context in scope.map { PasteVerificationTarget(context: context, scope: $0) } }
        let confirmed = await PasteVerification.verify {
            target?.confirmsInsertion() ?? false
        }
        if confirmed {
            Self.clipboard.finish(on: pasteboard, changeCount: deliveryChangeCount, after: 0)
            correctionMonitor?.observe(correctionTarget)
            return receipt(.verified, "Pasted")
        }
        // Unverified means the target has not visibly read the clipboard yet
        // (or exposes no text to AX). A busy or swapped-out app on a slow Mac
        // can take seconds to handle Cmd+V, so restoring now would paste the
        // user's previous clipboard instead of the dictation.
        let restoreDelay = Self.unverifiedRestoreDelay(activationSeconds: activationSeconds)
        Self.clipboard.finish(on: pasteboard, changeCount: deliveryChangeCount, after: restoreDelay)
        Self.unverifiedPasteSettlesAt = ProcessInfo.processInfo.systemUptime + restoreDelay
        // A slow field may show the text after verification gave up; the
        // monitor confirms the exact insertion itself before reading any edit.
        correctionMonitor?.observe(correctionTarget)
        return receipt(.unverified, "Pasted", target == nil ? .noTextField : .insertionNotSeen)
    }

    /// Uptime until which an unverified paste may still read the pasteboard.
    private static var unverifiedPasteSettlesAt: TimeInterval = 0

    private static func waitForUnverifiedPaste() async {
        let remaining = unverifiedPasteSettlesAt - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
    }

    static func unverifiedRestoreDelay(activationSeconds: TimeInterval) -> TimeInterval {
        min(8, max(2.5, 2.5 + 3 * max(0, activationSeconds)))
    }

    // MARK: - Activation

    private static let deliveries = DeliveryQueue()
    private static let clipboard = ClipboardRestorer()

    private static func activateAndConfirm(_ application: NSRunningApplication?) async {
        guard let application, !application.isTerminated else {
            try? await Task.sleep(nanoseconds: 80_000_000)
            return
        }

        application.activate()

        // Wait until the target is actually frontmost instead of a blind fixed
        // delay. Usually immediate; a Space switch or a slow Mac can take ~2 s.
        let deadline = ProcessInfo.processInfo.systemUptime + 2.5
        while ProcessInfo.processInfo.systemUptime < deadline, !Task.isCancelled, !application.isTerminated {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - Clipboard preservation

    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let autoGeneratedType = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")

    private static func markAppGenerated(_ pasteboard: NSPasteboard, transient: Bool) {
        if transient { pasteboard.setData(Data(), forType: transientType) }
        pasteboard.setData(Data(), forType: autoGeneratedType)
    }

    /// Reading a type makes its source render it if it was provided lazily
    /// (Excel/Word PDF, TIFF and EMF flavours), synchronously on this thread.
    /// Keep every non-image flavour, but at most one image/PDF rendering per
    /// item, and stop adding image renderings once the snapshot is large.
    static func snapshot(of pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        var totalBytes = 0
        return pasteboard.pasteboardItems?.map { item in
            var contents: [NSPasteboard.PasteboardType: Data] = [:]
            for type in snapshotTypes(item.types) {
                if isRendering(type), totalBytes > 32 * 1_048_576 { continue }
                if let data = item.data(forType: type) {
                    contents[type] = data
                    totalBytes += data.count
                }
            }
            return contents
        } ?? []
    }

    /// The types read for one item, in order: all non-rendering types, then the
    /// single preferred image/PDF rendering. PDF comes first because it is the
    /// only lossless one — restoring a bitmap in its place would turn a copied
    /// chart or Preview selection into a raster. Then PNG, TIFF, the first.
    static func snapshotTypes(_ types: [NSPasteboard.PasteboardType]) -> [NSPasteboard.PasteboardType] {
        let renderings = types.filter(isRendering)
        let preferred = renderings.first(where: { $0 == .pdf }) ?? renderings.first(where: { $0 == .png })
            ?? renderings.first(where: { $0 == .tiff }) ?? renderings.first
        return types.filter { !isRendering($0) } + (preferred.map { [$0] } ?? [])
    }

    private static func isRendering(_ type: NSPasteboard.PasteboardType) -> Bool {
        if [.pdf, .tiff, .png].contains(type) { return true }
        guard let uniform = UTType(type.rawValue) else {
            return type.rawValue == "com.apple.pict" || type.rawValue.localizedCaseInsensitiveContains("metafile")
        }
        return uniform.conforms(to: .image) || uniform.conforms(to: .pdf)
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
            // The restore is not a new copy; clipboard managers already hold it.
            if !contents.isEmpty, contents[autoGeneratedType] == nil { item.setData(Data(), forType: autoGeneratedType) }
            return item
        }
        pasteboard.writeObjects(items)
    }
}

/// Holds the user's clipboard across back-to-back deliveries. A second paste
/// that starts while the first one's delayed restore is pending must restore
/// the user's original clipboard, not the first dictation it finds there.
@MainActor
final class ClipboardRestorer {
    private var saved: [[NSPasteboard.PasteboardType: Data]]?
    private var ownedChangeCount: Int?
    private var pendingRestore: Task<Void, Never>?

    func begin(on pasteboard: NSPasteboard) {
        pendingRestore?.cancel()
        pendingRestore = nil
        // Nobody copied since our last delivery: the pasteboard still holds that
        // dictation, and the saved snapshot is still the user's clipboard.
        if saved != nil, let ownedChangeCount, ownedChangeCount == pasteboard.changeCount { return }
        saved = PasteService.snapshot(of: pasteboard)
        ownedChangeCount = nil
    }

    func delivered(changeCount: Int) {
        ownedChangeCount = changeCount
    }

    func finish(on pasteboard: NSPasteboard, changeCount: Int, after delay: TimeInterval) {
        guard delay > 0 else { restore(on: pasteboard, changeCount: changeCount); return }
        pendingRestore?.cancel()
        pendingRestore = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.restore(on: pasteboard, changeCount: changeCount)
        }
    }

    private func restore(on pasteboard: NSPasteboard, changeCount: Int) {
        pendingRestore = nil
        guard let saved else { return }
        PasteService.restore(saved, to: pasteboard, ifUnchangedSince: changeCount)
        self.saved = nil
        ownedChangeCount = nil
    }
}

/// FIFO main-actor gate that serialises paste deliveries.
@MainActor
final class DeliveryQueue {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

extension PasteService {
    fileprivate static func sendPasteKeyEvent(to application: NSRunningApplication?) -> Bool {
        let key = pasteKeyCode()
        guard let application, !application.isTerminated,
              let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return false }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        // A confirmed process target prevents global event-tap replay duplicates.
        keyDown.postToPid(application.processIdentifier)
        keyUp.postToPid(application.processIdentifier)
        return true
    }
}

// MARK: - Layout-aware paste key

extension PasteService {
    /// The key that types "v" while ⌘ is held. The receiving app maps the posted
    /// keycode through the user's layout, so a fixed ANSI V (9) is Cmd+K on
    /// Dvorak and Cmd+C on Workman. Translating with ⌘ held also honours layouts
    /// such as "Dvorak - QWERTY ⌘". Non-Latin layouts resolve shortcuts through
    /// the ASCII-capable layout, which is checked next.
    static func pasteKeyCode() -> CGKeyCode {
        let fallback = CGKeyCode(kVK_ANSI_V)
        for copy in [TISCopyCurrentKeyboardLayoutInputSource, TISCopyCurrentASCIICapableKeyboardLayoutInputSource] {
            guard let source = copy()?.takeRetainedValue() else { continue }
            if let key = keyCode(typing: 0x76, withCommandIn: source) { return key }
        }
        return fallback
    }

    private static func keyCode(typing character: UniChar, withCommandIn source: TISInputSource) -> CGKeyCode? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { buffer -> CGKeyCode? in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            let modifiers = UInt32(cmdKey >> 8) & 0xFF
            let keyboardType = UInt32(LMGetKbdType())
            func types(_ keyCode: UInt16) -> Bool {
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), modifiers, keyboardType,
                                            OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState,
                                            characters.count, &length, &characters)
                return status == 0 && length == 1 && (characters[0] | 0x20) == character
            }
            if types(UInt16(kVK_ANSI_V)) { return CGKeyCode(kVK_ANSI_V) }
            return (UInt16(0)..<128).first(where: types).map { CGKeyCode($0) }
        }
    }
}
