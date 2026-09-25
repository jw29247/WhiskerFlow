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

    func testMultilingualIdentifierMapsToTheMatchingModelAndTokenizerPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let applicationSupport = root.appendingPathComponent("Application Support", isDirectory: true)
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        let legacyBase = documents.appendingPathComponent("huggingface", isDirectory: true)
        let legacyModel = legacyBase
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-small", isDirectory: true)
        let legacyTokenizer = legacyBase
            .appendingPathComponent("models/openai/whisper-small", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyModel, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyTokenizer, withIntermediateDirectories: true)
        try Data("model".utf8).write(to: legacyModel.appendingPathComponent("config.json"))
        try Data("tokenizer".utf8).write(to: legacyTokenizer.appendingPathComponent("tokenizer.json"))

        let assets = try XCTUnwrap(ModelStoragePaths.prepareLocalAssets(
            modelIdentifier: "openai_whisper-small",
            applicationSupport: applicationSupport,
            documents: documents
        ))

        let base = ModelStoragePaths.whisperKitDownloadBase(in: applicationSupport)
        XCTAssertEqual(
            assets.modelFolder,
            base.appendingPathComponent(
                "models/argmaxinc/whisperkit-coreml/openai_whisper-small",
                isDirectory: true
            )
        )
        XCTAssertEqual(assets.tokenizerDownloadBase, base)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: assets.tokenizerDownloadBase
                .appendingPathComponent("models/openai/whisper-small/tokenizer.json")
                .path
        ))
    }

    /// WhisperKit keeps one tokenizer per model family. Looking for one named
    /// after the CoreML variant never found the meeting model's tokenizer, so
    /// every meeting load went to the network and failed offline.
    func testTokenizerFolderFollowsWhisperKitsModelFamily() {
        XCTAssertEqual(
            ModelStoragePaths.tokenizerFolderName(
                forModelIdentifier: "openai_whisper-large-v3-v20240930_turbo_632MB"),
            "whisper-large-v3"
        )
        XCTAssertEqual(ModelStoragePaths.tokenizerFolderName(forModelIdentifier: "openai_whisper-large-v3"), "whisper-large-v3")
        XCTAssertEqual(ModelStoragePaths.tokenizerFolderName(forModelIdentifier: "openai_whisper-large-v2_949MB"), "whisper-large-v2")
        XCTAssertEqual(ModelStoragePaths.tokenizerFolderName(forModelIdentifier: "openai_whisper-small.en"), "whisper-small.en")
        XCTAssertEqual(ModelStoragePaths.tokenizerFolderName(forModelIdentifier: "openai_whisper-small_216MB"), "whisper-small")
        XCTAssertEqual(ModelStoragePaths.tokenizerFolderName(forModelIdentifier: "openai_whisper-medium"), "whisper-medium")
        XCTAssertEqual(ModelStoragePaths.tokenizerFolderName(forModelIdentifier: "openai_whisper-tiny.en"), "whisper-tiny.en")
    }

    func testDownloadedMeetingModelIsFoundLocallyWithItsFamilyTokenizer() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let applicationSupport = root.appendingPathComponent("Application Support", isDirectory: true)
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        let base = ModelStoragePaths.whisperKitDownloadBase(in: applicationSupport)
        let identifier = "openai_whisper-large-v3-v20240930_turbo_632MB"
        let model = base.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(identifier)", isDirectory: true)
        let tokenizer = base.appendingPathComponent("models/openai/whisper-large-v3", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tokenizer, withIntermediateDirectories: true)
        try Data("tokenizer".utf8).write(to: tokenizer.appendingPathComponent("tokenizer.json"))

        let assets = try XCTUnwrap(ModelStoragePaths.prepareLocalAssets(
            modelIdentifier: identifier,
            applicationSupport: applicationSupport,
            documents: documents
        ))
        XCTAssertEqual(assets.modelFolder, model)
        XCTAssertEqual(assets.tokenizerDownloadBase, base)
    }

    /// An interrupted legacy copy must not leave a destination that is then
    /// trusted as a complete model forever.
    func testFailedLegacyCopyLeavesNoPartialDestination() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let applicationSupport = root.appendingPathComponent("Application Support", isDirectory: true)
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        let legacyModel = documents
            .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-small.en", isDirectory: true)
        let unreadable = legacyModel.appendingPathComponent("weights.bin")
        try FileManager.default.createDirectory(at: legacyModel, withIntermediateDirectories: true)
        try Data("model".utf8).write(to: legacyModel.appendingPathComponent("config.json"))
        try Data("weights".utf8).write(to: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path)
            try? FileManager.default.removeItem(at: root)
        }
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: unreadable.path), "Running with elevated file access")

        XCTAssertThrowsError(try ModelStoragePaths.prepareLocalAssets(
            modelIdentifier: "openai_whisper-small.en",
            applicationSupport: applicationSupport,
            documents: documents
        ))
        let parent = ModelStoragePaths.whisperKitDownloadBase(in: applicationSupport)
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: parent.appendingPathComponent("openai_whisper-small.en").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
    }
}
