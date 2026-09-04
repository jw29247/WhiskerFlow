import XCTest
@testable import WhiskerFlowCore

final class TranscriptDraftTests: XCTestCase {
    func testChangingSelectionCannotOverwriteUnsavedText() {
        let first = UUID(), second = UUID()
        var draft = TranscriptDraft()
        XCTAssertTrue(draft.select(id: first, text: "Original"))
        draft.text = "My correction"
        XCTAssertFalse(draft.select(id: second, text: "Another transcript"))
        XCTAssertEqual(draft.recordID, first)
        XCTAssertEqual(draft.text, "My correction")
    }

    func testCompletedTranscriptionUpdatesCleanDraftForSameRecord() {
        let id = UUID()
        var draft = TranscriptDraft()
        draft.select(id: id, text: "")
        draft.synchronize(id: id, text: "Finished transcript")
        XCTAssertEqual(draft.text, "Finished transcript")
        XCTAssertFalse(draft.isDirty)
    }

    func testSourceRefreshPreservesDirtyDraftAndDiscardUsesLatestSource() {
        let id = UUID()
        var draft = TranscriptDraft()
        draft.select(id: id, text: "Original")
        draft.text = "My correction"
        draft.synchronize(id: id, text: "New source")
        XCTAssertEqual(draft.text, "My correction")
        XCTAssertTrue(draft.isDirty)
        draft.discard()
        XCTAssertEqual(draft.text, "New source")
        XCTAssertFalse(draft.isDirty)
    }

    func testEmptyEditIsDirtyUntilConfirmedSaved() {
        var draft = TranscriptDraft()
        draft.select(id: UUID(), text: "Remove me")
        draft.text = ""
        XCTAssertTrue(draft.isDirty)
        draft.didSave()
        XCTAssertEqual(draft.text, "")
        XCTAssertFalse(draft.isDirty)
    }

    func testUnrelatedRecordRefreshDoesNotChangeEditor() {
        let id = UUID()
        var draft = TranscriptDraft()
        draft.select(id: id, text: "Keep me")
        draft.synchronize(id: UUID(), text: "Other")
        XCTAssertEqual(draft.recordID, id)
        XCTAssertEqual(draft.text, "Keep me")
    }
}
