import XCTest
@testable import WhiskerFlowAppSupport

final class ModelStoragePathsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("model-paths-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ relativePath: String, bytes: Int = 4096) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
    }

    private func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).path)
    }

    func testRemovesWhisperModelsAndTokenizers() throws {
        try write("WhiskerFlow/Models/models/argmaxinc/whisperkit-coreml/openai_whisper-tiny/model.bin")
        try write("WhiskerFlow/Models/models/openai/whisper-tiny/tokenizer.json")

        let freed = ModelStoragePaths.removeWhisperModels(applicationSupport: root)

        XCTAssertGreaterThan(freed, 0)
        XCTAssertFalse(exists("WhiskerFlow/Models/models/argmaxinc"))
        XCTAssertFalse(exists("WhiskerFlow/Models/models/openai"))
        XCTAssertFalse(exists("WhiskerFlow/Models"), "Empty parents go too")
        XCTAssertTrue(exists("WhiskerFlow"))
    }

    func testKeepsEverythingElse() throws {
        try write("WhiskerFlow/Models/models/argmaxinc/whisperkit-coreml/x/model.bin")
        try write("WhiskerFlow/Models/models/argmaxinc/speakerkit-coreml/pyannote/model.bin")
        try write("WhiskerFlow/transcripts.sqlite")
        try write("FluidAudio/Models/parakeet-tdt-0.6b-v3/encoder.bin")

        ModelStoragePaths.removeWhisperModels(applicationSupport: root)

        XCTAssertFalse(exists("WhiskerFlow/Models/models/argmaxinc/whisperkit-coreml"))
        XCTAssertTrue(exists("WhiskerFlow/Models/models/argmaxinc/speakerkit-coreml/pyannote/model.bin"))
        XCTAssertTrue(exists("WhiskerFlow/transcripts.sqlite"))
        XCTAssertTrue(exists("FluidAudio/Models/parakeet-tdt-0.6b-v3/encoder.bin"))
    }

    func testNothingToRemoveIsANoOp() {
        XCTAssertEqual(ModelStoragePaths.removeWhisperModels(applicationSupport: root), 0)
        XCTAssertTrue(exists(""))
    }
}
