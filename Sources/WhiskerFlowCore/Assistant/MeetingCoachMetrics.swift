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
        var ownIntervals: [Range<TimeInterval>] = []
        var systemIntervals: [Range<TimeInterval>] = []
        var missingOwn = false, missingSystem = false
        for input in valid {
            let start = max(input.elapsedSeconds, windowStart)
            let end = min(input.elapsedSeconds + input.durationSeconds, windowEnd)
            guard end > start else { continue }
            missingOwn = missingOwn || input.ownMicActivity == nil
            missingSystem = missingSystem || input.systemActivity == nil
            if input.ownMicActivity == true { ownIntervals.append(start..<end) }
            if input.systemActivity == true { systemIntervals.append(start..<end) }
        }
        let mergedOwn = merge(ownIntervals)
        let mergedSystem = merge(systemIntervals)
        let own = duration(of: mergedOwn)
        let system = duration(of: mergedSystem)
        let overlap = intersectionDuration(mergedOwn, mergedSystem)
        let certainty: MeetingActivityCertainty
        if missingOwn && missingSystem { certainty = .missingBothTracks }
        else if missingOwn { certainty = .missingOwnMicTrack }
        else if missingSystem { certainty = .missingSystemTrack }
        else if overlap > 0 { certainty = .uncertainOverlap }
        else { certainty = .reliable }
        return .init(windowDurationSeconds: min(windowSeconds, windowEnd), ownMicActiveSeconds: min(windowSeconds, own), systemActiveSeconds: min(windowSeconds, system), overlapSeconds: min(windowSeconds, overlap), certainty: certainty)
    }

    private static func merge(_ intervals: [Range<TimeInterval>]) -> [Range<TimeInterval>] {
        let sorted = intervals.sorted { $0.lowerBound < $1.lowerBound }
        var result: [Range<TimeInterval>] = []
        for interval in sorted {
            guard let last = result.last, interval.lowerBound <= last.upperBound else {
                result.append(interval)
                continue
            }
            result[result.count - 1] = last.lowerBound..<max(last.upperBound, interval.upperBound)
        }
        return result
    }

    private static func duration(of intervals: [Range<TimeInterval>]) -> TimeInterval {
        intervals.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
    }

    private static func intersectionDuration(_ lhs: [Range<TimeInterval>], _ rhs: [Range<TimeInterval>]) -> TimeInterval {
        var total = 0.0
        var left = 0
        var right = 0
        while left < lhs.count, right < rhs.count {
            let start = max(lhs[left].lowerBound, rhs[right].lowerBound)
            let end = min(lhs[left].upperBound, rhs[right].upperBound)
            if end > start { total += end - start }
            if lhs[left].upperBound < rhs[right].upperBound { left += 1 } else { right += 1 }
        }
        return total
    }

    public static func canPrompt(elapsedSeconds: TimeInterval, lastPromptElapsedSeconds: TimeInterval?) -> Bool {
        guard elapsedSeconds.isFinite, elapsedSeconds >= 0 else { return false }
        guard let last = lastPromptElapsedSeconds else { return true }
        return last.isFinite && elapsedSeconds - last >= promptCooldownSeconds
    }
}
