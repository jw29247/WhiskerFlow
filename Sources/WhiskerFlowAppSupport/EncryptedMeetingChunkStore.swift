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
        try loadOrCreateKey(retryingDuplicate: true)
    }

    private func loadOrCreateKey(retryingDuplicate: Bool) throws -> SymmetricKey {
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
            // Another writer won the race. Read its key once; a keychain that
            // reports not-found for reads but duplicate for writes must not
            // recurse without bound.
            guard retryingDuplicate else { throw MeetingChunkStoreError.keychain(addStatus) }
            return try loadOrCreateKey(retryingDuplicate: false)
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
    private let keyLock = NSLock()
    private var cachedKey: SymmetricKey?
    private var lastKeyFailureUptime: TimeInterval?
    /// A transient keychain failure (locked login keychain, dismissed ACL
    /// prompt, securityd timeout) must not disable encryption for the rest of
    /// the process. Retry at most this often so a denied prompt is not
    /// re-presented for every chunk.
    private static let keyRetryIntervalSeconds: TimeInterval = 30
    /// Manifests are decoded once and then kept under `lock`. Re-decoding the
    /// full manifest for every chunk write or upload receipt is quadratic over
    /// a long meeting.
    private var manifests: [UUID: MeetingRecordingSessionManifest] = [:]
    /// Upload receipts not yet persisted. A lost receipt only re-uploads an
    /// idempotent chunk, so they are written in batches.
    private var unsavedUploadMarks: [UUID: Int] = [:]
    private static let uploadMarksPerManifestWrite = 32
    /// Loose speaker-evidence saves are merged into segments so a long call
    /// keeps a bounded number of evidence files.
    private var looseSpeakerEvidenceCounts: [UUID: Int] = [:]
    private static let looseSpeakerEvidenceLimit = 128
    private static let speakerEvidenceSegmentLimit = 32

    private var key: SymmetricKey? {
        keyLock.lock()
        defer { keyLock.unlock() }
        if let cachedKey { return cachedKey }
        let now = ProcessInfo.processInfo.systemUptime
        if let lastKeyFailureUptime, now - lastKeyFailureUptime < Self.keyRetryIntervalSeconds {
            return nil
        }
        do {
            let loaded = try keyProvider.loadOrCreateKey()
            cachedKey = loaded
            lastKeyFailureUptime = nil
            return loaded
        } catch {
            lastKeyFailureUptime = now
            return nil
        }
    }

    public init(
        rootURL: URL,
        keyProvider: any MeetingChunkKeyProviding,
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.keyProvider = keyProvider
        self.fileManager = fileManager
    }

    /// Loads (or creates) the encryption key before a recording starts. Call
    /// off the main actor: the keychain may block on securityd or a prompt.
    /// Unlike the lazy chunk-write path this is not rate limited, so an
    /// explicit start always gets a fresh attempt.
    public func prepareEncryptionKey() throws {
        keyLock.lock()
        defer { keyLock.unlock() }
        guard cachedKey == nil else { return }
        do {
            cachedKey = try keyProvider.loadOrCreateKey()
            lastKeyFailureUptime = nil
        } catch {
            lastKeyFailureUptime = ProcessInfo.processInfo.systemUptime
            throw error
        }
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
            // Flush the chunk before it becomes discoverable; a power loss must
            // not leave a truncated final file for recovery to trip over.
            if let handle = try? FileHandle(forUpdating: partialURL) {
                try? handle.synchronize()
                try? handle.close()
            }
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
            do {
                try writeManifestLocked(manifest)
            } catch {
                // The writer retries this sequence. Do not leave an orphan that
                // recovery would later add beside the retried chunk.
                try? fileManager.removeItem(at: finalURL)
                throw error
            }
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

    public func saveSpeakerEvidence(sessionID: UUID, evidence: [MeetingSpeakerEvidence]) throws {
        guard !evidence.isEmpty else { return }
        try withLock {
            guard let encryptionKey = key else { throw MeetingChunkStoreError.encryptionFailed }
            guard fileManager.fileExists(atPath: manifestURL(sessionID).path) else { throw MeetingChunkStoreError.missingManifest }
            let directory = sessionDirectory(sessionID).appendingPathComponent("speakers", isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try writeSpeakerEvidenceFileLocked(
                evidence,
                to: directory.appendingPathComponent(UUID().uuidString + ".enc"),
                key: encryptionKey
            )
            let looseCount = looseSpeakerEvidenceCounts[sessionID].map { $0 + 1 }
                ?? speakerEvidenceFilesLocked(in: directory).filter { !Self.isSpeakerEvidenceSegment($0) }.count
            looseSpeakerEvidenceCounts[sessionID] = looseCount
            if looseCount >= Self.looseSpeakerEvidenceLimit {
                try compactSpeakerEvidenceLocked(sessionID: sessionID, directory: directory, key: encryptionKey)
            }
        }
    }

    public func loadSpeakerEvidence(sessionID: UUID) throws -> [MeetingSpeakerEvidence] {
        try withLock {
            guard let encryptionKey = key else { throw MeetingChunkStoreError.encryptionFailed }
            let directory = sessionDirectory(sessionID).appendingPathComponent("speakers", isDirectory: true)
            guard fileManager.fileExists(atPath: directory.path) else { return [] }
            // One unreadable save (for example a power loss mid-write) must not
            // discard every speaker name for the meeting.
            return speakerEvidenceFilesLocked(in: directory).flatMap { url in
                (try? readSpeakerEvidenceFileLocked(url, key: encryptionKey)) ?? []
            }
        }
    }

    private func speakerEvidenceFilesLocked(in directory: URL) -> [URL] {
        ((try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "enc" }
    }

    private static func isSpeakerEvidenceSegment(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix("segment-")
    }

    private func readSpeakerEvidenceFileLocked(_ url: URL, key: SymmetricKey) throws -> [MeetingSpeakerEvidence] {
        let bytes = try Data(contentsOf: url)
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: key)
        return try JSONDecoder().decode([MeetingSpeakerEvidence].self, from: plaintext)
    }

    private func writeSpeakerEvidenceFileLocked(_ evidence: [MeetingSpeakerEvidence], to url: URL, key: SymmetricKey) throws {
        guard let bytes = try AES.GCM.seal(JSONEncoder().encode(evidence), using: key).combined else {
            throw MeetingChunkStoreError.encryptionFailed
        }
        try bytes.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Merges loose saves into one segment, and segments into one when they
    /// accumulate, so an all-day call keeps a bounded file count. A merged
    /// file is written before its sources are removed; an interruption can
    /// only leave duplicate rows, never lose them.
    private func compactSpeakerEvidenceLocked(sessionID: UUID, directory: URL, key: SymmetricKey) throws {
        let files = speakerEvidenceFilesLocked(in: directory)
        let loose = files.filter { !Self.isSpeakerEvidenceSegment($0) }
        var segments = files.filter(Self.isSpeakerEvidenceSegment)
        let merge: ([URL]) throws -> URL? = { sources in
            let readable = sources.compactMap { url in
                (try? self.readSpeakerEvidenceFileLocked(url, key: key)).map { (url, $0) }
            }
            let rows = readable.flatMap(\.1)
            guard !rows.isEmpty else { return nil }
            let segment = directory.appendingPathComponent("segment-\(UUID().uuidString).enc")
            try self.writeSpeakerEvidenceFileLocked(rows, to: segment, key: key)
            // Keep unreadable sources in place; they cost nothing to skip.
            for (url, _) in readable { try? self.fileManager.removeItem(at: url) }
            return segment
        }
        if let segment = try merge(loose) { segments.append(segment) }
        looseSpeakerEvidenceCounts[sessionID] = 0
        if segments.count > Self.speakerEvidenceSegmentLimit {
            _ = try merge(segments)
        }
    }

    public func saveCaptionEvidence(sessionID: UUID, evidence: [MeetingCaptionEvidence]) throws {
        try withLock {
            guard let encryptionKey = key else { throw MeetingChunkStoreError.encryptionFailed }
            let directory = sessionDirectory(sessionID)
            guard fileManager.fileExists(atPath: directory.appendingPathComponent("manifest.json").path) else {
                throw MeetingChunkStoreError.missingManifest
            }
            let url = directory.appendingPathComponent("captions.wfevidence")
            var rows: [MeetingCaptionEvidence] = []
            if let data = try? Data(contentsOf: url),
               let plaintext = try? AES.GCM.open(AES.GCM.SealedBox(combined: data), using: encryptionKey) {
                rows = (try? JSONDecoder().decode([MeetingCaptionEvidence].self, from: plaintext)) ?? []
            }
            let previous = rows
            for row in evidence where !rows.contains(row) { rows.append(row) }
            guard rows != previous else { return }
            rows = Array(rows.suffix(1000))
            let data = try JSONEncoder().encode(rows)
            guard let encrypted = try AES.GCM.seal(data, using: encryptionKey).combined else {
                throw MeetingChunkStoreError.encryptionFailed
            }
            try encrypted.write(to: url, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    public func loadCaptionEvidence(sessionID: UUID) throws -> [MeetingCaptionEvidence] {
        try withLock {
            let url = sessionDirectory(sessionID).appendingPathComponent("captions.wfevidence")
            guard fileManager.fileExists(atPath: url.path) else { return [] }
            guard let encryptionKey = key else { throw MeetingChunkStoreError.encryptionFailed }
            let data = try Data(contentsOf: url)
            let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: encryptionKey)
            return try JSONDecoder().decode([MeetingCaptionEvidence].self, from: plaintext)
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
            let allUploaded = manifest.pendingChunks.isEmpty
            manifest.state = allUploaded ? .awaitingTranscription : .uploading
            let unsaved = (unsavedUploadMarks[sessionID] ?? 0) + 1
            if allUploaded || unsaved >= Self.uploadMarksPerManifestWrite {
                try writeManifestLocked(manifest)
            } else {
                manifests[sessionID] = manifest
                unsavedUploadMarks[sessionID] = unsaved
            }
        }
    }

    /// Records one failed delivery attempt and reports whether the session now
    /// waits for an explicit user retry. Deterministic failures (for example a
    /// recording with no speech) are held immediately; others after
    /// `maximumAttempts` counted failures, so a slow Mac does not re-transcribe
    /// the same hours of audio every hour forever.
    @discardableResult
    public func recordDeliveryFailure(
        sessionID: UUID,
        countsTowardLimit: Bool,
        holdImmediately: Bool = false,
        maximumAttempts: Int
    ) throws -> Bool {
        try withLock {
            var manifest = try loadManifestLocked(sessionID: sessionID)
            manifest.state = .failed
            if countsTowardLimit { manifest.deliveryFailureCount += 1 }
            if holdImmediately || manifest.deliveryFailureCount >= maximumAttempts {
                manifest.awaitingManualRetry = true
            }
            try writeManifestLocked(manifest)
            return manifest.awaitingManualRetry
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

    /// Reconciles each retained session with the chunk files on disk.
    ///
    /// Chunks already in the manifest are only stat-ed (their checksums are
    /// verified when read), so a periodic retry does not re-hash gigabytes of
    /// retained audio. The store lock is taken per session so a scan never
    /// blocks an active recording's chunk writes for long.
    public func recoverSessions(releasingManualRetryHolds: Bool = false) throws -> [MeetingRecordingSessionManifest] {
        let directories = try withLock { () -> [URL] in
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            return try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        }
        return directories.compactMap { directory in
            guard directory.hasDirectoryPath,
                  let sessionID = UUID(uuidString: directory.lastPathComponent) else {
                return nil
            }
            do {
                return try withLock { () -> MeetingRecordingSessionManifest? in
                    guard fileManager.fileExists(atPath: manifestURL(for: directory).path) else { return nil }
                    return try recoverSessionLocked(
                        sessionID: sessionID,
                        releasingManualRetryHold: releasingManualRetryHolds
                    )
                }
            } catch {
                // One corrupt or partially written session must not hide
                // other valid recordings that can still be uploaded.
                return nil
            }
        }
    }

    private func recoverSessionLocked(
        sessionID: UUID,
        releasingManualRetryHold: Bool
    ) throws -> MeetingRecordingSessionManifest {
        var manifest = try loadManifestLocked(sessionID: sessionID)
        var changed = false
        if releasingManualRetryHold, manifest.awaitingManualRetry || manifest.deliveryFailureCount > 0 {
            manifest.awaitingManualRetry = false
            manifest.deliveryFailureCount = 0
            changed = true
        }
        let directory = sessionDirectory(sessionID)
        // A not-yet-uploaded chunk whose file vanished or was truncated can
        // never be delivered. Drop it with an honest gap instead of failing
        // the whole session on every retry.
        let knownCount = manifest.chunks.count
        manifest.chunks.removeAll { descriptor in
            guard descriptor.uploadState == .pending else { return false }
            let path = directory.appendingPathComponent(descriptor.relativePath).path
            let size = (try? fileManager.attributesOfItem(atPath: path))?[.size] as? NSNumber
            return size?.intValue != descriptor.byteSize
        }
        if manifest.chunks.count != knownCount {
            manifest.sourceGapDetected = true
            changed = true
        }

        let chunksURL = directory.appendingPathComponent("chunks", isDirectory: true)
        let files = fileManager.fileExists(atPath: chunksURL.path)
            ? try fileManager.contentsOfDirectory(at: chunksURL, includingPropertiesForKeys: nil)
            : []
        let knownPaths = Set(manifest.chunks.map(\.relativePath))
        var knownSequences = Set(manifest.chunks.map { MeetingChunkKey(track: $0.track, sequence: $0.sequence) })
        for url in files where url.pathExtension == "wfchunk" {
            let relativePath = "chunks/\(url.lastPathComponent)"
            guard !knownPaths.contains(relativePath),
                  let parsed = Self.parseChunkFilename(url) else { continue }
            // Dedupe by (track, sequence): an orphan left by a failed manifest
            // write must not double ten seconds of audio beside its retry.
            let chunkKey = MeetingChunkKey(track: parsed.track, sequence: parsed.sequence)
            guard !knownSequences.contains(chunkKey) else { continue }
            guard let encrypted = try? Data(contentsOf: url),
                  Self.checksum(encrypted) == parsed.checksum else {
                // Quarantine an unreadable/truncated file so later scans skip
                // it, and keep every other chunk in the session recoverable.
                try? fileManager.moveItem(at: url, to: url.appendingPathExtension("corrupt"))
                manifest.sourceGapDetected = true
                changed = true
                continue
            }
            manifest.chunks.append(MeetingRecordingChunkDescriptor(
                track: parsed.track,
                sequence: parsed.sequence,
                startMs: parsed.startMs,
                endMs: parsed.endMs,
                byteSize: encrypted.count,
                checksum: parsed.checksum,
                relativePath: relativePath
            ))
            knownSequences.insert(chunkKey)
            if let expected = manifest.expectedChunkCounts[parsed.track], parsed.sequence >= expected {
                manifest.expectedChunkCounts[parsed.track] = parsed.sequence + 1
            }
            changed = true
        }
        if changed {
            manifest.chunks.sort {
                ($0.track.rawValue, $0.sequence) < ($1.track.rawValue, $1.sequence)
            }
            try writeManifestLocked(manifest)
        }
        return manifest
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
            manifests[sessionID] = nil
            unsavedUploadMarks[sessionID] = nil
            looseSpeakerEvidenceCounts[sessionID] = nil
        }
    }

    private func loadManifestLocked(sessionID: UUID) throws -> MeetingRecordingSessionManifest {
        let url = manifestURL(sessionID)
        guard fileManager.fileExists(atPath: url.path) else {
            manifests[sessionID] = nil
            unsavedUploadMarks[sessionID] = nil
            throw MeetingChunkStoreError.missingManifest
        }
        if let cached = manifests[sessionID] { return cached }
        do {
            let manifest = try JSONDecoder().decode(MeetingRecordingSessionManifest.self, from: Data(contentsOf: url))
            manifests[sessionID] = manifest
            return manifest
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
        manifests[manifest.sessionID] = manifest
        unsavedUploadMarks[manifest.sessionID] = nil
    }

    private struct ParsedChunkFilename {
        let track: MeetingAudioTrack
        let sequence: Int
        let startMs: Int64
        let endMs: Int64
        let checksum: String
    }

    private static func parseChunkFilename(_ url: URL) -> ParsedChunkFilename? {
        let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 5,
              let track = MeetingAudioTrack(rawValue: String(parts[0])),
              let sequence = Int(parts[1]),
              let startMs = Int64(parts[2]),
              let endMs = Int64(parts[3]) else { return nil }
        return ParsedChunkFilename(
            track: track,
            sequence: sequence,
            startMs: startMs,
            endMs: endMs,
            checksum: String(parts[4])
        )
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

private struct MeetingChunkKey: Hashable {
    let track: MeetingAudioTrack
    let sequence: Int
}

private enum SecureRandom {
    static func bytes(count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else { throw MeetingChunkStoreError.keychain(status) }
        return bytes
    }
}
