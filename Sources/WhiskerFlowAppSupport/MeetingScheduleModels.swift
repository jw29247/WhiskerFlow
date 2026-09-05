import Foundation

/// A calendar event returned by Atlas for Meeting Mode.
public struct AtlasCaptureScheduleIntent: Codable, Equatable, Sendable {
    public let eventID: String
    public let title: String
    public let startMs: Int64
    public let endMs: Int64
    public let meetingURL: String?
    public let location: String?
    public let existingMeetingID: String?
    public let overlapsPrevious: Bool

    public init(
        eventID: String,
        title: String,
        startMs: Int64,
        endMs: Int64,
        meetingURL: String?,
        location: String?,
        existingMeetingID: String?,
        overlapsPrevious: Bool
    ) {
        self.eventID = eventID
        self.title = title
        self.startMs = startMs
        self.endMs = endMs
        self.meetingURL = meetingURL
        self.location = location
        self.existingMeetingID = existingMeetingID
        self.overlapsPrevious = overlapsPrevious
    }

    /// Atlas's meeting-bot path only dispatches calendar events with a valid
    /// secure join URL. Ordinary task blocks remain visible in the Meeting Hub
    /// but must not start desktop audio capture automatically.
    public var isEligibleForAutomaticCapture: Bool {
        guard let meetingURL,
              let url = URL(string: meetingURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              url.host != nil else {
            return false
        }
        return true
    }
}

public enum MeetingCaptureSchedulePolicy {
    /// Return only the events that can be captured automatically.
    ///
    /// The complete input remains available to the Meeting Hub for display and
    /// manual recording actions.
    public static func automaticCaptureIntents(
        from intents: [AtlasCaptureScheduleIntent]
    ) -> [AtlasCaptureScheduleIntent] {
        let eligible = intents.filter(\.isEligibleForAutomaticCapture)
        return eligible.enumerated().map { index, intent in
            let overlapsPrevious = index > 0 && eligible[index - 1].endMs > intent.startMs
            guard intent.overlapsPrevious != overlapsPrevious else { return intent }
            return AtlasCaptureScheduleIntent(
                eventID: intent.eventID,
                title: intent.title,
                startMs: intent.startMs,
                endMs: intent.endMs,
                meetingURL: intent.meetingURL,
                location: intent.location,
                existingMeetingID: intent.existingMeetingID,
                overlapsPrevious: overlapsPrevious
            )
        }
    }
}
