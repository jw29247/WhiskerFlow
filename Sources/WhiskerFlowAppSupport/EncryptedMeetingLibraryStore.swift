import CryptoKit
import Foundation

/// Keeps meeting library entries (transcript, notes, bookmarks, dictation
/// markers and the private coach recap) on this Mac, sealed with the same
/// AES-GCM key as the meeting audio chunks. Each file is bound to its session
/// identity, so an entry cannot be swapped onto another meeting.
public final class EncryptedMeetingLibraryStore: @unchecked Sendable {
    public struct LoadResult: Sendable {
        public let entries: [MeetingLibraryEntry]
        /// Files that could not be decrypted or decoded. They are left in place.
        public let unreadableCount: Int
    }

    private static let fileExtension = "wfmeeting"
    private static let authenticationContext = "whiskerflow.meeting-library.v1"
    private let rootURL: URL
    private let keyProvider: any MeetingChunkKeyProviding
    private let fileManager: FileManager
    private let lock = NSLock()
    private var cachedKey: SymmetricKey?

    public init(rootURL: URL, keyProvider: any MeetingChunkKeyProviding, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.keyProvider = keyProvider
        self.fileManager = fileManager
    }

    public func loadAll() throws -> LoadResult {
        try withLock {
            guard fileManager.fileExists(atPath: rootURL.path) else { return LoadResult(entries: [], unreadableCount: 0) }
            let key = try keyLocked()
            let files = try fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == Self.fileExtension }
            var entries: [MeetingLibraryEntry] = []
            var unreadable = 0
            for url in files {
                guard let sessionID = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                      let entry = try? Self.open(Data(contentsOf: url), sessionID: sessionID, key: key),
                      entry.sessionID == sessionID else {
                    unreadable += 1
                    continue
                }
                entries.append(entry)
            }
            return LoadResult(entries: entries, unreadableCount: unreadable)
        }
    }

    public func save(_ entry: MeetingLibraryEntry) throws {
        try withLock {
            let key = try keyLocked()
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootURL.path)
            let plaintext = try JSONEncoder().encode(entry)
            let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: Self.aad(entry.sessionID))
            guard let bytes = sealed.combined else { throw MeetingChunkStoreError.encryptionFailed }
            let url = fileURL(entry.sessionID)
            try bytes.write(to: url, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    public func remove(sessionID: UUID) throws {
        try withLock {
            let url = fileURL(sessionID)
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        }
    }

    public func fileURL(_ sessionID: UUID) -> URL {
        rootURL.appendingPathComponent(sessionID.uuidString).appendingPathExtension(Self.fileExtension)
    }

    private static func open(_ data: Data, sessionID: UUID, key: SymmetricKey) throws -> MeetingLibraryEntry {
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key, authenticating: aad(sessionID))
        return try JSONDecoder().decode(MeetingLibraryEntry.self, from: plaintext)
    }

    private static func aad(_ sessionID: UUID) -> Data {
        Data("\(authenticationContext)|\(sessionID.uuidString)".utf8)
    }

    private func keyLocked() throws -> SymmetricKey {
        if let cachedKey { return cachedKey }
        let key = try keyProvider.loadOrCreateKey()
        cachedKey = key
        return key
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
