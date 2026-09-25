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
        let tokenizerRelativePath = "models/openai/\(tokenizerFolderName(forModelIdentifier: modelIdentifier))"
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

    /// WhisperKit stores one tokenizer per model family, named after the
    /// OpenAI repo (`ModelUtilities.tokenizerNameForVariant`), not per CoreML
    /// variant: every large-v3 build, including the pinned turbo meeting model,
    /// shares `whisper-large-v3`. Size suffixes such as `_216MB` are dropped.
    public static func tokenizerFolderName(forModelIdentifier modelIdentifier: String) -> String {
        let name = modelIdentifier.lowercased()
        for family in ["large-v3", "large-v2"] where name.contains(family) {
            return "whisper-\(family)"
        }
        for size in ["tiny", "base", "small", "medium", "large"] where name.contains("whisper-\(size)") {
            let englishOnly = size != "large" && name.contains("whisper-\(size).en")
            return "whisper-\(size)\(englishOnly ? ".en" : "")"
        }
        return modelIdentifier.replacingOccurrences(of: "openai_whisper-", with: "whisper-")
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
        // Copy beside the destination and move into place only once complete: an
        // existing destination is trusted as a finished model, so a copy cut short
        // by a quit or a full disk must never leave one behind.
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).partial", isDirectory: true)
        try? fileManager.removeItem(at: staging)
        do {
            try fileManager.copyItem(at: source, to: staging)
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }
}
