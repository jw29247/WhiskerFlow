import XCTest
import WhiskerFlowCore
@testable import WhiskerFlow

@MainActor
final class CorrectionStoreTests: XCTestCase {
    func testStableSamplesDeduplicateAndUndoRemovesOnlyCurrentPaste() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("corrections.json")
        let store = CorrectionStore(fileURL: url)
        let first = UUID(), second = UUID()
        let correction = VocabularyCorrection(find: "Mark", replaceWith: "Marc")
        store.record([correction], sessionID: first, application: "TextEdit")
        store.record([correction, correction], sessionID: first, application: "TextEdit")
        XCTAssertEqual(store.records.count, 1)
        store.record([correction], sessionID: second, application: "Notes")
        XCTAssertEqual(store.records.count, 2)
        store.record([], sessionID: second, application: "Notes")
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(CorrectionStore(fileURL: url).records, store.records)
        let data = try String(contentsOf: url)
        XCTAssertFalse(data.contains("transcript"))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
        store.remove(correction)
        XCTAssertTrue(CorrectionStore(fileURL: url).records.isEmpty)
    }

    func testCorruptFileIsPreservedAndErrorIsVisible() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("corrections.json")
        let original = Data("corrupt".utf8)
        try original.write(to: url)
        let store = CorrectionStore(fileURL: url)
        store.record([.init(find: "a", replaceWith: "b")], sessionID: UUID(), application: "Test")
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
}
