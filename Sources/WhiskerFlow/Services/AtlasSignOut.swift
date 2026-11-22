import Foundation

/// What signing out of Atlas says and when it has to wait.
///
/// An Atlas device token identifies one connection, not a person, so after a
/// sign-out the app cannot tell whether the next sign-in is the same person.
/// Anything still waiting to reach Atlas therefore has to get there before
/// sign-out, or stay on this Mac for good.
enum AtlasSignOut {
    /// Why sign-out has to wait, or nil when it can go ahead. A recording, or
    /// one waiting to be sent, could otherwise only reach the next account.
    static func blocker(recording: Bool, unsentRecordings: Int) -> String? {
        if recording {
            return "A meeting is being recorded. Stop the recording and let it reach Atlas before you sign out."
        }
        guard unsentRecordings > 0 else { return nil }
        let count = unsentRecordings == 1 ? "1 meeting recording hasn’t" : "\(unsentRecordings) meeting recordings haven’t"
        return "\(count) reached Atlas yet. Signing out now would stop \(unsentRecordings == 1 ? "it" : "them") from ever being sent to this account. Wait until Meetings shows \(unsentRecordings == 1 ? "it" : "them") as delivered, or choose Retry there, then sign out."
    }

    /// The confirmation: what goes, what stays, and what happens to notes and
    /// bookmarks that haven't reached Atlas.
    static func confirmation(unsyncedMeetingItems: Int) -> String {
        var text = "Removed from this Mac: the Atlas connection, the team glossary, your meeting schedule, the leaderboard, meeting summaries from Atlas and the Assistant’s client list.\n\nKept on this Mac: dictation history, your dictionary and corrections, Insights, settings, meeting transcripts and notes, and Assistant drafts.\n\nWhiskerFlow won’t dictate until you sign in again."
        if unsyncedMeetingItems > 0 {
            let items = unsyncedMeetingItems == 1 ? "1 meeting note or bookmark hasn’t" : "\(unsyncedMeetingItems) meeting notes and bookmarks haven’t"
            text += "\n\n\(items) reached Atlas. \(unsyncedMeetingItems == 1 ? "It stays" : "They stay") on this Mac and won’t be sent after you sign out."
        }
        return text
    }
}

/// Meetings recorded under an earlier Atlas sign-in. Their notes and
/// bookmarks that haven't reached Atlas stay on this Mac, and their
/// Atlas summaries aren't fetched again: the next sign-in may be someone else.
struct AtlasEarlierSignInMeetings {
    static let key = "atlasEarlierSignInMeetingSessions"
    let defaults: UserDefaults

    func contains(_ sessionID: UUID) -> Bool {
        (defaults.stringArray(forKey: Self.key) ?? []).contains(sessionID.uuidString)
    }

    func add(_ sessionIDs: some Sequence<UUID>) {
        let existing = defaults.stringArray(forKey: Self.key) ?? []
        var seen = Set(existing)
        let added = sessionIDs.map(\.uuidString).filter { seen.insert($0).inserted }
        guard !added.isEmpty else { return }
        defaults.set(existing + added, forKey: Self.key)
    }
}
