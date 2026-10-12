import Foundation
import XCTest
@testable import WhiskerFlowCore

final class AppCategoryTests: XCTestCase {
    // MARK: - Built-in mapping

    func testBuiltInAppsMapToTheirCategories() {
        let expected: [String: AppCategory] = [
            "com.apple.MobileSMS": .personalMessages, "net.whatsapp.WhatsApp": .personalMessages,
            "ru.keepcoder.Telegram": .personalMessages, "org.whispersystems.signal-desktop": .personalMessages,
            "com.hnc.Discord": .personalMessages,
            "com.tinyspeck.slackmacgap": .workMessages, "com.microsoft.teams2": .workMessages,
            "com.apple.mail": .email, "com.microsoft.Outlook": .email, "com.superhuman.electron": .email,
            "com.readdle.SparkDesktop": .email,
            "com.apple.dt.Xcode": .code, "com.microsoft.VSCode": .code, "com.todesktop.230313mzl4w4u92": .code,
            "com.exafunction.windsurf": .code, "com.apple.Terminal": .code, "com.googlecode.iterm2": .code,
            "com.mitchellh.ghostty": .code, "dev.warp.Warp-Stable": .code,
            "com.openai.chat": .aiPrompts, "com.anthropic.claudefordesktop": .aiPrompts,
            "com.apple.iWork.Pages": .documents, "com.microsoft.Word": .documents, "notion.id": .documents,
            "md.obsidian": .documents
        ]
        for (bundle, category) in expected {
            XCTAssertEqual(AppCategoryRules.category(forBundleIdentifier: bundle), category, bundle)
        }
        XCTAssertEqual(AppCategoryRules.category(forBundleIdentifier: "COM.APPLE.MAIL"), .email, "bundle IDs are case-insensitive")
        XCTAssertNil(AppCategoryRules.category(forBundleIdentifier: "com.example.unknown"))
        XCTAssertNil(AppCategoryRules.category(forBundleIdentifier: nil))
        XCTAssertEqual(Set(AppCategoryRules.knownApps.map { $0.bundleIdentifier.lowercased() }).count,
                       AppCategoryRules.knownApps.count, "no app is listed twice")
    }

    func testDefaultTonesPerCategory() {
        XCTAssertEqual(AppCategory.personalMessages.defaultTone, .casual)
        XCTAssertEqual(AppCategory.workMessages.defaultTone, .casual)
        XCTAssertEqual(AppCategory.email.defaultTone, .formal)
        XCTAssertEqual(AppCategory.code.defaultTone, .literal)
        XCTAssertEqual(AppCategory.aiPrompts.defaultTone, .casual)
        XCTAssertEqual(AppCategory.documents.defaultTone, .formal)
        XCTAssertEqual(AppCategory.other.defaultTone, .formal)
    }

    func testBrowsersAreRecognised() {
        for bundle in ["com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "com.microsoft.edgemac", "org.mozilla.firefox"] {
            XCTAssertTrue(AppCategoryRules.isBrowser(bundle), bundle)
        }
        XCTAssertFalse(AppCategoryRules.isBrowser("com.apple.mail"))
        XCTAssertFalse(AppCategoryRules.isBrowser(nil))
    }

    // MARK: - Website rules

    func testPageURLRules() {
        let expected: [String: AppCategory] = [
            "https://mail.google.com/mail/u/0/#inbox": .email,
            "https://outlook.office.com/mail/": .email,
            "https://app.slack.com/client/T01/C02": .workMessages,
            "https://acme.slack.com/archives/C02": .workMessages,
            "https://teams.microsoft.com/v2/": .workMessages,
            "https://chatgpt.com/c/abc": .aiPrompts,
            "https://claude.ai/new": .aiPrompts,
            "https://docs.google.com/document/d/1/edit": .documents,
            "https://www.notion.so/acme/Plan-123": .documents,
            "https://web.whatsapp.com/": .personalMessages,
            "docs.google.com/spreadsheets/d/1": .documents
        ]
        for (url, category) in expected {
            XCTAssertEqual(AppCategoryRules.category(forPageURL: url), category, url)
        }
        XCTAssertNil(AppCategoryRules.category(forPageURL: "https://en.wikipedia.org/wiki/Claude"))
        XCTAssertNil(AppCategoryRules.category(forPageURL: "https://notslack.com/"), "a suffix must be a whole domain label")
        XCTAssertNil(AppCategoryRules.category(forPageURL: "https://google.com/"))
        XCTAssertNil(AppCategoryRules.category(forPageURL: ""))
        XCTAssertNil(AppCategoryRules.category(forPageURL: nil))
    }

    func testWindowTitleRules() {
        XCTAssertEqual(AppCategoryRules.category(forWindowTitle: "Inbox (3) - someone@example.com - Gmail"), .email)
        XCTAssertEqual(AppCategoryRules.category(forWindowTitle: "Q3 plan - Google Docs - Google Chrome - Work"), .documents)
        XCTAssertEqual(AppCategoryRules.category(forWindowTitle: "general (Channel) - Acme - Slack"), .workMessages)
        XCTAssertEqual(AppCategoryRules.category(forWindowTitle: "ChatGPT"), .aiPrompts)
        XCTAssertEqual(AppCategoryRules.category(forWindowTitle: "Claude — Mozilla Firefox"), .aiPrompts)
        XCTAssertNil(AppCategoryRules.category(forWindowTitle: "Claude Monet - Wikipedia"))
        XCTAssertNil(AppCategoryRules.category(forWindowTitle: "Google Chrome"))
        XCTAssertNil(AppCategoryRules.category(forWindowTitle: nil))
    }

    // MARK: - Precedence

    func testPrecedenceIsOverrideThenURLThenBundleThenOther() {
        var preferences = WritingStylePreferences()
        let gmailInSafari = AppContext(bundleIdentifier: "com.apple.Safari", pageURL: "https://mail.google.com/")
        XCTAssertEqual(preferences.resolve(gmailInSafari), .init(category: .email, tone: .formal, source: .website))

        // URL rule beats the built-in app mapping.
        let claudeInSlack = AppContext(bundleIdentifier: "com.tinyspeck.slackmacgap", pageURL: "https://claude.ai/")
        XCTAssertEqual(preferences.resolve(claudeInSlack).category, .aiPrompts)

        // Built-in app mapping, then Other.
        XCTAssertEqual(preferences.resolve(AppContext(bundleIdentifier: "com.tinyspeck.slackmacgap")),
                       .init(category: .workMessages, tone: .casual, source: .builtInApp))
        XCTAssertEqual(preferences.resolve(AppContext(bundleIdentifier: "com.example.unknown")),
                       .init(category: .other, tone: .formal, source: .fallback))
        XCTAssertEqual(preferences.resolve(AppContext(bundleIdentifier: nil)).category, .other)
        XCTAssertEqual(preferences.resolve(AppContext(bundleIdentifier: "com.apple.Safari")).category, .other,
                       "an unreadable tab falls back to Other")

        // A per-app category override beats the URL rule.
        preferences.setCategory(.documents, forApp: "com.apple.Safari")
        XCTAssertEqual(preferences.resolve(gmailInSafari), .init(category: .documents, tone: .formal, source: .appOverride))
        XCTAssertFalse(preferences.needsWebsiteLookup(bundleIdentifier: "com.apple.Safari"))
        XCTAssertTrue(preferences.needsWebsiteLookup(bundleIdentifier: "com.google.Chrome"))
        XCTAssertFalse(preferences.needsWebsiteLookup(bundleIdentifier: "com.apple.mail"))
    }

    func testTonePrecedenceIsAppThenCategoryThenDefault() {
        var preferences = WritingStylePreferences()
        let mail = AppContext(bundleIdentifier: "com.apple.mail")
        XCTAssertEqual(preferences.resolve(mail).tone, .formal)
        preferences.setTone(.casual, for: .email)
        XCTAssertEqual(preferences.resolve(mail).tone, .casual)
        XCTAssertEqual(preferences.resolve(mail).source, .builtInApp)
        preferences.setTone(.veryCasual, forApp: "com.apple.mail")
        XCTAssertEqual(preferences.resolve(mail), .init(category: .email, tone: .veryCasual, source: .appOverride))

        // A tone override on a browser keeps website categorisation.
        preferences.setTone(.literal, forApp: "com.google.Chrome")
        let docs = AppContext(bundleIdentifier: "com.google.Chrome", pageURL: "https://docs.google.com/")
        XCTAssertEqual(preferences.resolve(docs).category, .documents)
        XCTAssertEqual(preferences.resolve(docs).tone, .literal)

        preferences.setTone(nil, forApp: "com.apple.mail")
        XCTAssertEqual(preferences.resolve(mail).tone, .casual)
        preferences.setTone(.formal, for: .email)
        XCTAssertTrue(preferences.categoryTones.isEmpty, "choosing the default stores nothing")
    }

    func testMovingAnAppBackToItsBuiltInCategoryClearsTheOverride() {
        var preferences = WritingStylePreferences()
        preferences.setCategory(.personalMessages, forApp: "com.tinyspeck.slackmacgap")
        XCTAssertEqual(preferences.resolve(AppContext(bundleIdentifier: "com.tinyspeck.slackmacgap")).category, .personalMessages)
        preferences.setCategory(.workMessages, forApp: "com.tinyspeck.slackmacgap")
        XCTAssertTrue(preferences.overrides.isEmpty)

        preferences.setCategory(.code, forApp: "com.example.editor")
        XCTAssertEqual(preferences.resolve(AppContext(bundleIdentifier: "COM.EXAMPLE.EDITOR")).category, .code)
        preferences.setCategory(.other, forApp: "com.example.editor")
        XCTAssertTrue(preferences.overrides.isEmpty)

        preferences.setCategory(.email, forApp: "com.example.x")
        preferences.setTone(.casual, forApp: "com.example.x")
        XCTAssertEqual(preferences.overrides, [.init(bundleIdentifier: "com.example.x", category: .email, tone: .casual)])
        preferences.resetApp("com.example.x")
        XCTAssertTrue(preferences.overrides.isEmpty)
        preferences.setCategory(.email, forApp: "")
        XCTAssertTrue(preferences.overrides.isEmpty)
    }

    // MARK: - Migration

    func testLegacyProfilesMigrateToOverridesWithIdenticalOutput() {
        let profiles = [
            WritingProfile(bundleIdentifier: "com.apple.mail", style: .conversational),
            WritingProfile(bundleIdentifier: "com.example.notes", style: .polished),
            WritingProfile(bundleIdentifier: "com.apple.Terminal", style: .literal),
            WritingProfile(bundleIdentifier: "com.apple.mail", style: .polished), // a duplicate keeps the first
            WritingProfile(bundleIdentifier: "", style: .polished)
        ]
        let preferences = WritingStylePreferences(migrating: profiles)
        XCTAssertEqual(preferences.overrides, [
            .init(bundleIdentifier: "com.apple.mail", tone: .legacyConversational),
            .init(bundleIdentifier: "com.example.notes", tone: .legacyPolished),
            .init(bundleIdentifier: "com.apple.Terminal", tone: .literal)
        ])
        XCTAssertTrue(preferences.categoryTones.isEmpty)

        // The migrated tone renders exactly what the old style did.
        let raw = "um hello there new line how are you."
        let formatting = FormattingOptions()
        XCTAssertEqual(process(raw, preferences.resolve(AppContext(bundleIdentifier: "com.apple.mail")).tone, formatting),
                       "hello there\nhow are you.")
        XCTAssertEqual(process(raw, preferences.resolve(AppContext(bundleIdentifier: "com.example.notes")).tone, formatting),
                       "Hello there\nHow are you.")
        XCTAssertEqual(process(raw, preferences.resolve(AppContext(bundleIdentifier: "com.apple.Terminal")).tone, formatting), raw)
        // Categories still apply: migrated Mail is an Email app with its old tone.
        XCTAssertEqual(preferences.resolve(AppContext(bundleIdentifier: "com.apple.mail")).category, .email)
        XCTAssertEqual(WritingTone(legacy: .standard), .legacyStandard)
        XCTAssertEqual(process("um hi", .legacyStandard, .init(removeFillerWords: true)), "hi")
    }

    func testPreferencesAndRecordsDecodeTolerantly() throws {
        let json = #"{"categoryTones":{"email":"excited","futureCategory":"casual"},"overrides":[{"bundleIdentifier":"a","category":"futureCategory"}]}"#
        let decoded = try JSONDecoder().decode(WritingStylePreferences.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.tone(for: .email), WritingTone(rawValue: "excited"), "a newer tone survives")
        XCTAssertEqual(decoded.overrides.first?.category, .other, "an unknown category reads as Other")
        XCTAssertEqual(WritingTone(rawValue: "excited").ruleBased, .formal)
        XCTAssertEqual(WritingToneRenderer.render("hello there", tone: WritingTone(rawValue: "excited")), "Hello there.")

        let preferences = WritingStylePreferences(categoryTones: ["code": .formal], overrides: [.init(bundleIdentifier: "b", tone: .casual)])
        XCTAssertEqual(try JSONDecoder().decode(WritingStylePreferences.self, from: JSONEncoder().encode(preferences)), preferences)

        let legacyRecord = #"{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","text":"hi","audioFilePath":"","createdAt":0,"status":{"transcribed":{}}}"#
        let record = try JSONDecoder().decode(TranscriptRecord.self, from: Data(legacyRecord.utf8))
        XCTAssertNil(record.appCategory)
        var tagged = record; tagged.appCategory = .email
        XCTAssertEqual(try JSONDecoder().decode(TranscriptRecord.self, from: JSONEncoder().encode(tagged)).appCategory, .email)
    }

    // MARK: - Tones

    func testFormalCapitalisesAndCompletesPunctuation() {
        XCTAssertEqual(render("hi Sarah, thanks for the proposal. i'll reply by friday", .formal),
                       "Hi Sarah, thanks for the proposal. I'll reply by friday.")
        XCTAssertEqual(render("are you free?", .formal), "Are you free?")
        XCTAssertEqual(render("Hi Sarah,", .formal), "Hi Sarah,", "a chosen comma stays")
        XCTAssertEqual(render("first line\nsecond line", .formal), "First line\nSecond line.")
        XCTAssertEqual(render("iPhone sales are up", .formal), "iPhone sales are up.")
        XCTAssertEqual(render("我们明天见", .formal), "我们明天见", "no Latin period on CJK text")
        XCTAssertEqual(render("", .formal), "")
    }

    func testCasualDropsThePeriodOnlyFromShortSingleSentences() {
        XCTAssertEqual(render("running ten minutes late, save me a seat.", .casual), "Running ten minutes late, save me a seat")
        // Questions and exclamations keep their mark.
        XCTAssertEqual(render("are you free tonight?", .casual), "Are you free tonight?")
        XCTAssertEqual(render("that's amazing!", .casual), "That's amazing!")
        // More than one sentence keeps full punctuation.
        XCTAssertEqual(render("I'm running late. Start without me.", .casual), "I'm running late. Start without me.")
        XCTAssertEqual(render("Can you make it? Let me know.", .casual), "Can you make it? Let me know.")
        XCTAssertEqual(render("line one.\nline two.", .casual), "Line one.\nLine two.")
        // A long message keeps its period.
        let long = "this is a much longer message that goes on for quite a while because it has a lot of detail to share today."
        XCTAssertTrue(render(long, .casual).hasSuffix("today."))
        // Abbreviations and ellipses aren't sentence ends, so they neither split nor lose a dot.
        XCTAssertEqual(render("see you at 5 p.m.", .casual), "See you at 5 p.m.")
        XCTAssertEqual(render("bring snacks, e.g. chips.", .casual), "Bring snacks, e.g. chips")
        XCTAssertEqual(render("well...", .casual), "Well...")
        XCTAssertEqual(render("no punctuation here", .casual), "No punctuation here", "nothing is added")
    }

    func testTextEndingInAURL() {
        XCTAssertEqual(render("here's the link https://example.com/Docs/A.b", .formal),
                       "Here's the link https://example.com/Docs/A.b", "no period joins the URL")
        XCTAssertEqual(render("the site is example.com", .formal), "The site is example.com")
        XCTAssertEqual(render("email me at jo@example.com", .formal), "Email me at jo@example.com")
        XCTAssertEqual(render("check out example.com.", .casual), "Check out example.com", "the sentence's period goes, the domain stays")
        XCTAssertEqual(render("see https://example.com/a.b", .casual), "See https://example.com/a.b", "the URL keeps its dot")
        XCTAssertEqual(render("go to example.com. then sign in.", .casual), "Go to example.com. Then sign in.",
                       "a domain followed by a period still ends a sentence")
        XCTAssertEqual(render("https://example.com is down.", .casual), "https://example.com is down",
                       "a URL at the start isn't capitalised")
        XCTAssertEqual(render("Look at https://Example.com/AbC.", .veryCasual), "look at https://Example.com/AbC",
                       "very casual keeps the URL's case")
    }

    func testVeryCasualLowercasesAndDropsTheTrailingPeriod() {
        XCTAssertEqual(render("Running late. See you soon.", .veryCasual), "running late. see you soon")
        XCTAssertEqual(render("Are You Coming?", .veryCasual), "are you coming?")
        XCTAssertEqual(render("I'll be there at 5 P.M.", .veryCasual), "i'll be there at 5 p.m.")
        XCTAssertEqual(render("Try WhiskerFlow on your iPhone, OK.", .veryCasual), "try WhiskerFlow on your iPhone, ok",
                           "mixed-case names keep their spelling")
    }

    func testLiteralIsUntouched() {
        let raw = "  um git commit -m fix.  "
        XCTAssertEqual(render(raw, .literal), raw)
        XCTAssertEqual(process(raw, .literal, .init(spokenLineCommands: true, removeFillerWords: true)), raw)
    }

    func testTonesKeepTheUsersCleanupSettings() {
        let raw = "um thanks new line talk soon."
        XCTAssertEqual(process(raw, .casual, .init()), "Um thanks new line talk soon")
        XCTAssertEqual(process(raw, .casual, .init(spokenLineCommands: true, removeFillerWords: true)), "Thanks\nTalk soon.")
        XCTAssertEqual(process("Send it to Mark, sorry, Marc.", .formal, .init(), corrections: true), "Send it to Marc.")
    }

    func testEveryCategoryExampleRendersInEveryTone() {
        for category in AppCategory.allCases {
            for tone in WritingTone.selectable {
                XCTAssertFalse(render(category.exampleRecognition, tone).isEmpty, "\(category) \(tone)")
            }
            XCTAssertNotEqual(render(category.exampleRecognition, .formal), render(category.exampleRecognition, .veryCasual))
        }
    }

    private func render(_ text: String, _ tone: WritingTone) -> String { WritingToneRenderer.render(text, tone: tone) }

    private func process(_ raw: String, _ tone: WritingTone, _ formatting: FormattingOptions, corrections: Bool = false) -> String {
        AssistantTextProcessing.process(raw, tone: tone, vocabulary: Vocabulary(), formatting: formatting,
                                        recognizeCorrections: corrections)
    }
}
