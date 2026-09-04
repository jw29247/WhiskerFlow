import Foundation

public struct MeetingActivityInput: Equatable, Sendable {
    public var elapsedSeconds: TimeInterval
    public var durationSeconds: TimeInterval
    public var ownMicActivity: Bool?
    public var systemActivity: Bool?

    public init(elapsedSeconds: TimeInterval, durationSeconds: TimeInterval, ownMicActivity: Bool?, systemActivity: Bool?) {
        self.elapsedSeconds = elapsedSeconds
        self.durationSeconds = durationSeconds
        self.ownMicActivity = ownMicActivity
        self.systemActivity = systemActivity
    }
}

public enum MeetingActivityCertainty: String, Codable, Equatable, Sendable {
    case reliable
    case missingOwnMicTrack
    case missingSystemTrack
    case missingBothTracks
    case uncertainOverlap
}

public struct MeetingActivityResult: Equatable, Sendable {
    public var windowDurationSeconds: TimeInterval
    public var ownMicActiveSeconds: TimeInterval
    public var systemActiveSeconds: TimeInterval
    public var overlapSeconds: TimeInterval
    public var certainty: MeetingActivityCertainty

    public init(windowDurationSeconds: TimeInterval, ownMicActiveSeconds: TimeInterval, systemActiveSeconds: TimeInterval, overlapSeconds: TimeInterval, certainty: MeetingActivityCertainty) {
        self.windowDurationSeconds = windowDurationSeconds
        self.ownMicActiveSeconds = ownMicActiveSeconds
        self.systemActiveSeconds = systemActiveSeconds
        self.overlapSeconds = overlapSeconds
        self.certainty = certainty
    }
}

public enum MeetingCoachMetrics {
    public static let windowSeconds: TimeInterval = 60
    public static let promptCooldownSeconds: TimeInterval = 60

    public static func accumulate(inputs: [MeetingActivityInput]) -> MeetingActivityResult {
        let valid = inputs.filter { $0.elapsedSeconds.isFinite && $0.durationSeconds.isFinite && $0.elapsedSeconds >= 0 && $0.durationSeconds > 0 }
        let windowEnd = valid.map { $0.elapsedSeconds + $0.durationSeconds }.max() ?? 0
        let windowStart = max(0, windowEnd - windowSeconds)
        var own = 0.0, system = 0.0, overlap = 0.0
        var missingOwn = false, missingSystem = false
        for input in valid {
            let duration = max(0, min(input.elapsedSeconds + input.durationSeconds, windowEnd) - max(input.elapsedSeconds, windowStart))
            guard duration > 0 else { continue }
            missingOwn = missingOwn || input.ownMicActivity == nil
            missingSystem = missingSystem || input.systemActivity == nil
            if input.ownMicActivity == true { own += duration }
            if input.systemActivity == true { system += duration }
            if input.ownMicActivity == true && input.systemActivity == true { overlap += duration }
        }
        let certainty: MeetingActivityCertainty
        if missingOwn && missingSystem { certainty = .missingBothTracks }
        else if missingOwn { certainty = .missingOwnMicTrack }
        else if missingSystem { certainty = .missingSystemTrack }
        else if overlap > 0 { certainty = .uncertainOverlap }
        else { certainty = .reliable }
        return .init(windowDurationSeconds: min(windowSeconds, windowEnd), ownMicActiveSeconds: min(windowSeconds, own), systemActiveSeconds: min(windowSeconds, system), overlapSeconds: min(windowSeconds, overlap), certainty: certainty)
    }

    public static func canPrompt(elapsedSeconds: TimeInterval, lastPromptElapsedSeconds: TimeInterval?) -> Bool {
        guard elapsedSeconds.isFinite, elapsedSeconds >= 0 else { return false }
        guard let last = lastPromptElapsedSeconds else { return true }
        return last.isFinite && elapsedSeconds - last >= promptCooldownSeconds
    }
}
