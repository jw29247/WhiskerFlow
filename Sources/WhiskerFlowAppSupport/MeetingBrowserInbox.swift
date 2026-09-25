import Foundation
import CryptoKit

public struct MeetBrowserSample: Codable, Sendable {
    public let atMs: Int64
    public let participantID: String
    public let displayName: String
}
public struct MeetBrowserBatch: Codable, Sendable {
    public let meetingCode: String
    public let samples: [MeetBrowserSample]
}
/// Native messaging uses a per-recording encrypted mailbox. No listening network port.
public enum MeetingBrowserInbox {
    public struct Configuration: Codable, Sendable {
        public let sessionID: UUID
        public let startMs: Int64
        public var updatedMs: Int64
        public let key: Data
    }
    public struct Envelope: Codable, Sendable {
        public let sessionID: UUID
        public let batch: MeetBrowserBatch
    }
    public static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/WhiskerFlow/MeetBridge")
    }
    public static func begin(sessionID: UUID, startMs: Int64, root: URL = root) throws -> Configuration {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let configuration = Configuration(sessionID: sessionID, startMs: startMs, updatedMs: nowMs, key: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
        try refresh(configuration, root: root)
        return configuration
    }
    public static var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    public static func refresh(_ configuration: Configuration, root: URL = root) throws {
        var current = configuration; current.updatedMs = nowMs
        let url = root.appendingPathComponent("active.json")
        try JSONEncoder().encode(current).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public static func accept(_ bytes: Data, root: URL = root) throws -> Bool {
        guard bytes.count <= 65536 else { return false }
        let decoded = try JSONDecoder().decode(MeetBrowserBatch.self, from: bytes)
        guard decoded.meetingCode.range(of: "^[a-z]{3}-[a-z]{4}-[a-z]{3}$", options: .regularExpression) != nil,
              decoded.samples.count <= 64,
              decoded.samples.allSatisfy({ !$0.participantID.isEmpty && $0.participantID.utf8.count <= 512 && !$0.displayName.isEmpty && $0.displayName.utf8.count <= 200 }) else { return false }
        // Page clocks drift from ours (sleep, NTP steps). Drop out-of-window
        // samples one by one: rejecting the batch would disarm the relay.
        let now = nowMs
        let batch = MeetBrowserBatch(meetingCode: decoded.meetingCode, samples: decoded.samples.filter { $0.atMs >= now - 10000 && $0.atMs <= now + 500 })
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: root.appendingPathComponent("active.json")))
        guard config.updatedMs >= nowMs - 5000 && config.updatedMs <= nowMs + 500 else { return false }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "incoming" }
        guard files.count < 100 else { return false }
        let envelope = Envelope(sessionID: config.sessionID, batch: batch)
        let encrypted = try AES.GCM.seal(JSONEncoder().encode(envelope), using: SymmetricKey(data: config.key)).combined!
        let url = root.appendingPathComponent(UUID().uuidString + ".incoming")
        try encrypted.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }
    public static func drain(_ configuration: Configuration, root: URL = root) throws -> [MeetBrowserBatch] {
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "incoming" }.prefix(100)
        var batches: [MeetBrowserBatch] = []
        for url in files {
            defer { try? FileManager.default.removeItem(at: url) }
            guard let bytes = try? Data(contentsOf: url), bytes.count <= 100000,
                  let plaintext = try? AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: SymmetricKey(data: configuration.key)),
                  let envelope = try? JSONDecoder().decode(Envelope.self, from: plaintext), envelope.sessionID == configuration.sessionID else { continue }
            batches.append(envelope.batch)
        }
        return batches
    }
    public static func end(_ configuration: Configuration, root: URL = root) {
        let url = root.appendingPathComponent("active.json")
        if let data = try? Data(contentsOf: url), let active = try? JSONDecoder().decode(Configuration.self, from: data), active.sessionID == configuration.sessionID { try? FileManager.default.removeItem(at: url) }
    }
}
