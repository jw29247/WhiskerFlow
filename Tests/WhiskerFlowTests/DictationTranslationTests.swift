import AVFoundation
import Translation
import XCTest
import WhiskerFlowAppSupport
import WhiskerFlowCore
@testable import WhiskerFlow

final class DictationTranslationTests: XCTestCase {
    func testStoredCodesMapToTranslationLanguages() {
        XCTAssertEqual(DictationTranslator.translationLanguage(for: "zh-CN").minimalIdentifier, "zh")
        XCTAssertEqual(DictationTranslator.translationLanguage(for: "zh-Hans").minimalIdentifier, "zh")
        XCTAssertEqual(DictationTranslator.translationLanguage(for: "zh-TW").minimalIdentifier, "zh-TW")
        XCTAssertEqual(DictationTranslator.translationLanguage(for: "hi-IN").minimalIdentifier, "hi")
        XCTAssertEqual(DictationTranslator.translationLanguage(for: "es").minimalIdentifier, "es")
    }

    func testDictionaryWordsAreMarkedToStayUntranslated() throws {
        guard #available(macOS 26.4, *) else { throw XCTSkip("Needs macOS 26.4") }
        let marked = DictationTranslator.protecting(["WhiskerFlow", "Sarah"], in: "Manda a sarah el enlace de WhiskerFlow")
        let kept = marked.runs.filter { $0.translation.skipsTranslation == true }.map { String(marked[$0.range].characters) }
        XCTAssertEqual(kept, ["sarah", "WhiskerFlow"])
    }

    @MainActor
    func testTranslationIsOnByDefaultAndAppleDictationIsNeverTheStoredEngine() {
        let suite = "translation-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("appleDictation", forKey: "engine")
        let settings = AppSettings(defaults: defaults, meetingTokenStore: MeetingCaptureTokenStore(service: suite))
        XCTAssertTrue(settings.translateToEnglish)
        XCTAssertNotEqual(settings.engine, .appleDictation)
        settings.language = "hi"
        XCTAssertEqual(settings.languagePlan.route, .appleDictation(locale: "hi-IN"))
    }

    /// Opt-in, silent: synthesises speech to files with `say -o` (nothing
    /// plays), recognises it and translates it on this Mac.
    /// `WHISKERFLOW_TRANSLATION_PROBE=1 swift test --filter DictationTranslationTests`
    func testSpokenLanguagesComeOutInEnglish() async throws {
        guard ProcessInfo.processInfo.environment["WHISKERFLOW_TRANSLATION_PROBE"] == "1" else { throw XCTSkip("Opt-in probe") }
        guard #available(macOS 26.0, *) else { throw XCTSkip("Needs macOS 26") }
        let cases: [(language: String, voice: String, text: String)] = [
            ("es", "Eddy (Spanish (Spain))", "Oye, ¿le puedes mandar a Sarah el informe de ventas antes del viernes? Gracias."),
            ("de", "Anna", "Ich habe den Entwurf überarbeitet, schau es dir bitte noch mal an."),
            ("ja", "Eddy (Japanese (Japan))", "明日の打ち合わせは十五時からに変更してもいいですか。"),
            ("zh-CN", "Eddy (Chinese (China mainland))", "我们下周一可以开个会讨论一下预算吗？"),
        ]
        let service = TranscriptionService()
        let translator = DictationTranslator()
        _ = await service.prepare(kind: .parakeetTDTv3, language: nil)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wf-translation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for item in cases {
            let url = folder.appendingPathComponent("\(item.language).wav")
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-v", item.voice, "-o", url.path, "--data-format=LEF32@16000", item.text]
            try say.run()
            say.waitUntilExit()
            let plan = DictationLanguagePlan(language: item.language, translateToEnglish: true)
            let kind: TranscriptionEngineKind
            var language: String? = item.language
            if case .appleDictation(let locale) = plan.route { kind = .appleDictation; language = locale } else { kind = .parakeetTDTv3 }
            let started = Date()
            let heard = try await service.transcribe(audioURL: url, kind: kind, language: language, allowAppleFallback: false).result.text
            let recognised = Date()
            let english = try await translator.translate(heard, from: item.language, displayName: item.language, keep: ["Sarah"])
            print("PROBE \(item.language) \(kind.rawValue) recognise=\(Int(recognised.timeIntervalSince(started) * 1000))ms translate=\(Int(Date().timeIntervalSince(recognised) * 1000))ms | \(heard) -> \(english)")
            XCTAssertEqual(DictationTextLanguage.detect(english), "en", item.language)
        }
    }
}
