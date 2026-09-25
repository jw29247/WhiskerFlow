import Foundation

/// Product evidence from the meeting's labelled captions, never diagnostic telemetry.
public struct MeetingCaptionEvidence: Codable, Equatable, Sendable {
    public let speaker: String
    public let text: String
    public init(speaker: String, text: String) { self.speaker = speaker; self.text = text }
}

public enum MeetingCaptionMatcher {
    public static func identity(for text: String, evidence: [MeetingCaptionEvidence]) -> MeetingSpeakerIdentity? {
        let words = normalized(text)
        guard words.split(separator: " ").count >= 5 else { return nil }
        let matches = evidence.filter {
            let candidate = normalized($0.text)
            return candidate.split(separator: " ").count >= 5
                && (candidate == words || (" " + candidate + " ").contains(" " + words + " ")
                    || strongOverlap(words, candidate))
        }
        let names = Set(matches.map(\.speaker))
        guard names.count == 1, let name = names.first, !name.isEmpty else { return nil }
        if name == "You" { return .microphone }
        return MeetingSpeakerIdentity(key: "google-meet:" + name, displayName: name, resolution: .googleMeet)
    }
    private static func strongOverlap(_ text: String, _ caption: String) -> Bool {
        let words = text.split(separator: " ").map(String.init)
        let reference = caption.split(separator: " ").map(String.init)
        guard words.count >= 10, words.count <= 500, reference.count >= 5 else { return false }
        let shingles = Set((0...(reference.count - 5)).map { reference[$0..<($0 + 5)].joined(separator: " ") })
        var covered = Set<Int>()
        for index in 0...(words.count - 5) where shingles.contains(words[index..<(index + 5)].joined(separator: " ")) {
            covered.formUnion(index..<(index + 5))
        }
        return Double(covered.count) / Double(words.count) >= 0.9
    }
    private static func normalized(_ text: String) -> String {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }
}
