import AppKit
import XCTest
@testable import WhiskerFlow

final class PasteServiceTests: XCTestCase {
    @MainActor
    func testAnOriginallyEmptyClipboardIsRestoredToEmpty() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("Temporary delivery", forType: .string)
        PasteService.restore([], to: board, ifUnchangedSince: board.changeCount)
        XCTAssertNil(board.string(forType: .string))
    }

    @MainActor
    func testDelayedRestoreDoesNotOverwriteNewCopy() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("Dictated text", forType: .string)
        let deliveryChangeCount = board.changeCount
        board.clearContents()
        board.setString("New copy", forType: .string)
        PasteService.restore([[.string: Data("Previous clipboard".utf8)]], to: board, ifUnchangedSince: deliveryChangeCount)
        XCTAssertEqual(board.string(forType: .string), "New copy")
    }

    @MainActor
    func testUnchangedClipboardRestoresAllOriginalTypes() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("Dictated text", forType: .string)
        let snapshot: [[NSPasteboard.PasteboardType: Data]] = [[.string: Data("Original".utf8), .html: Data("<b>Original</b>".utf8)]]
        PasteService.restore(snapshot, to: board, ifUnchangedSince: board.changeCount)
        XCTAssertEqual(board.string(forType: .string), "Original")
        XCTAssertEqual(board.string(forType: .html), "<b>Original</b>")
    }

    /// Regression: a second delivery that starts while the first one's delayed
    /// restore is pending must restore the user's clipboard, not the first dictation.
    @MainActor
    func testOverlappingDeliveriesRestoreTheOriginalClipboard() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("User clipboard", forType: .string)
        let restorer = ClipboardRestorer()
        restorer.begin(on: board)
        board.clearContents(); board.setString("First dictation", forType: .string)
        restorer.delivered(changeCount: board.changeCount)
        restorer.finish(on: board, changeCount: board.changeCount, after: 60)
        restorer.begin(on: board)
        board.clearContents(); board.setString("Second dictation", forType: .string)
        restorer.delivered(changeCount: board.changeCount)
        restorer.finish(on: board, changeCount: board.changeCount, after: 0)
        XCTAssertEqual(board.string(forType: .string), "User clipboard")
    }

    @MainActor
    func testANewCopyBetweenDeliveriesBecomesTheClipboardToRestore() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("Old copy", forType: .string)
        let restorer = ClipboardRestorer()
        restorer.begin(on: board)
        board.clearContents(); board.setString("First dictation", forType: .string)
        restorer.delivered(changeCount: board.changeCount)
        restorer.finish(on: board, changeCount: board.changeCount, after: 60)
        board.clearContents(); board.setString("New copy", forType: .string)
        restorer.begin(on: board)
        board.clearContents(); board.setString("Second dictation", forType: .string)
        restorer.delivered(changeCount: board.changeCount)
        restorer.finish(on: board, changeCount: board.changeCount, after: 0)
        XCTAssertEqual(board.string(forType: .string), "New copy")
    }

    @MainActor
    func testUnverifiedDeliveryKeepsDictationOnTheClipboardUntilTheDelay() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("User clipboard", forType: .string)
        let delay = ManualDeadline()
        let restorer = ClipboardRestorer(sleep: delay.sleep)
        restorer.begin(on: board)
        board.clearContents(); board.setString("Dictation", forType: .string)
        restorer.delivered(changeCount: board.changeCount)
        restorer.finish(on: board, changeCount: board.changeCount, after: 0.2)
        let restore = try XCTUnwrap(restorer.pendingRestore)
        await delay.untilRequested(1)
        XCTAssertEqual(delay.requested, [200_000_000])
        XCTAssertEqual(board.string(forType: .string), "Dictation", "kept until the delay has passed")
        delay.fire()
        await restore.value
        XCTAssertEqual(board.string(forType: .string), "User clipboard")
        XCTAssertGreaterThanOrEqual(PasteService.unverifiedRestoreDelay(activationSeconds: 0), 2.5)
        XCTAssertGreaterThan(PasteService.unverifiedRestoreDelay(activationSeconds: 1.2),
                             PasteService.unverifiedRestoreDelay(activationSeconds: 0))
    }

    @MainActor
    func testSnapshotReadsOneImageRenderingPerItem() {
        let excel: [NSPasteboard.PasteboardType] = [.string, .rtf, .html, .pdf, .tiff, .png,
                                                     .init("com.microsoft.Excel.sheet"), .init("com.apple.pict")]
        XCTAssertEqual(PasteService.snapshotTypes(excel), [.string, .rtf, .html, .init("com.microsoft.Excel.sheet"), .pdf])
        XCTAssertEqual(PasteService.snapshotTypes([.tiff, .png]), [.png])
        XCTAssertEqual(PasteService.snapshotTypes([.tiff]), [.tiff])
        XCTAssertEqual(PasteService.snapshotTypes([.string]), [.string])
    }

    @MainActor
    func testRestoredClipboardIsMarkedAppGenerated() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("Dictated text", forType: .string)
        PasteService.restore([[.string: Data("Original".utf8)]], to: board, ifUnchangedSince: board.changeCount)
        XCTAssertEqual(board.string(forType: .string), "Original")
        XCTAssertNotNil(board.data(forType: PasteService.autoGeneratedType))
    }

    /// Every reason a paste can fail after recognition leaves the text on the
    /// clipboard and says so, without claiming it is merely "ready to copy".
    @MainActor
    func testEveryFailedDeliveryLeavesTheTextOnTheClipboard() {
        let reasons: [(String, PasteDeliveryReceipt.Detail)] = [
            ("Couldn’t paste.", .noDestination), ("Couldn’t reach the app.", .notFrontmost),
            ("The selection changed.", .selectionChanged)
        ]
        for (reason, detail) in reasons {
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            board.setString("User clipboard", forType: .string)
            let receipt = PasteService.leaveOnClipboard("Dictated text", reason: reason, retry: nil, detail,
                                                        on: board, restorer: ClipboardRestorer())
            XCTAssertEqual(board.string(forType: .string), "Dictated text", "\(detail)")
            XCTAssertEqual(receipt.state, .failed)
            XCTAssertEqual(receipt.detail, detail)
            XCTAssertEqual(receipt.text, "Dictated text")
            XCTAssertEqual(receipt.message, "\(reason) Your text is on the clipboard.")
        }
    }

    /// The paste key failed after the dictation was written: it stays there and
    /// the user's earlier clipboard is not put back over it.
    @MainActor
    func testAFailedPasteDoesNotRestoreThePreviousClipboard() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("User clipboard", forType: .string)
        let restorer = ClipboardRestorer()
        restorer.begin(on: board)
        board.clearContents(); board.setString("Dictation", forType: .string)
        restorer.delivered(changeCount: board.changeCount)
        let receipt = PasteService.leaveOnClipboard("Dictation", reason: "Couldn’t paste.", retry: nil, .keyFailed,
                                                    on: board, restorer: restorer)
        restorer.finish(on: board, changeCount: board.changeCount, after: 0)
        XCTAssertEqual(board.string(forType: .string), "Dictation")
        XCTAssertEqual(receipt.message, "Couldn’t paste. Your text is on the clipboard.")
    }

    /// An earlier unverified paste's pending restore must not replace text a
    /// later failed delivery left on the clipboard.
    @MainActor
    func testAFailedDeliveryCancelsAnEarlierPendingRestore() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("User clipboard", forType: .string)
        let restorer = ClipboardRestorer()
        restorer.begin(on: board)
        board.clearContents(); board.setString("First dictation", forType: .string)
        restorer.delivered(changeCount: board.changeCount)
        restorer.finish(on: board, changeCount: board.changeCount, after: 60)
        _ = PasteService.leaveOnClipboard("Second dictation", reason: "Couldn’t paste.", retry: nil, .noDestination,
                                          on: board, restorer: restorer)
        // Nothing saved is left to restore, even if a later delivery finishes now.
        restorer.finish(on: board, changeCount: board.changeCount, after: 0)
        XCTAssertEqual(board.string(forType: .string), "Second dictation")
    }

    /// Dictating with WhiskerFlow itself in front copies the text and reports it
    /// as a success, instead of failing with "Destination unavailable".
    @MainActor
    func testOwnAppDestinationCopiesInsteadOfFailing() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("User clipboard", forType: .string)
        // A test host is not an app, so stand in another app's process for ours.
        // The copy returns before anything is sent to it.
        guard let standIn = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier > 0 && !$0.isTerminated }) else {
            return XCTFail("No running application to stand in for WhiskerFlow")
        }
        var service = PasteService(pasteboard: board)
        service.ownProcessIdentifier = standIn.processIdentifier
        let receipt = await service.paste("Dictated text", into: standIn, replacing: nil)
        XCTAssertEqual(receipt.state, .copied)
        XCTAssertEqual(receipt.detail, .ownApp)
        XCTAssertEqual(receipt.message, "Copied. Click into any app to paste.")
        XCTAssertEqual(board.string(forType: .string), "Dictated text")
    }

    @MainActor
    func testPasteKeyResolvesThroughTheKeyboardLayout() {
        // QWERTY resolves to ANSI V (9); Dvorak to 47. Any layout yields a real key.
        XCTAssertLessThan(PasteService.pasteKeyCode(), 128)
    }
}
