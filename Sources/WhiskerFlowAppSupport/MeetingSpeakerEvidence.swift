import Foundation

/// Product evidence from Meet's media metadata, never diagnostic telemetry.
public struct MeetingSpeakerEvidence: Codable, Equatable, Sendable {
    public let startMs: Int64
    public let endMs: Int64
    public let participantID: String
    public let displayName: String
    public init(startMs: Int64, endMs: Int64, participantID: String, displayName: String) {
        self.startMs = startMs; self.endMs = endMs
        self.participantID = participantID; self.displayName = displayName
    }
}

public enum MeetingSpeakerEvidenceMatcher {
    public static func identity(startMs: Int64, endMs: Int64, evidence: [MeetingSpeakerEvidence]) -> MeetingSpeakerIdentity? {
        guard endMs > startMs else { return nil }
        let rows = evidence.filter { $0.endMs > startMs && $0.startMs < endMs && $0.endMs > $0.startMs }
        let groups = Dictionary(grouping: rows, by: \.participantID)
        let duration = Double(endMs - startMs)
        var candidates: [(MeetingSpeakerIdentity, Double)] = []
        for (id, samples) in groups {
            guard !id.isEmpty, Set(samples.map(\.displayName)).count == 1, let name = samples.first?.displayName, !name.isEmpty else { return nil }
            // Union intervals: duplicate/retried evidence must never inflate confidence.
            var end = startMs
            var covered: Int64 = 0
            for row in samples.sorted(by: { $0.startMs < $1.startMs }) {
                let lower = max(startMs, row.startMs, end)
                let upper = min(endMs, row.endMs)
                covered += max(0, upper - lower)
                end = max(end, upper)
            }
            candidates.append((MeetingSpeakerIdentity(key: "google-meet:" + id, displayName: name, resolution: .googleMeet), Double(covered) / duration))
        }
        // Any competing remote activity leaves a whole mixed-audio segment ambiguous.
        guard candidates.count == 1, let best = candidates.first, best.1 >= 0.8 else { return nil }
        return best.0
    }
}
