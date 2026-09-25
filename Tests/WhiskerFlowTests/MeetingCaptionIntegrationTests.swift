import XCTest
import AppKit
import CryptoKit
import WhiskerFlowAppSupport
import WhiskerFlowCore
@testable import WhiskerFlow

final class MeetingCaptionIntegrationTests: XCTestCase {
    func testProcessorUsesNativeAccessibilityEvidenceWithoutCaptionsAndPreservesAudioText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EncryptedMeetingChunkStore(rootURL: root, keyProvider: FixedMeetingChunkKeyProvider(key: SymmetricKey(size: .bits256)))
        let id = UUID()
        try store.beginSession(sessionID: id, meetingID: nil, expectedChunkCounts: [.mixed: 1])
        _ = try store.writeChunk(sessionID: id, track: .mixed, sequence: 0, startMs: 0, endMs: 1000, plaintext: Data(repeating: 0, count: 64000))
        let text = "We should review the complete recording tomorrow"
        let snapshot = try XCTUnwrap(MeetingAccessibilityEvidence.snapshot(roots: [
            .init(id: "call", role: "AXWebArea", url: "https://meet.google.com/abc-defg-hij", children: [
                .init(id: "speaker", role: "AXImage", label: "Example Person is speaking"),
                .init(id: "leave", role: "AXButton", label: "Leave call")
            ])
        ]))
        var timeline = MeetingAccessibilityTimeline()
        _ = timeline.observe(snapshot, atMs: 0)
        try store.saveSpeakerEvidence(sessionID: id, evidence: timeline.observe(snapshot, atMs: 1000))
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(id.uuidString).appendingPathComponent("speakers"), includingPropertiesForKeys: nil)
        let raw = try Data(contentsOf: XCTUnwrap(files.first))
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains(text))
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("Example Person"))
        let processor = MeetingLocalProcessor(processingRoot: root.appendingPathComponent("processing"), transcribeMeeting: { _,_ in
            TranscriptionResult(text: text, segments: [.init(text: text, start: 0, end: 1)])
        })
        let result = try await processor.process(manifest: store.loadManifest(sessionID: id), store: store, language: "en")
        XCTAssertEqual(result.turns.first?.speaker.displayName, "Example Person")
        XCTAssertEqual(result.turns.first?.speaker.resolution, .googleMeet)
        XCTAssertEqual(result.turns.first?.text, text)
    }

    /// Explicit opt-in product evidence capture for the current supervised meeting.
    @MainActor
    func testCaptureCurrentMeetEvidence() async throws {
        guard let value = ProcessInfo.processInfo.environment["WHISKERFLOW_CAPTURE_CAPTION_SESSION"], let id = UUID(uuidString: value) else { throw XCTSkip("Explicit meeting required") }
        let pids = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "com.google.Chrome" || $0.bundleIdentifier == "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan"
        }.map(\.processIdentifier)
        let rows = await Task.detached { MeetingCaptionReader.read(pids: pids, report: { print("CAPTION_READER: \($0)") }) }.value
        XCTAssertFalse(rows.isEmpty, "Chrome must expose named caption rows")
        let root = StorageLocations.applicationSupportRootOrTemporary().appendingPathComponent("MeetingRecordings")
        let store = EncryptedMeetingChunkStore(rootURL: root, keyProvider: KeychainMeetingChunkKeyProvider())
        try store.saveCaptionEvidence(sessionID: id, evidence: rows)
        let saved = try store.loadCaptionEvidence(sessionID: id)
        XCTAssertTrue(rows.allSatisfy { saved.contains($0) })
        print("CAPTION_CAPTURE: rows=\(rows.count), named_labels=\(Set(rows.map(\.speaker)).count)")
    }
}
