import Foundation

/// The two sentences the practice screen asks the user to read.
public enum PracticePrompt: String, CaseIterable, Sendable {
    case sample
    case selfCorrection

    public var sentence: String {
        switch self {
        case .sample: return "WhiskerFlow turns what I say into text, right where my cursor is."
        case .selfCorrection: return "Let’s meet at 2, sorry, 3."
        }
    }

    public var instruction: String {
        switch self {
        case .sample: return "Read this sentence aloud."
        case .selfCorrection: return "Now change your mind halfway through. Say it just like this:"
        }
    }
}

public enum PracticeOutcome: Equatable, Sendable {
    /// The transcript reads like the prompt.
    case matched
    /// Self-correction prompt: only the corrected time was kept.
    case corrected
    /// Self-correction prompt: the words were right but the repair stayed in.
    case notCorrected
    /// Something else came through: still a working dictation, just not the prompt.
    case different
}

public enum PracticeEvaluation {
    public static func evaluate(_ prompt: PracticePrompt, transcript: String) -> PracticeOutcome {
        let words = normalizedWords(transcript)
        switch prompt {
        case .sample:
            let expected = Set(normalizedWords(prompt.sentence))
            guard !expected.isEmpty else { return .different }
            let overlap = Double(expected.intersection(words).count) / Double(expected.count)
            return overlap >= 0.6 ? .matched : .different
        case .selfCorrection:
            guard words.contains("meet") else { return .different }
            let saysThree = words.contains("3") || words.contains("three")
            let keepsRepair = words.contains("sorry") || words.contains("2") || words.contains("two")
            if saysThree && !keepsRepair { return .corrected }
            return saysThree ? .notCorrected : .different
        }
    }

    static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
    }
}
