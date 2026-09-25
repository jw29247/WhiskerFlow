import Foundation
import Testing
@testable import WhiskerFlow
import WhiskerFlowCore

@MainActor
struct MeetingAssistantTests {
    @Test func bookmarkSurvivesRestartAndKeepsStableRequestID() throws {
        let root = try temporaryRoot()
        let sessionID = UUID()
        var now = Date(timeIntervalSince1970: 100)
        var controller = MeetingAssistantController(rootURL: root, now: { now })
        controller.begin(sessionID: sessionID, title: "Planning")
        now = Date(timeIntervalSince1970: 112.5)
        let saved = try controller.addBookmark(label: "Decision")

        controller = MeetingAssistantController(rootURL: root, now: { now })
        let restored = try #require(controller.bookmarks.first)
        #expect(restored.id == saved.id)
        #expect(restored.sessionID == sessionID)
        #expect(restored.elapsedMilliseconds == 12_500)
        #expect(restored.label == "Decision")
        #expect(restored.syncState == .pending)
    }

    @Test func failedSyncAndExplicitRetryUseSameID() async throws {
        let root = try temporaryRoot()
        let sessionID = UUID()
        var now = Date(timeIntervalSince1970: 100)
        let controller = MeetingAssistantController(rootURL: root, now: { now })
        controller.begin(sessionID: sessionID, title: "Review")
        now = Date(timeIntervalSince1970: 109)
        let saved = try controller.addBookmark(label: nil)
        var requests: [MeetingBookmarkSyncRequest] = []
        let sync: MeetingBookmarkSync = { request in
            requests.append(request)
            throw TestFailure.offline
        }

        await controller.finalize(sessionID: sessionID, meetingReference: "meeting-1", durationMilliseconds: 10_000, sync: sync)
        #expect(requests.map(\.requestID) == [saved.id])
        #expect(controller.bookmarks.first?.syncState == .failed)

        await controller.retryPendingBookmarks(sessionID: sessionID) { request in
            requests.append(request)
            return "atlas-bookmark"
        }
        #expect(requests.map(\.requestID) == [saved.id, saved.id])
        #expect(controller.bookmarks.first?.syncState == .synced)
        #expect(controller.bookmarks.first?.atlasReference == "atlas-bookmark")
    }

    @Test func invalidTimestampNeverReachesSync() async throws {
        let root = try temporaryRoot()
        let sessionID = UUID()
        var now = Date(timeIntervalSince1970: 100)
        let controller = MeetingAssistantController(rootURL: root, now: { now })
        controller.begin(sessionID: sessionID, title: "Short")
        now = Date(timeIntervalSince1970: 120)
        _ = try controller.addBookmark(label: nil)
        var called = false
        await controller.finalize(sessionID: sessionID, meetingReference: "meeting", durationMilliseconds: 10_000) { _ in
            called = true
            return "never"
        }
        #expect(!called)
        #expect(controller.bookmarks.first?.syncState == .failed)
    }

    @Test func corruptStoreIsPreservedAndFailsClosed() throws {
        let root = try temporaryRoot()
        let file = root.appendingPathComponent("private-meeting-assistant.json")
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: file)
        let controller = MeetingAssistantController(rootURL: root)
        #expect(controller.storageError != nil)
        controller.begin(sessionID: UUID(), title: "Meeting")
        #expect(throws: MeetingAssistantError.corruptStore) {
            _ = try controller.addBookmark(label: nil)
        }
        #expect(try Data(contentsOf: file) == corrupt)
    }

    @Test func failedDurableWriteRollsBackBookmark() throws {
        let parent = try temporaryRoot()
        let invalidRoot = parent.appendingPathComponent("file-not-directory")
        try Data("x".utf8).write(to: invalidRoot)
        let controller = MeetingAssistantController(rootURL: invalidRoot)
        controller.begin(sessionID: UUID(), title: "Meeting")
        #expect(throws: MeetingAssistantError.storageUnavailable) {
            _ = try controller.addBookmark(label: "Must persist")
        }
        #expect(controller.bookmarks.isEmpty)
    }

    @Test func recoveredSessionWithUnknownDurationStillSyncsBookmarks() async throws {
        let root = try temporaryRoot()
        let sessionID = UUID()
        var now = Date(timeIntervalSince1970: 100)
        var controller = MeetingAssistantController(rootURL: root, now: { now })
        controller.begin(sessionID: sessionID, title: "Crashed call")
        now = Date(timeIntervalSince1970: 130)
        let saved = try controller.addBookmark(label: nil)
        var requests: [MeetingBookmarkSyncRequest] = []
        // Recovery has no recorded manifest duration and reports 0.
        await controller.finalize(sessionID: sessionID, meetingReference: "meeting", durationMilliseconds: 0) { request in
            requests.append(request)
            throw TestFailure.offline
        }
        #expect(requests.map(\.requestID) == [saved.id])
        controller = MeetingAssistantController(rootURL: root, now: { now })
        await controller.retryPendingBookmarks(sessionID: sessionID) { _ in "atlas-bookmark" }
        #expect(controller.bookmarks.first?.syncState == .synced)
    }

    @Test func fullStorageDoesNotBlockOtherSessionsFromSyncing() async throws {
        let root = try temporaryRoot()
        let controller = MeetingAssistantController(rootURL: root)
        var sessions: [UUID] = []
        for index in 0..<MeetingAssistantController.maximumStoredSessions {
            let id = UUID()
            sessions.append(id)
            controller.begin(sessionID: id, title: "Meeting \(index)")
            _ = try controller.addBookmark(label: nil)
            controller.end(sessionID: id)
        }
        let overflow = UUID()
        controller.begin(sessionID: overflow, title: "Overflow")
        #expect(controller.storageError != nil)
        #expect(throws: MeetingAssistantError.storageUnavailable) {
            _ = try controller.addBookmark(label: nil)
        }
        controller.end(sessionID: overflow)
        await controller.finalize(sessionID: sessions[0], meetingReference: "meeting-0", durationMilliseconds: 60_000) { _ in "atlas-bookmark" }
        #expect(controller.bookmarks.first { $0.sessionID == sessions[0] }?.syncState == .synced)
        let reloaded = MeetingAssistantController(rootURL: root)
        #expect(reloaded.bookmarks.first { $0.sessionID == sessions[0] }?.syncState == .synced)
    }

    @Test func finalizedMeetingReferenceSurvivesRestart() async throws {
        let root = try temporaryRoot()
        let sessionID = UUID()
        var controller = MeetingAssistantController(rootURL: root)
        controller.begin(sessionID: sessionID, title: "Meeting")
        await controller.finalize(sessionID: sessionID, meetingReference: "meeting-restored", durationMilliseconds: 1_000)
        controller = MeetingAssistantController(rootURL: root)
        #expect(controller.latestFinalizedMeetingReference == "meeting-restored")
    }

    @Test func concurrentFinalizeDoesNotSubmitBookmarkTwice() async throws {
        let root = try temporaryRoot()
        let sessionID = UUID()
        let controller = MeetingAssistantController(rootURL: root)
        controller.begin(sessionID: sessionID, title: "Meeting")
        _ = try controller.addBookmark(label: nil)
        var calls = 0
        let sync: MeetingBookmarkSync = { _ in
            calls += 1
            try await Task.sleep(nanoseconds: 50_000_000)
            return "bookmark"
        }
        let first = Task { @MainActor in
            await controller.finalize(sessionID: sessionID, meetingReference: "meeting", durationMilliseconds: 1_000, sync: sync)
        }
        let second = Task { @MainActor in
            await controller.finalize(sessionID: sessionID, meetingReference: "meeting", durationMilliseconds: 1_000, sync: sync)
        }
        await first.value
        await second.value
        #expect(calls == 1)
    }

    @Test func liveCoachIsOptInBoundedAndStopsWithSession() throws {
        let root = try temporaryRoot()
        let sessionID = UUID()
        let controller = MeetingAssistantController(rootURL: root, now: { Date(timeIntervalSince1970: 100) })
        controller.begin(sessionID: sessionID, title: "Call")
        controller.recordActivity(.init(elapsedSeconds: 0, durationSeconds: 1, ownMicActivity: true, systemActivity: false))
        #expect(controller.activityInputsCount == 0)
        controller.isCoachEnabled = true
        for second in 0..<120 {
            controller.recordActivity(.init(elapsedSeconds: Double(second), durationSeconds: 1, ownMicActivity: true, systemActivity: second % 20 == 0))
        }
        #expect(controller.activity.windowDurationSeconds == 60)
        #expect(controller.livePrompt != nil)
        #expect(controller.activityInputsCount <= 60)
        controller.end(sessionID: sessionID)
        #expect(controller.isActive == false)
        #expect(controller.activityInputsCount == 0)
    }

    @Test func bookmarkLimitIsTwoHundredPerSession() throws {
        let root = try temporaryRoot()
        let controller = MeetingAssistantController(rootURL: root)
        controller.begin(sessionID: UUID(), title: "Long call")
        for _ in 0..<200 { _ = try controller.addBookmark(label: nil) }
        #expect(throws: MeetingAssistantError.bookmarkLimitReached) {
            _ = try controller.addBookmark(label: nil)
        }
    }

    @Test func captureActivityClassificationUsesNoStoredAudio() {
        #expect(MeetingAudioCaptureService.hasAudibleActivity(Array(repeating: 0.02, count: 160)))
        #expect(!MeetingAudioCaptureService.hasAudibleActivity(Array(repeating: 0.001, count: 160)))
        #expect(!MeetingAudioCaptureService.hasAudibleActivity([]))
    }

    @Test func oldMeetingFinalizingLateNeverReplacesLatestIncludingRestart() async throws {
        let root = try temporaryRoot()
        var now = Date(timeIntervalSince1970: 100)
        var controller = MeetingAssistantController(rootURL: root, now: { now })
        let old = UUID(), latest = UUID()
        controller.begin(sessionID: old, title: "Old")
        controller.end(sessionID: old)
        now = now.addingTimeInterval(100)
        controller.begin(sessionID: latest, title: "Latest")
        controller.end(sessionID: latest)
        await controller.finalize(sessionID: latest, meetingReference: "latest", durationMilliseconds: 1_000)
        await controller.finalize(sessionID: old, meetingReference: "old", durationMilliseconds: 1_000)
        #expect(controller.latestFinalizedMeetingReference == "latest")
        controller = MeetingAssistantController(rootURL: root, now: { now })
        #expect(controller.latestFinalizedMeetingReference == "latest")
        await controller.finalize(sessionID: old, meetingReference: "old-retry", durationMilliseconds: 1_000)
        #expect(controller.latestFinalizedMeetingReference == "latest")
    }

    @Test func scheduledWrapUsesEndTimeOnceAndAdHocRequiresExplicitDuration() throws {
        let root = try temporaryRoot()
        let start = Date(timeIntervalSince1970: 100)
        let controller = MeetingAssistantController(rootURL: root, now: { start })
        controller.isCoachEnabled = true
        controller.plannedDurationMinutes = 120
        controller.begin(sessionID: UUID(), title: "Scheduled", scheduledEndAt: start.addingTimeInterval(600))
        sample(controller, at: 298)
        #expect(controller.livePrompt == nil)
        sample(controller, at: 299)
        #expect(controller.livePrompt?.contains("planned end") == true)
        controller.dismissPrompt()
        sample(controller, at: 599)
        #expect(controller.livePrompt == nil)
        controller.plannedDurationMinutes = nil
        controller.begin(sessionID: UUID(), title: "Ad hoc")
        sample(controller, at: 599)
        #expect(controller.plannedEndAt == nil)
        #expect(controller.livePrompt == nil)
        controller.plannedDurationMinutes = 15
        controller.begin(sessionID: UUID(), title: "Explicit duration")
        sample(controller, at: 599)
        #expect(controller.livePrompt?.contains("planned end") == true)
    }

    @Test func invalidAdHocDurationAndPastScheduledEndDoNotInventWrapTimes() throws {
        let start = Date(timeIntervalSince1970: 100)
        let controller = MeetingAssistantController(rootURL: try temporaryRoot(), now: { start })
        controller.isCoachEnabled = true
        for minutes in [-1, 0, 481, Int.max] {
            controller.plannedDurationMinutes = minutes
            controller.begin(sessionID: UUID(), title: "Ad hoc")
            sample(controller, at: 599)
            #expect(controller.plannedEndAt == nil)
            #expect(controller.livePrompt == nil)
        }
        controller.plannedDurationMinutes = 30
        controller.begin(sessionID: UUID(), title: "Already ended", scheduledEndAt: start.addingTimeInterval(-10))
        sample(controller, at: 599)
        #expect(controller.livePrompt == nil)
        #expect(controller.plannedEndAt == start.addingTimeInterval(-10))
    }

    @Test func breakReminderSharesCooldownAndRepeatsOnlyAfterThirtyMinutes() throws {
        let controller = MeetingAssistantController(rootURL: try temporaryRoot())
        controller.isCoachEnabled = true
        controller.begin(sessionID: UUID(), title: "Long meeting")
        for second in 1_710..<1_755 { sample(controller, at: Double(second), ownMic: true) }
        #expect(controller.livePrompt?.contains("speaking") == true)
        controller.dismissPrompt()
        sample(controller, at: 1_799)
        #expect(controller.livePrompt == nil) // Break is due, but speaking cooldown still applies.
        sample(controller, at: 1_814)
        #expect(controller.livePrompt?.contains("short break") == true)
        controller.dismissPrompt()
        sample(controller, at: 1_874)
        #expect(controller.livePrompt == nil)
        sample(controller, at: 3_614)
        #expect(controller.livePrompt?.contains("short break") == true)
    }

    @Test func pauseHideAndOffClearAnalysisAndSuppressAllReminders() throws {
        let controller = MeetingAssistantController(rootURL: try temporaryRoot())
        controller.isCoachEnabled = true
        let session = UUID()
        controller.begin(sessionID: session, title: "Call")
        for second in 0..<60 { sample(controller, at: Double(second), ownMic: true) }
        #expect(controller.livePrompt != nil)
        #expect(controller.shouldShowHUD)
        controller.isCoachPaused = true
        #expect(controller.activityInputsCount == 0)
        #expect(controller.livePrompt == nil)
        sample(controller, at: 1_799)
        #expect(controller.activityInputsCount == 0)
        #expect(controller.livePrompt == nil)
        controller.isCoachPaused = false
        sample(controller, at: 1_800)
        #expect(controller.livePrompt?.contains("short break") == true)
        controller.isCoachVisible = false
        #expect(!controller.shouldShowHUD)
        #expect(controller.livePrompt == nil)
        #expect(controller.activityInputsCount == 0)
        sample(controller, at: 3_600)
        #expect(controller.livePrompt == nil)
        controller.isCoachVisible = true
        controller.isCoachEnabled = false
        sample(controller, at: 5_400)
        #expect(controller.activityInputsCount == 0)
        #expect(!controller.shouldShowHUD)
        controller.end(sessionID: session)
        #expect(controller.plannedEndAt == nil)
        #expect(!controller.shouldShowHUD)
    }

    @Test func activityRejectsSubsecondDuplicateAndInvalidSamples() throws {
        let controller = MeetingAssistantController(rootURL: try temporaryRoot())
        controller.isCoachEnabled = true
        controller.begin(sessionID: UUID(), title: "Bounded")
        for tick in 0..<10_000 { sample(controller, at: Double(tick) / 10) }
        #expect(controller.activityInputsCount <= 60)
        #expect(controller.activity.windowDurationSeconds <= 60)
        let elapsed = controller.elapsedSeconds
        sample(controller, at: .nan)
        sample(controller, at: .infinity)
        sample(controller, at: -1)
        #expect(controller.elapsedSeconds == elapsed)
        #expect(controller.activityInputsCount <= 60)
    }

    private func sample(_ controller: MeetingAssistantController, at second: TimeInterval, ownMic: Bool = false) {
        controller.recordActivity(.init(elapsedSeconds: second, durationSeconds: 1, ownMicActivity: ownMic, systemActivity: false))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingAssistantTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private enum TestFailure: Error { case offline }
}
