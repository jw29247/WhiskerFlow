import AppKit
import XCTest
import WhiskerFlowCore
import WhiskerFlowAppSupport
@testable import WhiskerFlow

@MainActor
private final class SuspendedPasteService: TextDeliveryService {
    var hasAccessibilityPermission = true
    var pending: CheckedContinuation<PasteDeliveryReceipt, Never>?
    var entered: (() -> Void)?
    func requestAccessibilityPermission() {}
    func copy(_ text: String) {}
    func paste(_ text: String, into application: NSRunningApplication?, replacing selection: TextFieldSnapshot?) async -> PasteDeliveryReceipt {
        await withCheckedContinuation { continuation in
            pending = continuation
            entered?()
        }
    }
}

/// Posts the keystroke, then holds verification open.
@MainActor
private final class PostedPasteService: TextDeliveryService {
    var hasAccessibilityPermission = true
    var pending: CheckedContinuation<PasteDeliveryReceipt, Never>?
    var posted: (() -> Void)?
    func requestAccessibilityPermission() {}
    func copy(_ text: String) {}
    func paste(_ text: String, into application: NSRunningApplication?, replacing selection: TextFieldSnapshot?) async -> PasteDeliveryReceipt {
        await paste(text, into: application, replacing: selection, onPosted: {})
    }
    func paste(_ text: String, into application: NSRunningApplication?, replacing selection: TextFieldSnapshot?,
               onPosted: @escaping @MainActor () -> Void) async -> PasteDeliveryReceipt {
        onPosted()
        return await withCheckedContinuation { continuation in
            pending = continuation
            posted?()
        }
    }
}

final class DictationDeliveryLifecycleTests: XCTestCase {
    @MainActor
    func testPasteVerificationDoesNotKeepFinishedRecognitionBusy() async {
        let name = "WhiskerFlow.delivery-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults, meetingTokenStore: MeetingCaptureTokenStore(service: name))
        let paste = SuspendedPasteService()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let state = AppState(settings: settings, store: TranscriptStore(fileURL: root), pasteService: paste)
        state.isTranscribing = true
        state.status = .transcribing
        let entered = expectation(description: "Paste sent, verification pending")
        paste.entered = { entered.fulfill() }
        let operation = Task { await state.deliver("Synthetic sentence", pasteTarget: nil, delivery: .pasteAtCursor, mayUpdateStatus: true) }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertFalse(state.isTranscribing, "Recognition finished before delivery; verification must not keep the microphone busy")
        XCTAssertNotEqual(state.status, .transcribing)
        paste.pending?.resume(returning: PasteDeliveryReceipt(state: .unverified, text: "Synthetic sentence", message: "Sent; unverified"))
        await operation.value
        XCTAssertFalse(state.status.isBusy)
    }
    @MainActor
    func testPasteIsReportedWhenKeystrokeIsPostedNotAfterVerification() async {
        let name = "WhiskerFlow.delivery-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults, meetingTokenStore: MeetingCaptureTokenStore(service: name))
        let paste = PostedPasteService()
        let state = AppState(settings: settings, store: TranscriptStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), pasteService: paste)
        let posted = expectation(description: "Keystroke posted, verification pending")
        paste.posted = { posted.fulfill() }
        let operation = Task { await state.deliver("Synthetic sentence", pasteTarget: nil, delivery: .pasteAtCursor, mayUpdateStatus: true) }
        await fulfillment(of: [posted], timeout: 2)
        XCTAssertEqual(state.status, .success("Pasted"), "The HUD must not hold \"Pasting…\" while insertion is verified")
        paste.pending?.resume(returning: PasteDeliveryReceipt(state: .unverified, text: "Synthetic sentence", message: "Pasted"))
        await operation.value
        XCTAssertEqual(state.status, .success("Pasted"))
        XCTAssertEqual(state.lastPasteReceipt?.state, .unverified)
    }

    @MainActor
    func testLatePasteReceiptCannotOverwriteANewerDelivery() async {
        let name = "WhiskerFlow.delivery-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults, meetingTokenStore: MeetingCaptureTokenStore(service: name))
        let paste = SuspendedPasteService()
        let state = AppState(settings: settings, store: TranscriptStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), pasteService: paste)
        let entered = expectation(description: "Old delivery waiting")
        paste.entered = { entered.fulfill() }
        let old = Task { await state.deliver("Old", pasteTarget: nil, delivery: .pasteAtCursor, mayUpdateStatus: true) }
        await fulfillment(of: [entered], timeout: 2)
        await state.deliver("New", pasteTarget: nil, delivery: .copyOnly, mayUpdateStatus: true)
        paste.pending?.resume(returning: PasteDeliveryReceipt(state: .unverified, text: "Old", message: "Old receipt"))
        await old.value
        XCTAssertEqual(state.status, .success("Copied to clipboard"))
        XCTAssertNil(state.lastPasteReceipt)
    }

}
