import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WhiskerFlowAppSupport

/// The list of meetings kept on this Mac, newest and in-progress first.
struct MeetingLibraryList: View {
    @Bindable var appState: AppState
    let open: (UUID) -> Void

    var body: some View {
        let library = appState.meetingLibrary
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your meetings · on this Mac").font(.system(size: 13, weight: .medium))
                Spacer()
                Text("Transcripts kept: \(appState.settings.meetingTranscriptRetention.displayName.lowercased())")
                    .font(.caption).foregroundStyle(FlowStyle.muted)
            }
            if let error = library.storageError {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            if library.entries.isEmpty {
                Text(library.isLoaded
                     ? "Recorded meetings appear here with their transcript, notes and bookmarks."
                     : "Opening saved meetings…")
                    .font(.callout).foregroundStyle(FlowStyle.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(17).background(FlowStyle.surface, in: RoundedRectangle(cornerRadius: 11))
            } else {
                VStack(spacing: 8) {
                    ForEach(library.entries) { entry in
                        row(entry)
                    }
                }
            }
        }
    }

    private func row(_ entry: MeetingLibraryEntry) -> some View {
        HStack(spacing: 14) {
            Button { open(entry.sessionID) } label: {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                        HStack(spacing: 6) {
                            Text(entry.startedAt, format: .dateTime.day().month(.abbreviated).hour().minute())
                            if let duration = entry.durationMs, duration > 0 {
                                Text("·"); Text(MeetingTimeline.timestamp(duration))
                            }
                            if !entry.notes.isEmpty { Text("·"); Label("\(entry.notes.count)", systemImage: "note.text") }
                            if !entry.bookmarks.isEmpty { Text("·"); Label("\(entry.bookmarks.count)", systemImage: "bookmark") }
                        }.font(.system(size: 12)).foregroundStyle(FlowStyle.muted).labelStyle(.titleAndIcon)
                        if entry.status == .failed || entry.status == .queued, let detail = entry.statusDetail {
                            Text(detail).font(.caption).foregroundStyle(FlowStyle.muted).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 8)
                    MeetingStatusPill(status: entry.status)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if entry.status == .failed || entry.status == .queued {
                Button("Retry") { appState.retryMeeting(entry.sessionID) }
                    .disabled(appState.isMeetingCapturing || appState.isMeetingCaptureTransitioning)
            }
        }
        .padding(15).background(FlowStyle.surface, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(FlowStyle.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

struct MeetingStatusPill: View {
    let status: MeetingLibraryStatus

    var body: some View {
        HStack(spacing: 5) {
            if status == .uploading || status == .transcribing {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: symbol)
            }
            Text(status.displayName)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(color)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
    }

    private var symbol: String {
        switch status {
        case .recording: return "record.circle.fill"
        case .uploading: return "arrow.up.circle"
        case .transcribing: return "waveform"
        case .queued: return "clock"
        case .delivered: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        }
    }

    private var color: Color {
        switch status {
        case .recording, .failed: return FlowStyle.recording
        case .delivered: return .green
        case .queued: return FlowStyle.muted
        case .uploading, .transcribing: return FlowStyle.accent
        }
    }
}

/// Typed notes during a recording, stamped with the elapsed time.
struct MeetingNotepadView: View {
    @Bindable var appState: AppState
    let sessionID: UUID
    @State private var draft = ""
    @State private var feedback: String?
    @FocusState private var focused: Bool

    var body: some View {
        let notes = appState.meetingLibrary.entry(sessionID)?.notes ?? []
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Notepad", systemImage: "note.text").font(.headline)
                Spacer()
                Text("Saved with the meeting · sent to Atlas as bookmarks")
                    .font(.caption).foregroundStyle(FlowStyle.muted)
            }
            HStack(alignment: .bottom) {
                TextField("Type a note and press ⌘↩", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...4).focused($focused)
                    .onSubmit(save)
                Button("Add note", action: save)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(MeetingLibraryNote.sanitized(draft) == nil)
            }
            if let feedback { Text(feedback).font(.caption).foregroundStyle(FlowStyle.muted) }
            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(notes.reversed()) { note in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(MeetingTimeline.timestamp(note.elapsedMs))
                                .font(.system(size: 12, design: .monospaced)).foregroundStyle(FlowStyle.muted)
                            Text(note.text).font(.callout).textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .padding(18).background(FlowStyle.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(FlowStyle.line, lineWidth: 1))
    }

    private func save() {
        guard MeetingLibraryNote.sanitized(draft) != nil else { return }
        do {
            let note = try appState.addMeetingNote(draft)
            feedback = "Noted at \(MeetingTimeline.timestamp(note.elapsedMs))."
            draft = ""
            focused = true
        } catch MeetingLibraryError.noteLimitReached {
            feedback = "This meeting has reached its note limit."
        } catch {
            feedback = "Notes can be added while the meeting is recording."
        }
    }
}

/// One meeting: transcript with speakers and timestamps, notes, bookmarks,
/// Dictated markers, Atlas's summary when available, and the coach recap.
struct MeetingDetailView: View {
    @Bindable var appState: AppState
    let sessionID: UUID
    let close: () -> Void
    @State private var query = ""
    @State private var matchIndex = 0
    @State private var highlightedID: String?
    @State private var confirmDelete = false
    @State private var copied = false
    @State private var insightsState: InsightsState = .idle
    @FocusState private var searchFocused: Bool

    private enum InsightsState { case idle, loading, unavailable }

    var body: some View {
        if let entry = displayedEntry {
            content(entry)
        } else {
            VStack(spacing: 16) {
                Text("This meeting is no longer on this Mac.").foregroundStyle(FlowStyle.muted)
                Button("Back to meetings", action: close)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Bookmarks come from the assistant while it still has them, so a Retry
    /// there shows up here straight away.
    private var displayedEntry: MeetingLibraryEntry? {
        guard var entry = appState.meetingLibrary.entry(sessionID) else { return nil }
        let live = appState.meetingAssistant.libraryBookmarks(for: sessionID)
        if !live.isEmpty { entry.bookmarks = live }
        return entry
    }

    private func content(_ entry: MeetingLibraryEntry) -> some View {
        let timeline = MeetingTimeline.build(entry)
        let matches = MeetingTimeline.matches(query, in: timeline)
        let matchSet = Set(matches)
        let isLive = entry.status == .recording && appState.activeMeetingSessionID == sessionID
        return VStack(spacing: 0) {
            header(entry, isLive: isLive)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if isLive { MeetingNotepadView(appState: appState, sessionID: sessionID) }
                        moments(entry, proxy: proxy)
                        insights(entry)
                        if entry.coachRecap != nil || entry.coachSummary != nil {
                            DisclosureGroup("Private coach recap") {
                                if let summary = entry.coachSummary {
                                    MeetingCoachSummaryView(summary: summary).padding(.top, 8)
                                }
                                Text(entry.coachRecap ?? "").font(.callout).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                                Text("Kept on this Mac only. Not included in exports.")
                                    .font(.caption).foregroundStyle(FlowStyle.muted).padding(.top, 4)
                            }.padding(16).background(FlowStyle.surface, in: RoundedRectangle(cornerRadius: 11))
                        }
                        transcript(entry, timeline: timeline, matchSet: matchSet, isLive: isLive)
                    }
                    .padding(.horizontal, 32).padding(.vertical, 24)
                    .frame(maxWidth: 860, alignment: .leading).frame(maxWidth: .infinity)
                }
                .onChange(of: query) { _, _ in
                    matchIndex = 0
                    jump(to: MeetingTimeline.matches(query, in: MeetingTimeline.build(entry)).first, proxy: proxy)
                }
                .onChange(of: matchIndex) { _, index in
                    guard !matches.isEmpty else { return }
                    jump(to: matches[index % matches.count], proxy: proxy)
                }
                .safeAreaInset(edge: .top) { searchBar(matchCount: matches.count) }
            }
        }
        .background {
            Button("Find in transcript") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command).hidden()
            Button("Next match") { if !matches.isEmpty { matchIndex = (matchIndex + 1) % matches.count } }
                .keyboardShortcut("g", modifiers: .command).hidden()
            Button("Previous match") {
                if !matches.isEmpty { matchIndex = (matchIndex + matches.count - 1) % matches.count }
            }.keyboardShortcut("g", modifiers: [.command, .shift]).hidden()
        }
        .confirmationDialog("Delete this meeting from this Mac?", isPresented: $confirmDelete) {
            Button("Delete from this Mac", role: .destructive) {
                if appState.meetingLibrary.deleteDelivered(sessionID) { close() }
            }
        } message: {
            Text("The transcript, notes and coach recap on this Mac are removed. The copy in Atlas is unchanged.")
        }
        .task(id: entry.status) {
            guard entry.status == .delivered, entry.atlasInsights == nil,
                  AtlasDeviceMeetingReference.isValid(entry.atlasMeetingReference) else { return }
            insightsState = .loading
            insightsState = await appState.refreshAtlasInsights(sessionID) ? .idle : .unavailable
        }
    }

    private func header(_ entry: MeetingLibraryEntry, isLive: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Button(action: close) { Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(FlowStyle.accent)
                .keyboardShortcut("[", modifiers: .command).help("Back to meetings · ⌘[")
            VStack(alignment: .leading, spacing: 7) {
                Text(entry.title).font(.system(size: 24, weight: .semibold, design: .rounded)).lineLimit(2)
                HStack(spacing: 8) {
                    Text(entry.startedAt, format: .dateTime.weekday(.wide).day().month().hour().minute())
                    if isLive, let elapsed = appState.activeMeetingElapsedMs {
                        Text("·"); Text(MeetingTimeline.timestamp(elapsed)).monospacedDigit()
                    } else if let duration = entry.durationMs, duration > 0 {
                        Text("·"); Text(MeetingTimeline.timestamp(duration))
                    }
                    MeetingStatusPill(status: entry.status)
                }.font(.system(size: 12)).foregroundStyle(FlowStyle.muted)
                if let detail = entry.statusDetail, entry.status != .delivered {
                    Text(detail).font(.caption).foregroundStyle(FlowStyle.muted).textSelection(.enabled)
                }
            }
            Spacer()
            HStack(spacing: 8) {
                if entry.status == .failed || entry.status == .queued {
                    Button("Retry") { appState.retryMeeting(sessionID) }
                        .disabled(appState.isMeetingCapturing || appState.isMeetingCaptureTransitioning)
                }
                Button {
                    copyMarkdown(entry)
                } label: { Label(copied ? "Copied" : "Copy as Markdown", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Menu {
                    Button("Export Markdown…") { export(entry) }
                    if entry.status == .delivered {
                        Divider()
                        Button("Delete from this Mac…", role: .destructive) { confirmDelete = true }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                if let url = appState.atlasMeetingURL(for: entry) {
                    Link(destination: url) { Label("Open in Atlas", systemImage: "arrow.up.right.square") }
                        .buttonStyle(FlowPrimaryButtonStyle())
                }
            }
        }
        .padding(.horizontal, 32).padding(.vertical, 22)
    }

    private func searchBar(matchCount: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(FlowStyle.muted)
            TextField("Search transcript and notes · ⌘F", text: $query)
                .textFieldStyle(.plain).focused($searchFocused)
                .onSubmit { if matchCount > 0 { matchIndex = (matchIndex + 1) % matchCount } }
                .onExitCommand { query = ""; searchFocused = false }
            if !query.isEmpty {
                Text(matchCount == 0 ? "No matches" : "\(matchIndex % max(1, matchCount) + 1) of \(matchCount)")
                    .font(.caption).foregroundStyle(FlowStyle.muted).monospacedDigit()
                Button { matchIndex = (matchIndex + matchCount - 1) % max(1, matchCount) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.plain).disabled(matchCount == 0).help("Previous match · ⇧⌘G")
                Button { matchIndex = (matchIndex + 1) % max(1, matchCount) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.plain).disabled(matchCount == 0).help("Next match · ⌘G")
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(FlowStyle.muted)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(FlowStyle.surface, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(searchFocused ? FlowStyle.accent : FlowStyle.line, lineWidth: 1))
        .frame(maxWidth: 796).padding(.horizontal, 32).padding(.vertical, 10)
        .frame(maxWidth: .infinity).background(FlowStyle.canvas)
    }

    @ViewBuilder
    private func moments(_ entry: MeetingLibraryEntry, proxy: ScrollViewProxy) -> some View {
        let items: [(id: String, ms: Int64, symbol: String, text: String)] =
            entry.notes.map { ("note-\($0.id.uuidString)", $0.elapsedMs, "note.text", $0.text) }
            + entry.bookmarks.map { ("bookmark-\($0.id.uuidString)", $0.elapsedMs, "bookmark.fill", $0.label ?? "Bookmark") }
            + entry.dictations.map { ("dictation-\($0.id.uuidString)", $0.startMs, "mic.fill", "Dictated") }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Moments").font(.system(size: 13, weight: .medium))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(items.sorted { $0.ms < $1.ms }, id: \.id) { item in
                            Button { jump(to: item.id, proxy: proxy) } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: item.symbol).foregroundStyle(FlowStyle.accent)
                                    Text(MeetingTimeline.timestamp(item.ms)).monospacedDigit().foregroundStyle(FlowStyle.muted)
                                    Text(item.text).lineLimit(1).frame(maxWidth: 180, alignment: .leading)
                                }
                                .font(.system(size: 12))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(FlowStyle.surface, in: Capsule())
                                .overlay(Capsule().stroke(FlowStyle.line, lineWidth: 1))
                            }.buttonStyle(.plain).help("Jump to \(MeetingTimeline.timestamp(item.ms))")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func insights(_ entry: MeetingLibraryEntry) -> some View {
        if let insights = entry.atlasInsights, insights.hasContent {
            VStack(alignment: .leading, spacing: 12) {
                Label("Summary from Atlas", systemImage: "sparkles").font(.headline)
                if let summary = insights.summary { Text(summary).textSelection(.enabled) }
                list("Decisions", insights.decisions)
                list("Next steps", insights.nextActions.map { action in
                    [action.text, action.owner.map { "— \($0)" }, action.due.map { "(due \($0))" }]
                        .compactMap { $0 }.joined(separator: " ")
                })
                list("Outcomes", insights.outcomes)
                list("Open questions", insights.openQuestions)
                list("Risks", insights.risks)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(FlowStyle.surface, in: RoundedRectangle(cornerRadius: 12))
        } else if entry.status == .delivered {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(FlowStyle.muted)
                VStack(alignment: .leading, spacing: 4) {
                    Text(insightsState == .loading ? "Checking Atlas for the meeting summary…" : "Summary and next steps are in Atlas")
                        .font(.callout.weight(.medium))
                    Text("Atlas prepares meeting notes from the transcript. WhiskerFlow can’t read them back from Atlas yet, and it doesn’t write summaries on this Mac. Open the meeting in Atlas to see them.")
                        .font(.caption).foregroundStyle(FlowStyle.muted).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(FlowStyle.selection.opacity(0.6), in: RoundedRectangle(cornerRadius: 11))
        }
    }

    @ViewBuilder
    private func list(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(FlowStyle.muted)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) { Text("•"); Text(item).textSelection(.enabled) }
                }
            }
        }
    }

    private func transcript(_ entry: MeetingLibraryEntry, timeline: [MeetingTimelineItem], matchSet: Set<String>, isLive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Transcript").font(.system(size: 13, weight: .medium))
                Spacer()
                if entry.untranscribedAudibleWindowCount > 0 {
                    Text("\(entry.untranscribedAudibleWindowCount) stretch\(entry.untranscribedAudibleWindowCount == 1 ? "" : "es") of audible audio couldn’t be transcribed")
                        .font(.caption).foregroundStyle(FlowStyle.muted)
                }
            }.padding(.bottom, 8)
            if entry.turns.isEmpty {
                Text(isLive
                     ? "The transcript is made on this Mac after the meeting ends. Notes and bookmarks appear here as you add them."
                     : placeholder(for: entry.status))
                    .font(.callout).foregroundStyle(FlowStyle.muted).padding(.bottom, 10)
            }
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(timeline) { item in
                    row(item, isMatch: matchSet.contains(item.id))
                        .id(item.id)
                        .background(background(for: item.id, isMatch: matchSet.contains(item.id)),
                                    in: RoundedRectangle(cornerRadius: 7))
                }
            }
        }
    }

    private func placeholder(for status: MeetingLibraryStatus) -> String {
        switch status {
        case .transcribing: return "Making the transcript on this Mac…"
        case .uploading, .queued, .recording: return "The transcript will appear once the recording is processed on this Mac."
        case .failed: return "No transcript yet. The recording is kept on this Mac; choose Retry to process it again."
        case .delivered: return "No speech was detected in this recording."
        }
    }

    private func background(for id: String, isMatch: Bool) -> Color {
        if id == highlightedID { return FlowStyle.accent.opacity(0.18) }
        return isMatch ? Color.yellow.opacity(0.16) : .clear
    }

    @ViewBuilder
    private func row(_ item: MeetingTimelineItem, isMatch: Bool) -> some View {
        switch item {
        case .turn(_, let turn, let dictated):
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(MeetingTimeline.timestamp(turn.startMs))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(FlowStyle.muted)
                    .frame(width: 54, alignment: .trailing)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(turn.speaker.displayName).font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(turn.speaker.resolution == .selfSpeaker ? FlowStyle.accent : FlowStyle.ink)
                        if dictated {
                            Text("Dictated").font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(FlowStyle.accent.opacity(0.14), in: Capsule())
                                .foregroundStyle(FlowStyle.accent)
                                .help("Spoken with push-to-talk during the meeting")
                        }
                    }
                    Text(turn.text).font(.system(size: 14)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.padding(.vertical, 7).padding(.horizontal, 6)
        case .note(let note):
            marker(ms: note.elapsedMs, symbol: "note.text", title: "Note", text: note.text,
                   trailing: note.syncState == .synced ? "In Atlas" : "On this Mac")
        case .bookmark(let bookmark):
            marker(ms: bookmark.elapsedMs, symbol: "bookmark.fill", title: "Bookmark", text: bookmark.label ?? "",
                   trailing: bookmark.syncState == .synced ? "In Atlas" : "On this Mac")
        case .dictation(let span):
            marker(ms: span.startMs, symbol: "mic.fill", title: "Dictated",
                   text: "Push-to-talk \(MeetingTimeline.timestamp(span.startMs))–\(MeetingTimeline.timestamp(span.resolvedEndMs))",
                   trailing: nil)
        }
    }

    private func marker(ms: Int64, symbol: String, title: String, text: String, trailing: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(MeetingTimeline.timestamp(ms))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(FlowStyle.muted)
                .frame(width: 54, alignment: .trailing)
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: symbol).foregroundStyle(FlowStyle.accent)
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(text).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if let trailing { Text(trailing).font(.caption).foregroundStyle(FlowStyle.muted) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(FlowStyle.selection.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
        }.padding(.vertical, 3).padding(.horizontal, 6)
    }

    private func jump(to id: String?, proxy: ScrollViewProxy) {
        guard let id else { return }
        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
        highlightedID = id
    }

    private func markdown(_ entry: MeetingLibraryEntry) -> String {
        MeetingMarkdownExport.render(entry, atlasURL: appState.atlasMeetingURL(for: entry))
    }

    private func copyMarkdown(_ entry: MeetingLibraryEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown(entry), forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(2)); copied = false }
    }

    private func export(_ entry: MeetingLibraryEntry) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        let date = entry.startedAt.formatted(.iso8601.year().month().day())
        let safeTitle = entry.title.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        panel.nameFieldStringValue = "\(safeTitle) \(date).md"
        panel.canCreateDirectories = true
        let text = markdown(entry)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            appState.meetingLibraryExportFailed()
        }
    }
}
