import Foundation

/// Where dictated text is going, which decides how it is written.
public enum AppCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case personalMessages
    case workMessages
    case email
    case code
    case aiPrompts
    case documents
    case other

    public var id: String { rawValue }

    /// A category written by a newer build decodes as `.other` rather than
    /// failing the whole History or Assistant file.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AppCategory(rawValue: raw) ?? .other
    }

    public var displayName: String {
        switch self {
        case .personalMessages: return "Personal messages"
        case .workMessages: return "Work messages"
        case .email: return "Email"
        case .code: return "Code"
        case .aiPrompts: return "AI prompts"
        case .documents: return "Documents"
        case .other: return "Other"
        }
    }

    public var defaultTone: WritingTone {
        switch self {
        case .personalMessages, .workMessages, .aiPrompts: return .casual
        case .email, .documents, .other: return .formal
        case .code: return .literal
        }
    }

    /// Recognised speech for the Styles screen to render in each tone, so the
    /// example shows what that tone would actually paste.
    public var exampleRecognition: String {
        switch self {
        case .personalMessages: return "running ten minutes late, save me a seat."
        case .workMessages: return "pushed the fix, it should be live after lunch."
        case .email: return "hi Sarah, thanks for the proposal. I'll send my notes by Friday"
        case .code: return "rename fetchUser to loadAccount and update the tests"
        case .aiPrompts: return "summarise this thread and list the open questions."
        case .documents: return "the new onboarding flow cut setup time in half"
        case .other: return "remember to renew the domain before the end of the month"
        }
    }
}

/// How text in a category is written. Open-ended so a later cleanup step can add
/// tones (for example an AI "excited" tone) without a storage migration: a tone
/// this build doesn't know renders by `ruleBased`.
public struct WritingTone: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var id: String { rawValue }

    /// Capitalised, with full end punctuation.
    public static let formal = WritingTone(rawValue: "formal")
    /// Capitalised; a short single-sentence message loses its trailing period.
    public static let casual = WritingTone(rawValue: "casual")
    /// All lowercase, without a trailing period.
    public static let veryCasual = WritingTone(rawValue: "veryCasual")
    /// Exactly as recognised: no vocabulary, corrections or formatting.
    public static let literal = WritingTone(rawValue: "literal")

    /// Earlier per-app styles, reachable only through a migrated override so an
    /// app that had one keeps rendering exactly as it did.
    public static let legacyStandard = WritingTone(rawValue: "standard")
    public static let legacyConversational = WritingTone(rawValue: "conversational")
    public static let legacyPolished = WritingTone(rawValue: "polished")

    /// The tones offered in pickers.
    public static let selectable: [WritingTone] = [.formal, .casual, .veryCasual, .literal]

    public init(legacy style: WritingStyle) {
        switch style {
        case .standard: self = .legacyStandard
        case .conversational: self = .legacyConversational
        case .polished: self = .legacyPolished
        case .literal: self = .literal
        }
    }

    public var isLegacy: Bool { [.legacyStandard, .legacyConversational, .legacyPolished].contains(self) }

    /// The rule-based tone this renders as: itself when known, otherwise formal.
    public var ruleBased: WritingTone {
        Self.selectable.contains(self) || isLegacy ? self : .formal
    }

    public var displayName: String {
        switch self {
        case .formal: return "Formal"
        case .casual: return "Casual"
        case .veryCasual: return "Very casual"
        case .literal: return "Literal"
        case .legacyStandard: return "Standard (earlier style)"
        case .legacyConversational: return "Conversational (earlier style)"
        case .legacyPolished: return "Polished (earlier style)"
        default: return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }

    public var summary: String {
        switch self {
        case .formal: return "Capitalised, with full punctuation."
        case .casual: return "Capitalised. Short messages skip the final period."
        case .veryCasual: return "All lowercase, no final period."
        case .literal: return "Exactly as heard. Best for code and terminals."
        case .legacyStandard: return "Your formatting settings, as before."
        case .legacyConversational: return "Line commands and filler removal, as before."
        case .legacyPolished: return "Line commands, filler removal and capitals, as before."
        default: return "Written as formal on this version."
        }
    }
}

/// The app receiving dictation. The page URL and window title are only read for
/// browsers, stay in memory, and are never logged or stored.
public struct AppContext: Equatable, Sendable {
    public var bundleIdentifier: String?
    public var pageURL: String?
    public var windowTitle: String?

    public init(bundleIdentifier: String?, pageURL: String? = nil, windowTitle: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.pageURL = pageURL
        self.windowTitle = windowTitle
    }
}

/// The built-in knowledge of which apps and websites belong to which category.
public enum AppCategoryRules {
    public struct KnownApp: Equatable, Sendable {
        public let bundleIdentifier: String
        public let name: String
        public let category: AppCategory
    }

    public static let knownApps: [KnownApp] = [
        .init(bundleIdentifier: "com.apple.MobileSMS", name: "Messages", category: .personalMessages),
        .init(bundleIdentifier: "net.whatsapp.WhatsApp", name: "WhatsApp", category: .personalMessages),
        .init(bundleIdentifier: "desktop.WhatsApp", name: "WhatsApp", category: .personalMessages),
        .init(bundleIdentifier: "ru.keepcoder.Telegram", name: "Telegram", category: .personalMessages),
        .init(bundleIdentifier: "com.tdesktop.Telegram", name: "Telegram Desktop", category: .personalMessages),
        .init(bundleIdentifier: "org.whispersystems.signal-desktop", name: "Signal", category: .personalMessages),
        .init(bundleIdentifier: "com.hnc.Discord", name: "Discord", category: .personalMessages),

        .init(bundleIdentifier: "com.tinyspeck.slackmacgap", name: "Slack", category: .workMessages),
        .init(bundleIdentifier: "com.microsoft.teams2", name: "Microsoft Teams", category: .workMessages),
        .init(bundleIdentifier: "com.microsoft.teams", name: "Microsoft Teams (classic)", category: .workMessages),

        .init(bundleIdentifier: "com.apple.mail", name: "Mail", category: .email),
        .init(bundleIdentifier: "com.microsoft.Outlook", name: "Outlook", category: .email),
        .init(bundleIdentifier: "com.superhuman.electron", name: "Superhuman", category: .email),
        .init(bundleIdentifier: "com.readdle.SparkDesktop", name: "Spark", category: .email),
        .init(bundleIdentifier: "com.readdle.smartemail-Mac", name: "Spark Classic", category: .email),

        .init(bundleIdentifier: "com.apple.dt.Xcode", name: "Xcode", category: .code),
        .init(bundleIdentifier: "com.microsoft.VSCode", name: "Visual Studio Code", category: .code),
        .init(bundleIdentifier: "com.microsoft.VSCodeInsiders", name: "VS Code Insiders", category: .code),
        .init(bundleIdentifier: "com.todesktop.230313mzl4w4u92", name: "Cursor", category: .code),
        .init(bundleIdentifier: "com.exafunction.windsurf", name: "Windsurf", category: .code),
        .init(bundleIdentifier: "com.apple.Terminal", name: "Terminal", category: .code),
        .init(bundleIdentifier: "com.googlecode.iterm2", name: "iTerm2", category: .code),
        .init(bundleIdentifier: "com.mitchellh.ghostty", name: "Ghostty", category: .code),
        .init(bundleIdentifier: "dev.warp.Warp-Stable", name: "Warp", category: .code),

        .init(bundleIdentifier: "com.openai.chat", name: "ChatGPT", category: .aiPrompts),
        .init(bundleIdentifier: "com.openai.codex", name: "ChatGPT", category: .aiPrompts),
        .init(bundleIdentifier: "com.anthropic.claudefordesktop", name: "Claude", category: .aiPrompts),

        .init(bundleIdentifier: "com.apple.iWork.Pages", name: "Pages", category: .documents),
        .init(bundleIdentifier: "com.microsoft.Word", name: "Microsoft Word", category: .documents),
        .init(bundleIdentifier: "notion.id", name: "Notion", category: .documents),
        .init(bundleIdentifier: "md.obsidian", name: "Obsidian", category: .documents)
    ]

    public static let browsers: [(bundleIdentifier: String, name: String)] = [
        ("com.apple.Safari", "Safari"),
        ("com.apple.SafariTechnologyPreview", "Safari Technology Preview"),
        ("com.google.Chrome", "Google Chrome"),
        ("com.google.Chrome.beta", "Google Chrome Beta"),
        ("com.google.Chrome.canary", "Google Chrome Canary"),
        ("company.thebrowser.Browser", "Arc"),
        ("com.microsoft.edgemac", "Microsoft Edge"),
        ("org.mozilla.firefox", "Firefox"),
        ("com.brave.Browser", "Brave")
    ]

    /// Web apps by host. A rule also covers the host's subdomains.
    public static let hostCategories: [(host: String, category: AppCategory)] = [
        ("mail.google.com", .email), ("outlook.live.com", .email), ("outlook.office.com", .email),
        ("outlook.office365.com", .email), ("outlook.cloud.microsoft", .email), ("mail.yahoo.com", .email),
        ("app.fastmail.com", .email), ("mail.proton.me", .email), ("mail.superhuman.com", .email), ("app.hey.com", .email),

        ("slack.com", .workMessages), ("teams.microsoft.com", .workMessages), ("teams.live.com", .workMessages),
        ("teams.cloud.microsoft", .workMessages), ("chat.google.com", .workMessages),

        ("web.whatsapp.com", .personalMessages), ("web.telegram.org", .personalMessages),
        ("discord.com", .personalMessages), ("messages.google.com", .personalMessages),
        ("messenger.com", .personalMessages),

        ("chatgpt.com", .aiPrompts), ("chat.openai.com", .aiPrompts), ("claude.ai", .aiPrompts),
        ("gemini.google.com", .aiPrompts), ("perplexity.ai", .aiPrompts), ("copilot.microsoft.com", .aiPrompts),
        ("chat.mistral.ai", .aiPrompts),

        ("docs.google.com", .documents), ("notion.so", .documents), ("notion.site", .documents),
        ("coda.io", .documents), ("paper.dropbox.com", .documents), ("word.cloud.microsoft", .documents),
        ("quip.com", .documents),

        ("vscode.dev", .code), ("github.dev", .code), ("replit.com", .code)
    ]

    /// The web app a browser names at the end of its window title
    /// ("Q3 plan - Google Docs"). Matched only as a whole title segment.
    public static let titleCategories: [String: AppCategory] = [
        "gmail": .email, "outlook": .email, "superhuman": .email, "fastmail": .email,
        "slack": .workMessages, "microsoft teams": .workMessages, "google chat": .workMessages,
        "whatsapp": .personalMessages, "telegram": .personalMessages, "discord": .personalMessages,
        "messenger": .personalMessages,
        "chatgpt": .aiPrompts, "claude": .aiPrompts, "gemini": .aiPrompts, "perplexity": .aiPrompts,
        "google docs": .documents, "notion": .documents, "coda": .documents
    ]

    private static let bundleCategories: [String: AppCategory] = Dictionary(
        knownApps.map { ($0.bundleIdentifier.lowercased(), $0.category) }, uniquingKeysWith: { first, _ in first })
    private static let browserIdentifiers = Set(browsers.map { $0.bundleIdentifier.lowercased() })
    private static let browserTitleNames: Set<String> = Set(browsers.map { $0.name.lowercased() })
        .union(["chrome", "mozilla firefox", "edge", "brave"])

    /// Bundle identifiers are case-insensitive on macOS.
    public static func category(forBundleIdentifier bundleIdentifier: String?) -> AppCategory? {
        bundleIdentifier.flatMap { bundleCategories[$0.lowercased()] }
    }

    public static func isBrowser(_ bundleIdentifier: String?) -> Bool {
        bundleIdentifier.map { browserIdentifiers.contains($0.lowercased()) } ?? false
    }

    /// Accepts a full URL or a bare host ("docs.google.com/document/…").
    public static func category(forPageURL pageURL: String?) -> AppCategory? {
        guard let raw = pageURL?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let withScheme = raw.contains("://") ? raw : "https://" + raw
        guard let host = URL(string: withScheme)?.host?.lowercased() else { return nil }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return hostCategories.first { bare == $0.host || bare.hasSuffix("." + $0.host) }?.category
    }

    /// Browsers title windows "<page> - <web app> - <browser> - <profile>":
    /// drop the browser and anything after it, then match the last segment.
    public static func category(forWindowTitle title: String?) -> AppCategory? {
        guard let title, !title.isEmpty else { return nil }
        var segments = title.components(separatedBy: CharacterSet(charactersIn: "-–—|·"))
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        if let browserIndex = segments.lastIndex(where: { browserTitleNames.contains($0) }) {
            segments.removeSubrange(browserIndex...)
        }
        return segments.last.flatMap { titleCategories[$0] }
    }
}

/// A user's choice for one app. Either field may be unset: moving an app keeps
/// its category's tone, and a tone override keeps the app in its category.
public struct AppStyleOverride: Codable, Equatable, Identifiable, Sendable {
    public var bundleIdentifier: String
    public var category: AppCategory?
    public var tone: WritingTone?
    public var id: String { bundleIdentifier }

    public init(bundleIdentifier: String, category: AppCategory? = nil, tone: WritingTone? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.category = category
        self.tone = tone
    }
}

/// How one dictation was written, and why.
public struct WritingStyleResolution: Equatable, Sendable {
    public enum Source: String, Sendable {
        /// The user moved the app or gave it its own tone.
        case appOverride
        /// A browser tab's URL or title matched a web app.
        case website
        /// The built-in app list.
        case builtInApp
        /// Nothing matched.
        case fallback
    }

    public var category: AppCategory
    public var tone: WritingTone
    public var source: Source

    public init(category: AppCategory, tone: WritingTone, source: Source) {
        self.category = category
        self.tone = tone
        self.source = source
    }
}

public struct WritingStylePreferences: Codable, Equatable, Sendable {
    public static let overrideLimit = 200

    /// Tones the user chose per category, keyed by `AppCategory.rawValue`.
    /// A missing entry uses the category's default.
    public var categoryTones: [String: WritingTone]
    public var overrides: [AppStyleOverride]

    public init(categoryTones: [String: WritingTone] = [:], overrides: [AppStyleOverride] = []) {
        self.categoryTones = categoryTones
        self.overrides = overrides
    }

    /// Each earlier per-app style becomes a tone override on that app, so its
    /// dictation keeps rendering exactly as before.
    public init(migrating profiles: [WritingProfile]) {
        var seen = Set<String>()
        let overrides = profiles.filter { !$0.bundleIdentifier.isEmpty && seen.insert($0.bundleIdentifier.lowercased()).inserted }
            .prefix(Self.overrideLimit)
            .map { AppStyleOverride(bundleIdentifier: $0.bundleIdentifier, tone: WritingTone(legacy: $0.style)) }
        self.init(overrides: Array(overrides))
    }

    public func tone(for category: AppCategory) -> WritingTone {
        categoryTones[category.rawValue] ?? category.defaultTone
    }

    public func override(for bundleIdentifier: String?) -> AppStyleOverride? {
        guard let key = bundleIdentifier?.lowercased() else { return nil }
        return overrides.first { $0.bundleIdentifier.lowercased() == key }
    }

    /// Whether resolving this app could still change once its browser tab is read.
    public func needsWebsiteLookup(bundleIdentifier: String?) -> Bool {
        AppCategoryRules.isBrowser(bundleIdentifier) && override(for: bundleIdentifier)?.category == nil
    }

    /// The single place a destination becomes a category and tone.
    /// Category: per-app override > website rule (URL, then title) > built-in app > Other.
    /// Tone: per-app override > the category's tone.
    public func resolve(_ context: AppContext) -> WritingStyleResolution {
        let appOverride = override(for: context.bundleIdentifier)
        let category: AppCategory
        var source: WritingStyleResolution.Source
        if let pinned = appOverride?.category {
            category = pinned; source = .appOverride
        } else if let website = AppCategoryRules.category(forPageURL: context.pageURL)
                    ?? AppCategoryRules.category(forWindowTitle: context.windowTitle) {
            category = website; source = .website
        } else if let known = AppCategoryRules.category(forBundleIdentifier: context.bundleIdentifier) {
            category = known; source = .builtInApp
        } else {
            category = .other; source = .fallback
        }
        let tone: WritingTone
        if let pinned = appOverride?.tone {
            tone = pinned; source = .appOverride
        } else {
            tone = self.tone(for: category)
        }
        return WritingStyleResolution(category: category, tone: tone, source: source)
    }

    /// The same resolution with only a category known (for example a retry of a
    /// recording whose app is long gone).
    public func resolve(category: AppCategory) -> WritingStyleResolution {
        WritingStyleResolution(category: category, tone: tone(for: category), source: .fallback)
    }

    public mutating func setTone(_ tone: WritingTone, for category: AppCategory) {
        categoryTones[category.rawValue] = tone == category.defaultTone ? nil : tone
    }

    /// Moving an app back to its built-in category clears the category override.
    public mutating func setCategory(_ category: AppCategory?, forApp bundleIdentifier: String) {
        let builtIn = AppCategoryRules.category(forBundleIdentifier: bundleIdentifier)
            ?? (AppCategoryRules.isBrowser(bundleIdentifier) ? nil : .other)
        editOverride(bundleIdentifier) { $0.category = category == builtIn ? nil : category }
    }

    public mutating func setTone(_ tone: WritingTone?, forApp bundleIdentifier: String) {
        editOverride(bundleIdentifier) { $0.tone = tone }
    }

    public mutating func resetApp(_ bundleIdentifier: String) {
        overrides.removeAll { $0.bundleIdentifier.lowercased() == bundleIdentifier.lowercased() }
    }

    private mutating func editOverride(_ bundleIdentifier: String, _ edit: (inout AppStyleOverride) -> Void) {
        guard !bundleIdentifier.isEmpty, bundleIdentifier.count <= 200 else { return }
        var entry = override(for: bundleIdentifier) ?? AppStyleOverride(bundleIdentifier: bundleIdentifier)
        edit(&entry)
        resetApp(bundleIdentifier)
        if entry.category != nil || entry.tone != nil, overrides.count < Self.overrideLimit { overrides.append(entry) }
    }
}
