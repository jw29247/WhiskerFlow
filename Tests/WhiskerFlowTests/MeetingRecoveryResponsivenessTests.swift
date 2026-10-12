import XCTest
import Foundation
import CryptoKit
import AVFoundation
import WhiskerFlowAppSupport
@testable import WhiskerFlow

final class MeetingRecoveryResponsivenessTests: XCTestCase {
    @MainActor
    func testRecoveryScanDoesNotReadDiskOnMainThread() async throws {
        let name = "RecoveryResponsiveness.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }
        let coordinator = MeetingCaptureCoordinator(
            settings: AppSettings(defaults: defaults, meetingTokenStore: MeetingCaptureTokenStore(service: name)),
            microphonePermission: MicrophonePermissionController(provider: AVCaptureMicrophoneAuthorizationProvider()),
            transcription: TranscriptionService(),
            store: EncryptedMeetingChunkStore(rootURL: root,
                keyProvider: FixedMeetingChunkKeyProvider(key: SymmetricKey(size: .bits256)),
                fileManager: BackgroundCheckingFileManager()))
        let sessions = try await coordinator.scanRecoverySessions()
        XCTAssertTrue(sessions.isEmpty)
    }
}

private final class BackgroundCheckingFileManager: FileManager, @unchecked Sendable {
    override func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions = []) throws -> [URL] {
        XCTAssertFalse(Thread.isMainThread, "Recovery disk reads/checksums must not block dictation UI")
        return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }
}
