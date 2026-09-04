import Foundation

/// A find/replace pair inferred from a manual transcript edit, offered to the
/// user as a candidate `VocabularyRule`.
public struct VocabularyCorrection: Equatable, Hashable, Sendable {
    public let find: String
    public let replaceWith: String

    public init(find: String, replaceWith: String) {
        self.find = find
        self.replaceWith = replaceWith
    }
}

/// Infers vocabulary rules from the difference between a transcript and the
/// user's edited version of it, so a mistake corrected by hand once can be
/// fixed automatically from then on.
public enum VocabularyCorrectionDetector {
    /// Past this share of changed tokens the edit reads as a rewrite rather than
    /// a correction, and find/replace rules learned from it would misfire.
    private static let rewriteRatio = 0.4
    /// Longer runs are sentence surgery, not a term the user says repeatedly.
    private static let maxRunWords = 3
    /// Trimmed from both ends of a token so "stella," and "stella" are the same
    /// word. Deliberately excludes characters that carry meaning inside terms
    /// such as "C++", "#tag" and "co-op".
    private static let boundaryPunctuation = CharacterSet(charactersIn: ".,;:!?…\"'“”‘’`()[]{}<>«»")

    public static func corrections(
        original: String,
        edited: String,
        existingRules: Vocabulary = Vocabulary(),
        maxSuggestions: Int = 3,
        allowShortCorrections: Bool = false
    ) -> [VocabularyCorrection] {
        let originalTokens = tokens(in: original)
        let editedTokens = tokens(in: edited)
        guard !originalTokens.isEmpty, !editedTokens.isEmpty else { return [] }

        let runs = changedRuns(originalTokens, editedTokens)
        guard !runs.isEmpty else { return [] }

        let changedTokens = max(
            runs.reduce(0) { $0 + $1.find.count },
            runs.reduce(0) { $0 + $1.replaceWith.count }
        )
        let totalTokens = max(originalTokens.count, editedTokens.count)
        let shortWordCorrection = allowShortCorrections && totalTokens <= 3 && runs.count == 1
            && runs[0].find.count == 1 && runs[0].replaceWith.count == 1
        guard shortWordCorrection || Double(changedTokens) / Double(totalTokens) <= rewriteRatio else { return [] }

        var suggestions: [VocabularyCorrection] = []
        var seen: Set<VocabularyCorrection> = []
        for run in runs {
            guard (1...maxRunWords).contains(run.find.count),
                  (1...maxRunWords).contains(run.replaceWith.count) else { continue }
            let find = run.find.joined(separator: " ")
            let replaceWith = run.replaceWith.joined(separator: " ")
            guard find != replaceWith,
                  containsLetter(find),
                  containsLetter(replaceWith),
                  existingRules.apply(to: find) != replaceWith else { continue }
            let suggestion = VocabularyCorrection(find: find, replaceWith: replaceWith)
            guard seen.insert(suggestion).inserted else { continue }
            suggestions.append(suggestion)
            if suggestions.count == maxSuggestions { break }
        }
        return suggestions
    }

    private struct TokenRun {
        var find: [String] = []
        var replaceWith: [String] = []

        var isEmpty: Bool { find.isEmpty && replaceWith.isEmpty }
    }

    private enum AlignmentStep {
        case common(Int, Int)
        case removed(Int)
        case added(Int)
    }

    private static func tokens(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: boundaryPunctuation) }
            .filter { !$0.isEmpty }
    }

    private static func containsLetter(_ text: String) -> Bool {
        text.contains { $0.isLetter }
    }

    /// Contiguous stretches where the two token streams disagree. A token pair
    /// the alignment treats as common still lands in a run when the raw spelling
    /// differs, which is what makes case-only fixes ("firma" -> "Firma") visible.
    private static func changedRuns(_ original: [String], _ edited: [String]) -> [TokenRun] {
        var runs: [TokenRun] = []
        var current = TokenRun()

        for step in alignment(original, edited) {
            switch step {
            case .common(let i, let j) where original[i] == edited[j]:
                if !current.isEmpty { runs.append(current) }
                current = TokenRun()
            case .common(let i, let j):
                current.find.append(original[i])
                current.replaceWith.append(edited[j])
            case .removed(let i):
                current.find.append(original[i])
            case .added(let j):
                current.replaceWith.append(edited[j])
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// Longest-common-subsequence alignment, compared case-insensitively so a
    /// re-capitalised word still lines up with its original position.
    ///
    /// The DP table is O(n*m) and this runs on the main actor before every save, so
    /// the shared head and tail — all of a typical correction — are matched off
    /// first and only the disagreeing core reaches the table. A core larger than
    /// `maxAlignmentTokens` is a rewrite, not a correction: refuse it rather than
    /// allocating hundreds of megabytes to learn nothing.
    private static func alignment(_ original: [String], _ edited: [String]) -> [AlignmentStep] {
        let left = original.map { $0.lowercased() }
        let right = edited.map { $0.lowercased() }

        var head = 0
        while head < left.count, head < right.count, left[head] == right[head] { head += 1 }
        var tail = 0
        while tail < left.count - head, tail < right.count - head,
              left[left.count - 1 - tail] == right[right.count - 1 - tail] {
            tail += 1
        }

        let leftCore = Array(left[head..<(left.count - tail)])
        let rightCore = Array(right[head..<(right.count - tail)])
        guard leftCore.count <= maxAlignmentTokens, rightCore.count <= maxAlignmentTokens else {
            return []
        }

        var steps = (0..<head).map { AlignmentStep.common($0, $0) }
        steps += coreAlignment(leftCore, rightCore, offset: head)
        steps += (0..<tail).map {
            AlignmentStep.common(left.count - tail + $0, right.count - tail + $0)
        }
        return steps
    }

    private static let maxAlignmentTokens = 400

    private static func coreAlignment(
        _ left: [String],
        _ right: [String],
        offset: Int
    ) -> [AlignmentStep] {
        var lengths = [[Int]](
            repeating: [Int](repeating: 0, count: right.count + 1),
            count: left.count + 1
        )
        for i in stride(from: left.count - 1, through: 0, by: -1) {
            for j in stride(from: right.count - 1, through: 0, by: -1) {
                lengths[i][j] = left[i] == right[j]
                    ? lengths[i + 1][j + 1] + 1
                    : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }

        var steps: [AlignmentStep] = []
        var i = 0
        var j = 0
        while i < left.count, j < right.count {
            if left[i] == right[j] {
                steps.append(.common(i + offset, j + offset))
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                steps.append(.removed(i + offset))
                i += 1
            } else {
                steps.append(.added(j + offset))
                j += 1
            }
        }
        while i < left.count {
            steps.append(.removed(i + offset))
            i += 1
        }
        while j < right.count {
            steps.append(.added(j + offset))
            j += 1
        }
        return steps
    }
}
