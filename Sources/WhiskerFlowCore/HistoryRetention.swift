import Foundation

/// How long dictation transcripts stay in History. Insights are recorded
/// separately and never depend on this.
public enum HistoryRetention: String, CaseIterable, Codable, Identifiable, Sendable {
    case forever
    case oneYear
    case ninetyDays
    case thirtyDays
    case sevenDays
    case twentyFourHours
    case off

    /// New installs, and existing installs migrating from the old fixed
    /// 30-day / 25-record limit (every record they have is younger than this).
    public static let defaultValue: HistoryRetention = .ninetyDays

    /// Failed recordings carry no transcript text but are the only copy of audio
    /// the user may still want to retry, so even "Don't save history" keeps them
    /// for this long.
    public static let failedRecordingGrace: TimeInterval = 24 * 60 * 60

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .forever: return "Keep forever"
        case .oneYear: return "1 year"
        case .ninetyDays: return "90 days"
        case .thirtyDays: return "30 days"
        case .sevenDays: return "7 days"
        case .twentyFourHours: return "24 hours"
        case .off: return "Don't save history"
        }
    }

    /// Maximum age of a saved record. `nil` keeps records indefinitely; `.off`
    /// keeps no transcripts at all.
    public var maximumAge: TimeInterval? {
        let day: TimeInterval = 24 * 60 * 60
        switch self {
        case .forever: return nil
        case .oneYear: return 365 * day
        case .ninetyDays: return 90 * day
        case .thirtyDays: return 30 * day
        case .sevenDays: return 7 * day
        case .twentyFourHours: return day
        case .off: return 0
        }
    }

    public var savesTranscripts: Bool { self != .off }

    /// True when switching from `self` to `other` can delete records that
    /// `self` would keep.
    public func isLonger(than other: HistoryRetention) -> Bool {
        switch (maximumAge, other.maximumAge) {
        case (nil, nil): return false
        case (nil, _): return true
        case (_, nil): return false
        case let (lhs?, rhs?): return lhs > rhs
        }
    }
}

/// How long the audio behind a successful transcript is kept. Failed and
/// in-progress recordings always keep their audio (it is what Retry decodes)
/// until the record itself leaves History.
public struct TranscriptAudioRetention: Equatable, Sendable {
    /// Audio is kept for the newest `newestLimit` successful dictations no older
    /// than `newestMaximumAge` — the disk bound WhiskerFlow has always had, which
    /// before transcripts outlived their audio was the 25-record history cap.
    public var newestLimit: Int
    public var newestMaximumAge: TimeInterval
    /// Opt-in: additionally keep every successful dictation younger than this.
    public var keepAllYoungerThan: TimeInterval?

    public init(newestLimit: Int, newestMaximumAge: TimeInterval, keepAllYoungerThan: TimeInterval? = nil) {
        self.newestLimit = newestLimit
        self.newestMaximumAge = newestMaximumAge
        self.keepAllYoungerThan = keepAllYoungerThan
    }

    public static let standard = TranscriptAudioRetention(newestLimit: 25, newestMaximumAge: 30 * 24 * 60 * 60)
    /// "Keep recordings for 14 days" in Settings.
    public static let fourteenDays = TranscriptAudioRetention(newestLimit: 25, newestMaximumAge: 30 * 24 * 60 * 60,
                                                              keepAllYoungerThan: 14 * 24 * 60 * 60)

    /// Unreferenced WAVs younger than this survive the startup sweep: an
    /// interrupted session may still be filing them.
    public static let orphanSweepAge: TimeInterval = 30 * 24 * 60 * 60
}

/// What a retention pass removes. Pure, so the confirmation dialog can show
/// the same count the store will act on.
public struct HistoryRetentionPlan: Equatable, Sendable {
    /// Records that leave History entirely (their audio goes with them).
    public let expiredIDs: Set<UUID>
    /// Surviving successful records whose audio is released; their text stays.
    public let releasedAudioIDs: Set<UUID>

    public init(
        records: [TranscriptRecord],
        retention: HistoryRetention,
        audio: TranscriptAudioRetention = .standard,
        now: Date
    ) {
        var expired = Set<UUID>()
        var released = Set<UUID>()
        let cutoff = retention.maximumAge.map { now.addingTimeInterval(-$0) }
        let failedCutoff = now.addingTimeInterval(-HistoryRetention.failedRecordingGrace)
        var transcribedWithAudio = 0

        for record in records.sortedNewestFirst() {
            let isExpired: Bool
            if retention == .off {
                isExpired = record.status == .transcribed || record.createdAt < failedCutoff
            } else if let cutoff {
                isExpired = record.createdAt < cutoff
            } else {
                isExpired = false
            }
            if isExpired {
                expired.insert(record.id)
                continue
            }
            guard record.status == .transcribed, !record.audioFilePath.isEmpty else { continue }
            let isNewest = transcribedWithAudio < audio.newestLimit
                && record.createdAt >= now.addingTimeInterval(-audio.newestMaximumAge)
            let isRecent = audio.keepAllYoungerThan.map { record.createdAt >= now.addingTimeInterval(-$0) } ?? false
            if isNewest || isRecent { transcribedWithAudio += 1 } else { released.insert(record.id) }
        }
        expiredIDs = expired
        releasedAudioIDs = released
    }

    public var isEmpty: Bool { expiredIDs.isEmpty && releasedAudioIDs.isEmpty }
}

extension TranscriptRecord {
    /// History order: newest first, ties broken by id so the order is stable.
    static func isOrderedBefore(_ lhs: TranscriptRecord, _ rhs: TranscriptRecord) -> Bool {
        if lhs.createdAt == rhs.createdAt { return lhs.id.uuidString > rhs.id.uuidString }
        return lhs.createdAt > rhs.createdAt
    }
}

extension Array where Element == TranscriptRecord {
    func sortedNewestFirst() -> [TranscriptRecord] {
        // Stored history is already in order; skip the sort on the dictation path.
        for index in indices.dropFirst() where !TranscriptRecord.isOrderedBefore(self[index - 1], self[index]) {
            return sorted(by: TranscriptRecord.isOrderedBefore)
        }
        return self
    }
}
