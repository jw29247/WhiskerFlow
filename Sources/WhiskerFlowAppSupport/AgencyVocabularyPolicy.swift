import Foundation
import WhiskerFlowCore

public enum AgencyVocabularyError: Error, Equatable, Sendable {
    case payloadTooLarge
    case invalidPayload
}

public struct AgencyVocabularyDecodeReport: Equatable, Sendable {
    public let vocabulary: Vocabulary
    public let droppedRuleCount: Int

    public init(vocabulary: Vocabulary, droppedRuleCount: Int) {
        self.vocabulary = vocabulary
        self.droppedRuleCount = droppedRuleCount
    }
}

public enum AgencyVocabularyPolicy {
    public static let maximumPayloadBytes = 256 * 1024

    public static func decode(_ data: Data) throws -> Vocabulary {
        try decodeReport(data).vocabulary
    }

    /// The glossary is served live from a branch and reaches every user within the
    /// refresh window, so this decode — the only way the app ingests it — is where
    /// a rule that would rewrite everyday speech gets dropped.
    public static func decodeReport(_ data: Data) throws -> AgencyVocabularyDecodeReport {
        guard data.count <= maximumPayloadBytes else {
            throw AgencyVocabularyError.payloadTooLarge
        }
        let decoded: Vocabulary
        do {
            decoded = try JSONDecoder().decode(Vocabulary.self, from: data)
        } catch {
            throw AgencyVocabularyError.invalidPayload
        }
        let kept = decoded.rules.filter { rule in
            !GlossaryLint.flags(for: rule).contains(where: \.rewritesEverydaySpeech)
        }
        return AgencyVocabularyDecodeReport(
            vocabulary: Vocabulary(rules: kept),
            droppedRuleCount: decoded.rules.count - kept.count
        )
    }

    public static func initialVocabulary(cache: Data?, seed: Data?) throws -> Vocabulary {
        if let cache, let vocabulary = try? decode(cache) { return vocabulary }
        if let seed, let vocabulary = try? decode(seed) { return vocabulary }
        throw AgencyVocabularyError.invalidPayload
    }
}
