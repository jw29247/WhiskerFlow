import Foundation

public enum TranscriptStatus: Codable, Equatable, Hashable, Sendable {
    case recording
    case transcribing
    case transcribed
    case failed(errorMessage: String)

    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    public var isInProgress: Bool {
        switch self {
        case .recording, .transcribing: return true
        case .transcribed, .failed: return false
        }
    }
}

public struct TranscriptRecord: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var text: String
    public var audioFilePath: String
    public var createdAt: Date
    public var status: TranscriptStatus

    // Optional metadata (added later — decode as nil for older records).
    public var durationSeconds: Double?
    public var model: String?
    public var engine: String?
    public var language: String?
    public var updatedAt: Date?

    public init(
        id: UUID = UUID(),
        text: String,
        audioFilePath: String,
        createdAt: Date = Date(),
        status: TranscriptStatus,
        durationSeconds: Double? = nil,
        model: String? = nil,
        engine: String? = nil,
        language: String? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.text = text
        self.audioFilePath = audioFilePath
        self.createdAt = createdAt
        self.status = status
        self.durationSeconds = durationSeconds
        self.model = model
        self.engine = engine
        self.language = language
        self.updatedAt = updatedAt
    }

    public var wordCount: Int { text.transcriptWordCount }
}

public enum TranscriptStoreError: LocalizedError, Equatable {
    case corruptFileUnrecoverable(path: String)

    public var errorDescription: String? {
        switch self {
        case .corruptFileUnrecoverable(let path):
            return "Transcript history at \(path) could not be read and could not be backed up. "
                + "The file was left untouched; move it aside manually to start a new history."
        }
    }
}

public final class TranscriptStore {
    private let fileURL: URL
    private let now: () -> Date
    private let removeAudioFile: (String) -> Void
    private let retentionInterval: TimeInterval
    private let retentionLimit: Int
    private let recordingsDirectory: URL?
    private let fileManager: FileManager
    private let moveItem: (URL, URL) throws -> Void
    private let copyItem: (URL, URL) throws -> Void
    private var persistenceSuspended = false

    public private(set) var records: [TranscriptRecord] = []

    public init(
        fileURL: URL,
        now: @escaping () -> Date = Date.init,
        retentionInterval: TimeInterval = 30 * 24 * 60 * 60,
        retentionLimit: Int = 25,
        recordingsDirectory: URL? = nil,
        fileManager: FileManager = .default,
        removeAudioFile: @escaping (String) -> Void = { path in
            guard !path.isEmpty else { return }
            try? FileManager.default.removeItem(atPath: path)
        },
        moveItem: @escaping (URL, URL) throws -> Void = { source, destination in
            try FileManager.default.moveItem(at: source, to: destination)
        },
        copyItem: @escaping (URL, URL) throws -> Void = { source, destination in
            try FileManager.default.copyItem(at: source, to: destination)
        }
    ) {
        self.fileURL = fileURL
        self.now = now
        self.retentionInterval = retentionInterval
        self.retentionLimit = max(1, retentionLimit)
        self.recordingsDirectory = recordingsDirectory
        self.fileManager = fileManager
        self.removeAudioFile = removeAudioFile
        self.moveItem = moveItem
        self.copyItem = copyItem
    }

    public var retryQueue: [TranscriptRecord] {
        records.filter { $0.status.isFailed }
    }

    public func load() throws {
        persistenceSuspended = false
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            records = []
            try pruneExpired()
            return
        }

        let data = try Data(contentsOf: fileURL)
        do {
            records = try JSONDecoder.whiskerFlow.decode([TranscriptRecord].self, from: data)
        } catch {
            // Don't silently overwrite a file we can't parse — preserve it so the
            // user (or a future migration) can recover, then start clean. Without a
            // backup on disk, writing would destroy the only copy, so suspend
            // persistence instead of clobbering the original bytes.
            records = []
            guard backupCorruptFile() else {
                persistenceSuspended = true
                throw TranscriptStoreError.corruptFileUnrecoverable(path: fileURL.path)
            }
            try persist()
            return
        }
        try pruneExpired()
    }

    public func add(_ record: TranscriptRecord) throws {
        records.insert(record, at: 0)
        try pruneExpired()
    }

    /// Persistence stays suspended if `load()` suspended it: an unreadable history
    /// that could not be backed up is the only copy of those bytes, and replacing
    /// the whole list is no more entitled to destroy it than `add` is. Only a fresh
    /// `load()`, which re-reads the file, can clear the suspension.
    public func replaceAll(_ records: [TranscriptRecord]) throws {
        self.records = records
        try persist()
    }

    public func update(_ record: TranscriptRecord) throws {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[index] = record
        try persist()
    }

    public func setText(id: UUID, text: String) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].text = text
        records[index].updatedAt = now()
        try persist()
    }

    public func markTranscribing(id: UUID) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].status = .transcribing
        try persist()
    }

    public func markTranscribed(
        id: UUID,
        text: String,
        durationSeconds: Double? = nil,
        model: String? = nil,
        engine: String? = nil,
        language: String? = nil
    ) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }

        records[index].text = text
        records[index].status = .transcribed
        records[index].updatedAt = now()
        if let durationSeconds { records[index].durationSeconds = durationSeconds }
        if let model { records[index].model = model }
        if let engine { records[index].engine = engine }
        if let language { records[index].language = language }
        try persist()
    }

    public func markFailed(id: UUID, message: String) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }

        records[index].status = .failed(errorMessage: message)
        records[index].updatedAt = now()
        try persist()
    }

    public func delete(id: UUID) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        removeAudioFile(records[index].audioFilePath)
        records.remove(at: index)
        try persist()
    }

    public func pruneExpired() throws {
        let cutoff = now().addingTimeInterval(-retentionInterval)
        let ordered = records.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt { return lhs.id.uuidString > rhs.id.uuidString }
            return lhs.createdAt > rhs.createdAt
        }
        let recent = ordered.filter { $0.createdAt >= cutoff }
        let retained = Array(recent.prefix(retentionLimit))
        let removedRecords = ordered.filter { record in
            !retained.contains { $0.id == record.id }
        }
        for record in removedRecords {
            removeAudioFile(record.audioFilePath)
        }
        records = retained
        removeOldOrphanedAudioFiles(cutoff: cutoff)
        try persist()
    }

    private func removeOldOrphanedAudioFiles(cutoff: Date) {
        guard let recordingsDirectory,
              let urls = try? fileManager.contentsOfDirectory(
                  at: recordingsDirectory,
                  includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                  options: [.skipsHiddenFiles]
              ) else { return }

        let retainedPaths = Set(records.map { standardizedPath($0.audioFilePath) })
        for url in urls where url.pathExtension.lowercased() == "wav" {
            let path = standardizedPath(url.path)
            guard !retainedPaths.contains(path),
                  let values = try? url.resourceValues(
                      forKeys: [.isRegularFileKey, .contentModificationDateKey]
                  ),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt < cutoff else { continue }
            removeAudioFile(url.path)
        }
    }

    private func standardizedPath(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Success is the move/copy result, never a `fileExists` probe: an unrelated
    /// entry already sitting at the backup path would otherwise read as "backed
    /// up" and clear the way for `persist()` to overwrite the only copy of the
    /// corrupt bytes. Nothing at that path is removed for the same reason.
    private func backupCorruptFile() -> Bool {
        let stamp = Int(now().timeIntervalSince1970)
        let backupURL = fileURL.deletingPathExtension()
            .appendingPathExtension("corrupt-\(stamp).json")
        do {
            try moveItem(fileURL, backupURL)
            return true
        } catch {
            do {
                try copyItem(fileURL, backupURL)
                return true
            } catch {
                return false
            }
        }
    }

    private func persist() throws {
        if persistenceSuspended {
            throw TranscriptStoreError.corruptFileUnrecoverable(path: fileURL.path)
        }

        let folder = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let data = try JSONEncoder.whiskerFlow.encode(records)
        try data.write(to: fileURL, options: .atomic)
    }
}

extension JSONDecoder {
    static var whiskerFlow: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension JSONEncoder {
    static var whiskerFlow: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
