import XCTest
@testable import WhiskerFlowCore

final class PastedTextScopeTests: XCTestCase {
    func testSelectedUnicodeTextIsReplacedAndOnlyPastedSpanIsCompared() throws {
        let scope = try XCTUnwrap(PastedTextScope(before: "Hello 🌍. Goodbye.", selection: NSRange(location: 6, length: 2), pasted: "Jane and Mark"))
        XCTAssertTrue(scope.confirmsInsertion("Hello Jane and Mark. Goodbye."))
        XCTAssertEqual(scope.editedText(in: "Hello Jane and Marc. Goodbye."), "Jane and Marc")
        XCTAssertNil(scope.editedText(in: "Hi Jane and Marc. Goodbye."))
        XCTAssertNil(scope.editedText(in: "Hello Jane and Marc. See you."))
    }

    func testRejectsInvalidRangesAndUnconfirmedPaste() throws {
        XCTAssertNil(PastedTextScope(before: "🌍", selection: NSRange(location: 1, length: 1), pasted: "Hi"))
        XCTAssertNil(PastedTextScope(before: "Hi", selection: NSRange(location: 9, length: 0), pasted: "Hi"))
        let scope = try XCTUnwrap(PastedTextScope(before: "", selection: NSRange(location: 0, length: 0), pasted: "Hello Jane"))
        XCTAssertFalse(scope.confirmsInsertion("Hello John"))
        XCTAssertEqual(scope.editedText(in: "Hello Jane"), "Hello Jane")
    }
}

extension PastedTextScopeTests {
    func testShortCorrectionIsRememberedWithoutBroadRewriteLearning() {
        XCTAssertEqual(VocabularyCorrectionDetector.corrections(original: "Mark", edited: "Marc", allowShortCorrections: true), [.init(find: "Mark", replaceWith: "Marc")])
        XCTAssertTrue(VocabularyCorrectionDetector.corrections(original: "Hello Mark", edited: "Goodbye Jane", allowShortCorrections: true).isEmpty)
        XCTAssertTrue(VocabularyCorrectionDetector.corrections(original: "Hello Mark", edited: "Hello Mark tomorrow", allowShortCorrections: true).isEmpty)
    }
}

extension PastedTextScopeTests {
    func testContextNormalizationCannotShiftTheUTF16Scope() throws {
        let scope = try XCTUnwrap(PastedTextScope(before: "é!", selection: NSRange(location: 1, length: 0), pasted: "Mark"))
        XCTAssertTrue(scope.confirmsInsertion("éMark!"))
        XCTAssertFalse(scope.confirmsInsertion("e\u{301}Mark!"))
        XCTAssertNil(scope.editedText(in: "e\u{301}Marc!"))
    }
}
