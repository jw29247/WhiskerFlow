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
        PasteService.restore([ [.string: Data("Previous clipboard".utf8)] ], to: board, ifUnchangedSince: deliveryChangeCount)
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
}
