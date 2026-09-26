import AppKit
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
        guard isEnabled, onboardingStep == nil, let path = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-snapshot=") })
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
    /// `--ui-settings=History` opens Settings on that category.
    static var settingsCategory: String? { argument("--ui-settings=") }
    /// With `--ui-settings=` and `--ui-snapshot=<path.png>`, also writes the
    /// Settings window beside the main snapshot as `-settings.png`.
    static func writeSettingsSnapshotIfRequested() {
        guard settingsCategory != nil, let path = argument("--ui-snapshot=") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title.hasSuffix("Settings") }),
                  let view = window.contentView?.superview ?? window.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-settings.png")))
        }
    }
    static var isPaired: Bool { mode != "disconnected" && mode != "setup" && onboardingStep == nil }
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
        // Setup screens are written by `scheduleOnboardingSnapshotsIfRequested`.
        guard onboardingStep == nil, let path = argument("--ui-snapshot=") else { return }
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
    /// `--ui-state=onboarding-<step>` opens setup on that screen.
    static var onboardingStep: OnboardingStep? {
        guard mode.hasPrefix("onboarding-") else { return nil }
        return OnboardingStep(rawValue: String(mode.dropFirst("onboarding-".count)))
    }
    static var isRecordingMeeting: Bool { mode == "meeting-recording" || mode == "coach" }

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
            if mode != "empty" && mode != "setup" && onboardingStep == nil {
                let sampleAudio = silentRecording(in: root)
                for (index, text) in samples.enumerated() {
                    try? store.add(TranscriptRecord(text: text, audioFilePath: index == 0 ? sampleAudio : "", createdAt: Date().addingTimeInterval(-Double(index) * 86400 - 3600),
                                                    status: .transcribed, durationSeconds: Double(8 + index * 12), engine: "parakeetTDTv3", language: "en"))
                }
                try? store.add(TranscriptRecord(text: "", audioFilePath: "", createdAt: Date().addingTimeInterval(-260000),
                                                status: .failed(errorMessage: "The microphone disconnected before transcription finished.")))
            }
            let permission = MicrophonePermissionController(provider: PreviewMicrophone(granted: mode != "setup"))
            let onboardingStore = UserDefaultsOnboardingStore(defaults: defaults)
            if let step = onboardingStep {
                let passed: Set<OnboardingStep> = [.welcome, .permissions, .microphone, .shortcut, .practice]
                onboardingStore.save(OnboardingProgress(current: step, furthest: step,
                                                        completed: passed.filter { $0 < step }, startedAt: Date()))
            }
            let (dictionary, corrections) = sampleDictionary()
            let state = AppState(settings: settings, store: store, correctionStore: corrections,
                                 dictionaryStore: dictionary, microphonePermission: permission,
                                 onboardingStore: onboardingStore)
            if mode != "empty" && mode != "setup" && onboardingStep == nil {
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
            if mode != "empty" && mode != "setup" && onboardingStep == nil { addSampleInsights(to: state) }
            if mode == "error" { state.status = .failure("The microphone disconnected. Choose an available microphone in Settings.") }
            if mode == "recording" { state.isRecording = true; state.status = .recording; state.audioLevel = 0.16; state.liveText = "This is a preview of your words as you speak." }
            if mode == "transcribing" { state.isTranscribing = true; state.status = .transcribing }
            if screen == "dictate-style" {
                state.lastWritingStyle = DictationStyleReceipt(
                    resolution: .init(category: .email, tone: .formal, source: .website), appName: "Safari")
            }
            if let step = onboardingStep {
                state.hasAccessibilityPermission = step != .permissions
                state.hasScreenRecordingPermission = false
                if step == .permissions { state.onboarding.accessibilityRequestedAt = .distantPast }
                if step == .model || step <= .permissions {
                    var tracker = StagedDownloadProgress.parakeetFirstDownload
                    tracker.ingest(fraction: 0, startsNewOperation: true)
                    tracker.ingest(fraction: 1)
                    tracker.ingest(fraction: 0, startsNewOperation: true)
                    tracker.ingest(fraction: 0.48)
                    state.modelDownload = ModelDownloadStatus(tracker: tracker, needsDownload: true)
                    state.modelState = .preparing
                }
                state.onboarding.present()
            }
            state.meetingLibrary.insertForPreview(previewLibrary)
            if mode == "call-prompt" { state.showCallPromptForPreview() }
            if mode == "coach" { seedCoach(state.meetingAssistant) }
            return state
        }
        // End-to-end runs beside the installed app: same bundle ID (so the
        // TCC grants apply) but its own preferences, so nothing it changes
        // reaches the real settings.
        if let suite = DebugDictationTrigger.defaultsSuite, let defaults = UserDefaults(suiteName: suite) {
            return AppState(settings: AppSettings(defaults: defaults, meetingTokenStore: MeetingCaptureTokenStore(service: suite)),
                            onboardingStore: UserDefaultsOnboardingStore(defaults: defaults))
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

    /// One second of silence, so the detail view shows its recording controls.
    private static func silentRecording(in root: URL) -> String {
        let url = root.appendingPathComponent("preview.wav")
        let samples = 16_000
        var header = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        append(UInt32(36 + samples * 2)); header.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(16_000)); append(UInt32(32_000))
        append(UInt16(2)); append(UInt16(16)); header.append(Data("data".utf8)); append(UInt32(samples * 2))
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? (header + Data(count: samples * 2)).write(to: url)
        return url.path
    }

    /// Six weeks of made-up counts (no text) so Insights has something to show.
    private static func addSampleInsights(to state: AppState) {
        let apps = ["com.apple.TextEdit", "com.apple.Safari", "com.apple.Notes", "com.apple.MobileSMS", "com.apple.mail"]
        var seed: UInt64 = 0x5EED
        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound))
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        for dayOffset in 0..<42 where dayOffset < 9 || next(5) > 0 {
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: today) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            let busy = weekday != 1 && weekday != 7
            for _ in 0..<(busy ? 3 + next(9) : next(3)) {
                let hour = [9, 9, 10, 10, 11, 11, 14, 15, 16, 17, 20, 22][next(12)]
                let date = day.addingTimeInterval(TimeInterval(hour * 3600 + next(3600)))
                guard date < Date() else { continue }
                let seconds = Double(6 + next(40))
                let app = apps[min(next(9), apps.count - 1)]
                try? state.insights.record(DictationInsight(
                    date: date, words: Int(seconds * Double(120 + next(60)) / 60), speakingSeconds: seconds,
                    appBundleID: app, engine: "parakeetTDTv3",
                    vocabularyReplacements: next(4) == 0 ? 1 : 0, selfCorrections: next(9) == 0 ? 1 : 0
                ))
            }
        }
        state.refreshInsightsSummary()
    }

    /// With `--ui-state=onboarding-<step>`, `--ui-snapshot=<file.png>` writes the
    /// setup window to a PNG and exits. The app draws its own window, so visual QA
    /// needs no Screen Recording permission.
    static func scheduleOnboardingSnapshotsIfRequested() {
        #if DEBUG
        // `--ui-snapshot-every=<dir>`: keeps `<dir>/latest.png` current in a
        // real (non-preview) debug run, for scripted walkthroughs.
        if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-snapshot-every=") }) {
            let url = URL(fileURLWithPath: String(argument.dropFirst("--ui-snapshot-every=".count)))
                .appendingPathComponent("latest.png")
            Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
                MainActor.assumeIsolated { writeSnapshot(to: url) }
            }
        }
        guard isEnabled, onboardingStep != nil,
              let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-snapshot=") }) else { return }
        let path = String(argument.dropFirst("--ui-snapshot=".count))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            writeSnapshot(to: URL(fileURLWithPath: path))
            // A preview holds no data; an open sheet would stall a normal terminate.
            exit(0)
        }
        #endif
    }

    #if DEBUG
    private static func writeSnapshot(to url: URL) {
        let main = NSApp.windows.first { $0.isVisible && $0.title == "Set Up WhiskerFlow" }
            ?? NSApp.windows.first { $0.attachedSheet != nil }
            ?? NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true }
            ?? NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }
        guard let window = main?.attachedSheet ?? main,
              let view = window.contentView?.superview ?? window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url, options: .atomic)
    }
    #endif

    /// Sample meetings for the library screens. Invented content only.
    static var previewLibrary: [MeetingLibraryEntry] {
        guard isEnabled && isPaired && mode != "empty" else { return [] }
        let now = Date()
        var review = MeetingLibraryEntry(sessionID: UUID(), title: "Design review", startedAt: now.addingTimeInterval(-3 * 3600))
        review.status = .delivered
        review.deliveredAt = now.addingTimeInterval(-2.5 * 3600)
        review.durationMs = 1_512_000
        review.atlasMeetingID = "preview-meeting"
        let sam = MeetingSpeakerIdentity.manual(key: "sam", displayName: "Sam Lee")
        let priya = MeetingSpeakerIdentity.manual(key: "priya", displayName: "Priya Shah")
        review.turns = [
            MeetingSpeakerTurn(startMs: 4_000, endMs: 11_000, text: "Thanks for joining. Today I’d like to settle the onboarding flow and the pricing page.", speaker: .microphone),
            MeetingSpeakerTurn(startMs: 11_500, endMs: 24_000, text: "We tested both onboarding versions last week. The shorter one kept more people through step two.", speaker: sam),
            MeetingSpeakerTurn(startMs: 24_500, endMs: 33_000, text: "That matches the support tickets. Most questions came from the permissions screen.", speaker: priya),
            MeetingSpeakerTurn(startMs: 61_000, endMs: 68_000, text: "Remind me to send Sam the permissions copy after this call.", speaker: .microphone),
            MeetingSpeakerTurn(startMs: 69_000, endMs: 84_000, text: "For pricing, I’d keep three plans but move the annual toggle above the fold.", speaker: sam),
            MeetingSpeakerTurn(startMs: 85_000, endMs: 97_000, text: "Agreed. Let’s ship the short onboarding on Monday and review pricing next week.", speaker: .microphone),
            MeetingSpeakerTurn(startMs: 98_000, endMs: 104_000, text: "I’ll draft the pricing mock by Thursday.", speaker: .diarized(key: "s3", index: 3)),
        ]
        review.notes = [
            MeetingLibraryNote(elapsedMs: 26_000, text: "Permissions screen causes most tickets", createdAt: now, syncState: .synced),
            MeetingLibraryNote(elapsedMs: 90_000, text: "Ship short onboarding Monday", createdAt: now, syncState: .synced),
        ]
        review.bookmarks = [MeetingLibraryBookmark(id: UUID(), elapsedMs: 69_000, label: "Pricing layout", syncState: .synced)]
        review.dictations = [MeetingDictationSpan(startMs: 60_500, endMs: 68_500)]
        review.coachSummary = MeetingCoachSummary(
            durationSeconds: 1_512, youSeconds: 540, othersSeconds: 760, overlapSeconds: 40, longestMonologueSeconds: 118,
            monologueCount: 1, averageWordsPerMinute: 152, promptsShown: 3, aiSuggestionsShown: 1, aiHelpfulCount: 1)
        review.coachRecap = "Recording lasted 25m 12s. Microphone activity was estimated at 21 seconds in the final 60 seconds observed. This is an audio estimate, not a speaker assessment."
        var standup = MeetingLibraryEntry(sessionID: UUID(), title: "Team stand-up", startedAt: now.addingTimeInterval(-40 * 60))
        standup.status = .transcribing
        standup.statusDetail = "Making the transcript on this Mac."
        standup.durationMs = 900_000
        standup.coachSummary = MeetingCoachSummary(
            durationSeconds: 900, youSeconds: 420, othersSeconds: 300, overlapSeconds: 20, longestMonologueSeconds: 96,
            monologueCount: 2, averageWordsPerMinute: 171, promptsShown: 2)
        var client = MeetingLibraryEntry(sessionID: UUID(), title: "Client check-in", startedAt: now.addingTimeInterval(-26 * 3600))
        client.status = .failed
        client.awaitingManualRetry = true
        client.durationMs = 1_860_000
        client.statusDetail = "Couldn’t be processed. Atlas could not accept this request (HTTP 503). Choose Retry to try again."
        client.notes = [MeetingLibraryNote(elapsedMs: 300_000, text: "Follow up on contract dates", createdAt: now)]
        var entries = [review, standup, client]
        if isRecordingMeeting {
            var live = MeetingLibraryEntry(sessionID: recordingSessionID, title: "Product review", startedAt: now.addingTimeInterval(-7 * 60))
            live.notes = [
                MeetingLibraryNote(elapsedMs: 95_000, text: "Ask about the Q4 launch date", createdAt: now),
                MeetingLibraryNote(elapsedMs: 312_000, text: "Budget approved for two contractors", createdAt: now),
            ]
            entries.append(live)
        }
        return entries
    }

    static let recordingSessionID = UUID()

    /// Synthetic activity (no audio) so the coach HUD shows live numbers.
    static func seedCoach(_ coach: MeetingAssistantController) {
        coach.isCoachEnabled = true
        coach.goal = "Agree the launch date"
        coach.begin(sessionID: recordingSessionID, title: "Product review")
        func feed(_ from: Int, _ count: Int, own: Bool, system: Bool) {
            for second in from..<(from + count) {
                coach.recordActivity(.init(elapsedSeconds: Double(second), durationSeconds: 1, ownMicActivity: own, systemActivity: system))
            }
        }
        for block in 0..<6 { feed(block * 40, 25, own: false, system: true); feed(block * 40 + 25, 15, own: true, system: false) }
        feed(240, 100, own: true, system: false)
        coach.recordOwnSpeech(Array(repeating: "word", count: 52).joined(separator: " "), from: 300, to: 320)
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
