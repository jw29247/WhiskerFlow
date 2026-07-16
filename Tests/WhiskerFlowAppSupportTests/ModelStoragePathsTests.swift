import XCTest
@testable import WhiskerFlowAppSupport

final class ModelStoragePathsTests: XCTestCase {
    func testWhisperKitModelsUseApplicationSupportInsteadOfDocuments() {
        let applicationSupport = URL(fileURLWithPath: "/Users/test/Library/Application Support")

        XCTAssertEqual(
            ModelStoragePaths.whisperKitDownloadBase(in: applicationSupport),
            applicationSupport
                .appendingPathComponent("WhiskerFlow", isDirectory: true)
                .appendingPathComponent("Models", isDirectory: true)
        )
    }

    func testExistingLegacyModelAndTokenizerAreMigratedForOfflineLoading() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let applicationSupport = root.appendingPathComponent("Application Support", isDirectory: true)
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        let legacyBase = documents.appendingPathComponent("huggingface", isDirectory: true)
        let legacyModel = legacyBase
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-small.en", isDirectory: true)
        let legacyTokenizer = legacyBase
            .appendingPathComponent("models/openai/whisper-small.en", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyModel, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyTokenizer, withIntermediateDirectories: true)
        try Data("model".utf8).write(to: legacyModel.appendingPathComponent("config.json"))
        try Data("tokenizer".utf8).write(to: legacyTokenizer.appendingPathComponent("tokenizer.json"))

        let assets = try XCTUnwrap(ModelStoragePaths.prepareLocalAssets(
            modelIdentifier: "openai_whisper-small.en",
            applicationSupport: applicationSupport,
            documents: documents
        ))

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: assets.modelFolder.appendingPathComponent("config.json").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: assets.tokenizerDownloadBase
                .appendingPathComponent("models/openai/whisper-small.en/tokenizer.json")
                .path
        ))
        XCTAssertFalse(assets.modelFolder.path.hasPrefix(documents.path))
    }
}
