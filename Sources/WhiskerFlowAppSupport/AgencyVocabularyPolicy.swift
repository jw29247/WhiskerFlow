import Foundation
import WhiskerFlowCore

public enum AgencyVocabularyError: Error, Equatable, Sendable {
    case payloadTooLarge
    case invalidPayload
}

public enum AgencyVocabularyPolicy {
    public static let maximumPayloadBytes = 256 * 1024

    public static func decode(_ data: Data) throws -> Vocabulary {
        guard data.count <= maximumPayloadBytes else {
            throw AgencyVocabularyError.payloadTooLarge
        }
        do {
            return try JSONDecoder().decode(Vocabulary.self, from: data)
        } catch {
            throw AgencyVocabularyError.invalidPayload
        }
    }

    public static func initialVocabulary(cache: Data?, seed: Data?) throws -> Vocabulary {
        if let cache, let vocabulary = try? decode(cache) { return vocabulary }
        if let seed, let vocabulary = try? decode(seed) { return vocabulary }
        throw AgencyVocabularyError.invalidPayload
    }
}
