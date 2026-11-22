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
        let refreshed = await state.refreshAtlasInsights(earlier)
        XCTAssertFalse(refreshed, "Its Atlas summary isn't fetched under the new sign-in")
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

    // MARK: - Pieces

    func testBlockerAndConfirmationText() {
        XCTAssertNil(AtlasSignOut.blocker(recording: false, unsentRecordings: 0))
        XCTAssertTrue(AtlasSignOut.blocker(recording: true, unsentRecordings: 0)!.hasPrefix("A meeting is being recorded."))
        XCTAssertTrue(AtlasSignOut.blocker(recording: false, unsentRecordings: 1)!.hasPrefix("1 meeting recording hasn’t reached Atlas yet."))
        XCTAssertTrue(AtlasSignOut.blocker(recording: false, unsentRecordings: 3)!.hasPrefix("3 meeting recordings haven’t reached Atlas yet."))
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
        XCTAssertEqual(defaults.string(forKey: "leaderboardReportedThrough"), today.adding(days: 1).key)
        let days = [today.adding(days: -3), today.adding(days: -1), today].map {
            LeaderboardDay(day: $0, words: 10, dictations: 1, speakingSeconds: 5, timeSavedSeconds: 10, meetings: 0, meetingSeconds: 0)
        }
        XCTAssertEqual(LeaderboardReport.daysToSend(days, reportedThrough: today.adding(days: 1), today: today).map(\.day), [today],
                       "Earlier days are never sent to the next account")
        XCTAssertFalse(controller.meetingTally.days.isEmpty, "This Mac's own meeting count stays")
    }

    func testMeetingCaptureStopsWhileSignedOutAndResumesAfterSignIn() async throws {
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

        coordinator.toggleManualCapture()
        for _ in 0..<100 where coordinator.statusDetail != "Sign in with Atlas to record meetings." || coordinator.isCaptureTransitioning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(coordinator.isCapturing, "Nothing is recorded while signed out")
        XCTAssertEqual(coordinator.statusDetail, "Sign in with Atlas to record meetings.")

        signedOut = false
        coordinator.resumeAfterSignIn()
        XCTAssertTrue(coordinator.isMonitoringAtlas)
        coordinator.stopMonitoring()
    }
}
