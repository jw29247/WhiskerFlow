import XCTest
import CryptoKit
@testable import WhiskerFlow
import WhiskerFlowAppSupport
import WhiskerFlowCore

final class MeetingDeliveryTests: XCTestCase {
    @MainActor
    func testModelFailureStillDeliversRecordingAndKeepsItRecoverable() async throws {
        let (store, id, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = DeliveryStub()
        do {
            _ = try await MeetingDelivery(store: store, client: client).deliver(sessionID: id, process: {
                XCTAssertEqual(client.events, ["create", "prepare", "chunk", "chunk", "chunk", "complete", "playback", "playbackComplete"])
                throw TranscriptionError.modelUnavailable("Fixture")
            }, progress: { _ in })
            XCTFail("Model failure must remain visible")
        } catch TranscriptionError.modelUnavailable {}
        let retained = try store.loadManifest(sessionID: id)
        XCTAssertEqual(retained.atlasMeetingID, "meeting")
        XCTAssertTrue(retained.pendingChunks.isEmpty)
        XCTAssertFalse(client.events.contains("finalize"), "Never claim transcript success before transcription")
    }

    @MainActor
    func testInterruptedFinalizeRetriesWithoutTranscribingAgain() async throws {
        let (store, id, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = DeliveryStub()
        client.failFinalize = true
        let delivery = MeetingDelivery(store: store, client: client)
        var processCount = 0
        let process = {
            processCount += 1
            return MeetingLocalProcessingResult(turns: [MeetingSpeakerTurn(startMs: 0, endMs: 1000, text: "Fixture transcript", speaker: .microphone)], modelVersion: "fixture", durationMs: 1000)
        }
        do { _ = try await delivery.deliver(sessionID: id, process: process, progress: { _ in }); XCTFail() }
        catch MeetingAtlasClientError.server {}
        client.failFinalize = false
        _ = try await delivery.deliver(sessionID: id, process: process, progress: { _ in })
        XCTAssertEqual(processCount, 1)
        XCTAssertEqual(client.serverStatus, "covered")
        XCTAssertEqual(client.events.filter { $0 == "chunk" }.count, 3)
        XCTAssertEqual(client.events.filter { $0 == "create" }.count, 1)
        XCTAssertEqual(client.events.filter { $0 == "complete" }.count, 1, "Replaying complete after an accepted finalize would downgrade Atlas coverage")
        XCTAssertEqual(client.events.filter { $0 == "playback" }.count, 1)
        let encrypted = try Data(contentsOf: root.appendingPathComponent(id.uuidString).appendingPathComponent("transcript.v1.enc"))
        XCTAssertNil(encrypted.range(of: Data("Fixture transcript".utf8)))
    }

    private func fixture() throws -> (EncryptedMeetingChunkStore, UUID, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = EncryptedMeetingChunkStore(rootURL: root, keyProvider: FixedMeetingChunkKeyProvider(key: SymmetricKey(size: .bits256)))
        let id = UUID()
        try store.beginSession(sessionID: id, meetingID: nil, expectedChunkCounts: [.microphone: 1, .system: 1, .mixed: 1])
        for track in MeetingAudioTrack.allCases {
            _ = try store.writeChunk(sessionID: id, track: track, sequence: 0, startMs: 0, endMs: 1000, plaintext: Data(repeating: 0, count: 64000))
        }
        return (store, id, root)
    }
}

private final class DeliveryStub: MeetingAtlasClient, @unchecked Sendable {
    var events: [String] = []
    var failFinalize = false
    var serverStatus = "pending"
    var finalized = false
    func schedule(fromMs: Int64, toMs: Int64) async throws -> [AtlasCaptureScheduleIntent] { [] }
    func heartbeat(appVersion: String, permissionState: [String: String], diskState: String, captureState: String, lastFailureReason: String?) async throws {}
    func createMeeting(captureSessionID: UUID, title: String, occurredAtMs: Int64, eventID: String?) async throws -> (meetingID: String, created: Bool) { events.append("create"); return ("meeting", true) }
    func prepareRecording(meetingID: String, captureSessionID: UUID, trackChunkCounts: [MeetingAudioTrack: Int], sourceManifestHash: String?, playbackChunkCount: Int?) async throws -> String { events.append("prepare"); return "artifact" }
    func uploadChunk(artifactID: String, descriptor: MeetingRecordingChunkDescriptor, body: Data) async throws { events.append("chunk") }
    func uploadPlaybackChunk(artifactID: String, descriptor: MeetingRecordingChunkDescriptor, body: Data) async throws { events.append("playback") }
    func completePlayback(artifactID: String) async throws { events.append("playbackComplete") }
    func completeRecording(artifactID: String, durationMs: Int64, trackChunkCounts: [MeetingAudioTrack: Int], hasSourceGap: Bool, missingTracks: [MeetingAudioTrack], canonicalChecksum: String?, sourceManifestHash: String?, modelVersion: String?) async throws -> MeetingAtlasRecordingCompletion { events.append("complete"); serverStatus = "pending"; return MeetingAtlasRecordingCompletion(status: "recorded_pending_transcription", duplicate: false) }
    func appendSegments(meetingID: String, turns: [MeetingSpeakerTurn]) async throws { events.append("segments") }
    func finalize(meetingID: String, artifactID: String, transcriptionState: String, status: String) async throws { events.append("finalize")
        if !finalized { serverStatus = "covered"; finalized = true }
        // Simulate the server accepting finalization before its response is lost.
        if failFinalize { throw MeetingAtlasClientError.server("Fixture outage") }
    }
}
