import AVFoundation
import CryptoKit
import XCTest
@testable import WhiskerFlow
import WhiskerFlowAppSupport
import WhiskerFlowCore

@MainActor
final class MeetingLibraryCoordinatorTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots = []
        super.tearDown()
    }

    private func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingLibraryCoordinator-\(UUID().uuidString)")
        roots.append(root)
        return root
    }

    private struct Fixture {
        let coordinator: MeetingCaptureCoordinator
        let store: EncryptedMeetingChunkStore
        let library: MeetingLibraryController
        let libraryRoot: URL
        let key: SymmetricKey
        let client: LibraryDeliveryStub
        let sessionID: UUID
    }

    /// A retained recording whose transcript is already checkpointed, so
    /// delivery never loads a model.
    private func fixture(
        retention: MeetingTranscriptRetention = .ninetyDays,
        chunks: Bool = true,
        checkpoint: Bool = true
    ) throws -> Fixture {
        let name = "MeetingLibraryCoordinatorTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults, meetingTokenStore: MeetingCaptureTokenStore(service: name))
        let key = SymmetricKey(size: .bits256)
        let store = EncryptedMeetingChunkStore(rootURL: temporaryRoot(), keyProvider: FixedMeetingChunkKeyProvider(key: key))
        let libraryRoot = temporaryRoot()
        let library = MeetingLibraryController(
            store: EncryptedMeetingLibraryStore(rootURL: libraryRoot, keyProvider: FixedMeetingChunkKeyProvider(key: key))
        )
        library.retention = { retention }
        let client = LibraryDeliveryStub()
        let coordinator = MeetingCaptureCoordinator(
            settings: settings,
            microphonePermission: MicrophonePermissionController(provider: AVCaptureMicrophoneAuthorizationProvider()),
            transcription: TranscriptionService(),
            store: store,
            clientProvider: { client },
            library: library
        )
        let sessionID = UUID()
        try store.beginSession(sessionID: sessionID, meetingID: nil, expectedChunkCounts: [.microphone: 1, .system: 1, .mixed: 1],
                               title: "Design review", occurredAtMs: 1_790_000_000_000)
        if chunks {
            for track in MeetingAudioTrack.allCases {
                _ = try store.writeChunk(sessionID: sessionID, track: track, sequence: 0, startMs: 0, endMs: 60_000,
                                         plaintext: Data(repeating: 1, count: 64_000))
            }
            try store.markState(sessionID: sessionID, state: .awaitingTranscription, durationMs: 60_000)
        }
        if checkpoint {
            let result = MeetingLocalProcessingResult(turns: [
                MeetingSpeakerTurn(startMs: 1_000, endMs: 5_000, text: "Let's agree the scope.", speaker: .microphone),
                MeetingSpeakerTurn(startMs: 5_000, endMs: 9_000, text: "Option B works for us.",
                                   speaker: .manual(key: "meet-1", displayName: "Sam Lee")),
            ], modelVersion: "fixture", durationMs: 60_000)
            try store.writeProcessingCheckpoint(sessionID: sessionID, data: JSONEncoder().encode(result))
        }
        return Fixture(coordinator: coordinator, store: store, library: library, libraryRoot: libraryRoot, key: key,
                       client: client, sessionID: sessionID)
    }

    /// Simulates what happened while recording: a note, a bookmark-free
    /// dictation span, then the stop.
    private func recordLiveMoments(_ f: Fixture) throws {
        f.library.beginRecording(sessionID: f.sessionID, title: "Design review",
                                 startedAt: Date(timeIntervalSince1970: 1_790_000_000), calendarEventID: nil)
        try f.library.addNote(sessionID: f.sessionID, text: "Scope agreed — confirm budget", elapsedMs: 6_000)
        f.library.beginDictation(sessionID: f.sessionID, atMs: 1_000)
        f.library.endDictation(sessionID: f.sessionID, atMs: 5_500)
        f.library.finishRecording(f.sessionID, endedAtMs: 60_000, coachRecap: "Recording lasted 1m.", bookmarks: [])
    }

    func testDeliveredMeetingKeepsEncryptedTranscriptAndNotesButDeletesAudio() async throws {
        let f = try fixture()
        var noteRequests: [MeetingBookmarkSyncRequest] = []
        f.library.noteSync = { request in noteRequests.append(request); return "bookmark-\(noteRequests.count)" }
        try recordLiveMoments(f)

        await f.coordinator.deliver(sessionID: f.sessionID)

        XCTAssertThrowsError(try f.store.loadManifest(sessionID: f.sessionID), "Raw audio is deleted after delivery, as before")
        let entry = try XCTUnwrap(f.library.entry(f.sessionID))
        XCTAssertEqual(entry.status, .delivered)
        XCTAssertEqual(entry.atlasMeetingID, "meeting")
        XCTAssertEqual(entry.turns.map(\.speaker.displayName), ["You", "Sam Lee"])
        XCTAssertEqual(entry.coachRecap, "Recording lasted 1m.")
        XCTAssertEqual(entry.notes.map(\.syncState), [.synced])
        XCTAssertEqual(noteRequests.map(\.label), ["Scope agreed — confirm budget"], "Notes reuse the bookmark path")
        XCTAssertEqual(noteRequests.map(\.meetingReference), ["meeting"])
        XCTAssertEqual(noteRequests.map(\.elapsedMilliseconds), [6_000])
        XCTAssertTrue(MeetingTimeline.isDictated(entry.turns[0], spans: entry.dictations))

        // The library survives a restart, and nothing readable is on disk.
        await f.library.flush()
        let file = f.libraryRoot.appendingPathComponent("\(f.sessionID.uuidString).wfmeeting")
        let bytes = try Data(contentsOf: file)
        XCTAssertNil(bytes.range(of: Data("agree the scope".utf8)))
        XCTAssertNil(bytes.range(of: Data("confirm budget".utf8)))
        let relaunched = MeetingLibraryController(
            store: EncryptedMeetingLibraryStore(rootURL: f.libraryRoot, keyProvider: FixedMeetingChunkKeyProvider(key: f.key))
        )
        await relaunched.waitUntilLoaded()
        XCTAssertEqual(relaunched.entry(f.sessionID), entry)
    }

    func testDeliveryStagesAreShownInTheLibrary() async throws {
        let f = try fixture()
        try recordLiveMoments(f)
        var observed: [MeetingLibraryStatus] = []
        f.client.onEvent = { _ in
            if let status = f.library.entry(f.sessionID)?.status, observed.last != status { observed.append(status) }
        }
        await f.coordinator.deliver(sessionID: f.sessionID)
        XCTAssertEqual(observed, [.uploading])
        XCTAssertEqual(f.library.entry(f.sessionID)?.status, .delivered)
    }

    func testDeleteAfterDeliveryRemovesTheLocalCopyOnlyOnceNotesReachAtlas() async throws {
        let failing = try fixture(retention: .deleteAfterDelivery)
        failing.library.noteSync = { _ in throw AssistantError.message("Atlas offline") }
        try recordLiveMoments(failing)
        await failing.coordinator.deliver(sessionID: failing.sessionID)
        XCTAssertEqual(failing.library.entry(failing.sessionID)?.status, .delivered,
                       "A note that exists only on this Mac keeps its meeting")
        XCTAssertEqual(failing.library.entry(failing.sessionID)?.notes.first?.syncState, .failed)

        failing.library.noteSync = { _ in "bookmark" }
        await failing.library.retryNoteSync(sessionID: failing.sessionID)
        XCTAssertNil(failing.library.entry(failing.sessionID))
        await failing.library.flush()
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: failing.libraryRoot.appendingPathComponent("\(failing.sessionID.uuidString).wfmeeting").path))
    }

    func testLongNoteReachesAtlasInFullBeforeItsMeetingIsDeleted() async throws {
        let f = try fixture(retention: .deleteAfterDelivery)
        let text = (1...120).map { "point\($0)" }.joined(separator: " ")
        var requests: [MeetingBookmarkSyncRequest] = []
        f.library.noteSync = { request in
            requests.append(request)
            if requests.count == 2 { throw AssistantError.message("Atlas offline") }
            return "bookmark-\(requests.count)"
        }
        f.library.beginRecording(sessionID: f.sessionID, title: "Design review",
                                 startedAt: Date(timeIntervalSince1970: 1_790_000_000), calendarEventID: nil)
        try f.library.addNote(sessionID: f.sessionID, text: text, elapsedMs: 6_000)
        f.library.finishRecording(f.sessionID, endedAtMs: 60_000, coachRecap: nil, bookmarks: [])

        await f.coordinator.deliver(sessionID: f.sessionID)
        XCTAssertEqual(f.library.entry(f.sessionID)?.notes.first?.syncState, .failed, "One part didn't reach Atlas")
        XCTAssertNotNil(f.library.entry(f.sessionID), "So the only complete copy is kept")

        requests = []
        f.library.noteSync = { request in requests.append(request); return "bookmark-\(requests.count)" }
        await f.library.retryNoteSync(sessionID: f.sessionID)
        XCTAssertGreaterThan(requests.count, 1)
        XCTAssertTrue(requests.allSatisfy { ($0.label?.utf16.count ?? 0) <= MeetingLibraryNote.atlasLabelCharacters })
        XCTAssertEqual(Set(requests.map(\.requestID)).count, requests.count)
        XCTAssertEqual(Set(requests.map(\.elapsedMilliseconds)), [6_000])
        let sent = requests.compactMap(\.label).map {
            $0.replacingOccurrences(of: #"^\(\d+/\d+\) "#, with: "", options: .regularExpression)
        }
        XCTAssertEqual(sent.joined(separator: " "), text)
        XCTAssertNil(f.library.entry(f.sessionID), "Sent in full, so retention may now delete it")
    }

    func testRecordingIsKeptUntilItsLibraryCopyIsSaved() async throws {
        let f = try fixture()
        try recordLiveMoments(f)
        await f.library.flush()
        // The library folder can't be written: a file stands in its place.
        try FileManager.default.removeItem(at: f.libraryRoot)
        try Data().write(to: f.libraryRoot)

        await f.coordinator.deliver(sessionID: f.sessionID)
        XCTAssertNoThrow(try f.store.loadManifest(sessionID: f.sessionID), "Audio and checkpoint stay for a retry")
        XCTAssertNotNil(f.library.storageError)
        XCTAssertEqual(f.client.events.filter { $0 == "finalize" }.count, 1)

        try FileManager.default.removeItem(at: f.libraryRoot)
        f.coordinator.retryRecording(sessionID: f.sessionID)
        for _ in 0..<200 where (try? f.store.loadManifest(sessionID: f.sessionID)) != nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertThrowsError(try f.store.loadManifest(sessionID: f.sessionID), "Removed once the library copy is on disk")
        XCTAssertEqual(f.client.events.filter { $0 == "create" }.count, 1, "The retry repeats no upload")
        let relaunched = MeetingLibraryController(
            store: EncryptedMeetingLibraryStore(rootURL: f.libraryRoot, keyProvider: FixedMeetingChunkKeyProvider(key: f.key))
        )
        await relaunched.waitUntilLoaded()
        XCTAssertEqual(relaunched.entry(f.sessionID)?.status, .delivered)
        XCTAssertEqual(relaunched.entry(f.sessionID)?.turns.count, 2)
    }

    func testPermanentFailureIsShownAsFailedAndHeldForRetry() async throws {
        let f = try fixture(chunks: false, checkpoint: false)
        try recordLiveMoments(f)
        await f.coordinator.deliver(sessionID: f.sessionID)
        let entry = try XCTUnwrap(f.library.entry(f.sessionID))
        XCTAssertEqual(entry.status, .failed)
        XCTAssertTrue(entry.awaitingManualRetry)
        XCTAssertTrue(entry.statusDetail?.contains("Retry") == true)
        XCTAssertEqual(entry.notes.count, 1, "A failed meeting keeps its notes")
    }

    func testTransientFailureWaitsToSendAndKeepsAudio() async throws {
        let f = try fixture()
        try recordLiveMoments(f)
        f.client.failCreate = true
        await f.coordinator.deliver(sessionID: f.sessionID)
        XCTAssertEqual(f.library.entry(f.sessionID)?.status, .queued)
        XCTAssertNoThrow(try f.store.loadManifest(sessionID: f.sessionID))

        f.client.failCreate = false
        f.coordinator.retryRecording(sessionID: f.sessionID)
        for _ in 0..<200 where f.library.entry(f.sessionID)?.status != .delivered {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(f.library.entry(f.sessionID)?.status, .delivered, "Retry on one meeting delivers it")
    }

    func testRecoveryScanAddsOlderRetainedRecordingsWithoutReplacingSavedEntries() async throws {
        let f = try fixture()
        var saved = MeetingLibraryEntry(sessionID: f.sessionID, title: "Design review", startedAt: Date(), status: .transcribing)
        saved.turns = [MeetingSpeakerTurn(startMs: 0, endMs: 1_000, text: "Kept", speaker: .microphone)]
        try EncryptedMeetingLibraryStore(rootURL: f.libraryRoot, keyProvider: FixedMeetingChunkKeyProvider(key: f.key)).save(saved)
        let legacy = UUID()
        try f.store.beginSession(sessionID: legacy, meetingID: nil, expectedChunkCounts: [.mixed: 1], title: "Before the library")
        _ = try f.store.writeChunk(sessionID: legacy, track: .mixed, sequence: 0, startMs: 0, endMs: 10_000, plaintext: Data(repeating: 2, count: 320))

        _ = try await f.coordinator.scanRecoverySessions()

        XCTAssertEqual(f.library.entry(f.sessionID)?.turns.map(\.text), ["Kept"], "The stored entry is loaded, not replaced")
        XCTAssertEqual(f.library.entry(f.sessionID)?.status, .queued, "An entry left mid-flight by a quit waits to be sent")
        XCTAssertEqual(f.library.entry(legacy)?.title, "Before the library")
        XCTAssertEqual(f.library.entry(legacy)?.status, .queued)
    }

    func testNotesAndDictationOnlyWhileRecording() throws {
        let library = MeetingLibraryController.ephemeral()
        let id = UUID()
        XCTAssertThrowsError(try library.addNote(sessionID: id, text: "x", elapsedMs: 0))
        library.beginRecording(sessionID: id, title: "T", startedAt: Date(), calendarEventID: nil)
        XCTAssertThrowsError(try library.addNote(sessionID: id, text: "   ", elapsedMs: 0)) {
            XCTAssertEqual($0 as? MeetingLibraryError, .emptyNote)
        }
        library.beginDictation(sessionID: id, atMs: 10_000)
        library.beginDictation(sessionID: id, atMs: 11_000)
        library.finishRecording(id, endedAtMs: 20_000, coachRecap: nil, bookmarks: [])
        XCTAssertEqual(library.entry(id)?.dictations.map(\.startMs), [10_000], "A held key opens one span")
        XCTAssertEqual(library.entry(id)?.dictations.first?.endMs, 20_000, "Stopping the recording closes an open dictation")
        XCTAssertEqual(library.entry(id)?.status, .uploading)
        XCTAssertThrowsError(try library.addNote(sessionID: id, text: "late", elapsedMs: 21_000))
        library.setStatus(id, .delivered)
        library.setStatus(id, .uploading)
        XCTAssertEqual(library.entry(id)?.status, .delivered, "A delivered meeting never moves back")
        XCTAssertTrue(library.deleteDelivered(id))
        XCTAssertNil(library.entry(id))
    }

    func testAtlasInsightsAreReadOnlyWithADeviceReference() async throws {
        let f = try fixture()
        try recordLiveMoments(f)
        await f.coordinator.deliver(sessionID: f.sessionID)
        let refreshedWithRawID = await f.coordinator.refreshAtlasInsights(sessionID: f.sessionID)
        XCTAssertFalse(refreshedWithRawID, "getMeeting accepts only wm1_ references; the raw ID must not be sent")
        XCTAssertFalse(f.client.events.contains("getMeeting"))
    }
}

final class LibraryDeliveryStub: MeetingAtlasClient, @unchecked Sendable {
    var events: [String] = []
    var failCreate = false
    var onEvent: ((String) -> Void)?

    private func record(_ event: String) {
        events.append(event)
        onEvent?(event)
    }

    func schedule(fromMs: Int64, toMs: Int64) async throws -> [AtlasCaptureScheduleIntent] { [] }
    func heartbeat(appVersion: String, permissionState: [String: String], diskState: String, captureState: String, lastFailureReason: String?) async throws {}
    func createMeeting(captureSessionID: UUID, title: String, occurredAtMs: Int64, eventID: String?) async throws -> MeetingAtlasCreatedMeeting {
        if failCreate { throw URLError(.notConnectedToInternet) }
        record("create")
        return MeetingAtlasCreatedMeeting(meetingID: "meeting", created: true)
    }
    func prepareRecording(meetingID: String, captureSessionID: UUID, trackChunkCounts: [MeetingAudioTrack: Int], sourceManifestHash: String?, playbackChunkCount: Int?) async throws -> String { record("prepare"); return "artifact" }
    func uploadChunk(artifactID: String, descriptor: MeetingRecordingChunkDescriptor, body: Data) async throws { record("chunk") }
    func uploadPlaybackChunk(artifactID: String, descriptor: MeetingRecordingChunkDescriptor, body: Data) async throws { record("playback") }
    func completePlayback(artifactID: String) async throws { record("playbackComplete") }
    func completeRecording(artifactID: String, durationMs: Int64, trackChunkCounts: [MeetingAudioTrack: Int], hasSourceGap: Bool, missingTracks: [MeetingAudioTrack], canonicalChecksum: String?, sourceManifestHash: String?, modelVersion: String?) async throws -> MeetingAtlasRecordingCompletion {
        record("complete")
        return MeetingAtlasRecordingCompletion(status: "recorded_pending_transcription", duplicate: false)
    }
    func appendSegments(meetingID: String, turns: [MeetingSpeakerTurn]) async throws { record("segments") }
    func finalize(meetingID: String, artifactID: String, transcriptionState: String, status: String) async throws { record("finalize") }
    func meetingInsights(meetingReference: String) async throws -> AtlasMeetingInsights? {
        record("getMeeting")
        return nil
    }
}
