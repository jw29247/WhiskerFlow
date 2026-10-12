import Foundation
import XCTest
@testable import WhiskerFlow
import WhiskerFlowAppSupport
import WhiskerFlowCore

/// Opt-in, local-only: summarises library entries as numbers (turns, speakers
/// by how they were identified, coach figures). Prints no transcript text or names.
/// `WHISKERFLOW_LIBRARY_PROBE=1 swift test --filter MeetingLibrarySummaryProbeTests`
final class MeetingLibrarySummaryProbeTests: XCTestCase {
    func testSummariseLibrary() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WHISKERFLOW_LIBRARY_PROBE"] == "1", "Opt-in library probe")
        let root = StorageLocations.applicationSupportRootOrTemporary().appendingPathComponent("MeetingLibrary")
        let loaded = try EncryptedMeetingLibraryStore(rootURL: root, keyProvider: KeychainMeetingChunkKeyProvider()).loadAll()
        for entry in loaded.entries.sorted(by: { $0.startedAt < $1.startedAt }) {
            let bySpeaker = Dictionary(grouping: entry.turns, by: \.speaker.key)
            let resolutions = Dictionary(grouping: bySpeaker.values.compactMap(\.first), by: { $0.speaker.resolution.rawValue }).mapValues(\.count)
            let turnResolutions = Dictionary(grouping: entry.turns, by: { $0.speaker.resolution.rawValue }).mapValues(\.count)
            let words = entry.turns.reduce(0) { $0 + MeetingSpeakingPace.wordCount($1.text) }
            let own = entry.turns.filter { $0.speaker.resolution == .selfSpeaker }.reduce(0) { $0 + max(0, $1.endMs - $1.startMs) }
            let all = entry.turns.reduce(0) { $0 + max(0, $1.endMs - $1.startMs) }
            let transcriptShare = all > 0 ? String(format: "%.2f", Double(own) / Double(all)) : "-"
            let coach = entry.coachSummary.map { "talk_share=\($0.talkShare.map { String(format: "%.2f", $0) } ?? "-") longest_turn=\(Int($0.longestMonologueSeconds))s monologues=\($0.monologueCount) wpm=\($0.averageWordsPerMinute.map { String(Int($0)) } ?? "-") ai_tips=\($0.aiSuggestionsShown) prompts=\($0.promptsShown)" } ?? "none"
            print("LIBRARY_PROBE: \(entry.sessionID.uuidString.prefix(8)) transcript_you_share=\(transcriptShare) status=\(entry.status.rawValue) duration_s=\((entry.durationMs ?? 0) / 1000) turns=\(entry.turns.count) words=\(words) distinct_speakers=\(bySpeaker.count) speakers_by_kind=\(resolutions) turns_by_kind=\(turnResolutions) untranscribed_windows=\(entry.untranscribedAudibleWindowCount) notes=\(entry.notes.count) bookmarks=\(entry.bookmarks.count) dictations=\(entry.dictations.count) coach: \(coach)")
        }
    }
}
