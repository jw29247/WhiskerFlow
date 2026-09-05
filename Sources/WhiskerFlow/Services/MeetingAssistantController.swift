import Foundation
import Observation
import WhiskerFlowAppSupport
import WhiskerFlowCore

struct MeetingBookmarkSyncRequest: Codable, Equatable, Sendable {
    let requestID: UUID
    let localSessionID: UUID
    let meetingReference: String
    let elapsedMilliseconds: Int64
    let label: String?
}

typealias MeetingBookmarkSync = @MainActor (MeetingBookmarkSyncRequest) async throws -> String

enum MeetingAssistantError: Error, Equatable {
    case noActiveMeeting
    case bookmarkLimitReached
    case invalidBookmarkTimestamp
    case corruptStore
    case storageUnavailable
}

struct LocalMeetingBookmark: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let sessionID: UUID
    var elapsedMilliseconds: Int64
    var label: String?
    let createdAt: Date
    var updatedAt: Date
    var syncState: AssistantSyncState
    var atlasReference: String?
}

@MainActor
@Observable
final class MeetingAssistantController {
    private struct SessionRecord: Codable, Equatable {
        let id: UUID
        var title: String
        let startedAt: Date
        var durationMilliseconds: Int64?
        var meetingReference: String?
        var localSummary: String?
    }

    private struct Storage: Codable {
        var sessions: [SessionRecord] = []
        var bookmarks: [LocalMeetingBookmark] = []
    }

    static let maximumBookmarksPerSession = 200
    static let maximumStoredBookmarks = 2_000
    static let maximumStoredSessions = 100
    private static let maximumLabelCharacters = 120
    private let rootURL: URL
    private let storageURL: URL
    private let now: () -> Date
    private var storage: Storage
    private var activeSessionID: UUID?
    private var activeStartedAt: Date?
    private var activityInputs: [MeetingActivityInput] = []
    private var lastPromptElapsedSeconds: TimeInterval?
    private var plannedEndElapsedSeconds: TimeInterval?
    private var didPromptWrap = false
    private var lastBreakElapsedSeconds: TimeInterval = 0
    private var lastActivityElapsedSeconds: TimeInterval?
    private var syncingSessions: Set<UUID> = []
    private var storageFailure: MeetingAssistantError?

    private(set) var isActive = false
    var isCoachEnabled = false { didSet { clearSuppressedCoaching() } }
    var isCoachPaused = false { didSet { clearSuppressedCoaching() } }
    var isCoachVisible = true { didSet { clearSuppressedCoaching() } }
    /// An ad hoc wrap reminder is only enabled by an explicit duration selection.
    var plannedDurationMinutes: Int?
    private(set) var plannedEndAt: Date?
    var goal = ""
    var agenda = ""
    var bookmarkSync: MeetingBookmarkSync?
    private(set) var activeTitle: String?
    private(set) var elapsedSeconds: TimeInterval = 0
    private(set) var activity = MeetingCoachMetrics.accumulate(inputs: [])
    private(set) var livePrompt: String?
    private(set) var latestFinalizedMeetingReference: String?
    private(set) var storageError: String?

    var shouldShowHUD: Bool { isActive && isCoachEnabled && isCoachVisible }

    var bookmarks: [LocalMeetingBookmark] { storage.bookmarks }
    var activityInputsCount: Int { activityInputs.count }
    var localReview: String? { storage.sessions.reversed().compactMap(\.localSummary).first }

    init(rootURL: URL? = nil, now: @escaping () -> Date = Date.init) {
        let root = rootURL ?? StorageLocations.applicationSupportRootOrTemporary()
            .appendingPathComponent("MeetingAssistant", isDirectory: true)
        let storageURL = root.appendingPathComponent("private-meeting-assistant.json")
        self.rootURL = root
        self.storageURL = storageURL
        self.now = now
        let loaded = Self.load(from: storageURL)
        self.storage = loaded.storage
        self.storageError = loaded.error
        self.storageFailure = loaded.error == nil ? nil : .corruptStore
        self.latestFinalizedMeetingReference = Self.latestReference(in: loaded.storage.sessions)
        Self.secureDirectory(root)
    }

    func begin(sessionID: UUID, title: String, scheduledEndAt: Date? = nil) {
        let startedAt = now()
        activeSessionID = sessionID
        activeStartedAt = startedAt
        activeTitle = title
        isActive = true
        elapsedSeconds = 0
        isCoachPaused = false
        isCoachVisible = true
        let explicitDuration = plannedDurationMinutes.flatMap { $0 > 0 && $0 <= 480 ? TimeInterval($0 * 60) : nil }
        plannedEndAt = scheduledEndAt ?? explicitDuration.map { startedAt.addingTimeInterval($0) }
        plannedEndElapsedSeconds = plannedEndAt.map { $0.timeIntervalSince(startedAt) }
        didPromptWrap = false
        lastBreakElapsedSeconds = 0
        lastActivityElapsedSeconds = nil
        activityInputs.removeAll(keepingCapacity: true)
        activity = MeetingCoachMetrics.accumulate(inputs: [])
        livePrompt = nil
        lastPromptElapsedSeconds = nil
        if let index = storage.sessions.firstIndex(where: { $0.id == sessionID }) {
            storage.sessions[index].title = title
        } else {
            pruneStoredHistory(keepingAtMost: Self.maximumStoredSessions - 1)
            guard storage.sessions.count < Self.maximumStoredSessions else {
                storageError = "Private meeting storage is full because unsynced bookmarks must be preserved."
                storageFailure = .storageUnavailable
                return
            }
            storage.sessions.append(.init(id: sessionID, title: title, startedAt: startedAt))
        }
        persistOrRecordError()
    }

    @discardableResult
    func addBookmark(label: String?) throws -> LocalMeetingBookmark {
        guard let sessionID = activeSessionID, let startedAt = activeStartedAt else {
            throw MeetingAssistantError.noActiveMeeting
        }
        if let storageFailure { throw storageFailure }
        guard storage.bookmarks.lazy.filter({ $0.sessionID == sessionID }).count < Self.maximumBookmarksPerSession else {
            throw MeetingAssistantError.bookmarkLimitReached
        }
        guard storage.bookmarks.count < Self.maximumStoredBookmarks else { throw MeetingAssistantError.bookmarkLimitReached }
        let timestamp = max(0, now().timeIntervalSince(startedAt))
        let cleanedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let boundedLabel = cleanedLabel.map { String($0.prefix(Self.maximumLabelCharacters)) }
        let bookmark = LocalMeetingBookmark(
            id: UUID(), sessionID: sessionID,
            elapsedMilliseconds: Int64((timestamp * 1_000).rounded()),
            label: boundedLabel?.isEmpty == true ? nil : boundedLabel,
            createdAt: now(), updatedAt: now(), syncState: .pending, atlasReference: nil
        )
        storage.bookmarks.append(bookmark)
        do {
            try persist()
        } catch {
            storage.bookmarks.removeAll { $0.id == bookmark.id }
            storageError = "Private meeting bookmarks could not be saved on this Mac."
            storageFailure = .storageUnavailable
            throw MeetingAssistantError.storageUnavailable
        }
        return bookmark
    }

    func recordActivity(_ input: MeetingActivityInput) {
        guard isActive, input.elapsedSeconds.isFinite, input.elapsedSeconds >= 0,
              input.durationSeconds.isFinite, input.durationSeconds > 0 else { return }
        // Capture supplies one-second windows. Ignore repeated or faster samples.
        if let lastActivityElapsedSeconds, input.elapsedSeconds - lastActivityElapsedSeconds < 1 { return }
        lastActivityElapsedSeconds = input.elapsedSeconds
        elapsedSeconds = max(elapsedSeconds, input.elapsedSeconds + max(0, input.durationSeconds))
        guard isCoachEnabled, !isCoachPaused, isCoachVisible else { return }
        activityInputs.append(input)
        let cutoff = max(0, elapsedSeconds - MeetingCoachMetrics.windowSeconds)
        activityInputs.removeAll { $0.elapsedSeconds + $0.durationSeconds <= cutoff }
        if activityInputs.count > 60 { activityInputs.removeFirst(activityInputs.count - 60) }
        activity = MeetingCoachMetrics.accumulate(inputs: activityInputs)
        updatePrompt()
    }

    func dismissPrompt() { livePrompt = nil }

    func end(sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        if let index = storage.sessions.firstIndex(where: { $0.id == sessionID }) {
            let duration = max(0, now().timeIntervalSince(storage.sessions[index].startedAt))
            let minutes = Int(duration) / 60
            let seconds = Int(duration) % 60
            let detail = activity.windowDurationSeconds > 0
                ? "Microphone activity was estimated at \(Int(activity.ownMicActiveSeconds)) seconds in the final \(Int(activity.windowDurationSeconds)) seconds observed. This is an audio estimate, not a speaker assessment."
                : "No live activity estimate was retained; coaching was off, paused, or unavailable."
            storage.sessions[index].localSummary = "Recording lasted \(minutes)m \(seconds)s. \(detail) Review the transcript to assess decisions and next steps."
            persistOrRecordError()
        }
        activeSessionID = nil
        activeStartedAt = nil
        activeTitle = nil
        plannedEndAt = nil
        plannedEndElapsedSeconds = nil
        isActive = false
        activityInputs.removeAll(keepingCapacity: false)
        activity = MeetingCoachMetrics.accumulate(inputs: [])
        livePrompt = nil
        lastPromptElapsedSeconds = nil
    }

    func finalize(sessionID: UUID, meetingReference: String, durationMilliseconds: Int64, sync: MeetingBookmarkSync? = nil) async {
        guard durationMilliseconds >= 0,
              let index = storage.sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let previousSession = storage.sessions[index]
        let previousLatestReference = latestFinalizedMeetingReference
        storage.sessions[index].meetingReference = meetingReference
        storage.sessions[index].durationMilliseconds = durationMilliseconds
        latestFinalizedMeetingReference = Self.latestReference(in: storage.sessions)
        do { try persist() } catch {
            storage.sessions[index] = previousSession
            latestFinalizedMeetingReference = previousLatestReference
            if storageFailure == nil {
                storageError = "Private meeting state could not be saved on this Mac."
                storageFailure = .storageUnavailable
            }
            return
        }
        guard let sync = sync ?? bookmarkSync else { return }
        await syncPending(sessionID: sessionID, meetingReference: meetingReference, durationMilliseconds: durationMilliseconds, sync: sync)
    }

    func retryPendingBookmarks(sessionID: UUID, sync: MeetingBookmarkSync) async {
        guard let session = storage.sessions.first(where: { $0.id == sessionID }),
              let meetingReference = session.meetingReference,
              let duration = session.durationMilliseconds else { return }
        await syncPending(sessionID: sessionID, meetingReference: meetingReference, durationMilliseconds: duration, sync: sync)
    }

    func retryPendingBookmarks(sessionID: UUID) async {
        guard let bookmarkSync else { return }
        await retryPendingBookmarks(sessionID: sessionID, sync: bookmarkSync)
    }

    private func syncPending(sessionID: UUID, meetingReference: String, durationMilliseconds: Int64, sync: MeetingBookmarkSync) async {
        guard !syncingSessions.contains(sessionID) else { return }
        syncingSessions.insert(sessionID)
        defer { syncingSessions.remove(sessionID) }
        let ids = storage.bookmarks.filter { $0.sessionID == sessionID && $0.syncState != .synced }.map(\.id)
        for id in ids {
            guard let index = storage.bookmarks.firstIndex(where: { $0.id == id }) else { continue }
            let bookmark = storage.bookmarks[index]
            guard bookmark.elapsedMilliseconds >= 0, bookmark.elapsedMilliseconds <= durationMilliseconds else {
                storage.bookmarks[index].syncState = .failed
                storage.bookmarks[index].updatedAt = now()
                persistBookmarkChange(id: id, previous: bookmark)
                continue
            }
            let request = MeetingBookmarkSyncRequest(requestID: bookmark.id, localSessionID: sessionID, meetingReference: meetingReference, elapsedMilliseconds: bookmark.elapsedMilliseconds, label: bookmark.label)
            do {
                let reference = try await sync(request)
                guard let refreshed = storage.bookmarks.firstIndex(where: { $0.id == id }) else { continue }
                storage.bookmarks[refreshed].syncState = .synced
                storage.bookmarks[refreshed].atlasReference = reference
                storage.bookmarks[refreshed].updatedAt = now()
            } catch {
                guard let refreshed = storage.bookmarks.firstIndex(where: { $0.id == id }) else { continue }
                storage.bookmarks[refreshed].syncState = .failed
                storage.bookmarks[refreshed].updatedAt = now()
            }
            persistBookmarkChange(id: id, previous: bookmark)
        }
    }

    private static func latestReference(in sessions: [SessionRecord]) -> String? {
        // Stable array order breaks equal-start-time ties, including after a restart.
        sessions.enumerated().filter { $0.element.meetingReference != nil }.max {
            if $0.element.startedAt == $1.element.startedAt { return $0.offset < $1.offset }
            return $0.element.startedAt < $1.element.startedAt
        }?.element.meetingReference
    }

    private func clearSuppressedCoaching() {
        guard !isCoachEnabled || isCoachPaused || !isCoachVisible else { return }
        activityInputs.removeAll(keepingCapacity: false)
        activity = MeetingCoachMetrics.accumulate(inputs: [])
        livePrompt = nil
    }

    private func updatePrompt() {
        guard MeetingCoachMetrics.canPrompt(elapsedSeconds: elapsedSeconds, lastPromptElapsedSeconds: lastPromptElapsedSeconds) else { return }
        if !didPromptWrap, let end = plannedEndElapsedSeconds, end > 0,
           elapsedSeconds >= max(0, end - 300) {
            let timing = elapsedSeconds >= end ? "The planned end has passed." : "The planned end is approaching."
            livePrompt = "\(timing) Check your objective, decisions and next steps."
            didPromptWrap = true
        } else if elapsedSeconds - lastBreakElapsedSeconds >= 1_800 {
            livePrompt = "You’ve been in this meeting for a while. Consider a short break when there’s a suitable pause."
            lastBreakElapsedSeconds = elapsedSeconds
        } else if activity.windowDurationSeconds >= 30, activity.ownMicActiveSeconds >= 45 {
            let uncertainty = activity.certainty == .reliable ? "" : " Audio overlap or a missing track makes this estimate uncertain."
            livePrompt = "You’ve been speaking for much of the last minute. A pause may make room for the next turn.\(uncertainty)"
        } else {
            return
        }
        lastPromptElapsedSeconds = elapsedSeconds
    }

    private func persist() throws {
        if let storageFailure { throw storageFailure }
        Self.secureDirectory(rootURL)
        let data = try JSONEncoder().encode(storage)
        try data.write(to: storageURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
    }

    private func persistOrRecordError() {
        do {
            try persist()
        } catch {
            if storageFailure == nil {
                storageError = "Private meeting state could not be saved on this Mac."
                storageFailure = .storageUnavailable
            }
        }
    }

    private func persistBookmarkChange(id: UUID, previous: LocalMeetingBookmark) {
        do {
            try persist()
        } catch {
            if let index = storage.bookmarks.firstIndex(where: { $0.id == id }) {
                storage.bookmarks[index] = previous
            }
            if storageFailure == nil {
                storageError = "Private meeting state could not be saved on this Mac."
                storageFailure = .storageUnavailable
            }
        }
    }

    private func pruneStoredHistory(keepingAtMost maximum: Int) {
        guard storage.sessions.count > maximum else { return }
        let protected = Set(storage.bookmarks.filter { $0.syncState != .synced }.map(\.sessionID))
        while storage.sessions.count > maximum,
              let index = storage.sessions.firstIndex(where: { !protected.contains($0.id) }) {
            let removed = storage.sessions.remove(at: index)
            storage.bookmarks.removeAll { $0.sessionID == removed.id && $0.syncState == .synced }
        }
    }

    private static func load(from url: URL) -> (storage: Storage, error: String?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (Storage(), nil) }
        do {
            let data = try Data(contentsOf: url)
            return (try JSONDecoder().decode(Storage.self, from: data), nil)
        } catch {
            return (Storage(), "Private meeting state is unreadable. The original file was preserved.")
        }
    }

    private static func secureDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
