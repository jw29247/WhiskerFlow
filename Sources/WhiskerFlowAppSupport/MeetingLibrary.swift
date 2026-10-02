import CryptoKit
import Foundation
import WhiskerFlowCore

/// Where a meeting is in its local lifecycle, as shown in the library.
public enum MeetingLibraryStatus: String, Codable, CaseIterable, Sendable {
    case recording
    /// Sending the encrypted recording (or the finished transcript) to Atlas.
    case uploading
    /// Making the transcript on this Mac.
    case transcribing
    /// Saved on this Mac and waiting for Atlas (unpaired, offline or cooling
    /// down between automatic retries).
    case queued
    case delivered
    case failed

    public var displayName: String {
        switch self {
        case .recording: return "Recording"
        case .uploading: return "Uploading"
        case .transcribing: return "Transcribing"
        case .queued: return "Waiting to send"
        case .delivered: return "Delivered"
        case .failed: return "Failed"
        }
    }

    public var isInProgress: Bool {
        switch self {
        case .recording, .uploading, .transcribing, .queued: return true
        case .delivered, .failed: return false
        }
    }
}

/// A typed note taken during a recording, stamped with the elapsed time.
public struct MeetingLibraryNote: Codable, Equatable, Identifiable, Sendable {
    public static let maximumCharacters = 1_000
    /// Atlas stores notes through `notetaker.assistant.addBookmark`, whose
    /// label accepts at most 200 characters.
    public static let atlasLabelCharacters = 200

    public let id: UUID
    public var elapsedMs: Int64
    public var text: String
    public let createdAt: Date
    public var syncState: AssistantSyncState
    public var atlasReference: String?

    public init(
        id: UUID = UUID(), elapsedMs: Int64, text: String, createdAt: Date,
        syncState: AssistantSyncState = .pending, atlasReference: String? = nil
    ) {
        self.id = id
        self.elapsedMs = max(0, elapsedMs)
        self.text = text
        self.createdAt = createdAt
        self.syncState = syncState
        self.atlasReference = atlasReference
    }

    /// Trims and bounds typed text; `nil` when nothing is left to save.
    public static func sanitized(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maximumCharacters))
    }

    /// The labels that carry this note to Atlas, in order. A longer note is
    /// sent as numbered parts ("(1/3) …") at the same moment, so every word
    /// reaches Atlas; the note counts as sent only once each part has.
    /// Lengths are UTF-16 units, as Atlas's JavaScript validation counts them.
    public var atlasLabels: [String] {
        let singleLine = text.replacingOccurrences(of: "\n", with: " ")
        guard singleLine.utf16.count > Self.atlasLabelCharacters else { return [singleLine] }
        // Room for the "(n/m) " prefix, up to 99 parts.
        let budget = Self.atlasLabelCharacters - 10
        var parts: [String] = []
        var current = ""
        for word in singleLine.split(separator: " ") {
            var rest = word
            while !rest.isEmpty {
                let candidate = current.isEmpty ? String(rest) : current + " " + rest
                if candidate.utf16.count <= budget {
                    current = candidate
                    rest = ""
                } else if current.isEmpty {
                    // A word longer than a whole part is cut where the part fills up.
                    let end = Self.prefixEnd(of: rest, utf16Budget: budget)
                    parts.append(String(rest[..<end]))
                    rest = rest[end...]
                } else {
                    parts.append(current)
                    current = ""
                }
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts.enumerated().map { "(\($0.offset + 1)/\(parts.count)) \($0.element)" }
    }

    /// Atlas's idempotency key for each label. The first keeps the note's own
    /// ID; later parts get a stable ID derived from it, so a retry after a
    /// partial send repeats each part under the same key.
    public func atlasRequestID(part: Int) -> UUID {
        guard part > 0 else { return id }
        var bytes = Array(SHA256.hash(data: Data("\(id.uuidString)#\(part)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // version 5: name-based
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        return bytes.withUnsafeBufferPointer { NSUUID(uuidBytes: $0.baseAddress) as UUID }
    }

    /// Where the longest prefix of `text` within `utf16Budget` ends; at least
    /// one character, so splitting always advances.
    private static func prefixEnd(of text: Substring, utf16Budget: Int) -> Substring.Index {
        var used = 0
        var end = text.startIndex
        for index in text.indices {
            used += text[index].utf16.count
            guard used <= utf16Budget || end == text.startIndex else { break }
            end = text.index(after: index)
        }
        return end
    }
}

/// A bookmark copied from the private meeting assistant into the library.
public struct MeetingLibraryBookmark: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var elapsedMs: Int64
    public var label: String?
    public var syncState: AssistantSyncState

    public init(id: UUID, elapsedMs: Int64, label: String?, syncState: AssistantSyncState) {
        self.id = id
        self.elapsedMs = max(0, elapsedMs)
        self.label = label
        self.syncState = syncState
    }
}

/// Time the user spent dictating with push-to-talk during the recording.
public struct MeetingDictationSpan: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var startMs: Int64
    /// `nil` while the key is still held.
    public var endMs: Int64?

    public init(id: UUID = UUID(), startMs: Int64, endMs: Int64? = nil) {
        self.id = id
        self.startMs = max(0, startMs)
        self.endMs = endMs.map { max(self.startMs, $0) }
    }

    public var resolvedEndMs: Int64 { endMs ?? startMs }
}

/// Meeting notes Atlas generated from the delivered transcript. Only what
/// `notetaker.getMeeting` returns is shown; nothing is generated on this Mac.
public struct AtlasMeetingInsights: Codable, Equatable, Sendable {
    public struct Action: Codable, Equatable, Sendable {
        public var text: String
        public var owner: String?
        public var due: String?

        public init(text: String, owner: String? = nil, due: String? = nil) {
            self.text = text
            self.owner = owner
            self.due = due
        }
    }

    /// Atlas note status: `not_started`, `processing`, `suggested` or `failed`.
    public var notesStatus: String
    public var summary: String?
    public var outcomes: [String]
    public var decisions: [String]
    public var nextActions: [Action]
    public var openQuestions: [String]
    public var risks: [String]
    public var fetchedAt: Date

    public init(
        notesStatus: String, summary: String? = nil, outcomes: [String] = [], decisions: [String] = [],
        nextActions: [Action] = [], openQuestions: [String] = [], risks: [String] = [], fetchedAt: Date
    ) {
        self.notesStatus = notesStatus
        self.summary = summary
        self.outcomes = outcomes
        self.decisions = decisions
        self.nextActions = nextActions
        self.openQuestions = openQuestions
        self.risks = risks
        self.fetchedAt = fetchedAt
    }

    public var hasContent: Bool {
        summary != nil || !outcomes.isEmpty || !decisions.isEmpty || !nextActions.isEmpty
            || !openQuestions.isEmpty || !risks.isEmpty
    }

    /// Parses the `value` of a `notetaker.getMeeting` response. The notes and
    /// intelligence fields follow Atlas's `SafeMeetingNotes` and
    /// `SafeMeetingIntelligence` projections.
    public static func parse(getMeetingValue value: Any, fetchedAt: Date) -> AtlasMeetingInsights? {
        guard let row = value as? [String: Any] else { return nil }
        let notes = row["notes"] as? [String: Any] ?? [:]
        let intelligence = row["intelligence"] as? [String: Any] ?? [:]
        let status = notes["status"] as? String ?? "not_started"
        func strings(_ raw: Any?) -> [String] {
            (raw as? [Any] ?? []).compactMap { ($0 as? String)?.trimmedNonEmpty }
        }
        var summary = (notes["summary"] as? String)?.trimmedNonEmpty
        if summary == nil { summary = (intelligence["clientSafeSummary"] as? String)?.trimmedNonEmpty }
        var nextActions: [Action] = (notes["nextActions"] as? [Any] ?? []).compactMap { raw in
            guard let action = raw as? [String: Any], let text = (action["text"] as? String)?.trimmedNonEmpty else {
                return nil
            }
            return Action(
                text: text,
                owner: (action["owner"] as? String)?.trimmedNonEmpty,
                due: (action["due"] as? String)?.trimmedNonEmpty
            )
        }
        if nextActions.isEmpty {
            nextActions = (intelligence["proposedActions"] as? [Any] ?? []).compactMap { raw in
                guard let action = raw as? [String: Any],
                      let title = (action["title"] as? String)?.trimmedNonEmpty else { return nil }
                return Action(text: title)
            }
        }
        let decisions = (intelligence["decisions"] as? [Any] ?? []).compactMap { raw in
            ((raw as? [String: Any])?["text"] as? String)?.trimmedNonEmpty
        }
        var openQuestions = strings(notes["openQuestions"])
        if openQuestions.isEmpty { openQuestions = strings(intelligence["openQuestions"]) }
        var risks = strings(notes["risks"])
        if risks.isEmpty { risks = strings(intelligence["risks"]) }
        return AtlasMeetingInsights(
            notesStatus: status,
            summary: summary,
            outcomes: strings(notes["outcomes"]),
            decisions: decisions,
            nextActions: nextActions,
            openQuestions: openQuestions,
            risks: risks,
            fetchedAt: fetchedAt
        )
    }
}

/// Atlas's opaque, owner-bound meeting reference (`wm1_` plus 43 base64url
/// characters). `notetaker.getMeeting` accepts only this form.
public enum AtlasDeviceMeetingReference {
    public static func isValid(_ value: String?) -> Bool {
        guard let value, value.count == 47, value.hasPrefix("wm1_") else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        return value.dropFirst(4).unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

/// One meeting kept on this Mac: its status, transcript, notes, bookmarks,
/// dictation markers and private coach recap. Stored encrypted.
public struct MeetingLibraryEntry: Codable, Equatable, Identifiable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public let sessionID: UUID
    public var title: String
    public let startedAt: Date
    public var durationMs: Int64?
    public var calendarEventID: String?
    public var status: MeetingLibraryStatus
    public var statusDetail: String?
    /// Automatic delivery stopped; the user must press Retry.
    public var awaitingManualRetry: Bool
    public var atlasMeetingID: String?
    public var atlasMeetingReference: String?
    public var deliveredAt: Date?
    public var turns: [MeetingSpeakerTurn]
    public var untranscribedAudibleWindowCount: Int
    public var notes: [MeetingLibraryNote]
    public var bookmarks: [MeetingLibraryBookmark]
    public var dictations: [MeetingDictationSpan]
    public var coachRecap: String?
    /// Private coaching numbers (talk time, monologues, pace). Never words.
    public var coachSummary: MeetingCoachSummary?
    public var atlasInsights: AtlasMeetingInsights?

    public var id: UUID { sessionID }

    public init(
        sessionID: UUID, title: String, startedAt: Date, calendarEventID: String? = nil,
        status: MeetingLibraryStatus = .recording
    ) {
        self.version = Self.currentVersion
        self.sessionID = sessionID
        self.title = title
        self.startedAt = startedAt
        self.durationMs = nil
        self.calendarEventID = calendarEventID
        self.status = status
        self.statusDetail = nil
        self.awaitingManualRetry = false
        self.atlasMeetingID = nil
        self.atlasMeetingReference = nil
        self.deliveredAt = nil
        self.turns = []
        self.untranscribedAudibleWindowCount = 0
        self.notes = []
        self.bookmarks = []
        self.dictations = []
        self.coachRecap = nil
        self.coachSummary = nil
        self.atlasInsights = nil
    }

    private enum CodingKeys: String, CodingKey {
        case version, sessionID, title, startedAt, durationMs, calendarEventID, status, statusDetail
        case awaitingManualRetry, atlasMeetingID, atlasMeetingReference, deliveredAt, turns
        case untranscribedAudibleWindowCount, notes, bookmarks, dictations, coachRecap, coachSummary, atlasInsights
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        sessionID = try c.decode(UUID.self, forKey: .sessionID)
        title = try c.decode(String.self, forKey: .title)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        durationMs = try c.decodeIfPresent(Int64.self, forKey: .durationMs)
        calendarEventID = try c.decodeIfPresent(String.self, forKey: .calendarEventID)
        // An unknown status from a newer build is shown as failed, never lost.
        status = (try? c.decode(MeetingLibraryStatus.self, forKey: .status)) ?? .failed
        statusDetail = try c.decodeIfPresent(String.self, forKey: .statusDetail)
        awaitingManualRetry = try c.decodeIfPresent(Bool.self, forKey: .awaitingManualRetry) ?? false
        atlasMeetingID = try c.decodeIfPresent(String.self, forKey: .atlasMeetingID)
        atlasMeetingReference = try c.decodeIfPresent(String.self, forKey: .atlasMeetingReference)
        deliveredAt = try c.decodeIfPresent(Date.self, forKey: .deliveredAt)
        turns = try c.decodeIfPresent([MeetingSpeakerTurn].self, forKey: .turns) ?? []
        untranscribedAudibleWindowCount = try c.decodeIfPresent(Int.self, forKey: .untranscribedAudibleWindowCount) ?? 0
        notes = try c.decodeIfPresent([MeetingLibraryNote].self, forKey: .notes) ?? []
        bookmarks = try c.decodeIfPresent([MeetingLibraryBookmark].self, forKey: .bookmarks) ?? []
        dictations = try c.decodeIfPresent([MeetingDictationSpan].self, forKey: .dictations) ?? []
        coachRecap = try c.decodeIfPresent(String.self, forKey: .coachRecap)
        coachSummary = try? c.decodeIfPresent(MeetingCoachSummary.self, forKey: .coachSummary)
        atlasInsights = try c.decodeIfPresent(AtlasMeetingInsights.self, forKey: .atlasInsights)
    }

    /// Notes that exist only on this Mac.
    public var hasUnsyncedNotes: Bool { notes.contains { $0.syncState != .synced } }

    /// Library order: in-progress meetings first, then newest first.
    public static func libraryOrder(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.status.isInProgress != rhs.status.isInProgress { return lhs.status.isInProgress }
        if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
        return lhs.sessionID.uuidString > rhs.sessionID.uuidString
    }
}

public enum MeetingCoachTranscriptPace {
    /// Your average pace from the final transcript: words in your own turns
    /// over their duration. More accurate than the live estimate, because the
    /// meeting model and speaker labels are used.
    public static func wordsPerMinute(_ turns: [MeetingSpeakerTurn]) -> Double? {
        let own = turns.filter { $0.speaker.resolution == .selfSpeaker && $0.endMs > $0.startMs }
        let words = own.reduce(0) { $0 + MeetingSpeakingPace.wordCount($1.text) }
        let seconds = own.reduce(0.0) { $0 + Double($1.endMs - $1.startMs) / 1_000 }
        return MeetingSpeakingPace.rate(words: words, seconds: seconds)
    }

    /// Trends across the library's meetings, newest first.
    public static func trends(_ entries: [MeetingLibraryEntry]) -> MeetingCoachTrends {
        MeetingCoachTrends(entries.sorted { $0.startedAt > $1.startedAt }.compactMap(\.coachSummary))
    }
}

/// How long delivered meeting transcripts stay on this Mac.
public enum MeetingTranscriptRetention: String, CaseIterable, Codable, Identifiable, Sendable {
    case forever
    case oneYear
    case ninetyDays
    case thirtyDays
    case deleteAfterDelivery

    public static let defaultValue: Self = .ninetyDays

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .forever: return "Forever"
        case .oneYear: return "1 year"
        case .ninetyDays: return "90 days"
        case .thirtyDays: return "30 days"
        case .deleteAfterDelivery: return "Delete after delivery"
        }
    }

    /// Age measured from the meeting's start.
    public var maximumAge: TimeInterval? {
        let day: TimeInterval = 24 * 60 * 60
        switch self {
        case .forever: return nil
        case .oneYear: return 365 * day
        case .ninetyDays: return 90 * day
        case .thirtyDays: return 30 * day
        case .deleteAfterDelivery: return 0
        }
    }

    /// Only delivered meetings are ever removed: until then the local copy is
    /// the only one. A note that has not reached Atlas also keeps its meeting,
    /// so retention never silently destroys the user's only copy of it.
    public func shouldRemove(_ entry: MeetingLibraryEntry, now: Date) -> Bool {
        guard entry.status == .delivered, !entry.hasUnsyncedNotes else { return false }
        switch self {
        case .forever: return false
        case .deleteAfterDelivery: return true
        default:
            guard let maximumAge else { return false }
            return now.timeIntervalSince(entry.startedAt) >= maximumAge
        }
    }
}

/// One row of the transcript view, in time order.
public enum MeetingTimelineItem: Equatable, Identifiable, Sendable {
    case turn(index: Int, turn: MeetingSpeakerTurn, dictated: Bool)
    case note(MeetingLibraryNote)
    case bookmark(MeetingLibraryBookmark)
    case dictation(MeetingDictationSpan)

    public var id: String {
        switch self {
        case .turn(let index, _, _): return "turn-\(index)"
        case .note(let note): return "note-\(note.id.uuidString)"
        case .bookmark(let bookmark): return "bookmark-\(bookmark.id.uuidString)"
        case .dictation(let span): return "dictation-\(span.id.uuidString)"
        }
    }

    public var timestampMs: Int64 {
        switch self {
        case .turn(_, let turn, _): return turn.startMs
        case .note(let note): return note.elapsedMs
        case .bookmark(let bookmark): return bookmark.elapsedMs
        case .dictation(let span): return span.startMs
        }
    }

    /// Text the transcript search looks at.
    public var searchableText: String {
        switch self {
        case .turn(_, let turn, _): return "\(turn.speaker.displayName) \(turn.text)"
        case .note(let note): return note.text
        case .bookmark(let bookmark): return bookmark.label ?? "Bookmark"
        case .dictation: return "Dictated"
        }
    }

    fileprivate var sortRank: Int {
        switch self {
        case .dictation: return 0
        case .bookmark: return 1
        case .note: return 2
        case .turn: return 3
        }
    }
}

public enum MeetingTimeline {
    /// Merges turns, notes, bookmarks and dictation markers by time. A marker
    /// at the same millisecond as a turn precedes it.
    public static func build(_ entry: MeetingLibraryEntry) -> [MeetingTimelineItem] {
        var items: [MeetingTimelineItem] = entry.turns.enumerated().map { index, turn in
            .turn(index: index, turn: turn, dictated: isDictated(turn, spans: entry.dictations))
        }
        items += entry.notes.map(MeetingTimelineItem.note)
        items += entry.bookmarks.map(MeetingTimelineItem.bookmark)
        items += entry.dictations.map(MeetingTimelineItem.dictation)
        return items.enumerated().sorted { lhs, rhs in
            if lhs.element.timestampMs != rhs.element.timestampMs {
                return lhs.element.timestampMs < rhs.element.timestampMs
            }
            if lhs.element.sortRank != rhs.element.sortRank { return lhs.element.sortRank < rhs.element.sortRank }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// A turn is marked Dictated when it is the user's own microphone and at
    /// least half of it falls inside push-to-talk time. Remote speakers who
    /// talk over a dictation are never marked.
    public static func isDictated(_ turn: MeetingSpeakerTurn, spans: [MeetingDictationSpan]) -> Bool {
        guard turn.speaker.resolution == .selfSpeaker, !spans.isEmpty else { return false }
        let duration = max(1, turn.endMs - turn.startMs)
        let overlap = spans.reduce(Int64(0)) { total, span in
            total + max(0, min(turn.endMs, span.resolvedEndMs) - max(turn.startMs, span.startMs))
        }
        return overlap * 2 >= duration
    }

    /// The row to scroll to for a moment in the meeting: the first row at or
    /// after it, else the last row.
    public static func anchorID(forMs ms: Int64, in items: [MeetingTimelineItem]) -> String? {
        items.first { $0.timestampMs >= ms }?.id ?? items.last?.id
    }

    /// Row identifiers whose text contains every word of the query, ignoring
    /// case and diacritics.
    public static func matches(_ query: String, in items: [MeetingTimelineItem]) -> [String] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        return items.filter { item in
            let text = item.searchableText
            return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }.map(\.id)
    }

    /// `m:ss`, or `h:mm:ss` from one hour.
    public static func timestamp(_ ms: Int64) -> String {
        let seconds = max(0, Int(ms / 1_000))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%d:%02d", minutes, remainder)
    }
}

public enum MeetingMarkdownExport {
    /// Renders a meeting as Markdown. The private coach recap is left out
    /// unless asked for, because exported notes are usually shared.
    public static func render(
        _ entry: MeetingLibraryEntry,
        atlasURL: URL? = nil,
        includeCoachRecap: Bool = false,
        timeZone: TimeZone = .current,
        locale: Locale = Locale(identifier: "en_GB")
    ) -> String {
        var lines: [String] = ["# \(escapeHeading(entry.title))", ""]
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "d MMMM yyyy, HH:mm"
        var meta = [formatter.string(from: entry.startedAt)]
        if let duration = entry.durationMs, duration > 0 { meta.append(MeetingTimeline.timestamp(duration)) }
        lines.append(meta.joined(separator: " · "))
        if let atlasURL { lines += ["", "[Open in Atlas](\(atlasURL.absoluteString))"] }

        if let insights = entry.atlasInsights, insights.hasContent {
            lines += ["", "## Summary from Atlas"]
            if let summary = insights.summary { lines += ["", summary] }
            section("Decisions", insights.decisions, into: &lines)
            section("Outcomes", insights.outcomes, into: &lines)
            section("Next steps", insights.nextActions.map { action in
                var text = action.text
                if let owner = action.owner { text += " — \(owner)" }
                if let due = action.due { text += " (due \(due))" }
                return text
            }, into: &lines)
            section("Open questions", insights.openQuestions, into: &lines)
            section("Risks", insights.risks, into: &lines)
        }

        if !entry.notes.isEmpty {
            lines += ["", "## Notes", ""]
            lines += entry.notes.sorted { $0.elapsedMs < $1.elapsedMs }.map {
                "- **\(MeetingTimeline.timestamp($0.elapsedMs))** \(oneLine($0.text))"
            }
        }
        if !entry.bookmarks.isEmpty {
            lines += ["", "## Bookmarks", ""]
            lines += entry.bookmarks.sorted { $0.elapsedMs < $1.elapsedMs }.map {
                "- **\(MeetingTimeline.timestamp($0.elapsedMs))** \(oneLine($0.label ?? "Bookmarked moment"))"
            }
        }

        lines += ["", "## Transcript", ""]
        let timeline = MeetingTimeline.build(entry)
        if entry.turns.isEmpty { lines.append("_No transcript on this Mac yet._") }
        for item in timeline {
            switch item {
            case .turn(_, let turn, let dictated):
                let marker = dictated ? " _(Dictated)_" : ""
                lines.append("**[\(MeetingTimeline.timestamp(turn.startMs))] \(turn.speaker.displayName):**\(marker) \(oneLine(turn.text))")
                lines.append("")
            case .note(let note):
                lines.append("> **Note [\(MeetingTimeline.timestamp(note.elapsedMs))]:** \(oneLine(note.text))")
                lines.append("")
            case .bookmark(let bookmark):
                lines.append("> **Bookmark [\(MeetingTimeline.timestamp(bookmark.elapsedMs))]** \(oneLine(bookmark.label ?? ""))".trimmingCharacters(in: .whitespaces))
                lines.append("")
            case .dictation(let span):
                lines.append("_[\(MeetingTimeline.timestamp(span.startMs))–\(MeetingTimeline.timestamp(span.resolvedEndMs))] Dictated with push-to-talk_")
                lines.append("")
            }
        }
        if includeCoachRecap, let recap = entry.coachRecap {
            lines += ["## Private coach recap", "", recap, ""]
        }
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func section(_ title: String, _ items: [String], into lines: inout [String]) {
        guard !items.isEmpty else { return }
        lines += ["", "### \(title)", ""]
        lines += items.map { "- \(oneLine($0))" }
    }

    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    private static func escapeHeading(_ text: String) -> String {
        oneLine(text).trimmingCharacters(in: .whitespaces)
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
