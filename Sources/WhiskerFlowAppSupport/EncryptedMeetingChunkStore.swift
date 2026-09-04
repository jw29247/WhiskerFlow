import CryptoKit
import Foundation
import Security

public enum MeetingChunkStoreError: LocalizedError, Equatable {
    case invalidSession
    case invalidChunk
    case missingManifest
    case missingChunk
    case checksumMismatch
    case encryptionFailed
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidSession: return "The meeting recording session is invalid."
        case .invalidChunk: return "The meeting recording chunk is invalid."
        case .missingManifest: return "The meeting recording manifest is missing."
        case .missingChunk: return "The meeting recording chunk is missing."
        case .checksumMismatch: return "The meeting recording checksum does not match."
        case .encryptionFailed: return "The meeting recording could not be encrypted."
        case .keychain: return "The meeting recording encryption key is unavailable."
        }
    }
}

public protocol MeetingChunkKeyProviding: Sendable {
    func loadOrCreateKey() throws -> SymmetricKey
}

public struct FixedMeetingChunkKeyProvider: MeetingChunkKeyProviding {
    private let keyData: Data

    public init(key: SymmetricKey) {
        self.keyData = key.withUnsafeBytes { Data($0) }
    }

    public func loadOrCreateKey() throws -> SymmetricKey {
        SymmetricKey(data: keyData)
    }
}

public final class KeychainMeetingChunkKeyProvider: MeetingChunkKeyProviding, @unchecked Sendable {
    private let service: String
    private let account: String

    public init(
        service: String = "agency.thatworks.WhiskerFlow.meeting-recording",
        account: String = "encryption-key.v1"
    ) {
        self.service = service
        self.account = account
    }

    public func loadOrCreateKey() throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            return SymmetricKey(data: data)
        }
        guard status == errSecItemNotFound else { throw MeetingChunkStoreError.keychain(status) }

        let data = Data(try SecureRandom.bytes(count: 32))
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            return try loadOrCreateKey()
        }
        guard addStatus == errSecSuccess else { throw MeetingChunkStoreError.keychain(addStatus) }
        return SymmetricKey(data: data)
    }
}

public final class EncryptedMeetingChunkStore: @unchecked Sendable {
    private let fileManager: FileManager
    private let rootURL: URL
    private let keyProvider: any MeetingChunkKeyProviding
    private let lock = NSLock()
    private lazy var key: SymmetricKey? = try? keyProvider.loadOrCreateKey()

    public init(
        rootURL: URL,
        keyProvider: any MeetingChunkKeyProviding,
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.keyProvider = keyProvider
        self.fileManager = fileManager
    }

    @discardableResult
    public func beginSession(
        sessionID: UUID,
        meetingID: String?,
        expectedChunkCounts: [MeetingAudioTrack: Int],
        title: String? = nil,
        calendarEventID: String? = nil,
        occurredAtMs: Int64? = nil
    ) throws -> MeetingRecordingSessionManifest {
        try withLock {
            guard !expectedChunkCounts.isEmpty,
                  expectedChunkCounts.values.allSatisfy({ $0 > 0 }) else {
                throw MeetingChunkStoreError.invalidSession
            }
            let directory = sessionDirectory(sessionID)
            try fileManager.createDirectory(at: directory.appendingPathComponent("chunks", isDirectory: true), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: manifestURL(sessionID).path) {
                return try loadManifestLocked(sessionID: sessionID)
            }
            let manifest = MeetingRecordingSessionManifest(
                sessionID: sessionID,
                meetingID: meetingID,
                expectedChunkCounts: expectedChunkCounts,
                title: title,
                calendarEventID: calendarEventID,
                occurredAtMs: occurredAtMs
            )
            try writeManifestLocked(manifest)
            return manifest
        }
    }

    public func loadManifest(sessionID: UUID) throws -> MeetingRecordingSessionManifest {
        try withLock { try loadManifestLocked(sessionID: sessionID) }
    }

    /// Returns a stable digest of the source manifest. Mutable upload state is
    /// intentionally excluded so Atlas can verify the same capture manifest
    /// across retries without receiving local paths or recording content.
    public func sourceManifestChecksum(sessionID: UUID) throws -> String {
        try withLock {
            let manifest = try loadManifestLocked(sessionID: sessionID)
            var lines = ["session=\(manifest.sessionID.uuidString)"]
            for (track, count) in manifest.expectedChunkCounts.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                lines.append("expected|\(track.rawValue)|\(count)")
            }
            for chunk in manifest.chunks.sorted(by: {
                ($0.track.rawValue, $0.sequence) < ($1.track.rawValue, $1.sequence)
            }) {
                lines.append([
                    "chunk",
                    chunk.track.rawValue,
                    String(chunk.sequence),
                    String(chunk.startMs),
                    String(chunk.endMs),
                    String(chunk.byteSize),
                    chunk.checksum,
                    chunk.relativePath,
                ].joined(separator: "|"))
            }
            return Self.checksum(Data(lines.joined(separator: "\n").utf8))
        }
    }

    public func writeChunk(
        sessionID: UUID,
        track: MeetingAudioTrack,
        sequence: Int,
        startMs: Int64,
        endMs: Int64,
        plaintext: Data
    ) throws -> MeetingRecordingChunkDescriptor {
        try withLock {
            guard sequence >= 0, endMs > startMs, !plaintext.isEmpty else {
                throw MeetingChunkStoreError.invalidChunk
            }
            guard let encryptionKey = key else { throw MeetingChunkStoreError.encryptionFailed }
            var manifest = try loadManifestLocked(sessionID: sessionID)
            guard let expected = manifest.expectedChunkCounts[track] else {
                throw MeetingChunkStoreError.invalidChunk
            }
            if sequence >= expected {
                // The initial forecast is deliberately bounded for the upload
                // manifest, but a long-running manual call must be able to
                // extend its local manifest without losing a written chunk.
                manifest.expectedChunkCounts[track] = sequence + 1
            }
            if let existing = manifest.chunks.first(where: { $0.track == track && $0.sequence == sequence }) {
                let existingURL = sessionDirectory(sessionID).appendingPathComponent(existing.relativePath)
                guard fileManager.fileExists(atPath: existingURL.path) else {
                    throw MeetingChunkStoreError.missingChunk
                }
                let existingData = try Data(contentsOf: existingURL)
                let checksum = Self.checksum(existingData)
                guard checksum == existing.checksum else { throw MeetingChunkStoreError.checksumMismatch }
                return existing
            }

            let sealedBox: AES.GCM.SealedBox
            do {
                sealedBox = try AES.GCM.seal(plaintext, using: encryptionKey)
            } catch {
                throw MeetingChunkStoreError.encryptionFailed
            }
            guard let encrypted = sealedBox.combined else {
                throw MeetingChunkStoreError.encryptionFailed
            }
            let checksum = Self.checksum(encrypted)
            let filename = "\(track.rawValue)-\(sequence)-\(startMs)-\(endMs)-\(checksum).wfchunk"
            let relativePath = "chunks/\(filename)"
            let finalURL = sessionDirectory(sessionID).appendingPathComponent(relativePath)
            let partialURL = finalURL.appendingPathExtension("partial")
            try fileManager.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encrypted.write(to: partialURL, options: .atomic)
            try fileManager.moveItem(at: partialURL, to: finalURL)

            let descriptor = MeetingRecordingChunkDescriptor(
                track: track,
                sequence: sequence,
                startMs: startMs,
                endMs: endMs,
                byteSize: encrypted.count,
                checksum: checksum,
                relativePath: relativePath
            )
            manifest.chunks.append(descriptor)
            manifest.chunks.sort {
                ($0.track.rawValue, $0.sequence) < ($1.track.rawValue, $1.sequence)
            }
            try writeManifestLocked(manifest)
            return descriptor
        }
    }

    public func readChunk(
        sessionID: UUID,
        descriptor: MeetingRecordingChunkDescriptor
    ) throws -> Data {
        try withLock {
            let url = sessionDirectory(sessionID).appendingPathComponent(descriptor.relativePath)
            guard fileManager.fileExists(atPath: url.path) else { throw MeetingChunkStoreError.missingChunk }
            let encrypted = try Data(contentsOf: url)
            guard Self.checksum(encrypted) == descriptor.checksum else {
                throw MeetingChunkStoreError.checksumMismatch
            }
            guard let encryptionKey = key else { throw MeetingChunkStoreError.encryptionFailed }
            do {
                return try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: encryptionKey)
            } catch {
                throw MeetingChunkStoreError.encryptionFailed
            }
        }
    }

    /// Returns the encrypted bytes for the authenticated upload transport. The
    /// plaintext path above is used only by local transcription.
    public func readEncryptedChunk(
        sessionID: UUID,
        descriptor: MeetingRecordingChunkDescriptor
    ) throws -> Data {
        try withLock {
            let url = sessionDirectory(sessionID).appendingPathComponent(descriptor.relativePath)
            guard fileManager.fileExists(atPath: url.path) else { throw MeetingChunkStoreError.missingChunk }
            let encrypted = try Data(contentsOf: url)
            guard Self.checksum(encrypted) == descriptor.checksum else {
                throw MeetingChunkStoreError.checksumMismatch
            }
            return encrypted
        }
    }

    public func markUploaded(sessionID: UUID, track: MeetingAudioTrack, sequence: Int) throws {
        try withLock {
            var manifest = try loadManifestLocked(sessionID: sessionID)
            guard let index = manifest.chunks.firstIndex(where: { $0.track == track && $0.sequence == sequence }) else {
                throw MeetingChunkStoreError.missingChunk
            }
            manifest.chunks[index].uploadState = .uploaded
            manifest.state = manifest.pendingChunks.isEmpty ? .awaitingTranscription : .uploading
            try writeManifestLocked(manifest)
        }
    }

    public func markState(
        sessionID: UUID,
        state: MeetingLocalRecordingState,
        durationMs: Int64? = nil,
        sourceGapDetected: Bool? = nil
    ) throws {
        try withLock {
            var manifest = try loadManifestLocked(sessionID: sessionID)
            manifest.state = state
            if let durationMs { manifest.durationMs = durationMs }
            if let sourceGapDetected { manifest.sourceGapDetected = sourceGapDetected }
            try writeManifestLocked(manifest)
        }
    }

    public func attachAtlasReferences(
        sessionID: UUID,
        meetingID: String,
        artifactID: String
    ) throws {
        try withLock {
            var manifest = try loadManifestLocked(sessionID: sessionID)
            manifest.attachAtlasReferences(meetingID: meetingID, artifactID: artifactID)
            try writeManifestLocked(manifest)
        }
    }

    public func recoverSessions() throws -> [MeetingRecordingSessionManifest] {
        try withLock {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let directories = try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            return directories.compactMap { directory in
                guard directory.hasDirectoryPath,
                      UUID(uuidString: directory.lastPathComponent) != nil,
                      fileManager.fileExists(atPath: manifestURL(for: directory).path) else {
                    return nil
                }
                do {
                    let sessionID = UUID(uuidString: directory.lastPathComponent)!
                    var manifest = try loadManifestLocked(sessionID: sessionID)
                    let recovered = try scanFinalChunksLocked(sessionID: sessionID)
                    let known = Set(manifest.chunks.map(\.relativePath))
                    let additional = recovered.filter { !known.contains($0.relativePath) }
                    if !additional.isEmpty {
                        manifest.chunks.append(contentsOf: additional)
                        manifest.chunks.sort {
                            ($0.track.rawValue, $0.sequence) < ($1.track.rawValue, $1.sequence)
                        }
                        try writeManifestLocked(manifest)
                    }
                    return manifest
                } catch {
                    // One corrupt or partially written session must not hide
                    // other valid recordings that can still be uploaded.
                    return nil
                }
            }
        }
    }

    /// Transcript checkpoints are encrypted just like source audio and bound to
    /// the session identity. They survive interrupted uploads without plaintext.
    public func writeProcessingCheckpoint(sessionID: UUID, data: Data) throws {
        try withLock {
            _ = try loadManifestLocked(sessionID: sessionID)
            guard let key else { throw MeetingChunkStoreError.encryptionFailed }
            let sealed = try AES.GCM.seal(data, using: key, authenticating: Data(sessionID.uuidString.utf8))
            guard let bytes = sealed.combined else { throw MeetingChunkStoreError.encryptionFailed }
            try bytes.write(to: sessionDirectory(sessionID).appendingPathComponent("transcript.v1.enc"), options: .atomic)
        }
    }

    public func readProcessingCheckpoint(sessionID: UUID) throws -> Data? {
        try withLock {
            let url = sessionDirectory(sessionID).appendingPathComponent("transcript.v1.enc")
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            guard let key else { throw MeetingChunkStoreError.encryptionFailed }
            return try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: url)), using: key, authenticating: Data(sessionID.uuidString.utf8))
        }
    }

    /// Keep audio acknowledgement durable separately from the transcript. Atlas
    /// completeRecording must not be replayed after a successful finalization.
    public func writeDeliveryReceipt(sessionID: UUID, data: Data) throws {
        try withLock {
            _ = try loadManifestLocked(sessionID: sessionID)
            guard let key else { throw MeetingChunkStoreError.encryptionFailed }
            let sealed = try AES.GCM.seal(data, using: key, authenticating: Data(sessionID.uuidString.utf8))
            guard let bytes = sealed.combined else { throw MeetingChunkStoreError.encryptionFailed }
            try bytes.write(to: sessionDirectory(sessionID).appendingPathComponent("delivery.v1.enc"), options: .atomic)
        }
    }

    public func readDeliveryReceipt(sessionID: UUID) throws -> Data? {
        try withLock {
            let url = sessionDirectory(sessionID).appendingPathComponent("delivery.v1.enc")
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            guard let key else { throw MeetingChunkStoreError.encryptionFailed }
            return try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: url)), using: key, authenticating: Data(sessionID.uuidString.utf8))
        }
    }

    public func removeSession(sessionID: UUID) throws {
        try withLock {
            let directory = sessionDirectory(sessionID)
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
            }
        }
    }

    private func loadManifestLocked(sessionID: UUID) throws -> MeetingRecordingSessionManifest {
        let url = manifestURL(sessionID)
        guard fileManager.fileExists(atPath: url.path) else { throw MeetingChunkStoreError.missingManifest }
        do {
            return try JSONDecoder().decode(MeetingRecordingSessionManifest.self, from: Data(contentsOf: url))
        } catch {
            throw MeetingChunkStoreError.missingManifest
        }
    }

    private func writeManifestLocked(_ manifest: MeetingRecordingSessionManifest) throws {
        let directory = sessionDirectory(manifest.sessionID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(manifest)
        // Foundation's atomic write replaces the prior manifest in one rename;
        // do not remove the old manifest first or a force quit could leave
        // recoverable chunk files with no manifest to discover them.
        try data.write(to: manifestURL(manifest.sessionID), options: .atomic)
    }

    private func scanFinalChunksLocked(sessionID: UUID) throws -> [MeetingRecordingChunkDescriptor] {
        let chunksURL = sessionDirectory(sessionID).appendingPathComponent("chunks", isDirectory: true)
        guard fileManager.fileExists(atPath: chunksURL.path) else { return [] }
        let files = try fileManager.contentsOfDirectory(at: chunksURL, includingPropertiesForKeys: nil)
        return try files.compactMap { url in
            guard url.pathExtension == "wfchunk" else { return nil }
            let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 5,
                  let track = MeetingAudioTrack(rawValue: String(parts[0])),
                  let sequence = Int(parts[1]),
                  let startMs = Int64(parts[2]),
                  let endMs = Int64(parts[3]) else { return nil }
            let encrypted = try Data(contentsOf: url)
            let checksum = Self.checksum(encrypted)
            guard checksum == String(parts[4]) else { throw MeetingChunkStoreError.checksumMismatch }
            return MeetingRecordingChunkDescriptor(
                track: track,
                sequence: sequence,
                startMs: startMs,
                endMs: endMs,
                byteSize: encrypted.count,
                checksum: checksum,
                relativePath: "chunks/\(url.lastPathComponent)"
            )
        }
    }

    private func sessionDirectory(_ sessionID: UUID) -> URL {
        rootURL.appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    private func manifestURL(_ sessionID: UUID) -> URL {
        sessionDirectory(sessionID).appendingPathComponent("manifest.json")
    }

    private func manifestURL(for directory: URL) -> URL {
        directory.appendingPathComponent("manifest.json")
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private static func checksum(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private enum SecureRandom {
    static func bytes(count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else { throw MeetingChunkStoreError.keychain(status) }
        return bytes
    }
}
