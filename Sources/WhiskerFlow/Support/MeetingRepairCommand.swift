#if DEBUG
import AppKit
import CoreGraphics
import Foundation
import WhiskerFlowAppSupport

/// Explicit maintenance entry point for one retained recording. No capture,
/// automatic recovery, or deletion. The report contains delivery metadata only.
@MainActor
enum MeetingRepairCommand {
    static var sessionID: UUID? {
        CommandLine.arguments.first { $0.hasPrefix("--repair-meeting=") }
            .flatMap { UUID(uuidString: String($0.dropFirst("--repair-meeting=".count))) }
    }

    static var captureVerificationRequested: Bool { CommandLine.arguments.contains("--verify-meeting-capture") }

    static func captureAndDeliver() async {
        let id = UUID()
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("whiskerflow-capture-verification.json")
        func report(_ state: String) {
            let data = try? JSONSerialization.data(withJSONObject: ["sessionID": id.uuidString, "state": state], options: [.prettyPrinted])
            try? data?.write(to: marker, options: .atomic)
        }
        guard CGPreflightScreenCaptureAccess() else {
            report("Screen Recording permission required")
            NSApp.terminate(nil)
            return
        }
        let microphone = MicrophonePermissionController(provider: AVCaptureMicrophoneAuthorizationProvider())
        guard await microphone.requestIfNeeded() == .authorized else {
            report("Microphone permission required")
            NSApp.terminate(nil)
            return
        }
        let store = EncryptedMeetingChunkStore(rootURL: StorageLocations.applicationSupportRootOrTemporary().appendingPathComponent("MeetingRecordings"), keyProvider: KeychainMeetingChunkKeyProvider())
        let capture = MeetingAudioCaptureService(store: store, sessionID: id)
        do {
            try store.beginSession(sessionID: id, meetingID: nil, expectedChunkCounts: [.microphone: 6, .system: 6, .mixed: 6], title: "WhiskerFlow delivery verification", occurredAtMs: Int64(Date().timeIntervalSince1970 * 1000))
            try await capture.start(selection: .systemDefault)
            report("recording")
            try await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            _ = try await capture.stop()
            let manifest = try store.loadManifest(sessionID: id)
            try store.markState(sessionID: id, state: .awaitingTranscription, durationMs: manifest.chunks.map(\.endMs).max(), sourceGapDetected: capture.sourceGapDetected)
            report("recorded")
            await run(id)
        } catch {
            await capture.cancel()
            report("Capture failed: \(error.localizedDescription)")
            NSApp.terminate(nil)
        }
    }

    static func run(_ sessionID: UUID) async {
        let reportURL = FileManager.default.temporaryDirectory.appendingPathComponent("whiskerflow-repair-\(sessionID.uuidString).json")
        var report: [String: Any] = ["sessionID": sessionID.uuidString]
        func publish(_ stage: String) {
            report["stage"] = stage
            report["updatedAt"] = ISO8601DateFormatter().string(from: Date())
            if let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? bytes.write(to: reportURL, options: .atomic)
            }
        }
        publish("starting")
        do {
            guard let token = MeetingCaptureTokenStore().read() else { throw MeetingAtlasClientError.notPaired }
            let store = EncryptedMeetingChunkStore(rootURL: StorageLocations.applicationSupportRootOrTemporary().appendingPathComponent("MeetingRecordings"), keyProvider: KeychainMeetingChunkKeyProvider())
            let client = URLSessionMeetingAtlasClient(baseURL: URL(string: "https://atlas.thatworks.agency")!, token: token)
            let processor = MeetingLocalProcessor(transcription: TranscriptionService())
            let completion = try await MeetingDelivery(store: store, client: client).deliver(sessionID: sessionID) {
                try await processor.process(manifest: store.loadManifest(sessionID: sessionID), store: store, language: "en")
            } progress: { publish($0) }
            let manifest = try store.loadManifest(sessionID: sessionID)
            report["meetingID"] = manifest.atlasMeetingID
            report["artifactID"] = manifest.atlasArtifactID
            report["recordingStatus"] = completion.status
            report["success"] = true
            publish("finalized")
        } catch {
            report["success"] = false
            report["error"] = error.localizedDescription
            publish("failed")
        }
        NSApp.terminate(nil)
    }
}
#endif
