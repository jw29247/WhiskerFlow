import Foundation

public enum ModelStoragePaths {
    /// WhiskerFlow's own model folder in Application Support.
    public static func modelsBase(in applicationSupport: URL) -> URL {
        applicationSupport
            .appendingPathComponent("WhiskerFlow", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// Where WhisperKit kept its Core ML models and tokenizers. Whisper was
    /// removed, so these are dead weight (often several GB). SpeakerKit and
    /// Parakeet keep their models elsewhere, and other apps' Whisper models
    /// (in the shared Hugging Face folder) are never touched.
    public static func removedWhisperFolders(in applicationSupport: URL) -> [URL] {
        let models = modelsBase(in: applicationSupport).appendingPathComponent("models", isDirectory: true)
        return [
            models.appendingPathComponent("argmaxinc/whisperkit-coreml", isDirectory: true),
            models.appendingPathComponent("openai", isDirectory: true),
        ]
    }

    /// Deletes the removed Whisper downloads and returns the bytes freed. Safe
    /// to call on every launch: once they are gone it only checks two paths.
    @discardableResult
    public static func removeWhisperModels(applicationSupport: URL, fileManager: FileManager = .default) -> Int64 {
        var freed: Int64 = 0
        for folder in removedWhisperFolders(in: applicationSupport) where fileManager.fileExists(atPath: folder.path) {
            let size = allocatedSize(of: folder, fileManager: fileManager)
            if (try? fileManager.removeItem(at: folder)) != nil { freed += size }
        }
        // Drop the folders left empty, never anything that still has contents.
        var parent = modelsBase(in: applicationSupport).appendingPathComponent("models/argmaxinc", isDirectory: true)
        for _ in 0..<3 {
            guard let contents = try? fileManager.contentsOfDirectory(atPath: parent.path),
                  contents.allSatisfy({ $0 == ".DS_Store" }) else { break }
            try? fileManager.removeItem(at: parent)
            parent.deleteLastPathComponent()
        }
        return freed
    }

    public static func removeWhisperModels(fileManager: FileManager = .default) -> Int64 {
        guard let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return 0
        }
        return removeWhisperModels(applicationSupport: applicationSupport, fileManager: fileManager)
    }

    private static func allocatedSize(of folder: URL, fileManager: FileManager) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: []
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
