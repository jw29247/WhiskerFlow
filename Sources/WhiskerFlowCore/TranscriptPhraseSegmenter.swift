import Foundation

/// Groups word timings into phrase segments. Parakeet times each word, while a
/// meeting turn is a phrase: speaker labels are matched per segment, so a
/// segment must be long enough to carry a voice and short enough to belong to
/// one speaker. A phrase ends at a sentence end, a pause, or a length cap.
public enum TranscriptPhraseSegmenter {
    public static let defaultMaximumPause: Double = 0.8
    public static let defaultMaximumDuration: Double = 15

    /// Words ending in a full stop that don't end a sentence.
    private static let abbreviations: Set<String> = [
        "mr.", "mrs.", "ms.", "dr.", "prof.", "st.", "vs.", "etc.", "e.g.", "i.e.", "approx.", "no.",
    ]

    public static func phrases(
        from words: [TranscriptionSegment],
        maximumPause: Double = defaultMaximumPause,
        maximumDuration: Double = defaultMaximumDuration
    ) -> [TranscriptionSegment] {
        var phrases: [TranscriptionSegment] = []
        var current: [TranscriptionSegment] = []

        func close() {
            guard let first = current.first, let last = current.last else { return }
            phrases.append(TranscriptionSegment(
                text: current.map(\.text).joined(separator: " "),
                start: first.start, end: max(last.end, first.start)))
            current = []
        }

        for word in words {
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            // A bare punctuation token belongs to the word before it.
            if text.allSatisfy({ $0.isPunctuation }) {
                if let last = current.popLast() {
                    current.append(TranscriptionSegment(text: last.text + text, start: last.start, end: max(last.end, word.end)))
                    if endsSentence(text) { close() }
                } else if let last = phrases.popLast() {
                    phrases.append(TranscriptionSegment(text: last.text + text, start: last.start, end: last.end))
                }
                continue
            }
            if let last = current.last, let first = current.first,
               word.start - last.end > maximumPause || word.end - first.start > maximumDuration {
                close()
            }
            current.append(TranscriptionSegment(text: text, start: word.start, end: word.end))
            if endsSentence(text) { close() }
        }
        close()
        return phrases
    }

    private static func endsSentence(_ word: String) -> Bool {
        guard let last = word.last, ".?!".contains(last) else { return false }
        if last == ".", abbreviations.contains(word.lowercased()) { return false }
        return true
    }
}
