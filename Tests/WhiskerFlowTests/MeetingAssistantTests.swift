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

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingAssistantTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private enum TestFailure: Error { case offline }
}
