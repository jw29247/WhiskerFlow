import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WhiskerFlowAppSupport
import WhiskerFlowCore

/// Words to spell right, replacements to apply, and learned corrections waiting
/// for a decision. Replaces the Corrections screen in the same sidebar slot.
struct DictionaryView: View {
    @Bindable var appState: AppState
    @State private var tab: DictionaryTab = .words
    @State private var search = ""
    @State private var sort: DictionarySort = .recent
    @State private var newWord = ""
    @State private var newHeard = ""
    @State private var newWritten = ""
    @State private var issues: [UUID: [DictionaryIssue]] = [:]
    @State private var importMessage: String?
    @State private var confirmClear = false

    init(appState: AppState, initialTab: DictionaryTab = .words) {
        self.appState = appState
        _tab = State(initialValue: initialTab)
        _search = State(initialValue: UIPreview.dictionarySearch)
    }

    private var entries: [DictionaryEntry] { appState.dictionary.entries }
    private var suggestions: [DictionarySuggestion] { appState.dictionarySuggestions }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if let error = appState.dictionary.errorMessage ?? appState.corrections.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
            }
            Picker("", selection: $tab) {
                Text("Words · \(entries.filter { $0.kind == .word }.count)").tag(DictionaryTab.words)
                Text("Replacements · \(entries.filter { $0.kind == .replacement }.count)").tag(DictionaryTab.replacements)
                Text("Suggestions · \(suggestions.count)").tag(DictionaryTab.suggestions)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(FlowStyle.muted)
                TextField("Search", text: $search).textFieldStyle(.plain)
                if tab != .suggestions {
                    Picker("Sort", selection: $sort) {
                        ForEach(DictionarySort.allCases) { Text($0.label).tag($0) }
                    }.fixedSize()
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(FlowStyle.surface, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(FlowStyle.line))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    switch tab {
                    case .words: wordsTab
                    case .replacements: replacementsTab
                    case .suggestions: suggestionsTab
                    }
                }.padding(.bottom, 12)
            }
            footer
        }
        .padding(32)
        .task(id: lintKey) { await refreshIssues() }
        .alert("Import finished", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(importMessage ?? "") }
        .alert("Clear remembered corrections?", isPresented: $confirmClear) {
            Button("Clear corrections", role: .destructive) { appState.corrections.clear() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This removes the correction history behind Suggestions from this Mac. Your Words and Replacements stay as they are.") }
    }

    // MARK: - Header and footer

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Dictionary").font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("Names, jargon and fixes, learned as you go.").foregroundStyle(FlowStyle.muted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Toggle("Remember corrections", isOn: $appState.settings.rememberCorrections)
                    .toggleStyle(.switch).fixedSize()
                Toggle("Automatically add learned words", isOn: $appState.settings.autoAddLearnedWords)
                    .toggleStyle(.switch).fixedSize().disabled(!appState.settings.rememberCorrections)
            }
            Menu {
                Button("Import CSV…", action: importCSV)
                Button("Export CSV…", action: exportCSV).disabled(entries.isEmpty)
                Divider()
                Button("Clear remembered corrections…", role: .destructive) { confirmClear = true }
                    .disabled(appState.corrections.records.isEmpty)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().padding(.leading, 8)
                .accessibilityLabel("Dictionary options")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !appState.hasAccessibilityPermission && appState.settings.rememberCorrections {
                HStack {
                    Label("Allow Accessibility to notice corrections in other apps.", systemImage: "hand.raised").font(.callout)
                    Spacer()
                    Button("Allow Accessibility") { appState.requestAccessibilityPermission() }
                }
            }
            Text("Fix a word after WhiskerFlow pastes it, or edit a transcript in History. A correction seen twice is added automatically unless it would change everyday words or clash with another entry. Learned entries left unused for 90 days go back to Suggestions unless starred. Everything stays on this Mac.")
                .font(.caption).foregroundStyle(FlowStyle.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Words

    @ViewBuilder
    private var wordsTab: some View {
        addRow {
            TextField("Add a name, product or term", text: $newWord).onSubmit(addWord)
                .onChange(of: newWord) { _, value in newWord = String(value.prefix(DictionaryEntry.maximumLength)) }
            Button("Add word", action: addWord)
                .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        let words = visible(entries.filter { $0.kind == .word })
        let readOnly = visibleReadOnly(words: true)
        if words.isEmpty && readOnly.isEmpty {
            FlowEmptyState(symbol: "character.book.closed", title: search.isEmpty ? "No words yet" : "No matching words",
                           detail: "Words teach WhiskerFlow how to spell and capitalise names, products and jargon. Recognisers that accept hints are told to expect them.")
        }
        ForEach(words) { entry in wordRow(entry) }
        readOnlyRows(readOnly)
    }

    private func wordRow(_ entry: DictionaryEntry) -> some View {
        entryCard(entry) {
            TextField("Word", text: text(entry, \.written)).font(.system(size: 15, weight: .medium))
            if !entry.variants.isEmpty {
                Text("Also fixes \(entry.variants.map { "“\($0)”" }.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(FlowStyle.muted)
            }
        }
    }

    // MARK: - Replacements

    @ViewBuilder
    private var replacementsTab: some View {
        addRow {
            TextField("Heard", text: $newHeard)
                .onChange(of: newHeard) { _, value in newHeard = String(value.prefix(DictionaryEntry.maximumLength)) }
            Image(systemName: "arrow.right").foregroundStyle(FlowStyle.muted)
            TextField("Written", text: $newWritten).onSubmit(addReplacement)
                .onChange(of: newWritten) { _, value in newWritten = String(value.prefix(DictionaryEntry.maximumLength)) }
            Button("Add replacement", action: addReplacement)
                .disabled(newHeard.trimmingCharacters(in: .whitespaces).isEmpty
                          || newWritten.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        let replacements = visible(entries.filter { $0.kind == .replacement })
        let readOnly = visibleReadOnly(words: false)
        if replacements.isEmpty && readOnly.isEmpty {
            FlowEmptyState(symbol: "arrow.left.arrow.right", title: search.isEmpty ? "No replacements yet" : "No matching replacements",
                           detail: "Replacements rewrite what the recogniser heard into what you meant, after every dictation.")
        }
        ForEach(replacements) { entry in replacementRow(entry) }
        readOnlyRows(readOnly)
    }

    private func replacementRow(_ entry: DictionaryEntry) -> some View {
        entryCard(entry) {
            HStack(spacing: 10) {
                TextField("Heard", text: text(entry, \.heard)).foregroundStyle(FlowStyle.muted)
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(FlowStyle.muted)
                TextField("Written", text: text(entry, \.written)).fontWeight(.medium)
            }.font(.system(size: 15))
            HStack(spacing: 14) {
                Toggle("Match case", isOn: flag(entry, \.caseSensitive))
                Toggle("Whole word only", isOn: flag(entry, \.wholeWord))
            }.toggleStyle(.checkbox).font(.caption)
        }
    }

    // MARK: - Suggestions

    @ViewBuilder
    private var suggestionsTab: some View {
        let items = suggestions.filter { search.isEmpty || matches($0.pair.heard) || matches($0.pair.written) }
        if items.isEmpty {
            FlowEmptyState(symbol: "text.badge.checkmark", title: "Nothing waiting for a decision",
                           detail: appState.settings.rememberCorrections
                               ? "Corrections you make after a paste, or in History, appear here until they are added or dismissed."
                               : "Turn on Remember corrections to learn from the fixes you make.")
        }
        ForEach(items) { suggestion in suggestionRow(suggestion) }
    }

    private func suggestionRow(_ suggestion: DictionarySuggestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(suggestion.pair.heard).foregroundStyle(FlowStyle.muted).strikethrough()
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(FlowStyle.muted)
                Text(suggestion.pair.written).fontWeight(.medium).textSelection(.enabled)
                kindBadge(suggestion.proposed.kind == .word ? "Word" : "Replacement")
                Spacer()
                Button(suggestion.proposed.kind == .word ? "Add word" : "Add replacement") {
                    appState.acceptDictionarySuggestion(suggestion)
                }
                Button { appState.dismissDictionarySuggestion(suggestion) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Dismiss — don’t suggest this again")
                    .accessibilityLabel("Dismiss \(suggestion.pair.heard) to \(suggestion.pair.written)")
            }.font(.system(size: 15))
            Text(suggestionDetail(suggestion)).font(.caption).foregroundStyle(FlowStyle.muted)
            ForEach(suggestion.issues, id: \.self) { issue in
                Label(issue.message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(16).background(FlowStyle.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(FlowStyle.line, lineWidth: 1))
    }

    private func suggestionDetail(_ suggestion: DictionarySuggestion) -> String {
        var parts: [String] = []
        if let demoted = suggestion.demotedAt {
            parts.append("Moved back \(demoted.formatted(date: .abbreviated, time: .omitted)) after 90 days unused")
        }
        if suggestion.sightings > 0 {
            parts.append("Seen \(suggestion.sightings) \(suggestion.sightings == 1 ? "time" : "times")")
        }
        if !suggestion.applications.isEmpty { parts.append(suggestion.applications.joined(separator: ", ")) }
        if suggestion.demotedAt == nil, let last = suggestion.lastSeen {
            parts.append(last.formatted(date: .abbreviated, time: .omitted))
        }
        if suggestion.demotedAt == nil, suggestion.issues.isEmpty,
           suggestion.sightings < DictionaryLearning.autoAddThreshold, appState.settings.autoAddLearnedWords {
            parts.append("Added automatically if seen again")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Shared pieces

    private func addRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .textFieldStyle(.roundedBorder)
            .padding(.bottom, 6)
    }

    private func entryCard<Content: View>(_ entry: DictionaryEntry, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button { appState.dictionary.toggleStar(entry.id) } label: {
                Image(systemName: entry.starred ? "star.fill" : "star")
                    .foregroundStyle(entry.starred ? Color.yellow : FlowStyle.muted)
            }
            .buttonStyle(.plain).padding(.top, 3)
            .help(entry.starred ? "Starred — never removed automatically" : "Star to keep this entry for good")
            .accessibilityLabel(entry.starred ? "Unstar" : "Star")
            VStack(alignment: .leading, spacing: 8) {
                content().textFieldStyle(.plain)
                HStack(spacing: 8) {
                    Text(usageText(count: entry.useCount, last: entry.lastUsedAt))
                    if entry.origin == .learned { kindBadge("Learned") }
                    if entry.origin == .imported { kindBadge("Imported") }
                }.font(.caption).foregroundStyle(FlowStyle.muted)
                ForEach(issues[entry.id] ?? [], id: \.self) { issue in
                    Label(issue.message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
            Button { appState.dictionary.remove(entry.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(FlowStyle.muted).padding(.top, 3)
                .help("Remove").accessibilityLabel("Remove \(entry.written)")
        }
        .padding(14).background(FlowStyle.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(FlowStyle.line, lineWidth: 1))
    }

    @ViewBuilder
    private func readOnlyRows(_ rules: [DictionaryRule]) -> some View {
        if !rules.isEmpty {
            Text("From your team").font(.system(size: 12, weight: .medium)).foregroundStyle(FlowStyle.muted).padding(.top, 10)
            ForEach(Array(rules.enumerated()), id: \.offset) { _, item in
                let usage = appState.dictionary.dictionary.readOnlyUsage[DictionaryPair(heard: item.rule.find, written: item.rule.replaceWith).key]
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Image(systemName: "lock").font(.caption).foregroundStyle(FlowStyle.muted).frame(width: 16)
                    if item.rule.find.lowercased() != item.rule.replaceWith.lowercased() {
                        Text(item.rule.find).foregroundStyle(FlowStyle.muted)
                        Image(systemName: "arrow.right").font(.caption).foregroundStyle(FlowStyle.muted)
                    }
                    Text(item.rule.replaceWith).fontWeight(.medium)
                    kindBadge(item.source.shortLabel)
                    Spacer()
                    Text(usageText(count: usage?.count ?? 0, last: usage?.lastUsedAt)).font(.caption).foregroundStyle(FlowStyle.muted)
                }
                .font(.system(size: 14)).padding(.horizontal, 14).padding(.vertical, 10)
                .background(FlowStyle.canvas, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(FlowStyle.line, style: StrokeStyle(lineWidth: 1, dash: [3])))
                .help("Read-only. Managed in \(item.source.label.lowercased()).")
            }
        }
    }

    private func kindBadge(_ label: String) -> some View {
        Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(FlowStyle.accent)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(FlowStyle.selection, in: Capsule())
    }

    private func usageText(count: Int, last: Date?) -> String {
        guard count > 0 else { return "Not used yet" }
        let times = "Applied \(count) \(count == 1 ? "time" : "times")"
        guard let last else { return times }
        return times + " · last used " + last.formatted(.relative(presentation: .named))
    }

    // MARK: - Filtering

    private func matches(_ text: String) -> Bool { text.localizedCaseInsensitiveContains(search) }

    private func visible(_ list: [DictionaryEntry]) -> [DictionaryEntry] {
        let filtered = search.isEmpty ? list : list.filter {
            matches($0.written) || matches($0.heard) || $0.variants.contains(where: matches)
        }
        switch sort {
        case .recent: return filtered.sorted { $0.addedAt > $1.addedAt }
        case .usage: return filtered.sorted { ($0.useCount, $0.lastActivity) > ($1.useCount, $1.lastActivity) }
        case .alphabetical: return filtered.sorted { $0.written.localizedCaseInsensitiveCompare($1.written) == .orderedAscending }
        }
    }

    private func visibleReadOnly(words: Bool) -> [DictionaryRule] {
        let usage = appState.dictionary.dictionary.readOnlyUsage
        let filtered = appState.readOnlyDictionaryRules.filter {
            ($0.rule.find.lowercased() == $0.rule.replaceWith.lowercased()) == words
                && (search.isEmpty || matches($0.rule.find) || matches($0.rule.replaceWith))
        }
        guard sort != .recent else { return filtered }
        func count(_ rule: DictionaryRule) -> Int { usage[DictionaryPair(heard: rule.rule.find, written: rule.rule.replaceWith).key]?.count ?? 0 }
        return sort == .usage
            ? filtered.sorted { count($0) > count($1) }
            : filtered.sorted { $0.rule.replaceWith.localizedCaseInsensitiveCompare($1.rule.replaceWith) == .orderedAscending }
    }

    // MARK: - Editing

    private func current(_ id: UUID) -> DictionaryEntry? { entries.first { $0.id == id } }

    private func text(_ entry: DictionaryEntry, _ keyPath: WritableKeyPath<DictionaryEntry, String>) -> Binding<String> {
        Binding(
            get: { current(entry.id)?[keyPath: keyPath] ?? "" },
            set: { value in
                guard var updated = current(entry.id) else { return }
                updated[keyPath: keyPath] = String(value.prefix(DictionaryEntry.maximumLength))
                appState.dictionary.replace(updated)
            })
    }

    private func flag(_ entry: DictionaryEntry, _ keyPath: WritableKeyPath<DictionaryEntry, Bool>) -> Binding<Bool> {
        Binding(
            get: { current(entry.id)?[keyPath: keyPath] ?? false },
            set: { value in
                guard var updated = current(entry.id) else { return }
                updated[keyPath: keyPath] = value
                appState.dictionary.replace(updated)
            })
    }

    private func addWord() {
        let word = newWord.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else { return }
        appState.dictionary.add(.word(word))
        newWord = ""
    }

    private func addReplacement() {
        let heard = newHeard.trimmingCharacters(in: .whitespaces)
        let written = newWritten.trimmingCharacters(in: .whitespaces)
        guard !heard.isEmpty, !written.isEmpty else { return }
        appState.dictionary.add(.replacement(heard, written))
        newHeard = ""
        newWritten = ""
    }

    /// Lint runs on a background task: checking every entry against every other
    /// compiles a regex per pair, too slow to do on each keystroke.
    private var lintKey: [DictionaryEntry] { entries }

    private func refreshIssues() async {
        let personal = appState.dictionary.dictionary
        let readOnly = appState.readOnlyDictionaryRules
        let result = await Task.detached(priority: .utility) { () -> [UUID: [DictionaryIssue]] in
            let rules = readOnly + DictionaryRule.personal(personal)
            var result: [UUID: [DictionaryIssue]] = [:]
            for entry in personal.entries {
                let found = DictionaryLint.issues(for: entry, against: rules)
                if !found.isEmpty { result[entry.id] = found }
            }
            return result
        }.value
        guard !Task.isCancelled else { return }
        issues = result
    }

    // MARK: - CSV

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let report = try DictionaryCSV.importEntries(from: text, existing: entries)
            appState.dictionary.update { $0.entries.append(contentsOf: report.entries) }
            var lines = ["Added \(report.entries.count) \(report.entries.count == 1 ? "entry" : "entries")."]
            if report.duplicateCount > 0 { lines.append("Skipped \(report.duplicateCount) already in your dictionary.") }
            for problem in report.problems.prefix(5) { lines.append("Line \(problem.line): \(problem.message)") }
            if report.problems.count > 5 { lines.append("…and \(report.problems.count - 5) more rows that couldn’t be read.") }
            importMessage = lines.joined(separator: "\n")
        } catch {
            importMessage = error.localizedDescription
        }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "WhiskerFlow Dictionary.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try DictionaryCSV.export(entries).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            importMessage = "Could not export: \(error.localizedDescription)"
        }
    }
}

enum DictionaryTab: String, Hashable { case words, replacements, suggestions }

private enum DictionarySort: String, CaseIterable, Identifiable {
    case recent, usage, alphabetical
    var id: String { rawValue }
    var label: String {
        switch self {
        case .recent: return "Recently added"
        case .usage: return "Most used"
        case .alphabetical: return "A–Z"
        }
    }
}

private extension DictionarySource {
    var shortLabel: String {
        switch self {
        case .personal: return "Yours"
        case .shared: return "Shared library"
        case .client(let name): return "Client · \(name)"
        }
    }
}
