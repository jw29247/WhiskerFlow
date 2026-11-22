import Foundation

/// A count with its noun, so a single item never reads as "1 recordings".
public enum CountPhrase {
    /// "1 recording", "0 recordings", "1,204 words".
    public static func of(_ count: Int, _ singular: String, plural: String? = nil) -> String {
        "\(count.formatted()) \(noun(count, singular, plural: plural))"
    }

    /// The noun alone: the singular for exactly one, the plural otherwise.
    public static func noun(_ count: Int, _ singular: String, plural: String? = nil) -> String {
        count == 1 ? singular : plural ?? singular + "s"
    }
}
