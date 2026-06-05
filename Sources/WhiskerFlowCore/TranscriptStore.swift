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

public final class TranscriptStore {
    private let fileURL: URL
    private let now: () -> Date
    private let removeAudioFile: (String) -> Void
    private let retentionInterval: TimeInterval

    public private(set) var records: [TranscriptRecord] = []

    public init(
        fileURL: URL,
        now: @escaping () -> Date = Date.init,
        retentionInterval: TimeInterval = 30 * 24 * 60 * 60,
        removeAudioFile: @escaping (String) -> Void = { path in
            guard !path.isEmpty else { return }
            try? FileManager.default.removeItem(atPath: path)
        }
    ) {
        self.fileURL = fileURL
        self.now = now
        self.retentionInterval = retentionInterval
        self.removeAudioFile = removeAudioFile
    }

    public var retryQueue: [TranscriptRecord] {
        records.filter { $0.status.isFailed }
    }

    public func load() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            records = []
            return
        }

        let data = try Data(contentsOf: fileURL)
        do {
            records = try JSONDecoder.whiskerFlow.decode([TranscriptRecord].self, from: data)
        } catch {
            // Don't silently overwrite a file we can't parse — preserve it so the
            // user (or a future migration) can recover, then start clean.
            try? backupCorruptFile()
            records = []
            try persist()
            return
        }
        try pruneExpired()
    }

    public func add(_ record: TranscriptRecord) throws {
        records.insert(record, at: 0)
        try pruneExpired()
    }

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
        let expired = records.filter { $0.createdAt < cutoff }
        for record in expired {
            removeAudioFile(record.audioFilePath)
        }
        records.removeAll { $0.createdAt < cutoff }
        try persist()
    }

    private func backupCorruptFile() throws {
        let stamp = Int(now().timeIntervalSince1970)
        let backupURL = fileURL.deletingPathExtension()
            .appendingPathExtension("corrupt-\(stamp).json")
        try? FileManager.default.removeItem(at: backupURL)
        try FileManager.default.moveItem(at: fileURL, to: backupURL)
    }

    private func persist() throws {
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
