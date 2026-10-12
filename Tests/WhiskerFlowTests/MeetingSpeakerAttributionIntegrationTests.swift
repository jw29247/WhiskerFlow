import XCTest
import AppKit
import CryptoKit
import WhiskerFlowAppSupport
import WhiskerFlowCore
@testable import WhiskerFlow

final class MeetingSpeakerAttributionIntegrationTests: XCTestCase {
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
}
