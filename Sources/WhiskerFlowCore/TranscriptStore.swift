import Foundation

public enum TranscriptStatus: Codable, Equatable, Hashable, Sendable {
    case transcribed
    case failed(errorMessage: String)
}

public struct TranscriptRecord: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var text: String
    public var audioFilePath: String
    public var createdAt: Date
    public var status: TranscriptStatus

    public init(
        id: UUID = UUID(),
        text: String,
        audioFilePath: String,
        createdAt: Date = Date(),
        status: TranscriptStatus
    ) {
        self.id = id
        self.text = text
        self.audioFilePath = audioFilePath
        self.createdAt = createdAt
        self.status = status
    }
}

public final class TranscriptStore {
    private let fileURL: URL
    private let now: () -> Date

    public private(set) var records: [TranscriptRecord] = []

    public init(fileURL: URL, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
    }

    public var retryQueue: [TranscriptRecord] {
        records.filter { record in
            if case .failed = record.status {
                return true
            }
            return false
        }
    }

    public func load() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            records = []
            return
        }

        let data = try Data(contentsOf: fileURL)
        records = try JSONDecoder.whiskerFlow.decode([TranscriptRecord].self, from: data)
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

    public func markTranscribed(id: UUID, text: String) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }

        records[index].text = text
        records[index].status = .transcribed
        try persist()
    }

    public func markFailed(id: UUID, message: String) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }

        records[index].status = .failed(errorMessage: message)
        try persist()
    }

    public func pruneExpired() throws {
        let cutoff = now().addingTimeInterval(-30 * 24 * 60 * 60)
        records.removeAll { $0.createdAt < cutoff }
        try persist()
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
