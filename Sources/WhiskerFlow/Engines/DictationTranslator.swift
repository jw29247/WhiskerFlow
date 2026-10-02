import Foundation
import Translation
import WhiskerFlowAppSupport

enum DictationTranslationError: LocalizedError, Equatable {
    case needsDownload(String)
    case unsupported(String)
    case unavailable

    var errorDescription: String? {
        switch self {
        case .needsDownload(let language):
            return "Download \(language) translation in Settings → Dictation to have it written in English."
        case .unsupported(let language):
            return "Apple can't translate \(language) into English on this Mac yet."
        case .unavailable:
            return "Translation into English needs macOS 26."
        }
    }
}

/// Turns a transcript into English with Apple's on-device translation, using
/// the Apple Intelligence model where macOS offers it (26.4 and later).
/// Sessions are kept per source language, because the first translation
/// after loading a language costs about a second and later ones about 0.3 s.
actor DictationTranslator {
    enum Readiness: Equatable, Sendable { case ready, needsDownload, unsupported }

    private var sessions: [String: AnyObject] = [:]
    private var lastUse: [String: Date] = [:]

    static let english = Locale.Language(identifier: "en")

    /// The Translation framework's name for a stored language code.
    static func translationLanguage(for code: String) -> Locale.Language {
        switch code {
        case "zh-CN", "zh", "zh-Hans": return Locale.Language(identifier: "zh")
        case "zh-TW", "zh-Hant": return Locale.Language(identifier: "zh-TW")
        case "yue": return Locale.Language(identifier: "zh-HK")
        default: return Locale.Language(identifier: String(code.prefix { $0 != "-" }))
        }
    }

    static func readiness(from code: String) async -> Readiness {
        guard #available(macOS 26.0, *) else { return .unsupported }
        switch await LanguageAvailability().status(from: translationLanguage(for: code), to: english) {
        case .installed: return .ready
        case .supported: return .needsDownload
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    /// - Parameter keep: Dictionary words to leave untranslated (names,
    ///   products), where macOS supports marking them (26.4 and later).
    func translate(_ text: String, from code: String, displayName: String, keep: [String] = []) async throws -> String {
        guard #available(macOS 26.0, *) else { throw DictationTranslationError.unavailable }
        switch await Self.readiness(from: code) {
        case .ready: break
        case .needsDownload: throw DictationTranslationError.needsDownload(displayName)
        case .unsupported: throw DictationTranslationError.unsupported(displayName)
        }
        let session = session(for: code)
        lastUse[code] = Date()
        if #available(macOS 26.4, *), !keep.isEmpty {
            let response = try await session.translate(Self.protecting(keep, in: text))
            return response.targetText
        }
        return try await session.translate(text).targetText
    }

    /// Loads a language's model ahead of the first translation: at launch,
    /// and at a key press after a minute idle (it goes cold, like Parakeet).
    func warmUp(from code: String) async {
        guard #available(macOS 26.0, *), await Self.readiness(from: code) == .ready else { return }
        if let last = lastUse[code], Date().timeIntervalSince(last) < 60 { return }
        lastUse[code] = Date()
        _ = try? await session(for: code).translate(".")
    }

    @available(macOS 26.0, *)
    private func session(for code: String) -> TranslationSession {
        if let existing = sessions[code] as? TranslationSession { return existing }
        let source = Self.translationLanguage(for: code)
        let session: TranslationSession
        if #available(macOS 26.4, *) {
            session = TranslationSession(installedSource: source, target: Self.english, preferredStrategy: .highFidelity)
        } else {
            session = TranslationSession(installedSource: source, target: Self.english)
        }
        sessions[code] = session
        return session
    }

    @available(macOS 26.4, *)
    static func protecting(_ terms: [String], in text: String) -> AttributedString {
        var attributed = AttributedString(text)
        for term in terms where !term.isEmpty {
            var searchStart = attributed.startIndex
            while searchStart < attributed.endIndex,
                  let range = attributed[searchStart...].range(of: term, options: [.caseInsensitive]) {
                attributed[range].translation.skipsTranslation = true
                searchStart = range.upperBound
            }
        }
        return attributed
    }
}
