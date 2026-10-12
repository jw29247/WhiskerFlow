import AppKit
import SwiftUI
import WhiskerFlowCore

/// One card per app category: its tone, a live example, and the apps in it.
struct StylesView: View {
    let assistant: AssistantController
    let formatting: FormattingOptions
    @State private var apps: [StyleApp] = []

    private var styles: WritingStylePreferences { assistant.writingStyles }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Each app belongs to a category, and each category has a tone. Styles are rules applied on this Mac; nothing is sent anywhere.")
                .font(.callout).foregroundStyle(FlowStyle.muted)
            // Eight cards: a plain grid, so every card exists (a lazy grid skips
            // off-screen cards, which hides them from accessibility).
            Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 16) {
                ForEach(Array(stride(from: 0, to: AppCategory.allCases.count + 1, by: 2)), id: \.self) { index in
                    GridRow(alignment: .top) {
                        card(at: index)
                        card(at: index + 1)
                    }
                }
            }
        }
        .onAppear { apps = StyleApp.catalog(including: styles.overrides.map(\.bundleIdentifier)) }
    }

    /// Categories in order, then the browsers card.
    @ViewBuilder
    private func card(at index: Int) -> some View {
        let categories = AppCategory.allCases
        if index < categories.count {
            let category = categories[index]
            CategoryCard(category: category, styles: styles, formatting: formatting,
                         apps: apps(in: category), candidates: apps, edit: assistant.editWritingStyles)
        } else if index == categories.count {
            browsersCard
        }
    }

    /// A browser follows its tab unless the user pinned it to a category.
    private func apps(in category: AppCategory) -> [StyleApp] {
        apps.filter { app in
            guard !app.isBrowser || styles.override(for: app.bundleIdentifier)?.category != nil else { return false }
            return styles.resolve(AppContext(bundleIdentifier: app.bundleIdentifier)).category == category
        }
    }

    private var browsersCard: some View {
        let browsers = apps.filter { $0.isBrowser && styles.needsWebsiteLookup(bundleIdentifier: $0.bundleIdentifier) }
        return StyleCard {
            Label("Browsers", systemImage: "globe").font(.headline)
            Text("Sorted by the website you're on: Gmail is Email, Slack is Work messages, ChatGPT and Claude are AI prompts, Google Docs is Documents. Other websites use Other. The page is read with Accessibility and never saved.")
                .font(.caption).foregroundStyle(FlowStyle.muted).fixedSize(horizontal: false, vertical: true)
            if browsers.isEmpty {
                Text("No browsers found.").font(.caption).foregroundStyle(FlowStyle.muted)
            }
            ForEach(browsers) { app in
                AppStyleRow(app: app, styles: styles, edit: assistant.editWritingStyles)
            }
        }
    }
}

private struct CategoryCard: View {
    let category: AppCategory
    let styles: WritingStylePreferences
    let formatting: FormattingOptions
    let apps: [StyleApp]
    let candidates: [StyleApp]
    let edit: ((inout WritingStylePreferences) -> Void) -> Void
    @State private var showsAll = false
    private static let collapsedCount = 5

    private var tone: WritingTone { styles.tone(for: category) }
    private var example: String {
        AssistantTextProcessing.process(category.exampleRecognition, tone: tone, vocabulary: Vocabulary(),
                                        formatting: formatting, recognizeCorrections: false)
    }

    var body: some View {
        StyleCard {
            HStack {
                Label(category.displayName, systemImage: category.symbol).font(.headline)
                Spacer()
                Picker("Tone", selection: Binding(get: { tone }, set: { value in edit { $0.setTone(value, for: category) } })) {
                    ForEach(WritingTone.selectable) { Text($0.displayName).tag($0) }
                }
                .labelsHidden().fixedSize()
                .accessibilityLabel("\(category.displayName) tone")
            }
            Text(tone.summary).font(.caption).foregroundStyle(FlowStyle.muted)
            Text(example)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(FlowStyle.canvas, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Example: \(example)")
            if apps.isEmpty {
                Text("No apps yet.").font(.caption).foregroundStyle(FlowStyle.muted)
            }
            ForEach(showsAll ? apps : Array(apps.prefix(Self.collapsedCount))) { app in
                AppStyleRow(app: app, styles: styles, edit: edit)
            }
            HStack {
                if apps.count > Self.collapsedCount {
                    Button(showsAll ? "Show fewer" : "Show \(apps.count - Self.collapsedCount) more") { showsAll.toggle() }
                        .buttonStyle(.plain).foregroundStyle(FlowStyle.accent).font(.caption)
                }
                Spacer()
                Menu("Add app") {
                    ForEach(candidates.filter { !apps.contains($0) }) { app in
                        Button(app.name) { edit { $0.setCategory(category, forApp: app.bundleIdentifier) } }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize().font(.caption)
            }
        }
    }
}

private struct AppStyleRow: View {
    let app: StyleApp
    let styles: WritingStylePreferences
    let edit: ((inout WritingStylePreferences) -> Void) -> Void

    var body: some View {
        let override = styles.override(for: app.bundleIdentifier)
        HStack(spacing: 8) {
            Image(nsImage: app.icon).resizable().frame(width: 18, height: 18).accessibilityHidden(true)
            Text(app.name).font(.callout).lineLimit(1)
            if let tone = override?.tone {
                Text(tone.displayName).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(FlowStyle.selection, in: Capsule())
            }
            Spacer()
            Menu {
                Section("Move to") {
                    ForEach(AppCategory.allCases) { category in
                        Button {
                            edit { $0.setCategory(category, forApp: app.bundleIdentifier) }
                        } label: {
                            if styles.resolve(AppContext(bundleIdentifier: app.bundleIdentifier)).category == category,
                               !app.isBrowser || override?.category != nil {
                                Label(category.displayName, systemImage: "checkmark")
                            } else {
                                Text(category.displayName)
                            }
                        }
                    }
                    if app.isBrowser, override?.category != nil {
                        Button("Follow the website") { edit { $0.setCategory(nil, forApp: app.bundleIdentifier) } }
                    }
                }
                Section("Tone for \(app.name)") {
                    Button {
                        edit { $0.setTone(nil, forApp: app.bundleIdentifier) }
                    } label: {
                        if override?.tone == nil {
                            Label("Category tone", systemImage: "checkmark")
                        } else {
                            Text("Category tone")
                        }
                    }
                    ForEach(tones(current: override?.tone)) { tone in
                        Button {
                            edit { $0.setTone(tone, forApp: app.bundleIdentifier) }
                        } label: {
                            if override?.tone == tone {
                                Label(tone.displayName, systemImage: "checkmark")
                            } else {
                                Text(tone.displayName)
                            }
                        }
                    }
                }
                if override != nil {
                    Divider()
                    Button("Reset \(app.name)") { edit { $0.resetApp(app.bundleIdentifier) } }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Style options for \(app.name)")
        }
    }

    /// A migrated earlier style stays selectable while it is the app's tone.
    private func tones(current: WritingTone?) -> [WritingTone] {
        guard let current, !WritingTone.selectable.contains(current) else { return WritingTone.selectable }
        return WritingTone.selectable + [current]
    }
}

private struct StyleCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(FlowStyle.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(FlowStyle.line, lineWidth: 1))
    }
}

/// An app the Styles screen can show: installed built-ins and browsers, apps
/// the user has styled, and whatever is running now.
struct StyleApp: Identifiable, Hashable {
    let bundleIdentifier: String
    let name: String
    let icon: NSImage
    let isBrowser: Bool
    var id: String { bundleIdentifier.lowercased() }

    static func == (lhs: StyleApp, rhs: StyleApp) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    @MainActor
    static func catalog(including styled: [String]) -> [StyleApp] {
        let workspace = NSWorkspace.shared
        var seen = Set<String>()
        var result: [StyleApp] = []
        func add(_ bundleIdentifier: String, name fallback: String?, requireInstalled: Bool) {
            guard seen.insert(bundleIdentifier.lowercased()).inserted else { return }
            let url = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier)
            if requireInstalled, url == nil { seen.remove(bundleIdentifier.lowercased()); return }
            let name = url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
                ?? fallback ?? bundleIdentifier
            let icon = url.map { workspace.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
            result.append(StyleApp(bundleIdentifier: bundleIdentifier, name: name, icon: icon,
                                   isBrowser: AppCategoryRules.isBrowser(bundleIdentifier)))
        }
        for app in AppCategoryRules.knownApps { add(app.bundleIdentifier, name: app.name, requireInstalled: true) }
        for browser in AppCategoryRules.browsers { add(browser.bundleIdentifier, name: browser.name, requireInstalled: true) }
        for bundleIdentifier in styled { add(bundleIdentifier, name: nil, requireInstalled: false) }
        let ownIdentifier = Bundle.main.bundleIdentifier?.lowercased()
        for app in workspace.runningApplications where app.activationPolicy == .regular {
            guard let bundleIdentifier = app.bundleIdentifier, bundleIdentifier.lowercased() != ownIdentifier else { continue }
            add(bundleIdentifier, name: app.localizedName, requireInstalled: false)
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

extension AppCategory {
    var symbol: String {
        switch self {
        case .personalMessages: return "bubble.left.and.bubble.right"
        case .workMessages: return "briefcase"
        case .email: return "envelope"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .aiPrompts: return "sparkles"
        case .documents: return "doc.text"
        case .other: return "square.grid.2x2"
        }
    }
}
