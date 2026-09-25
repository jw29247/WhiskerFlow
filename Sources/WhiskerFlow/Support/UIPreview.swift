import SwiftUI
import WhiskerFlowAppSupport
import WhiskerFlowCore

/// Explicit, debug-only visual QA. Never starts capture, network services or updates.
/// Normal launches and all release builds use real application state.
@MainActor
enum UIPreview {
    static var isEnabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--ui-preview")
        #else
        false
        #endif
    }
    static var mode: String {
        guard isEnabled else { return "" }
        return ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-state=") }).map { String($0.dropFirst("--ui-state=".count)) } ?? "ready"
    }
    static var colorScheme: ColorScheme? {
        guard isEnabled else { return nil }
        return ProcessInfo.processInfo.arguments.contains("--ui-dark") ? .dark : .light
    }
    /// `--ui-screen=styles` opens Assistant → Styles; `dictate-style` shows the
    /// Dictate screen after a styled dictation.
    static var screen: String? {
        guard isEnabled else { return nil }
        return ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-screen=") }).map { String($0.dropFirst("--ui-screen=".count)) }
    }
    /// `--ui-snapshot=<path.png>` writes the main window to a PNG once it has
    /// settled, so screenshots don't need Screen Recording permission.
    static func writeSnapshotIfRequested() {
        guard isEnabled, let path = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-snapshot=") })
            .map({ String($0.dropFirst("--ui-snapshot=".count)) }) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 700 }),
                  let view = window.contentView?.superview ?? window.contentView, let layer = view.layer else { return }
            let scale = window.backingScaleFactor
            let size = view.bounds.size
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                                pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext else { return }
            context.scaleBy(x: scale, y: scale)
            layer.render(in: context)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            // Scroll content isn't part of the window's layer render: also write
            // the largest scroll view's whole document beside it.
            func scrollViews(in view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews(in:))
            }
            if let document = scrollViews(in: view).max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })?.documentView,
               let page = document.bitmapImageRepForCachingDisplay(in: document.bounds) {
                document.cacheDisplay(in: document.bounds, to: page)
                try? page.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-content.png")))
            }
        }
    }
    static var isPaired: Bool { mode != "disconnected" && mode != "setup" }
    /// `--ui-destination=Dictionary` opens that sidebar item for screenshots.
    static var destination: String? { argument("--ui-destination=") }
    static var dictionaryTab: DictionaryTab {
        argument("--ui-dictionary-tab=").flatMap(DictionaryTab.init(rawValue:)) ?? .words
    }

    /// `--ui-snapshot=/path.png` renders the main window into a PNG once the UI
    /// has settled, then quits. It draws in-process, so it needs no Screen
    /// Recording permission.
    static func scheduleSnapshotIfRequested() {
        #if DEBUG
        guard let path = argument("--ui-snapshot=") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }),
                  let view = window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            NSApp.terminate(nil)
        }
        #endif
    }

    static var dictionarySearch: String { argument("--ui-dictionary-search=") ?? "" }

    private static func argument(_ prefix: String) -> String? {
        guard isEnabled else { return nil }
        return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }
    static var isRecordingMeeting: Bool { mode == "meeting-recording" }

    static func makeAppState() -> AppState {
        #if DEBUG
        if isEnabled {
            let identifier = "agency.thatworks.WhiskerFlow.ui-preview.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: identifier)!
            let settings = AppSettings(defaults: defaults, meetingTokenStore: MeetingCaptureTokenStore(service: identifier))
            settings.showMenuBarExtra = false
            if mode == "toggle" { settings.recordingMode = .toggle; settings.delivery = .copyOnly }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(identifier, isDirectory: true)
            let store = TranscriptStore(fileURL: root.appendingPathComponent("transcripts.json"), removeAudioFile: { _ in })
            let samples = [
                "Let’s move the review to Thursday morning.",
                "A quick thought for the next design session.\n\nLet’s give the main screen a little more breathing room and make the next action obvious.",
                "The best tools get out of your way. A shortcut, a thought, and the words are there."
            ]
            if mode != "empty" && mode != "setup" {
                for (index, text) in samples.enumerated() {
                    try? store.add(TranscriptRecord(text: text, audioFilePath: "", createdAt: Date().addingTimeInterval(-Double(index) * 86400 - 3600),
                                                    status: .transcribed, durationSeconds: Double(8 + index * 12), engine: "parakeetTDTv3", language: "en"))
                }
                try? store.add(TranscriptRecord(text: "", audioFilePath: "", createdAt: Date().addingTimeInterval(-260000),
                                                status: .failed(errorMessage: "The microphone disconnected before transcription finished.")))
            }
            let permission = MicrophonePermissionController(provider: PreviewMicrophone(granted: mode != "setup"))
            let (dictionary, corrections) = sampleDictionary()
            let state = AppState(settings: settings, store: store, correctionStore: corrections,
                                 dictionaryStore: dictionary, microphonePermission: permission)
            if mode != "empty" && mode != "setup" {
                let learned = dictionary.entries.first { $0.written == "Claude" }!
                state.dictionaryNotice = DictionaryNotice(changes: [
                    DictionaryChange(pair: learned.pair, before: nil, after: learned)
                ])
            }
            state.records = store.records
            state.selectedRecordID = store.records.first?.id
            state.modelState = mode == "preparing" ? .preparing : .ready
            state.meetingModelState = .ready
            state.hasAccessibilityPermission = mode != "setup"
            state.hasScreenRecordingPermission = mode != "setup"
            if mode == "error" { state.status = .failure("The microphone disconnected. Choose an available microphone in Settings.") }
            if mode == "recording" { state.isRecording = true; state.status = .recording; state.audioLevel = 0.16; state.liveText = "This is a preview of your words as you speak." }
            if mode == "transcribing" { state.isTranscribing = true; state.status = .transcribing }
            if screen == "dictate-style" {
                state.lastWritingStyle = DictationStyleReceipt(
                    resolution: .init(category: .email, tone: .formal, source: .website), appName: "Safari")
            }
            return state
        }
        #endif
        return AppState()
    }

    /// Sample entries covering every row state: starred, learned, imported,
    /// absorbed misspellings, flags, usage, and suggestions both blocked and demoted.
    private static func sampleDictionary() -> (DictionaryStore, CorrectionStore) {
        let now = Date()
        let hours = { (h: Double) in now.addingTimeInterval(-h * 3600) }
        func entry(_ base: DictionaryEntry, starred: Bool = false, uses: Int = 0, lastUsed: Date? = nil) -> DictionaryEntry {
            var entry = base
            entry.starred = starred
            entry.useCount = uses
            entry.lastUsedAt = lastUsed
            return entry
        }
        var dictionary = UserDictionary()
        guard mode != "empty" && mode != "setup" else { return (DictionaryStore(), CorrectionStore()) }
        dictionary.entries = [
            entry(.word("Siobhan", addedAt: hours(900)), starred: true, uses: 14, lastUsed: hours(2)),
            entry(.word("Kubernetes", variants: ["kubernetis"], origin: .learned, addedAt: hours(300)), uses: 6, lastUsed: hours(30)),
            entry(.word("WhiskerFlow", addedAt: hours(2000)), uses: 31, lastUsed: hours(1)),
            entry(.word("Figma", origin: .imported, addedAt: hours(50))),
            entry(.word("Niamh", origin: .learned, addedAt: hours(5)), uses: 1, lastUsed: hours(4)),
            entry(.replacement("clawed", "Claude", origin: .learned, addedAt: hours(0.1)), uses: 9, lastUsed: hours(0.1)),
            entry(.replacement("sequel server", "SQL Server", addedAt: hours(400)), uses: 3, lastUsed: hours(70)),
            entry(.replacement("CX", "customer experience", caseSensitive: true, addedAt: hours(800)), uses: 2, lastUsed: hours(200))
        ]
        var demoted = DictionaryEntry.replacement("vivim", "Vivamn", origin: .learned, addedAt: hours(2600))
        demoted.useCount = 1
        dictionary.demoted = [DemotedEntry(entry: demoted, demotedAt: hours(20))]
        dictionary.readOnlyUsage[DictionaryPair(heard: "manukora", written: "Manukora").key] = DictionaryUsageStat(count: 4, lastUsedAt: hours(26))
        let corrections = CorrectionStore()
        corrections.record([VocabularyCorrection(find: "firmest teller", replaceWith: "Firma Stella")], sessionID: UUID(), application: "Slack")
        for app in ["Notes", "Mail", "Slack"] {
            corrections.record([VocabularyCorrection(find: "word", replaceWith: "Word")], sessionID: UUID(), application: app)
        }
        corrections.record([VocabularyCorrection(find: "oti", replaceWith: "Otty")], sessionID: UUID(), application: "Linear")
        let store = DictionaryStore()
        store.update { $0 = dictionary }
        return (store, corrections)
    }

    static var meetings: [AtlasCaptureScheduleIntent] {
        guard isEnabled && isPaired else { return [] }
        let base = Calendar.current.startOfDay(for: Date())
        return [("preview-review", "Product review", 14), ("preview-team", "Team catch-up", 33), ("preview-previous", "Design review", -12)].map { id, title, hour in
            let start = base.addingTimeInterval(Double(hour) * 3600)
            return AtlasCaptureScheduleIntent(eventID: id, title: title, startMs: Int64(start.timeIntervalSince1970 * 1000),
                                              endMs: Int64(start.addingTimeInterval(1800).timeIntervalSince1970 * 1000),
                                              meetingURL: nil, location: nil, existingMeetingID: hour < 0 ? "preview-meeting" : nil, overlapsPrevious: false)
        }
    }
}

#if DEBUG
@MainActor
private final class PreviewMicrophone: MicrophoneAuthorizationProviding {
    var authorizationState: MicrophoneAuthorizationState
    init(granted: Bool) { authorizationState = granted ? .authorized : .notDetermined }
    func requestAccess() async { authorizationState = .authorized }
}
#endif
