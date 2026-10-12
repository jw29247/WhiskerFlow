import Foundation
import NaturalLanguage

/// A language someone can dictate in.
public struct DictationLanguageOption: Identifiable, Equatable, Sendable {
    /// Stored in settings: a base code ("es"), a script or region variant
    /// where it matters ("zh-TW"), or "auto".
    public let code: String
    public var id: String { code }

    /// "Spanish — Español"; English names first so a colleague can help.
    public var displayName: String {
        guard code != "auto" else { return "Auto-detect (European languages)" }
        let english = Locale(identifier: "en").localizedString(forIdentifier: code) ?? code
        let native = Locale(identifier: code).localizedString(forIdentifier: code) ?? english
        return english.caseInsensitiveCompare(native) == .orderedSame ? english : "\(english) — \(native)"
    }

    public var isAuto: Bool { code == "auto" }
}

/// Which recogniser hears which language. Parakeet covers 25 European
/// languages and is the fastest; Apple's on-device dictation model
/// (`DictationTranscriber`, macOS 26) covers the rest.
public enum DictationLanguageCatalog {
    public static let parakeetLanguages: Set<String> = [
        "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "hr", "hu", "it", "lt", "lv", "mt", "nl", "pl",
        "pt", "ro", "ru", "sk", "sl", "sv", "uk",
    ]

    /// Apple dictation locales, by the code stored in settings.
    public static let appleDictationLocales: [String: String] = [
        "ar": "ar-SA", "ca": "ca-ES", "he": "he-IL", "hi": "hi-IN", "id": "id-ID", "ja": "ja-JP", "ko": "ko-KR",
        "ms": "ms-MY", "nb": "nb-NO", "th": "th-TH", "tr": "tr-TR", "vi": "vi-VN", "zh-CN": "zh-CN", "zh-TW": "zh-TW",
        "yue": "yue-CN",
    ]

    /// Auto and English first, then alphabetical by English name.
    public static let options: [DictationLanguageOption] = {
        let rest = (parakeetLanguages.subtracting(["en"]).union(appleDictationLocales.keys))
            .map(DictationLanguageOption.init(code:))
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        return [DictationLanguageOption(code: "auto"), DictationLanguageOption(code: "en")] + rest
    }()

    /// The catalog option for a stored or system code ("es-MX" → Spanish,
    /// "zh" or "zh-Hans" → Chinese, Simplified).
    public static func option(for code: String) -> DictationLanguageOption? {
        let lowered = code.replacingOccurrences(of: "_", with: "-").lowercased()
        if let exact = options.first(where: { $0.code.lowercased() == lowered }) { return exact }
        if lowered.hasPrefix("zh") {
            let traditional = lowered.contains("hant") || lowered.hasSuffix("-tw") || lowered.hasSuffix("-hk") || lowered.hasSuffix("-mo")
            return options.first { $0.code == (traditional ? "zh-TW" : "zh-CN") }
        }
        let base = String(lowered.prefix { $0 != "-" })
        return options.first { $0.code == base }
    }

    /// The Mac's first preferred language we support, else English.
    public static func suggested(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        preferredLanguages.lazy.compactMap { option(for: $0)?.code }.first ?? "en"
    }
}

public enum DictationRoute: Equatable, Sendable {
    case parakeet
    case appleDictation(locale: String)
}

/// How a dictation in the chosen language becomes text: which recogniser
/// hears it, and whether the result is translated into English. Decided once
/// from the setting, never by listening, so it costs nothing per dictation.
public struct DictationLanguagePlan: Equatable, Sendable {
    public enum TranslationSource: Equatable, Sendable {
        /// The language the person said they speak.
        case language(String)
        /// Auto-detect: read the language off the transcript.
        case detected
    }

    public let language: String
    public let route: DictationRoute
    /// Nil: the transcript is pasted as heard.
    public let translationSource: TranslationSource?

    public init(language: String, translateToEnglish: Bool) {
        let option = DictationLanguageCatalog.option(for: language)
        let code = option?.code ?? "en"
        self.language = code
        if let locale = DictationLanguageCatalog.appleDictationLocales[code] {
            route = .appleDictation(locale: locale)
        } else {
            route = .parakeet
        }
        if !translateToEnglish || code == "en" {
            translationSource = nil
        } else {
            translationSource = code == "auto" ? .detected : .language(code)
        }
    }

    /// What formatting (filler words, punctuation rules) should assume.
    public var outputLanguage: String { translationSource == nil ? language : "en" }
}

/// Reads the language of a transcript. Under a millisecond; used only to
/// skip translating text that is already English.
public enum DictationTextLanguage {
    /// A base code ("en", "es", "ja", "zh-Hans"), or nil when the text is too
    /// short or mixed to tell.
    public static func detect(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 6 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, confidence >= 0.5 else {
            return nil
        }
        return language.rawValue
    }

    public static func isEnglish(_ text: String) -> Bool { detect(text) == "en" }
}
