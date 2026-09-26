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
    /// Visual QA only: the sidebar destination to open first, e.g. "Meetings".
    static var initialDestination: String? {
        guard isEnabled else { return nil }
        return ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--ui-destination=") }
            .map { String($0.dropFirst("--ui-destination=".count)) }
    }
    static var isPaired: Bool { mode != "disconnected" && mode != "setup" }
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
            if mode != "empty" && mode != "setup" {
                for (index, text) in samples.enumerated() {
                    try? store.add(TranscriptRecord(text: text, audioFilePath: "", createdAt: Date().addingTimeInterval(-Double(index) * 86400 - 3600),
                                                    status: .transcribed, durationSeconds: Double(8 + index * 12), engine: "parakeetTDTv3", language: "en"))
                }
                try? store.add(TranscriptRecord(text: "", audioFilePath: "", createdAt: Date().addingTimeInterval(-260000),
                                                status: .failed(errorMessage: "The microphone disconnected before transcription finished.")))
            }
            let permission = MicrophonePermissionController(provider: PreviewMicrophone(granted: mode != "setup"))
            let state = AppState(settings: settings, store: store, microphonePermission: permission)
            state.records = store.records
            state.selectedRecordID = store.records.first?.id
            state.modelState = mode == "preparing" ? .preparing : .ready
            state.meetingModelState = .ready
            state.hasAccessibilityPermission = mode != "setup"
            state.hasScreenRecordingPermission = mode != "setup"
            if mode == "error" { state.status = .failure("The microphone disconnected. Choose an available microphone in Settings.") }
            if mode == "recording" { state.isRecording = true; state.status = .recording; state.audioLevel = 0.16; state.liveText = "This is a preview of your words as you speak." }
            if mode == "transcribing" { state.isTranscribing = true; state.status = .transcribing }
            state.meetingLibrary.insertForPreview(previewLibrary)
            if mode == "call-prompt" { state.showCallPromptForPreview() }
            if mode == "coach" { seedCoach(state.meetingAssistant) }
            return state
        }
        #endif
        return AppState()
    }

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
