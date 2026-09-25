import Foundation

public enum AssistantTextProcessing {
    public static func process(_ raw: String, style: WritingStyle, vocabulary: Vocabulary,
                               formatting: FormattingOptions, recognizeCorrections: Bool) -> String {
        guard style != .literal else { return raw }
        return process(raw, style: style, vocabulary: CompiledVocabulary(vocabulary),
                       formatting: formatting, recognizeCorrections: recognizeCorrections)
    }

    /// For callers that process repeatedly (live partials): compile the
    /// vocabulary's regexes once instead of on every call.
    public static func process(_ raw: String, style: WritingStyle, vocabulary: CompiledVocabulary,
                               formatting: FormattingOptions, recognizeCorrections: Bool) -> String {
        guard style != .literal else { return raw }
        let repaired = recognizeCorrections ? SpokenSelfCorrection.resolve(raw) : raw
        let options: FormattingOptions
        switch style {
        case .standard: options = formatting
        case .conversational: options = .init(spokenLineCommands: true, removeFillerWords: true)
        case .polished: options = .init(spokenLineCommands: true, capitalizeSentences: true, removeFillerWords: true)
        case .literal: return raw
        }
        return TranscriptFormatter.format(vocabulary.apply(to: repaired), options: options)
    }
}
