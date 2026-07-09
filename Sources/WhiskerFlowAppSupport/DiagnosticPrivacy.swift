import Foundation

public enum DiagnosticPrivacy {
    private static let breadcrumbCategories: Set<String> = [
        "recording", "audio", "model", "storage", "glossary"
    ]
    private static let metadataKeys: Set<String> = [
        "phase", "engine", "error_code", "stop_reason", "input_kind", "model"
    ]

    public static func allowsBreadcrumb(category: String?) -> Bool {
        guard let category else { return false }
        return breadcrumbCategories.contains(category)
    }

    public static func safeMetadata(from metadata: [String: String]) -> [String: String] {
        metadata.filter { metadataKeys.contains($0.key) }
    }
}
