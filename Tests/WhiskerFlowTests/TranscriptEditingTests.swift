import XCTest
@testable import WhiskerFlow
import WhiskerFlowCore
import WhiskerFlowAppSupport

final class TranscriptEditingTests: XCTestCase {
    @MainActor
    func testSavingPrunedTranscriptRecoversTextWithoutResurrectingAudio() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TranscriptStore(fileURL: root.appendingPathComponent("history.json"), retentionLimit: 1, removeAudioFile: { _ in })
        let old = TranscriptRecord(text: "Original", audioFilePath: "/already/pruned.wav", createdAt: Date().addingTimeInterval(-100), status: .transcribed)
        try store.add(old)
        try store.add(TranscriptRecord(text: "New dictation", audioFilePath: "", status: .transcribed))
        let state = makeState(store: store)
        let recovered = try XCTUnwrap(state.saveEditedTranscript(old, text: "Unsaved correction"))
        XCTAssertNotEqual(recovered.id, old.id)
        XCTAssertEqual(recovered.text, "Unsaved correction")
        XCTAssertEqual(recovered.audioFilePath, "")
        XCTAssertEqual(state.records.first?.text, "Unsaved correction")
    }

    @MainActor
    func testSaveFailureDoesNotPretendRecoverySucceeded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A directory cannot be atomically replaced by the history JSON file.
        let store = TranscriptStore(fileURL: root)
        let state = makeState(store: store)
        let record = TranscriptRecord(text: "Original", audioFilePath: "", status: .transcribed)
        XCTAssertNil(state.saveEditedTranscript(record, text: "Keep my draft"))
        if case .failure = state.status {} else { XCTFail("Save failure must be visible") }
    }

    @MainActor
    func testHistoryCorrectionsPersistOnceAndRespectUndoAndDisable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TranscriptStore(fileURL: root.appendingPathComponent("history.json"))
        let record = TranscriptRecord(text: "Please send the report to Mark before Friday.", audioFilePath: "", status: .transcribed)
        try store.add(record)
        let state = makeState(store: store)
        state.updateText(record, to: "Please send the report to Marc before Friday.")
        XCTAssertEqual(state.corrections.records.map(\.replacement), ["Marc"])
        let edited = try XCTUnwrap(state.records.first)
        state.updateText(edited, to: edited.text)
        XCTAssertEqual(state.corrections.records.count, 1)
        state.updateText(edited, to: record.text)
        XCTAssertTrue(state.corrections.records.isEmpty)
        state.settings.rememberCorrections = false
        state.updateText(record, to: "Please send the report to Marc before Friday.")
        XCTAssertTrue(state.corrections.records.isEmpty)
    }

    @MainActor
    private func makeState(store: TranscriptStore) -> AppState {
        let name = "WhiskerFlow.editor-tests.\(UUID().uuidString)"
        let settings = AppSettings(defaults: UserDefaults(suiteName: name)!, meetingTokenStore: MeetingCaptureTokenStore(service: name))
        let state = AppState(settings: settings, store: store)
        state.records = store.records
        return state
    }
}
