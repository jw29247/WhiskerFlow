import CryptoKit
import Foundation
import Observation
import WhiskerFlowAppSupport
import WhiskerFlowCore

enum MeetingLibraryError: LocalizedError, Equatable {
    case notRecording
    case emptyNote
    case noteLimitReached
    /// The meeting's library copy couldn't be written to disk.
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .saveFailed: return "Its copy in the meeting library couldn’t be written."
        case .notRecording, .emptyNote, .noteLimitReached: return nil
        }
    }
}

/// The meeting library on this Mac: status, transcript, notes, bookmarks,
/// dictation markers and the coach recap for past and in-progress meetings.
/// Entries are held in memory for the UI and written, encrypted, on a serial
/// utility queue so disk work never runs on the dictation main actor.
@MainActor
@Observable
final class MeetingLibraryController {
    static let maximumNotesPerMeeting = 500

    private(set) var entries: [MeetingLibraryEntry] = []
    private(set) var isLoaded = false
    private(set) var storageError: String?
    /// Notes reach Atlas through the same transport as bookmarks.
    @ObservationIgnored var noteSync: MeetingBookmarkSync?
    @ObservationIgnored var retention: () -> MeetingTranscriptRetention = { .defaultValue }
    /// A recording ended: its start and length. Counts it for the leaderboard.
    @ObservationIgnored var onRecordingFinished: ((Date, Int64) -> Void)?
    @ObservationIgnored private let store: EncryptedMeetingLibraryStore
    @ObservationIgnored private let persistQueue = DispatchQueue(
        label: "agency.thatworks.WhiskerFlow.meeting-library", qos: .utility
    )
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var syncingNotes: Set<UUID> = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(store: EncryptedMeetingLibraryStore, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    static func production() -> MeetingLibraryController {
        let root = StorageLocations.applicationSupportRootOrTemporary()
            .appendingPathComponent("MeetingLibrary", isDirectory: true)
        return MeetingLibraryController(
            store: EncryptedMeetingLibraryStore(rootURL: root, keyProvider: KeychainMeetingChunkKeyProvider())
        )
    }

    /// An in-memory-only library for tests and the UI preview; it never
    /// touches the user's meetings.
    static func ephemeral() -> MeetingLibraryController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhiskerFlowMeetingLibrary-\(UUID().uuidString)", isDirectory: true)
        return MeetingLibraryController(
            store: EncryptedMeetingLibraryStore(
                rootURL: root, keyProvider: FixedMeetingChunkKeyProvider(key: SymmetricKey(size: .bits256))
            )
        )
    }

    func entry(_ sessionID: UUID) -> MeetingLibraryEntry? {
        entries.first { $0.sessionID == sessionID }
    }

    // MARK: Loading and retention

    func load() {
        guard loadTask == nil else { return }
        let store = store
        loadTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) { () -> Result<EncryptedMeetingLibraryStore.LoadResult, Error> in
                Result { try store.loadAll() }
            }.value
            guard let self else { return }
            switch result {
            case .success(let loaded):
                // Changes made while loading (a recording that just started)
                // are newer than their stored copy.
                let known = Set(entries.map(\.sessionID))
                entries += loaded.entries.filter { !known.contains($0.sessionID) }
                sortEntries()
                if loaded.unreadableCount > 0 {
                    storageError = loaded.unreadableCount == 1
                        ? "One saved meeting couldn’t be read on this Mac. The file was kept."
                        : "\(loaded.unreadableCount) saved meetings couldn’t be read on this Mac. The files were kept."
                }
            case .failure:
                storageError = "Saved meetings couldn’t be opened. Unlock the login keychain and reopen WhiskerFlow."
            }
            isLoaded = true
            applyRetention()
        }
    }

    /// Waits for the initial load (tests and startup ordering).
    func waitUntilLoaded() async {
        load()
        await loadTask?.value
    }

    func applyRetention() {
        let policy = retention()
        let date = now()
        let expired = entries.filter { policy.shouldRemove($0, now: date) }.map(\.sessionID)
        for sessionID in expired { remove(sessionID) }
    }

    /// Removes a delivered meeting's local copy. Undelivered meetings hold the
    /// only transcript, so they cannot be deleted from here.
    @discardableResult
    func deleteDelivered(_ sessionID: UUID) -> Bool {
        guard let entry = entry(sessionID), entry.status == .delivered else { return false }
        remove(sessionID)
        return true
    }

    // MARK: Lifecycle updates from the capture coordinator

    func beginRecording(sessionID: UUID, title: String, startedAt: Date, calendarEventID: String?) {
        if entry(sessionID) != nil {
            update(sessionID) { $0.status = .recording }
            return
        }
        var entry = MeetingLibraryEntry(
            sessionID: sessionID, title: title, startedAt: startedAt,
            calendarEventID: calendarEventID, status: .recording
        )
        entry.statusDetail = nil
        entries.append(entry)
        sortEntries()
        persist(entry)
    }

    func setStatus(_ sessionID: UUID, _ status: MeetingLibraryStatus, detail: String? = nil, awaitingManualRetry: Bool = false) {
        update(sessionID) {
            // A delivered meeting never moves back to an in-progress state.
            guard $0.status != .delivered else { return }
            $0.status = status
            $0.statusDetail = detail
            $0.awaitingManualRetry = awaitingManualRetry
        }
    }

    var coachTrends: MeetingCoachTrends { MeetingCoachTranscriptPace.trends(entries) }

    func finishRecording(
        _ sessionID: UUID, endedAtMs: Int64, coachRecap: String?, bookmarks: [MeetingLibraryBookmark],
        coachSummary: MeetingCoachSummary? = nil
    ) {
        if let entry = entry(sessionID), entry.status == .recording {
            onRecordingFinished?(entry.startedAt, max(entry.durationMs ?? 0, endedAtMs))
        }
        update(sessionID) { entry in
            for index in entry.dictations.indices where entry.dictations[index].endMs == nil {
                entry.dictations[index].endMs = max(entry.dictations[index].startMs, endedAtMs)
            }
            entry.durationMs = max(entry.durationMs ?? 0, endedAtMs)
            entry.coachRecap = coachRecap
            entry.coachSummary = coachSummary
            entry.bookmarks = bookmarks
            if entry.status == .recording {
                entry.status = .uploading
                entry.statusDetail = "Saving the recording on this Mac."
            }
        }
    }

    func setDuration(_ sessionID: UUID, durationMs: Int64) {
        guard durationMs > 0 else { return }
        update(sessionID) { $0.durationMs = durationMs }
    }

    /// Stores the transcript as soon as it exists, before Atlas has it.
    func recordTranscript(_ sessionID: UUID, turns: [MeetingSpeakerTurn], untranscribedAudibleWindowCount: Int) {
        update(sessionID) {
            $0.turns = turns
            $0.untranscribedAudibleWindowCount = untranscribedAudibleWindowCount
            if let transcriptPace = MeetingCoachTranscriptPace.wordsPerMinute(turns) {
                $0.coachSummary?.averageWordsPerMinute = transcriptPace
            }
        }
    }

    func markDelivered(
        _ sessionID: UUID, atlasMeetingID: String?, atlasMeetingReference: String? = nil,
        bookmarks: [MeetingLibraryBookmark]?
    ) {
        update(sessionID) {
            $0.status = .delivered
            $0.statusDetail = nil
            $0.awaitingManualRetry = false
            $0.deliveredAt = now()
            $0.atlasMeetingID = atlasMeetingID ?? $0.atlasMeetingID
            $0.atlasMeetingReference = atlasMeetingReference ?? $0.atlasMeetingReference
            if let bookmarks { $0.bookmarks = bookmarks }
        }
    }

    func updateBookmarks(_ sessionID: UUID, _ bookmarks: [MeetingLibraryBookmark]) {
        guard let entry = entry(sessionID), entry.bookmarks != bookmarks else { return }
        update(sessionID) { $0.bookmarks = bookmarks }
    }

    /// Brings the library in line with the recordings retained on disk after
    /// a relaunch: recordings from before the library existed get an entry,
    /// and entries left mid-flight by a quit show that they wait to be sent.
    func reconcile(retained manifests: [MeetingRecordingSessionManifest], activeSessionID: UUID?, delivering: Set<UUID>) {
        let retained = Dictionary(manifests.map { ($0.sessionID, $0) }, uniquingKeysWith: { first, _ in first })
        for manifest in manifests where entry(manifest.sessionID) == nil && !manifest.chunks.isEmpty {
            let startedAt = manifest.occurredAtMs.map { Date(timeIntervalSince1970: Double($0) / 1_000) } ?? manifest.createdAt
            var entry = MeetingLibraryEntry(
                sessionID: manifest.sessionID, title: manifest.title ?? "Meeting", startedAt: startedAt,
                calendarEventID: manifest.calendarEventID, status: manifest.awaitingManualRetry ? .failed : .queued
            )
            entry.durationMs = manifest.durationMs ?? manifest.chunks.map(\.endMs).max()
            entry.awaitingManualRetry = manifest.awaitingManualRetry
            entry.atlasMeetingID = manifest.atlasMeetingID
            entry.statusDetail = manifest.awaitingManualRetry
                ? "Saved on this Mac but couldn’t be processed. Choose Retry to try again."
                : "Saved on this Mac. It will be sent automatically."
            entries.append(entry)
            persist(entry)
        }
        for entry in entries where entry.status.isInProgress
            && entry.sessionID != activeSessionID && !delivering.contains(entry.sessionID) {
            if let manifest = retained[entry.sessionID] {
                setStatus(
                    entry.sessionID, manifest.awaitingManualRetry ? .failed : .queued,
                    detail: manifest.awaitingManualRetry
                        ? "Saved on this Mac but couldn’t be processed. Choose Retry to try again."
                        : "Saved on this Mac. It will be sent automatically.",
                    awaitingManualRetry: manifest.awaitingManualRetry
                )
            } else {
                setStatus(entry.sessionID, .failed, detail: "The recording is no longer on this Mac, so it can’t be sent.")
            }
        }
        sortEntries()
    }

    // MARK: Notes and dictation

    @discardableResult
    func addNote(sessionID: UUID, text: String, elapsedMs: Int64) throws -> MeetingLibraryNote {
        guard let entry = entry(sessionID), entry.status == .recording else { throw MeetingLibraryError.notRecording }
        guard let text = MeetingLibraryNote.sanitized(text) else { throw MeetingLibraryError.emptyNote }
        guard entry.notes.count < Self.maximumNotesPerMeeting else { throw MeetingLibraryError.noteLimitReached }
        let note = MeetingLibraryNote(elapsedMs: elapsedMs, text: text, createdAt: now())
        update(sessionID) { $0.notes.append(note) }
        return note
    }

    func beginDictation(sessionID: UUID, atMs: Int64) {
        update(sessionID) { entry in
            guard entry.status == .recording, !entry.dictations.contains(where: { $0.endMs == nil }) else { return }
            entry.dictations.append(MeetingDictationSpan(startMs: atMs))
        }
    }

    func endDictation(sessionID: UUID, atMs: Int64) {
        update(sessionID) { entry in
            guard let index = entry.dictations.lastIndex(where: { $0.endMs == nil }) else { return }
            entry.dictations[index].endMs = max(entry.dictations[index].startMs, atMs)
        }
    }

    /// Sends notes that are not yet in Atlas as labelled bookmarks, a long
    /// note as several parts. Atlas rejects offsets past the recording's end,
    /// so a note is clamped to it.
    func syncNotes(sessionID: UUID, meetingReference: String, durationMs: Int64?) async {
        guard let sync = noteSync, !syncingNotes.contains(sessionID),
              let entry = entry(sessionID) else { return }
        syncingNotes.insert(sessionID)
        defer { syncingNotes.remove(sessionID) }
        let limit = durationMs.flatMap { $0 > 0 ? $0 : nil } ?? entry.durationMs ?? .max
        for note in entry.notes where note.syncState != .synced {
            var outcome = AssistantSyncState.synced
            var reference: String?
            // Synced only once every part is in Atlas: until then retention
            // keeps the meeting, which holds the only complete copy.
            for (part, label) in note.atlasLabels.enumerated() {
                let request = MeetingBookmarkSyncRequest(
                    requestID: note.atlasRequestID(part: part), localSessionID: sessionID,
                    meetingReference: meetingReference, elapsedMilliseconds: min(note.elapsedMs, limit), label: label
                )
                do {
                    let received = try await sync(request)
                    if part == 0 { reference = received }
                } catch {
                    outcome = .failed
                    break
                }
            }
            update(sessionID) { entry in
                guard let index = entry.notes.firstIndex(where: { $0.id == note.id }) else { return }
                entry.notes[index].syncState = outcome
                if let reference { entry.notes[index].atlasReference = reference }
            }
        }
    }

    func retryNoteSync(sessionID: UUID) async {
        guard let entry = entry(sessionID), let reference = entry.atlasMeetingID else { return }
        await syncNotes(sessionID: sessionID, meetingReference: reference, durationMs: entry.durationMs)
        applyRetention()
    }

    func setInsights(_ sessionID: UUID, _ insights: AtlasMeetingInsights) {
        update(sessionID) { $0.atlasInsights = insights }
    }

    /// Writes this meeting's current copy after every write queued before it,
    /// and reports whether it reached the disk. Background writes only report
    /// failures through `storageError`; callers that are about to delete the
    /// meeting's only other copy need the answer. No entry means nothing to keep.
    func save(_ sessionID: UUID) async -> Bool {
        guard let entry = entry(sessionID) else { return true }
        let store = store
        let saved = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            persistQueue.async { continuation.resume(returning: (try? store.save(entry)) != nil) }
        }
        if !saved {
            storageError = "A meeting couldn’t be saved on this Mac. Unlock the login keychain and try again."
        }
        return saved
    }

    /// Resolves once every write queued so far has run.
    func flush() async {
        let queue = persistQueue
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
    }

    #if DEBUG
    /// Visual QA only: the UI preview's ephemeral library.
    func insertForPreview(_ previewEntries: [MeetingLibraryEntry]) {
        entries += previewEntries
        sortEntries()
        isLoaded = true
    }
    #endif

    // MARK: Private

    private func update(_ sessionID: UUID, _ mutate: (inout MeetingLibraryEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.sessionID == sessionID }) else { return }
        var entry = entries[index]
        mutate(&entry)
        guard entry != entries[index] else { return }
        entries[index] = entry
        sortEntries()
        persist(entry)
    }

    private func remove(_ sessionID: UUID) {
        entries.removeAll { $0.sessionID == sessionID }
        let store = store
        persistQueue.async { [weak self] in
            do { try store.remove(sessionID: sessionID) } catch {
                Task { @MainActor [weak self] in
                    self?.storageError = "A meeting couldn’t be removed from this Mac. It will be tried again."
                }
            }
        }
    }

    private func persist(_ entry: MeetingLibraryEntry) {
        let store = store
        persistQueue.async { [weak self] in
            do { try store.save(entry) } catch {
                Task { @MainActor [weak self] in
                    self?.storageError = "A meeting couldn’t be saved on this Mac. Unlock the login keychain and try again."
                }
            }
        }
    }

    private func sortEntries() {
        entries.sort(by: MeetingLibraryEntry.libraryOrder)
    }
}
