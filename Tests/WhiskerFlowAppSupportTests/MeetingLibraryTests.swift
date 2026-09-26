import CryptoKit
import XCTest
import WhiskerFlowAppSupport
import WhiskerFlowCore

final class MeetingLibraryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func entry(status: MeetingLibraryStatus = .delivered) -> MeetingLibraryEntry {
        var entry = MeetingLibraryEntry(sessionID: UUID(), title: "Weekly sync", startedAt: start, status: status)
        entry.durationMs = 125_000
        entry.turns = [
            MeetingSpeakerTurn(startMs: 0, endMs: 4_000, text: "Morning everyone.", speaker: .microphone),
            MeetingSpeakerTurn(startMs: 4_000, endMs: 9_000, text: "Let's look at the café launch.",
                               speaker: .diarized(key: "s1", index: 1)),
            MeetingSpeakerTurn(startMs: 40_000, endMs: 46_000, text: "Remind me to send the deck.", speaker: .microphone),
            MeetingSpeakerTurn(startMs: 41_000, endMs: 44_000, text: "Sure.", speaker: .diarized(key: "s1", index: 1)),
        ]
        entry.notes = [MeetingLibraryNote(elapsedMs: 5_000, text: "Launch date\nstill open", createdAt: start)]
        entry.bookmarks = [MeetingLibraryBookmark(id: UUID(), elapsedMs: 40_000, label: "Deck", syncState: .synced)]
        entry.dictations = [MeetingDictationSpan(startMs: 39_500, endMs: 45_000)]
        return entry
    }

    // MARK: Retention

    func testRetentionDefaultsToNinetyDaysAndMeasuresFromMeetingStart() {
        XCTAssertEqual(MeetingTranscriptRetention.defaultValue, .ninetyDays)
        var delivered = entry()
        delivered.notes[0].syncState = .synced
        let day: TimeInterval = 86_400
        XCTAssertFalse(MeetingTranscriptRetention.ninetyDays.shouldRemove(delivered, now: start.addingTimeInterval(89 * day)))
        XCTAssertTrue(MeetingTranscriptRetention.ninetyDays.shouldRemove(delivered, now: start.addingTimeInterval(90 * day)))
        XCTAssertTrue(MeetingTranscriptRetention.thirtyDays.shouldRemove(delivered, now: start.addingTimeInterval(31 * day)))
        XCTAssertFalse(MeetingTranscriptRetention.oneYear.shouldRemove(delivered, now: start.addingTimeInterval(364 * day)))
        XCTAssertFalse(MeetingTranscriptRetention.forever.shouldRemove(delivered, now: start.addingTimeInterval(9_999 * day)))
        XCTAssertTrue(MeetingTranscriptRetention.deleteAfterDelivery.shouldRemove(delivered, now: start))
    }

    func testRetentionNeverRemovesUndeliveredMeetingsOrUnsyncedNotes() {
        let old = start.addingTimeInterval(1_000 * 86_400)
        for status in MeetingLibraryStatus.allCases where status != .delivered {
            XCTAssertFalse(MeetingTranscriptRetention.deleteAfterDelivery.shouldRemove(entry(status: status), now: old), "\(status)")
        }
        var withNote = entry()
        withNote.notes[0].syncState = .failed
        XCTAssertFalse(MeetingTranscriptRetention.deleteAfterDelivery.shouldRemove(withNote, now: old))
        withNote.notes[0].syncState = .synced
        XCTAssertTrue(MeetingTranscriptRetention.deleteAfterDelivery.shouldRemove(withNote, now: old))
    }

    // MARK: Timeline

    func testTimelineInterleavesNotesBookmarksAndDictationByTime() {
        let items = MeetingTimeline.build(entry())
        XCTAssertEqual(items.map(\.timestampMs), [0, 4_000, 5_000, 39_500, 40_000, 40_000, 41_000])
        guard case .bookmark = items[4], case .turn(let index, _, _) = items[5] else {
            return XCTFail("A marker at the same moment precedes the turn")
        }
        XCTAssertEqual(index, 2)
    }

    func testOnlyOwnMicrophoneTurnsInsideDictationAreMarkedDictated() {
        let items = MeetingTimeline.build(entry())
        let dictated = items.compactMap { item -> (String, Bool)? in
            guard case .turn(_, let turn, let flag) = item else { return nil }
            return (turn.text, flag)
        }
        XCTAssertEqual(dictated.map(\.1), [false, false, true, false], "Remote speech during a dictation is not the user's dictation")
        let edge = MeetingSpeakerTurn(startMs: 44_000, endMs: 60_000, text: "Later", speaker: .microphone)
        XCTAssertFalse(MeetingTimeline.isDictated(edge, spans: [MeetingDictationSpan(startMs: 39_500, endMs: 45_000)]))
    }

    func testAnchorJumpsToFirstRowAtOrAfterMoment() {
        let items = MeetingTimeline.build(entry())
        XCTAssertEqual(MeetingTimeline.anchorID(forMs: 4_500, in: items), items[2].id)
        XCTAssertEqual(MeetingTimeline.anchorID(forMs: 999_000, in: items), items.last?.id)
        XCTAssertNil(MeetingTimeline.anchorID(forMs: 0, in: []))
    }

    func testSearchMatchesEveryWordIgnoringCaseAndDiacritics() {
        let items = MeetingTimeline.build(entry())
        XCTAssertEqual(MeetingTimeline.matches("CAFE launch", in: items), ["turn-1"])
        XCTAssertEqual(MeetingTimeline.matches("speaker 1", in: items), ["turn-1", "turn-3"])
        XCTAssertEqual(MeetingTimeline.matches("launch", in: items).count, 2, "Notes are searchable too")
        XCTAssertTrue(MeetingTimeline.matches("   ", in: items).isEmpty)
    }

    func testTimestampFormatting() {
        XCTAssertEqual(MeetingTimeline.timestamp(0), "0:00")
        XCTAssertEqual(MeetingTimeline.timestamp(65_999), "1:05")
        XCTAssertEqual(MeetingTimeline.timestamp(3_723_000), "1:02:03")
    }

    // MARK: Markdown

    func testMarkdownIncludesTranscriptNotesAndDictatedMarkerButNotCoachRecap() {
        var meeting = entry()
        meeting.coachRecap = "You spoke for 70% of the call."
        let markdown = MeetingMarkdownExport.render(
            meeting, atlasURL: URL(string: "https://atlas.example/meetings/abc"),
            timeZone: TimeZone(identifier: "Europe/London")!
        )
        XCTAssertTrue(markdown.hasPrefix("# Weekly sync\n\n"))
        XCTAssertTrue(markdown.contains("· 2:05"))
        XCTAssertTrue(markdown.contains("[Open in Atlas](https://atlas.example/meetings/abc)"))
        XCTAssertTrue(markdown.contains("**[0:04] Speaker 1:** Let's look at the café launch."))
        XCTAssertTrue(markdown.contains("**[0:40] You:** _(Dictated)_ Remind me to send the deck."))
        XCTAssertTrue(markdown.contains("> **Note [0:05]:** Launch date still open"))
        XCTAssertTrue(markdown.contains("_[0:39–0:45] Dictated with push-to-talk_"))
        XCTAssertFalse(markdown.contains("70%"), "The private coach recap is not exported by default")
        XCTAssertTrue(MeetingMarkdownExport.render(meeting, includeCoachRecap: true).contains("70%"))
    }

    func testMarkdownShowsAtlasSummaryOnlyWhenAtlasProvidedOne() {
        var meeting = entry()
        XCTAssertFalse(MeetingMarkdownExport.render(meeting).contains("Summary from Atlas"))
        meeting.atlasInsights = AtlasMeetingInsights(
            notesStatus: "suggested", summary: "Agreed the launch plan.", decisions: ["Launch in May"],
            nextActions: [.init(text: "Send the deck", owner: "Jacob", due: "Friday")], fetchedAt: start
        )
        let markdown = MeetingMarkdownExport.render(meeting)
        XCTAssertTrue(markdown.contains("## Summary from Atlas\n\nAgreed the launch plan."))
        XCTAssertTrue(markdown.contains("- Launch in May"))
        XCTAssertTrue(markdown.contains("- Send the deck — Jacob (due Friday)"))
    }

    // MARK: Notes

    func testNoteSanitizingAndAtlasLabelBound() {
        XCTAssertNil(MeetingLibraryNote.sanitized("  \n "))
        XCTAssertEqual(MeetingLibraryNote.sanitized(" hi ")!, "hi")
        XCTAssertEqual(MeetingLibraryNote.sanitized(String(repeating: "a", count: 5_000))!.count, 1_000)
        let long = MeetingLibraryNote(elapsedMs: 0, text: String(repeating: "b", count: 500), createdAt: start)
        XCTAssertEqual(long.atlasLabel.count, 200)
        XCTAssertTrue(long.atlasLabel.hasSuffix("…"))
        XCTAssertEqual(MeetingLibraryNote(elapsedMs: -5, text: "a\nb", createdAt: start).atlasLabel, "a b")
    }

    // MARK: Atlas insights

    func testParsesAtlasGetMeetingProjection() throws {
        let json = """
        {"contractVersion":1,"meeting":{"meetingId":"wm1_x","title":"T","occurredAtMs":1,"processingState":"processed"},
         "transcript":{"segments":[]},
         "notes":{"status":"suggested","summary":" Agreed scope. ","outcomes":["Scope fixed"],
                  "nextActions":[{"text":"Draft SOW","owner":"Sam","evidenceSegmentIndexes":[1]},{"text":"  "}],
                  "openQuestions":["Budget?"],"risks":[]},
         "intelligence":{"decisions":[{"text":"Go with option B","evidenceSegmentIndexes":[]}],"risks":["Timeline"],
                         "openQuestions":[],"proposedActions":[{"title":"Ignored because notes have actions"}]}}
        """
        let value = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let insights = try XCTUnwrap(AtlasMeetingInsights.parse(getMeetingValue: value, fetchedAt: start))
        XCTAssertEqual(insights.notesStatus, "suggested")
        XCTAssertEqual(insights.summary, "Agreed scope.")
        XCTAssertEqual(insights.outcomes, ["Scope fixed"])
        XCTAssertEqual(insights.nextActions, [.init(text: "Draft SOW", owner: "Sam")])
        XCTAssertEqual(insights.decisions, ["Go with option B"])
        XCTAssertEqual(insights.openQuestions, ["Budget?"])
        XCTAssertEqual(insights.risks, ["Timeline"], "Intelligence risks fill in when notes have none")
        XCTAssertTrue(insights.hasContent)
    }

    func testNotStartedAtlasNotesHaveNoContent() throws {
        let insights = try XCTUnwrap(AtlasMeetingInsights.parse(getMeetingValue: ["notes": ["status": "not_started"]], fetchedAt: start))
        XCTAssertFalse(insights.hasContent)
        XCTAssertNil(AtlasMeetingInsights.parse(getMeetingValue: "nope", fetchedAt: start))
    }

    func testDeviceMeetingReferenceFormat() {
        XCTAssertTrue(AtlasDeviceMeetingReference.isValid("wm1_" + String(repeating: "A", count: 42) + "-"))
        XCTAssertFalse(AtlasDeviceMeetingReference.isValid("wm1_" + String(repeating: "A", count: 42)))
        XCTAssertFalse(AtlasDeviceMeetingReference.isValid("jd7abc123"), "Raw Convex meeting IDs are not device references")
        XCTAssertFalse(AtlasDeviceMeetingReference.isValid("wm1_" + String(repeating: "=", count: 43)))
        XCTAssertFalse(AtlasDeviceMeetingReference.isValid(nil))
    }

    // MARK: Ordering and decoding

    func testLibraryOrderPutsInProgressFirstThenNewest() {
        var older = entry(); older.title = "older"
        var newer = MeetingLibraryEntry(sessionID: UUID(), title: "newer", startedAt: start.addingTimeInterval(60), status: .delivered)
        var live = MeetingLibraryEntry(sessionID: UUID(), title: "live", startedAt: start.addingTimeInterval(-600), status: .recording)
        newer.durationMs = 1; live.durationMs = 1; older.durationMs = 1
        XCTAssertEqual([older, newer, live].sorted(by: MeetingLibraryEntry.libraryOrder).map(\.title), ["live", "newer", "older"])
    }

    func testEntryDecodesMissingFieldsAndUnknownStatus() throws {
        let id = UUID()
        let json = #"{"sessionID":"\#(id.uuidString)","title":"Old","startedAt":0,"status":"archivedInFuture"}"#
        let decoded = try JSONDecoder().decode(MeetingLibraryEntry.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.sessionID, id)
        XCTAssertEqual(decoded.status, .failed)
        XCTAssertTrue(decoded.turns.isEmpty && decoded.notes.isEmpty && decoded.dictations.isEmpty)
    }

    // MARK: Encrypted store

    func testStoreRoundTripsEncryptedAndBindsFileToSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("library-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        let store = EncryptedMeetingLibraryStore(rootURL: root, keyProvider: FixedMeetingChunkKeyProvider(key: key))
        let first = entry()
        let second = entry()
        try store.save(first)
        try store.save(second)

        let bytes = try Data(contentsOf: store.fileURL(first.sessionID))
        XCTAssertNil(bytes.range(of: Data("Morning everyone".utf8)), "Transcript text must not be stored in plaintext")
        XCTAssertNil(bytes.range(of: Data("Launch date".utf8)), "Notes must not be stored in plaintext")
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL(first.sessionID).path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let loaded = try store.loadAll()
        XCTAssertEqual(Set(loaded.entries.map(\.sessionID)), [first.sessionID, second.sessionID])
        XCTAssertEqual(loaded.entries.first { $0.sessionID == first.sessionID }, first)

        // A file renamed onto another session fails authentication.
        try FileManager.default.removeItem(at: store.fileURL(second.sessionID))
        try FileManager.default.copyItem(at: store.fileURL(first.sessionID), to: store.fileURL(second.sessionID))
        let swapped = try store.loadAll()
        XCTAssertEqual(swapped.entries.map(\.sessionID), [first.sessionID])
        XCTAssertEqual(swapped.unreadableCount, 1)

        let otherKey = EncryptedMeetingLibraryStore(rootURL: root, keyProvider: FixedMeetingChunkKeyProvider(key: SymmetricKey(size: .bits256)))
        XCTAssertEqual(try otherKey.loadAll().entries.count, 0)

        try store.remove(sessionID: first.sessionID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(first.sessionID).path))
    }
}
