import AVFoundation
import CryptoKit
import Foundation
import Security
import XCTest
@testable import WhiskerFlow
import WhiskerFlowAppSupport
import WhiskerFlowCore

/// One in-memory Keychain item, so sign-in and sign-out never touch a real one.
private final class MemoryKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    var deleteStatus: OSStatus = errSecSuccess
    /// Anything but success makes every read fail, like a locked Keychain.
    var readStatus: OSStatus = errSecSuccess

    init(token: String?) { stored = token.map { Data($0.utf8) } }

    var token: String? {
        lock.lock()
        defer { lock.unlock() }
        return stored.flatMap { String(data: $0, encoding: .utf8) }
    }

    func store(service: String) -> MeetingCaptureTokenStore {
        MeetingCaptureTokenStore(
            service: service,
            copyMatching: { [self] _, result in
                lock.lock()
                defer { lock.unlock() }
                guard readStatus == errSecSuccess else { return readStatus }
                guard let stored else { return errSecItemNotFound }
                result?.pointee = stored as CFData
                return errSecSuccess
            },
            addItem: { [self] attributes in
                lock.lock()
                defer { lock.unlock() }
                stored = (attributes as NSDictionary)[kSecValueData as String] as? Data
                return errSecSuccess
            },
            updateItem: { [self] _, attributes in
                lock.lock()
                defer { lock.unlock() }
                guard stored != nil else { return errSecItemNotFound }
                stored = (attributes as NSDictionary)[kSecValueData as String] as? Data
                return errSecSuccess
            },
            deleteItem: { [self] _ in
                lock.lock()
                defer { lock.unlock() }
                guard deleteStatus == errSecSuccess else { return deleteStatus }
                stored = nil
                return errSecSuccess
            }
        )
    }
}

/// Holds one request open until the test releases it, so a sign-out can
/// happen while it is in flight. No sleeps: the test waits for the request
/// to start, then resumes it.
final class HeldReply<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var reply: CheckedContinuation<Value, Never>?
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var started = false

    /// Called by the stub: suspends until `release`.
    func hold() async -> Value {
        await withCheckedContinuation { continuation in
            lock.lock()
            reply = continuation
            started = true
            let waiter = startedWaiter
            startedWaiter = nil
            lock.unlock()
            waiter?.resume()
        }
    }

    func untilStarted() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if started {
                lock.unlock()
                continuation.resume()
            } else {
                startedWaiter = continuation
                lock.unlock()
            }
        }
    }

    func release(_ value: Value) {
        lock.lock()
        let reply = reply
        self.reply = nil
        lock.unlock()
        reply?.resume(returning: value)
    }
}

/// A meeting Atlas client whose schedule and summary requests wait for the test.
private final class HeldMeetingAtlasStub: MeetingAtlasClient, @unchecked Sendable {
    let heldSchedule = HeldReply<[AtlasCaptureScheduleIntent]>()
    let heldInsights = HeldReply<AtlasMeetingInsights?>()

    func schedule(fromMs: Int64, toMs: Int64) async throws -> [AtlasCaptureScheduleIntent] { await heldSchedule.hold() }
    func meetingInsights(meetingReference: String) async throws -> AtlasMeetingInsights? { await heldInsights.hold() }
    func heartbeat(appVersion: String, permissionState: [String: String], diskState: String, captureState: String, lastFailureReason: String?) async throws {}
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
}

/// An Assistant transport whose next request waits for the test.
private final class HeldAssistantTransport: AssistantAtlasTransport, @unchecked Sendable {
    let reply = HeldReply<Data>()
    func call(operation: String, arguments: Data) async throws -> Data { await reply.hold() }
}

@MainActor
final class AtlasSignOutTests: XCTestCase {
    private static let firstToken = "twnt_first_device_token_0001"
    private static let secondToken = "twnt_second_device_token_0002"

    private func temporaryRoot() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AtlasSignOutTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeDefaults() -> UserDefaults {
        let name = "AtlasSignOutTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    /// A signed-in production-like app: the sign-in gate is enforced.
    private func signedInApp(_ keychain: MemoryKeychain) -> (AppState, UserDefaults) {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults, meetingTokenStore: keychain.store(service: "AtlasSignOutTests"))
        settings.cacheMeetingSchedule([AtlasCaptureScheduleIntent(
            eventID: "event", title: "Client kickoff", startMs: 1_790_000_000_000, endMs: 1_790_003_600_000,
            meetingURL: nil, location: nil, existingMeetingID: nil, overlapsPrevious: false
        )])
        let state = AppState(settings: settings, store: TranscriptStore(fileURL: temporaryRoot().appendingPathComponent("transcripts.json")))
        state.enforcesAtlasSignIn = true
        return (state, defaults)
    }

    func testSignOutRemovesTheTokenAndEverythingTiedToTheAccount() {
        let keychain = MemoryKeychain(token: Self.firstToken)
        let (state, _) = signedInApp(keychain)
        XCTAssertTrue(state.isAtlasPaired)
        XCTAssertFalse(state.requiresAtlasSignIn)
        XCTAssertFalse(state.settings.cachedMeetingSchedule().isEmpty)
        let identity = AppState.accountIdentity(forToken: Self.firstToken)
        XCTAssertEqual(state.assistant.accountIdentityProvider?(), identity)
        XCTAssertNotNil(state.assistant.saveLocalDraft("Follow up with the client", kind: .note, clientReference: nil, accountIdentity: identity))

        XCTAssertTrue(state.signOutOfAtlas())

        XCTAssertNil(keychain.token, "The token is deleted from the Keychain")
        XCTAssertEqual(state.settings.atlasDeviceToken, "", "and from the settings cache")
        XCTAssertFalse(state.isAtlasPaired)
        XCTAssertNil(state.assistant.accountIdentityProvider?(), "No account is assumed after an explicit sign-out")
        XCTAssertTrue(state.requiresAtlasSignIn, "The sign-in gate is back")
        XCTAssertTrue(state.settings.cachedMeetingSchedule().isEmpty, "The cached schedule from Atlas is gone")
        XCTAssertNil(state.leaderboard.board)
        XCTAssertEqual(state.assistant.saved.drafts.count, 1, "Drafts are local and stay")
        XCTAssertNil(state.atlasSignOutError)
    }

    func testAKeychainFailureKeepsTheAccountAndSaysSo() {
        let keychain = MemoryKeychain(token: Self.firstToken)
        keychain.deleteStatus = errSecInteractionNotAllowed
        let (state, _) = signedInApp(keychain)

        XCTAssertFalse(state.signOutOfAtlas())

        XCTAssertEqual(keychain.token, Self.firstToken)
        XCTAssertTrue(state.isAtlasPaired)
        XCTAssertFalse(state.requiresAtlasSignIn)
        XCTAssertFalse(state.settings.cachedMeetingSchedule().isEmpty, "Nothing is removed when the token stays")
        XCTAssertNotNil(state.atlasSignOutError)
    }

    func testOnlyAnExplicitSignOutStopsMeetingRecording() {
        // A Keychain that can't be read looks like "no token" to the window,
        // but it is not a sign-out and must not cost the user a meeting.
        let locked = MemoryKeychain(token: Self.firstToken)
        locked.readStatus = errSecInteractionNotAllowed
        let (unreadable, _) = signedInApp(locked)
        XCTAssertTrue(unreadable.requiresAtlasSignIn)
        XCTAssertFalse(unreadable.meetingRecordingRequiresSignIn)

        let (state, defaults) = signedInApp(MemoryKeychain(token: Self.firstToken))
        XCTAssertFalse(state.meetingRecordingRequiresSignIn)

        XCTAssertTrue(state.signOutOfAtlas())
        XCTAssertTrue(state.meetingRecordingRequiresSignIn, "No recording after an explicit sign-out")
        XCTAssertTrue(defaults.bool(forKey: "signedOutOfAtlas"), "and that survives a relaunch")

        state.completeAtlasSignIn(token: Self.secondToken)
        XCTAssertFalse(state.meetingRecordingRequiresSignIn)
        XCTAssertFalse(defaults.bool(forKey: "signedOutOfAtlas"))
    }

    func testSignOutWaitsForMeetingRecordingsThatHaveNotReachedAtlas() {
        let keychain = MemoryKeychain(token: Self.firstToken)
        let (state, _) = signedInApp(keychain)
        let sessionID = UUID()
        state.meetingLibrary.beginRecording(sessionID: sessionID, title: "Design review", startedAt: Date(), calendarEventID: nil)
        state.meetingLibrary.setStatus(sessionID, .queued, detail: "Saved on this Mac.")

        XCTAssertNotNil(state.atlasSignOutBlocker)
        XCTAssertFalse(state.signOutOfAtlas())
        XCTAssertEqual(keychain.token, Self.firstToken, "The recording can still reach the account that made it")
        XCTAssertEqual(state.atlasSignOutError, state.atlasSignOutBlocker)

        state.meetingLibrary.setStatus(sessionID, .failed, detail: "Held", awaitingManualRetry: true)
        XCTAssertNotNil(state.atlasSignOutBlocker, "A recording held for Retry still waits for this account")

        state.meetingLibrary.markDelivered(sessionID, atlasMeetingID: "meeting", atlasMeetingReference: nil, bookmarks: nil)
        XCTAssertNil(state.atlasSignOutBlocker)
        XCTAssertTrue(state.signOutOfAtlas())
    }

    func testNotesFromMeetingsBeforeSignOutAreNeverSentToTheNextSignIn() async {
        let keychain = MemoryKeychain(token: Self.firstToken)
        let (state, _) = signedInApp(keychain)
        let earlier = UUID()
        state.meetingLibrary.beginRecording(sessionID: earlier, title: "Design review", startedAt: Date(), calendarEventID: nil)
        state.meetingLibrary.markDelivered(earlier, atlasMeetingID: "meeting", atlasMeetingReference: nil, bookmarks: nil)
        XCTAssertTrue(state.signOutOfAtlas())
        state.completeAtlasSignIn(token: Self.secondToken)

        let request = MeetingBookmarkSyncRequest(requestID: UUID(), localSessionID: earlier, meetingReference: "wm1_reference",
                                                 elapsedMilliseconds: 1_000, label: "Note")
        do {
            _ = try await state.meetingLibrary.noteSync?(request)
            XCTFail("A note from an earlier sign-in must not be sent")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Recorded under an earlier Atlas sign-in, so this stays on this Mac.")
        }
    }

    func testSigningBackInAsTheSameAccountKeepsItsDrafts() async {
        let keychain = MemoryKeychain(token: Self.firstToken)
        let (state, _) = signedInApp(keychain)
        let identity = AppState.accountIdentity(forToken: Self.firstToken)
        let draft = state.assistant.saveLocalDraft("Agenda for Thursday", kind: .note, clientReference: nil, accountIdentity: identity)!
        XCTAssertTrue(state.signOutOfAtlas())

        state.completeAtlasSignIn(token: Self.firstToken)

        XCTAssertEqual(keychain.token, Self.firstToken)
        XCTAssertTrue(state.isAtlasPaired)
        XCTAssertFalse(state.requiresAtlasSignIn, "Signed in again without a restart")
        XCTAssertEqual(state.assistant.accountIdentityProvider?(), identity)
        state.assistant.requestTransport = { throw AssistantError.message("Offline in tests.") }
        await state.assistant.sendDraft(draft)
        XCTAssertEqual(state.assistant.message, "Offline in tests.", "The draft is accepted for this connection")
    }

    func testSigningInAsAnotherAccountKeepsAnotherConnectionsDraftsBack() async {
        let keychain = MemoryKeychain(token: Self.firstToken)
        let (state, _) = signedInApp(keychain)
        let first = AppState.accountIdentity(forToken: Self.firstToken)
        let draft = state.assistant.saveLocalDraft("Agenda for Thursday", kind: .note, clientReference: nil, accountIdentity: first)!
        XCTAssertTrue(state.signOutOfAtlas())

        state.completeAtlasSignIn(token: Self.secondToken)

        XCTAssertEqual(keychain.token, Self.secondToken)
        XCTAssertFalse(state.requiresAtlasSignIn)
        XCTAssertEqual(state.assistant.accountIdentityProvider?(), AppState.accountIdentity(forToken: Self.secondToken))
        state.assistant.requestTransport = { XCTFail("Nothing is sent for another connection's draft"); throw CancellationError() }
        await state.assistant.sendDraft(draft)
        XCTAssertEqual(state.assistant.message,
                       "This draft belongs to a different Atlas connection. Reconnect that account or copy it for review.")
        XCTAssertEqual(state.assistant.saved.drafts.count, 1, "It stays on this Mac")
    }

    func testAnAssistantRequestThatFinishesAfterSignOutKeepsTheUsersOwnWords() async throws {
        let (state, _) = signedInApp(MemoryKeychain(token: Self.firstToken))
        let identity = AppState.accountIdentity(forToken: Self.firstToken)
        let assistant = state.assistant
        assistant.synchronizeAccount()
        assistant.setCloudEnabled(true)
        assistant.selectClient("client_acme")
        assistant.addClientTerm(find: "acme", replacement: "ACME")
        let transport = HeldAssistantTransport()
        assistant.requestTransport = { transport }
        let refresh = Task { await assistant.refreshClients() }
        await transport.reply.untilStarted()

        XCTAssertTrue(state.signOutOfAtlas())
        transport.reply.release(try JSONSerialization.data(withJSONObject: [
            "contractVersion": 1, "profiles": [["reference": "client_acme", "name": "Acme"]],
        ] as [String: Any]))
        await refresh.value

        XCTAssertEqual(assistant.saved.clientCustomVocabulary?["client_acme"]?.rules.map(\.find), ["acme"],
                       "The user's own client words stay")
        XCTAssertTrue(assistant.saved.cloudEnabled, "The Atlas AI choice stays")
        XCTAssertEqual(assistant.saved.accountIdentity, identity, "The signed-out state is not adopted as an account")
        XCTAssertTrue(assistant.saved.clients.isEmpty, "The late client list is discarded")
    }

    func testRelaunchingSignedOutKeepsTheUsersOwnWords() {
        let keychain = MemoryKeychain(token: Self.firstToken)
        let (state, _) = signedInApp(keychain)
        state.assistant.synchronizeAccount()
        state.assistant.selectClient("client_acme")
        state.assistant.addClientTerm(find: "acme", replacement: "ACME")
        XCTAssertTrue(state.signOutOfAtlas())

        // What any later entry point (a launch, a dictation) does first.
        XCTAssertFalse(state.assistant.synchronizeAccount(), "There is no connection to adopt")
        XCTAssertEqual(state.assistant.saved.clientCustomVocabulary?["client_acme"]?.rules.count, 1)
    }

    // MARK: - Pieces

    func testBlockerAndConfirmationText() {
        XCTAssertNil(AtlasSignOut.blocker(recording: false, unsentRecordings: 0))
        XCTAssertTrue(AtlasSignOut.blocker(recording: true, unsentRecordings: 0)!.hasPrefix("A meeting is being recorded."))
        XCTAssertTrue(AtlasSignOut.blocker(recording: false, unsentRecordings: 1)!.hasPrefix("1 meeting recording hasn’t reached Atlas yet."))
        XCTAssertTrue(AtlasSignOut.blocker(recording: false, unsentRecordings: 3)!.hasPrefix("3 meeting recordings haven’t reached Atlas yet."))
        XCTAssertNil(AtlasSignOut.blocker(recording: false, unsentRecordings: 0, recordingCheck: .notStarted))
        XCTAssertTrue(AtlasSignOut.blocker(recording: true, unsentRecordings: 0, recordingCheck: .checking)!.hasPrefix("A meeting is being recorded."))
        XCTAssertFalse(AtlasSignOut.confirmation(unsyncedMeetingItems: 0).contains("won’t be sent"))
        XCTAssertTrue(AtlasSignOut.confirmation(unsyncedMeetingItems: 2)
            .contains("2 meeting notes and bookmarks haven’t reached Atlas. They stay on this Mac and won’t be sent after you sign out."))
    }

    func testLeaderboardStopsAndTheNextAccountStartsFromToday() {
        let defaults = makeDefaults()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let controller = LeaderboardController(client: { nil }, usageDays: { _ in [] }, defaults: defaults,
                                               calendar: { calendar }, now: { now })
        controller.recordMeeting(startedAt: now, durationMs: 60_000)
        controller.startPeriodicReporting()
        XCTAssertTrue(controller.isReportingPeriodically)

        controller.signOut()

        XCTAssertFalse(controller.isReportingPeriodically)
        XCTAssertNil(controller.board)
        let today = LocalDay(now, calendar: calendar)
        XCTAssertEqual(defaults.string(forKey: "leaderboardReportsFrom"), today.key,
                       "Earlier days are never sent to the next account")
        XCTAssertFalse(controller.meetingTally.days.isEmpty, "This Mac's own meeting count stays")
    }

    private func heldCoordinator(_ client: HeldMeetingAtlasStub, defaults: UserDefaults) -> (MeetingCaptureCoordinator, AppSettings) {
        let settings = AppSettings(defaults: defaults, meetingTokenStore: MemoryKeychain(token: Self.firstToken).store(service: "AtlasSignOutTests"))
        settings.askToRecordCalls = false
        let coordinator = MeetingCaptureCoordinator(
            settings: settings,
            microphonePermission: MicrophonePermissionController(provider: AVCaptureMicrophoneAuthorizationProvider()),
            transcription: TranscriptionService(),
            store: EncryptedMeetingChunkStore(rootURL: temporaryRoot(), keyProvider: FixedMeetingChunkKeyProvider(key: SymmetricKey(size: .bits256))),
            clientProvider: { client },
            library: .ephemeral(),
            assistant: MeetingAssistantController(rootURL: temporaryRoot()),
            diskStateReader: { "ready" }
        )
        return (coordinator, settings)
    }

    func testAMeetingSummaryThatArrivesAfterSignOutIsDropped() async {
        let client = HeldMeetingAtlasStub()
        let (coordinator, _) = heldCoordinator(client, defaults: makeDefaults())
        let sessionID = UUID()
        coordinator.library.beginRecording(sessionID: sessionID, title: "Design review", startedAt: Date(), calendarEventID: nil)
        coordinator.library.markDelivered(sessionID, atlasMeetingID: "meeting",
                                          atlasMeetingReference: "wm1_" + String(repeating: "a", count: 43), bookmarks: nil)
        let refresh = Task { await coordinator.refreshAtlasInsights(sessionID: sessionID) }
        await client.heldInsights.untilStarted()

        // What `AppState.signOutOfAtlas()` does to the coordinator and library.
        coordinator.signOut()
        coordinator.library.removeAtlasInsights()
        client.heldInsights.release(AtlasMeetingInsights(notesStatus: "suggested", summary: "The old account's summary", fetchedAt: Date()))

        let saved = await refresh.value
        XCTAssertFalse(saved)
        XCTAssertNil(coordinator.library.entry(sessionID)?.atlasInsights, "The earlier sign-in's summary is not restored")
    }

    func testAScheduleThatArrivesAfterSignOutIsNotCachedOrShown() async {
        let client = HeldMeetingAtlasStub()
        let (coordinator, settings) = heldCoordinator(client, defaults: makeDefaults())
        // `refreshSchedule()` runs this in a task nothing cancels.
        let poll = Task { await coordinator.pollSchedule() }
        await client.heldSchedule.untilStarted()

        // What `AppState.signOutOfAtlas()` does to the schedule.
        settings.removeCachedMeetingSchedule()
        coordinator.requiresSignIn = { true }
        coordinator.signOut()
        client.heldSchedule.release([AtlasCaptureScheduleIntent(
            eventID: "event", title: "Old account's client call", startMs: 1_790_000_000_000, endMs: 1_790_003_600_000,
            meetingURL: nil, location: nil, existingMeetingID: nil, overlapsPrevious: false
        )])
        await poll.value

        XCTAssertTrue(coordinator.scheduleIntents.isEmpty, "Not shown")
        XCTAssertTrue(settings.cachedMeetingSchedule().isEmpty, "Not cached for the next account")
    }

    private static let recordingKey = SymmetricKey(size: .bits256)

    private func recoveringCoordinator(root: URL) -> MeetingCaptureCoordinator {
        let settings = AppSettings(defaults: makeDefaults(), meetingTokenStore: MemoryKeychain(token: nil).store(service: "AtlasSignOutTests"))
        settings.askToRecordCalls = false
        return MeetingCaptureCoordinator(
            settings: settings,
            microphonePermission: MicrophonePermissionController(provider: AVCaptureMicrophoneAuthorizationProvider()),
            transcription: TranscriptionService(),
            store: EncryptedMeetingChunkStore(rootURL: root, keyProvider: FixedMeetingChunkKeyProvider(key: Self.recordingKey)),
            // Signed out: nothing is delivered, so the recording stays pending.
            clientProvider: { nil },
            library: .ephemeral(),
            assistant: MeetingAssistantController(rootURL: temporaryRoot()),
            diskStateReader: { "ready" }
        )
    }

    func testSignOutWaitsUntilStartupHasFoundRecordingsOnThisMac() async throws {
        let root = temporaryRoot()
        let seed = EncryptedMeetingChunkStore(rootURL: root, keyProvider: FixedMeetingChunkKeyProvider(key: Self.recordingKey))
        let sessionID = UUID()
        try seed.beginSession(sessionID: sessionID, meetingID: nil, expectedChunkCounts: [.mixed: 1], title: "Before the relaunch")
        _ = try seed.writeChunk(sessionID: sessionID, track: .mixed, sequence: 0, startMs: 0, endMs: 10_000, plaintext: Data("audio".utf8))
        let coordinator = recoveringCoordinator(root: root)

        coordinator.start()
        // The library and the scan haven't run yet: nothing is known to be unsent.
        XCTAssertEqual(coordinator.unsentRecordingCount, 0)
        XCTAssertEqual(coordinator.signOutBlocker,
                       "WhiskerFlow is still checking for meeting recordings on this Mac. Try again in a moment.")

        await coordinator.waitForRecovery()
        XCTAssertEqual(coordinator.recordingCheck, .finished)
        XCTAssertEqual(coordinator.unsentRecordingCount, 1)
        XCTAssertTrue(coordinator.signOutBlocker?.hasPrefix("1 meeting recording hasn’t reached Atlas yet.") == true)
        coordinator.stopMonitoring()
    }

    func testSignOutStaysBlockedWhenTheStartupScanFails() async throws {
        // A file where the recordings folder should be: the scan can't list it.
        let root = temporaryRoot()
        try Data("not a folder".utf8).write(to: root)
        let coordinator = recoveringCoordinator(root: root)

        coordinator.start()
        await coordinator.waitForRecovery()

        XCTAssertEqual(coordinator.recordingCheck, .failed)
        XCTAssertEqual(coordinator.unsentRecordingCount, 0)
        XCTAssertEqual(coordinator.signOutBlocker,
                       "WhiskerFlow couldn’t read the meeting recordings saved on this Mac, so it can’t tell whether any still need to reach Atlas. Quit and reopen WhiskerFlow, then try again.")
        coordinator.stopMonitoring()
    }

    func testMeetingCaptureStopsWhileSignedOutAndResumesAfterSignIn() async {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults, meetingTokenStore: MemoryKeychain(token: nil).store(service: "AtlasSignOutTests"))
        settings.askToRecordCalls = false
        let key = SymmetricKey(size: .bits256)
        let client = LibraryDeliveryStub()
        let coordinator = MeetingCaptureCoordinator(
            settings: settings,
            microphonePermission: MicrophonePermissionController(provider: AVCaptureMicrophoneAuthorizationProvider()),
            transcription: TranscriptionService(),
            store: EncryptedMeetingChunkStore(rootURL: temporaryRoot(), keyProvider: FixedMeetingChunkKeyProvider(key: key)),
            clientProvider: { client },
            library: .ephemeral(),
            assistant: MeetingAssistantController(rootURL: temporaryRoot()),
            diskStateReader: { "ready" }
        )
        coordinator.start()
        XCTAssertTrue(coordinator.isMonitoringAtlas)

        var signedOut = true
        coordinator.requiresSignIn = { signedOut }
        coordinator.signOut()
        XCTAssertFalse(coordinator.isMonitoringAtlas, "No schedule poll or heartbeat")
        XCTAssertTrue(coordinator.scheduleIntents.isEmpty)
        XCTAssertNil(coordinator.callPrompt)

        await coordinator.toggleManualCapture()?.value
        XCTAssertFalse(coordinator.isCapturing, "Nothing is recorded while signed out")
        XCTAssertEqual(coordinator.statusDetail, "Sign in with Atlas to record meetings.")

        signedOut = false
        coordinator.resumeAfterSignIn()
        XCTAssertTrue(coordinator.isMonitoringAtlas)
        coordinator.stopMonitoring()
    }
}
