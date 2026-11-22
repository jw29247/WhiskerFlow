import Foundation

/// Guards what a failure or breadcrumb may write to the local diagnostic log.
public enum DiagnosticPrivacy {
    private static let categories: Set<String> = [
        "recording", "audio", "model", "storage", "glossary", "network"
    ]
    /// Every key here carries a fixed vocabulary or a count — never transcript
    /// text, a path, or a device name. Anything else is dropped.
    private static let metadataKeys: Set<String> = [
        "phase", "engine", "error_code", "stop_reason", "input_kind", "model",
        "source", "dropped_rules", "kept_rules", "recovered"
    ]
    private static let maximumValueLength = 64

    public static func allowsCategory(_ category: String?) -> Bool {
        guard let category else { return false }
        return categories.contains(category)
    }

    /// Keeps allow-listed keys whose values are short identifier-like tokens
    /// (an enum case, an error code, a count), so a mistaken call site cannot
    /// write free text under an allowed key.
    public static func safeMetadata(from metadata: [String: String]) -> [String: String] {
        metadata.filter { metadataKeys.contains($0.key) && isSafeValue($0.value) }
    }

    static func isSafeValue(_ value: String) -> Bool {
        !value.isEmpty && value.count <= maximumValueLength && value.unicodeScalars.allSatisfy {
            ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || "_-.:".unicodeScalars.contains($0)
        }
    }
}
