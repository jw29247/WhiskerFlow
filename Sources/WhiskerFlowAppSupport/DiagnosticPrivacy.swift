import Foundation

public enum DiagnosticPrivacy {
    private static let breadcrumbCategories: Set<String> = [
        "recording", "audio", "model", "storage", "glossary"
    ]
    /// Every key here carries a fixed vocabulary or a count — never transcript
    /// text, a path, or a device name. Anything else is dropped.
    private static let metadataKeys: Set<String> = [
        "phase", "engine", "error_code", "stop_reason", "input_kind", "model",
        "source", "dropped_rules", "kept_rules", "recovered"
    ]

    public static func allowsBreadcrumb(category: String?) -> Bool {
        guard let category else { return false }
        return breadcrumbCategories.contains(category)
    }

    public static func safeMetadata(from metadata: [String: String]) -> [String: String] {
        metadata.filter { metadataKeys.contains($0.key) }
    }

    public static func safeDebugImageName(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// Keep the crash classification an exception value carries ("Fatal error:
    /// Index out of range") while removing anything that could identify the user
    /// or the machine: home directories, container paths, addresses, mail
    /// addresses, and long hex/UUID runs. Truncated so an unexpectedly chatty
    /// framework message cannot smuggle a payload past the redactions.
    public static func sanitizedCrashText(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        var result = text
        for rule in crashTextRules {
            result = rule.regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: rule.template
            )
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return nil }
        if result.count > crashTextLimit {
            result = String(result.prefix(crashTextLimit - 1)) + "…"
        }
        return result
    }

    private static let crashTextLimit = 300

    private struct CrashTextRule {
        let regex: NSRegularExpression
        let template: String
    }

    private static let crashTextRules: [CrashTextRule] = [
        // Mail addresses first: the local part can look like a path component.
        ("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", "…"),
        // The whole home path goes, not just the account name — document names
        // are as identifying as the folder they sit in. A space is swallowed only
        // when the run after it still leads to a "/", so a path with a space in a
        // folder name is redacted whole without eating the following prose.
        ("(/Users/|/home/)(?:[^\\s\"',;)\\]]|[ ](?=[^\\s\"',;)\\]]*/))*", "$1…"),
        // Temporary containers keep only the leaf, which is the useful part.
        ("/(?:private/)?var/(?:[^\\s/\"',;)\\]]+/)+([^\\s/\"',;)\\]]+)", "$1"),
        ("\\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\\b", "…"),
        ("\\b(?:0[xX])?[0-9A-Fa-f]{16,}\\b", "…")
    ].compactMap { (pattern: String, template: String) -> CrashTextRule? in
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return CrashTextRule(regex: regex, template: template)
    }
}
