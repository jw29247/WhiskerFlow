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
        let restorer = ClipboardRestorer()
        restorer.begin(on: board)
        board.clearContents(); board.setString("Dictation", forType: .string)
        restorer.delivered(changeCount: board.changeCount)
        restorer.finish(on: board, changeCount: board.changeCount, after: 0.2)
        XCTAssertEqual(board.string(forType: .string), "Dictation")
        try await Task.sleep(nanoseconds: 600_000_000)
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

    @MainActor
    func testPasteKeyResolvesThroughTheKeyboardLayout() {
        // QWERTY resolves to ANSI V (9); Dvorak to 47. Any layout yields a real key.
        XCTAssertLessThan(PasteService.pasteKeyCode(), 128)
    }
}
