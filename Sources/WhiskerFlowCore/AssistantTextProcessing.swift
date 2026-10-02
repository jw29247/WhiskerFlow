import Foundation

public enum AssistantTextProcessing {
    public static func process(_ raw: String, tone: WritingTone, vocabulary: Vocabulary,
                               formatting: FormattingOptions, recognizeCorrections: Bool) -> String {
        guard tone != .literal else { return raw }
        return process(raw, tone: tone, vocabulary: CompiledVocabulary(vocabulary),
                       formatting: formatting, recognizeCorrections: recognizeCorrections)
    }

    /// For callers that process repeatedly (live partials): compile the
    /// vocabulary's regexes once instead of on every call.
    ///
    /// Filler removal and spoken line commands follow the user's formatting
    /// settings; the tone decides capitalisation and end punctuation.
    public static func process(_ raw: String, tone: WritingTone, vocabulary: CompiledVocabulary,
                               formatting: FormattingOptions, recognizeCorrections: Bool) -> String {
        guard tone != .literal else { return raw }
        let repaired = recognizeCorrections ? SpokenSelfCorrection.resolve(raw) : raw
        let replaced = vocabulary.apply(to: repaired)
        switch tone {
        case .legacyStandard:
            return TranscriptFormatter.format(replaced, options: formatting)
        case .legacyConversational:
            return TranscriptFormatter.format(replaced, options: .init(spokenLineCommands: true, removeFillerWords: true,
                                                                       language: formatting.language))
        case .legacyPolished:
            return TranscriptFormatter.format(replaced, options: .init(spokenLineCommands: true, capitalizeSentences: true,
                                                                       removeFillerWords: true, language: formatting.language))
        default:
            let cleaned = TranscriptFormatter.format(replaced, options: .init(
                spokenLineCommands: formatting.spokenLineCommands,
                removeFillerWords: formatting.removeFillerWords,
                language: formatting.language))
            return WritingToneRenderer.render(cleaned.trimmingCharacters(in: .whitespacesAndNewlines), tone: tone)
        }
    }

    /// Counts the corrections `process` applies to `raw`, for Insights. Run off
    /// the delivery path: it repeats the self-correction and vocabulary passes.
    public static func correctionCounts(_ raw: String, tone: WritingTone, vocabulary: Vocabulary,
                                        recognizeCorrections: Bool) -> TextCorrectionCounts {
        guard tone != .literal else { return TextCorrectionCounts() }
        let repaired = recognizeCorrections ? SpokenSelfCorrection.resolveCounting(raw) : (text: raw, repairs: 0)
        return TextCorrectionCounts(
            vocabularyReplacements: CompiledVocabulary(vocabulary).replacementCount(in: repaired.text),
            selfCorrections: repaired.repairs
        )
    }
}

public struct TextCorrectionCounts: Equatable, Sendable {
    public var vocabularyReplacements: Int
    public var selfCorrections: Int

    public init(vocabularyReplacements: Int = 0, selfCorrections: Int = 0) {
        self.vocabularyReplacements = vocabularyReplacements
        self.selfCorrections = selfCorrections
    }
}
