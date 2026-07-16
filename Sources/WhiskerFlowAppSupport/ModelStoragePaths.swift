import Foundation

public struct WhisperKitLocalAssets: Sendable {
    public let modelFolder: URL
    public let tokenizerDownloadBase: URL
}

public enum ModelStoragePaths {
    public static func whisperKitDownloadBase(in applicationSupport: URL) -> URL {
        applicationSupport
            .appendingPathComponent("WhiskerFlow", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    public static func prepareWhisperKitDownloadBase(
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = whisperKitDownloadBase(in: applicationSupport)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    public static func prepareLocalAssets(
        modelIdentifier: String,
        fileManager: FileManager = .default
    ) throws -> WhisperKitLocalAssets? {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first,
        let documents = fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return try prepareLocalAssets(
            modelIdentifier: modelIdentifier,
            applicationSupport: applicationSupport,
            documents: documents,
            fileManager: fileManager
        )
    }

    public static func prepareLocalAssets(
        modelIdentifier: String,
        applicationSupport: URL,
        documents: URL,
        fileManager: FileManager = .default
    ) throws -> WhisperKitLocalAssets? {
        let localBase = whisperKitDownloadBase(in: applicationSupport)
        try fileManager.createDirectory(at: localBase, withIntermediateDirectories: true)

        let modelRelativePath = "models/argmaxinc/whisperkit-coreml/\(modelIdentifier)"
        let tokenizerIdentifier = modelIdentifier.replacingOccurrences(
            of: "openai_whisper-",
            with: "whisper-"
        )
        let tokenizerRelativePath = "models/openai/\(tokenizerIdentifier)"
        let localModel = localBase.appendingPathComponent(modelRelativePath, isDirectory: true)
        let localTokenizer = localBase.appendingPathComponent(tokenizerRelativePath, isDirectory: true)
        let legacyBase = documents.appendingPathComponent("huggingface", isDirectory: true)

        try copyDirectoryIfNeeded(
            from: legacyBase.appendingPathComponent(modelRelativePath, isDirectory: true),
            to: localModel,
            fileManager: fileManager
        )
        try copyDirectoryIfNeeded(
            from: legacyBase.appendingPathComponent(tokenizerRelativePath, isDirectory: true),
            to: localTokenizer,
            fileManager: fileManager
        )

        guard fileManager.fileExists(atPath: localModel.path),
              fileManager.fileExists(
                atPath: localTokenizer.appendingPathComponent("tokenizer.json").path
              ) else { return nil }
        return WhisperKitLocalAssets(
            modelFolder: localModel,
            tokenizerDownloadBase: localBase
        )
    }

    private static func copyDirectoryIfNeeded(
        from source: URL,
        to destination: URL,
        fileManager: FileManager
    ) throws {
        guard !fileManager.fileExists(atPath: destination.path),
              fileManager.fileExists(atPath: source.path) else { return }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.copyItem(at: source, to: destination)
    }
}
