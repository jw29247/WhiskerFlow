import AVFoundation
import CryptoKit
import Foundation
import XCTest
@testable import WhiskerFlow
import WhiskerFlowAppSupport

/// Counts schedule fetches and heartbeats; everything else is unused here.
private final class ScheduleStub: MeetingAtlasClient, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var beats = 0
    var heartbeats: Int { lock.withLock { beats } }
    private var result: [AtlasCaptureScheduleIntent] = []
    var fetches: Int { lock.withLock { count } }
    var intents: [AtlasCaptureScheduleIntent] {
        get { lock.withLock { result } }
        set { lock.withLock { result = newValue } }
    }

    func schedule(fromMs: Int64, toMs: Int64) async throws -> [AtlasCaptureScheduleIntent] {
        lock.withLock {
            count += 1
            return result
        }
    }

    func heartbeat(appVersion: String, permissionState: [String: String], diskState: String, captureState: String, lastFailureReason: String?) async throws {
        lock.withLock { beats += 1 }
    }
    func createMeeting(captureSessionID: UUID, title: String, occurredAtMs: Int64, eventID: String?) async throws -> MeetingAtlasCreatedMeeting {
        throw URLError(.notConnectedToInternet)
    }

    func prepareRecording(meetingID: String, captureSessionID: UUID, trackChunkCounts: [MeetingAudioTrack: Int], sourceManifestHash: String?, playbackChunkCount: Int?) async throws -> String {
        throw URLError(.notConnectedToInternet)
    }

    func uploadChunk(artifactID: String, descriptor: MeetingRecordingChunkDescriptor, body: Data) async throws {}
    func uploadPlaybackChunk(artifactID: String, descriptor: MeetingRecordingChunkDescriptor, body: Data) async throws {}
    func completePlayback(artifactID: String) async throws {}
    func completeRecording(artifactID: String, durationMs: Int64, trackChunkCounts: [MeetingAudioTrack: Int], hasSourceGap: Bool, missingTracks: [MeetingAudioTrack], canonicalChecksum: String?, sourceManifestHash: String?, modelVersion: String?) async throws -> MeetingAtlasRecordingCompletion {
        throw URLError(.notConnectedToInternet)
    }

    func appendSegments(meetingID: String, turns: [MeetingSpeakerTurn]) async throws {}
    func finalize(meetingID: String, artifactID: String, transcriptionState: String, status: String) async throws {}
    func meetingInsights(meetingReference: String) async throws -> AtlasMeetingInsights? { nil }
}

@MainActor
final class MeetingSchedulePollTests: XCTestCase {
    private let minute: Int64 = 60_000

    private func intent(startMs: Int64, endMs: Int64, url: String? = nil) -> AtlasCaptureScheduleIntent {
        AtlasCaptureScheduleIntent(eventID: "event-\(startMs)", title: "Weekly sync", startMs: startMs, endMs: endMs,
                                   meetingURL: url, location: nil, existingMeetingID: nil, overlapsPrevious: false)
    }

    private func coordinator(client: ScheduleStub) -> (MeetingCaptureCoordinator, AppSettings) {
        let name = "MeetingSchedulePollTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults, meetingTokenStore: MeetingCaptureTokenStore.inMemory(service: name))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let coordinator = MeetingCaptureCoordinator(
            settings: settings,
            microphonePermission: MicrophonePermissionController(provider: AVCaptureMicrophoneAuthorizationProvider()),
            transcription: TranscriptionService(),
            store: EncryptedMeetingChunkStore(rootURL: root, keyProvider: FixedMeetingChunkKeyProvider(key: SymmetricKey(size: .bits256))),
            clientProvider: { client },
            callDetector: CallDetectionService(readSignals: { CallDetectionSignals(inputs: [], windows: []) }),
            joinedMeetingProvider: { _ in false },
            diskStateReader: { "ready" }
        )
        coordinator.canRecordDetectedCall = { true }
        return (coordinator, settings)
    }

    func testPolicyKeepsTheMinuteCadenceWheneverAnythingDependsOnIt() {
        let now: Int64 = 1_800_000_000_000
        let recent = now - minute
        func poll(last: Int64? = recent, automatic: Bool = false, capturing: Bool = false,
                  intents: [AtlasCaptureScheduleIntent] = []) -> Bool {
            MeetingSchedulePollPolicy.shouldPoll(nowMs: now, lastFetchMs: last, automaticRecording: automatic,
                                                 capturing: capturing, intents: intents)
        }
        XCTAssertFalse(poll(), "Automatic recording off, nothing near: wait")
        XCTAssertTrue(poll(automatic: true), "Automatic recording keeps every minute")
        XCTAssertTrue(poll(capturing: true), "A running recording keeps every minute")
        XCTAssertTrue(poll(last: nil), "After a failure or before the first fetch")
        XCTAssertTrue(poll(last: now - 10 * minute), "At most 10 minutes old")
        XCTAssertTrue(poll(last: now + minute), "Clock moved back")
        XCTAssertTrue(poll(intents: [intent(startMs: now + 15 * minute, endMs: now + 45 * minute)]), "Starts within 15 minutes")
        XCTAssertTrue(poll(intents: [intent(startMs: now - 60 * minute, endMs: now - 14 * minute)]), "Ended within 15 minutes")
        XCTAssertFalse(poll(intents: [intent(startMs: now + 16 * minute, endMs: now + 46 * minute)]))
    }

    func testOpeningMeetingsFetchesOnlyWhenTheListIsOverAMinuteOld() async {
        let client = ScheduleStub()
        let (coordinator, settings) = coordinator(client: client)
        settings.meetingModeEnabled = false
        XCTAssertFalse(coordinator.refreshScheduleIfStale(), "Before the first fetch the loop already fetches every minute")
        await coordinator.pollSchedule()
        XCTAssertEqual(client.fetches, 1)
        let fetchedAt = coordinator.lastScheduleFetchMs ?? MeetingCaptureCoordinator.nowMs()
        XCTAssertFalse(coordinator.refreshScheduleIfStale(nowMs: fetchedAt + minute - 1), "A list under a minute old is current")
        XCTAssertTrue(coordinator.refreshScheduleIfStale(nowMs: fetchedAt + minute), "An older list is fetched as the screen opens")
    }

    func testIdleTicksFetchEveryTenMinutesWithAutomaticRecordingOff() async {
        let client = ScheduleStub()
        let (coordinator, settings) = coordinator(client: client)
        settings.meetingModeEnabled = false
        let start = MeetingCaptureCoordinator.nowMs()
        // The loop's first tick fetches; the fetch records the wall clock.
        await coordinator.pollScheduleIfDue(nowMs: start)
        XCTAssertEqual(client.fetches, 1)
        let fetchedAt = coordinator.lastScheduleFetchMs ?? start
        for tick in 1..<10 {
            await coordinator.pollScheduleIfDue(nowMs: fetchedAt + Int64(tick) * minute)
        }
        XCTAssertEqual(client.fetches, 1, "Nine idle ticks fetch nothing")
        await coordinator.pollScheduleIfDue(nowMs: fetchedAt + 10 * minute)
        XCTAssertEqual(client.fetches, 2)
    }

    func testAutomaticRecordingFetchesEveryMinuteAsBefore() async {
        let client = ScheduleStub()
        let (coordinator, settings) = coordinator(client: client)
        settings.meetingModeEnabled = true
        let start = MeetingCaptureCoordinator.nowMs()
        for tick in 0..<5 {
            await coordinator.pollScheduleIfDue(nowMs: start + Int64(tick) * minute)
        }
        XCTAssertEqual(client.fetches, 5)
    }

    func testTurningAutomaticRecordingOnFetchesAtTheNextMinuteTick() async {
        let client = ScheduleStub()
        let (coordinator, settings) = coordinator(client: client)
        settings.meetingModeEnabled = false
        let start = MeetingCaptureCoordinator.nowMs()
        await coordinator.pollScheduleIfDue(nowMs: start)
        await coordinator.pollScheduleIfDue(nowMs: start + minute)
        XCTAssertEqual(client.fetches, 1)
        settings.meetingModeEnabled = true
        await coordinator.pollScheduleIfDue(nowMs: start + 2 * minute)
        XCTAssertEqual(client.fetches, 2, "A meeting about to start is armed no later than before")
    }

    func testAMeetingAddedSinceTheLastFetchStillNamesTheCallPrompt() async throws {
        let client = ScheduleStub()
        let (coordinator, settings) = coordinator(client: client)
        settings.meetingModeEnabled = false
        settings.askToRecordCalls = true
        let now = MeetingCaptureCoordinator.nowMs()
        await coordinator.pollSchedule()
        XCTAssertEqual(client.fetches, 1)
        // Simulate a schedule fetched five minutes ago, then an event added since.
        coordinator.setLastScheduleFetchForTesting(now - 5 * minute)
        client.intents = [intent(startMs: now - minute, endMs: now + 30 * minute, url: "https://meet.google.com/abc-defg-hij")]
        let meet = DetectedCall(platform: .googleMeet, appBundleID: "com.google.Chrome", isBrowser: true, meetingCode: "abc-defg-hij")
        coordinator.handleCallEvent(.started(meet))
        XCTAssertNotNil(coordinator.callPrompt)
        for _ in 0..<500 where coordinator.callPrompt?.intent == nil {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(client.fetches, 2)
        XCTAssertEqual(coordinator.callPrompt?.title, "Weekly sync")
    }

    // MARK: Heartbeat

    func testHeartbeatPolicySendsEveryMinuteWhenSomethingHappensAndEveryFiveOtherwise() {
        let idle = MeetingHeartbeatPolicy.State(permissionState: ["microphone": "granted"], captureState: "idle", lastFailureReason: nil)
        let now: Int64 = 1_800_000_000_000
        let last = (atMs: now - minute, state: idle)
        XCTAssertFalse(MeetingHeartbeatPolicy.shouldSend(nowMs: now, lastSent: last, state: idle, busy: false))
        XCTAssertTrue(MeetingHeartbeatPolicy.shouldSend(nowMs: now, lastSent: nil, state: idle, busy: false), "First, or after a failure")
        XCTAssertTrue(MeetingHeartbeatPolicy.shouldSend(nowMs: now, lastSent: last, state: idle, busy: true), "Recording or uploading")
        var recording = idle
        recording.captureState = "recording"
        XCTAssertTrue(MeetingHeartbeatPolicy.shouldSend(nowMs: now, lastSent: last, state: recording, busy: false), "State changed")
        var failed = idle
        failed.lastFailureReason = "schedule"
        XCTAssertTrue(MeetingHeartbeatPolicy.shouldSend(nowMs: now, lastSent: last, state: failed, busy: false))
        var denied = idle
        denied.permissionState = ["microphone": "denied"]
        XCTAssertTrue(MeetingHeartbeatPolicy.shouldSend(nowMs: now, lastSent: last, state: denied, busy: false))
        XCTAssertTrue(MeetingHeartbeatPolicy.shouldSend(nowMs: now + 4 * minute, lastSent: last, state: idle, busy: false))
    }

    func testIdleHeartbeatTicksSendEveryFiveMinutes() async {
        let client = ScheduleStub()
        let (coordinator, _) = coordinator(client: client)
        let start = MeetingCaptureCoordinator.nowMs()
        for tick in 0..<10 {
            await coordinator.sendHeartbeatIfDue(nowMs: start + Int64(tick) * minute)
        }
        XCTAssertEqual(client.heartbeats, 2, "Sent at 0 and 5 minutes, instead of 10 times")
    }
}
