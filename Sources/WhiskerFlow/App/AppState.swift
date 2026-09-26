import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import Logging
import OpenTelemetryApi
import Observation
import WhiskerFlowAppSupport
import WhiskerFlowCore

enum AppStatus: Equatable {
    case idle
    case preparingMic
    case recording
    case transcribing
    case delivering
    case success(String)
    case failure(String)

    var isBusy: Bool {
        switch self {
        case .preparingMic, .recording, .transcribing: return true
        case .idle, .delivering, .success, .failure: return false
        }
    }
}

extension AppStatus {
    var diagnosticName: String {
        switch self {
        case .idle: return "idle"
        case .preparingMic: return "preparing"
        case .recording: return "recording"
        case .transcribing: return "transcribing"
        case .delivering: return "delivering"
        case .success: return "success"
        case .failure: return "failure"
        }
    }

    var hudNotificationMessage: String? {
        if self == .delivering { return "Pasting…" }
        guard case .success(let message) = self else { return nil }
        return message
    }
}

enum ModelState: Equatable {
    case unloaded
    case preparing
    case ready
    case failed(String)
}

@MainActor
@Observable
final class AppState {
    private struct TranscriptionJobConfiguration {
        let engine: TranscriptionEngineKind
        let model: WhisperModel
        let language: String?
        let vocabulary: Vocabulary
        let formatting: FormattingOptions
        let cliConfiguration: WhisperConfiguration
        let allowAppleFallback: Bool
        let delivery: DeliveryMode
        let playSounds: Bool
        /// Resolved from the app at key press; a browser's tab can refine it at release.
        var writing = WritingStyleResolution(category: .other, tone: .formal, source: .fallback)
        var recognizeCorrections = false
        var hints: RecognizerHints = .none
        var purpose: AssistantController.CapturePurpose = .dictation
        var quickKind: AssistantRecordKind = .note
        var clientReference: String?
        var accountIdentity: String?
        /// Retries re-transcribe old audio in the background, long after its paste
        /// target is gone: they only update History and never paste or copy.
        var deliversText = true
        /// The capture never cleared the audibility floor, so a recognizer that
        /// also finds no words means nothing was said: discard it rather than
        /// file a failure that no retry can ever recover.
        var discardsWithoutSpeech = false
    }

    /// How long a `.finishing` session may take before the UI is force-recovered.
    /// Derived from the decode budget it backstops — a release can serially await
    /// several live decodes — plus a margin, so only a genuine wedge trips it and a
    /// merely slow decode is never reported as a timeout.
    private static let finishWatchdogSeconds = Int(DecodeTimeoutPolicy.liveFinishBudget) + 15
    /// Upper bound on how long quitting waits for a transcript to finish saving.
    /// A release-time live decode can take far longer on a slow Mac, so anything
    /// still in flight when it runs out is filed for retry rather than waited on.
    private static let shutdownDrainSeconds: TimeInterval = 5
    /// How often the Meetings view's free-space verdict is re-measured off-main.
    private static let meetingStorageRefreshSeconds: UInt64 = 60

    var records: [TranscriptRecord] = []
    var selectedRecordID: TranscriptRecord.ID?
    var status: AppStatus = .idle {
        didSet {
            lifecycleLogger.info("Dictation state changed", metadata: ["event": "state_changed", "state": "\(status.diagnosticName)", "session": "\(latestRecordingSessionID?.uuidString ?? "")", "recording": "\(isRecording)", "transcribing": "\(isTranscribing)"])
        }
    }
    var isRecording = false
    var isTranscribing = false
    var audioLevel: Float = 0
    /// Rolling verdict on the live input, surfaced as a HUD warning.
    var signalQuality: AudioSignalQuality = .unknown
    /// Live transcript shown in the HUD while streaming dictation is active.
    var liveText = ""
    var recordingStartedAt: Date?
    var modelState: ModelState = .unloaded
    var hasAccessibilityPermission = false
    var devices: [AudioInputDescriptor] = []
    var lastError: String?
    var searchText = ""
    /// Corrections spotted in the user's last transcript edit, offered as
    /// personal vocabulary rules until accepted or dismissed.
    var pendingVocabularySuggestions: [VocabularyCorrection] = []
    /// The latest automatic Dictionary addition, offered for Undo.
    var dictionaryNotice: DictionaryNotice?
    var meetingModelState: ModelState = .unloaded
    /// First-run download progress of the dictation model, for setup.
    var modelDownload = ModelDownloadStatus()
    let onboarding: OnboardingController
    /// Routes a practice dictation into setup's own text field; nil in tests
    /// that inject their own delivery service.
    let practiceDelivery: InAppPracticeDelivery?

    var settings: AppSettings

    private let logger = Logging.Logger(
        label: "agency.thatworks.WhiskerFlow.AppState"
    )
    private let lifecycleLogger = Logging.Logger(label: "agency.thatworks.WhiskerFlow.DictationLifecycle")
    private let store: TranscriptStore
    private let transcription: TranscriptionService
    private let meetingCapture: MeetingCaptureCoordinator
    private let atlasAuthSession = AtlasAuthSession()
    private let live: LiveDictationSession
    private let recordingCoordinator = RecordingCoordinator()
    private var pasteService: any TextDeliveryService
    var lastPasteReceipt: PasteDeliveryReceipt?
    var assistantVoiceInstruction = ""
    var meetingAssistant: MeetingAssistantController { meetingCapture.assistant }
    private var correctionEditBaselines: [UUID: String] = [:]
    let assistant: AssistantController
    let corrections: CorrectionStore
    let dictionary: DictionaryStore
    let insights: InsightsStore
    /// Recomputed when a dictation is recorded, on reset and on a typing-speed change.
    private(set) var insightsSummary = InsightsSummary(buckets: [], recentSamples: [])
    /// With history off, the last transcript stays in memory for a few minutes
    /// so Copy keeps working. It is never written to disk.
    private(set) var ephemeralTranscript: TranscriptRecord?
    private var ephemeralTranscriptExpiry: Task<Void, Never>?
    private var retentionPruneTask: Task<Void, Never>?
    nonisolated static let ephemeralTranscriptLifetimeSeconds: UInt64 = 10 * 60
    private let correctionMonitor = PasteCorrectionMonitor()
    private let soundService = SoundService()
    let microphonePermission: MicrophonePermissionController
    let sharedVocabulary = SharedVocabularyService()
    private var hotkeyMonitor: HotkeyMonitor?
    private var assistantHotkeyMonitors: [HotkeyMonitor] = []
    private var assistantShortcutActive = false
    static let selectionShortcut = KeyCombo(keyCode: 14, modifiers: [.command, .option, .shift])
    static let quickCaptureShortcut = KeyCombo(keyCode: 45, modifiers: [.command, .option, .shift])
    static let bookmarkShortcut = KeyCombo(keyCode: 11, modifiers: [.command, .option, .shift])
    private var meetingCoachHUD: MeetingCoachHUDController?
    private var callPromptHUD: CallPromptHUDController?
    private var hudController: RecordingHUDController?
    private var audioDeviceMonitor: AudioDeviceChangeMonitor?
    private var deviceRefreshTask: Task<Void, Never>?
    private var warmUpTask: Task<Void, Never>?
    private var meetingWarmUpTask: Task<Void, Never>?
    private let pendingPersistWork = PendingWorkTracker()
    private var hasStarted = false
    private var recordingIntentActive = false
    private var pasteTargetApplication: NSRunningApplication?
    /// The browser-tab read for the current recording. Accessibility IPC can be
    /// slow, so it runs beside the recording and is applied at formatting time.
    private var websiteLookup: Task<AppContext, Never>?
    /// How the latest dictation was written, shown on the Dictate screen.
    var lastWritingStyle: DictationStyleReceipt?
    private var activeTranscriptionIDs: Set<UUID> = []
    private var latestRecordingSessionID: UUID?
    private var latestDeliveryID: UUID?
    /// The shutdown-drain token each in-flight finish holds, so the watchdog can
    /// release it when it gives up on that finish instead of leaking it for the rest
    /// of the process's life.
    private var finishWorkTokens: [UUID: UUID] = [:]
    /// Sessions the finish watchdog gave up on. A finish that returns after its
    /// session was abandoned must not paste, must not touch lifecycle UI a newer
    /// session owns, and must not play sounds — it only files the transcript.
    private var abandonedSessionIDs: Set<UUID> = []
    /// The spooled audio of each finish still in flight. The streaming path only
    /// files its record after the live decode and the paste, so a quit that
    /// outlasts the drain would otherwise leave that audio referenced by nothing.
    private var inFlightFinishAudio: [UUID: (url: URL, configuration: TranscriptionJobConfiguration)] = [:]
    /// Sessions whose audio shutdown already filed as a retryable record, keyed
    /// to that record, so a finish landing afterwards completes it instead of
    /// adding a duplicate.
    private var recoveryRecordIDs: [UUID: UUID] = [:]
    private var retryAllTask: Task<Void, Never>?
    private var meetingStorageTask: Task<Void, Never>?
    private var meetingStoragePollTask: Task<Void, Never>?
    /// Cached Keychain state. Views and the hotkey path read these instead of the
    /// Keychain, which can block the main thread on a slow securityd or an ACL
    /// prompt; see `refreshAtlasAccountCache()`.
    private var atlasTokenAvailable = false
    private var atlasAccountIdentity: String?
    private var activeRecordingConfiguration: TranscriptionJobConfiguration?
    /// Whether the most recent recording streamed live (vs. file-based capture).
    private var streamingActive = false
    private var signalAssessor = AudioSignalAssessor()
    /// Keeps App Nap off while the hotkey is armed. A menu-bar utility with no
    /// visible window is otherwise napped: its queues are throttled and its
    /// priority lowered, which delays the first hotkey press after idle.
    private var hotkeyReadinessActivity: NSObjectProtocol?
    /// Held from hotkey press until the transcript is delivered, so timers and
    /// I/O on the capture, decode and paste path are not coalesced.
    private var dictationActivity: NSObjectProtocol?
    private var dictationWarmUpTask: Task<Void, Never>?
    /// Neural Engine state decays within seconds; re-warm during long holds.
    private static let dictationWarmUpInterval: UInt64 = 4_000_000_000
    var isSigningInToAtlas = false
    var atlasSignInError: String?
    var atlasSignInConfirmation: String?

    init(
        settings: AppSettings? = nil,
        store: TranscriptStore? = nil,
        correctionStore: CorrectionStore? = nil,
        dictionaryStore: DictionaryStore? = nil,
        insightsStore: InsightsStore? = nil,
        microphonePermission: MicrophonePermissionController? = nil,
        pasteService: (any TextDeliveryService)? = nil,
        onboardingStore: (any OnboardingProgressStoring)? = nil
    ) {
        let resolvedSettings = settings ?? AppSettings()
        let resolvedMicrophonePermission = microphonePermission ?? MicrophonePermissionController(
            provider: AVCaptureMicrophoneAuthorizationProvider()
        )
        let transcription = TranscriptionService()
        self.settings = resolvedSettings
        self.store = store ?? .defaultStore()
        self.assistant = store == nil && !UIPreview.isEnabled ? .defaultStore() : AssistantController()
        self.corrections = correctionStore ?? (store == nil ? .defaultStore() : CorrectionStore())
        self.dictionary = dictionaryStore ?? (store == nil
            ? .defaultStore(legacyVocabulary: resolvedSettings.vocabulary)
            : DictionaryStore(legacyVocabulary: resolvedSettings.vocabulary))
        // An injected history (tests, UI preview) never writes the real Insights.
        self.insights = insightsStore ?? (store == nil && !UIPreview.isEnabled ? .defaultStore() : .temporaryStore())
        self.microphonePermission = resolvedMicrophonePermission
        self.transcription = transcription
        self.meetingCapture = MeetingCaptureCoordinator(
            settings: resolvedSettings,
            microphonePermission: resolvedMicrophonePermission,
            transcription: transcription,
            // Tests and the UI preview must never read or write the user's meetings.
            library: store == nil && !UIPreview.isEnabled ? .production() : .ephemeral(),
            assistant: store == nil && !UIPreview.isEnabled ? nil : MeetingAssistantController(
                rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("WhiskerFlowAssistant-\(UUID().uuidString)"))
        )
        self.live = LiveDictationSession(transcription: transcription)
        var defaultPasteService = PasteService()
        defaultPasteService.correctionMonitor = correctionMonitor
        if let pasteService {
            self.pasteService = pasteService
            practiceDelivery = nil
        } else {
            let router = InAppPracticeDelivery(base: defaultPasteService)
            self.pasteService = router
            practiceDelivery = router
        }
        onboarding = OnboardingController(store: onboardingStore ?? UserDefaultsOnboardingStore())
        if (store == nil && !UIPreview.isEnabled) || UIPreview.mode == "coach" {
            meetingCoachHUD = MeetingCoachHUDController(controller: meetingCapture.assistant)
        }
        if (store == nil && !UIPreview.isEnabled) || UIPreview.mode == "call-prompt" {
            callPromptHUD = CallPromptHUDController(appState: self)
        }
        applyCoachSettings()
        // Until the Keychain proves otherwise, the account is the one the
        // assistant state was last saved for.
        atlasAccountIdentity = assistant.saved.accountIdentity
        refreshAtlasAccountCache()
        assistant.accountIdentityProvider = { [weak self] in self?.atlasAccountIdentity }
        meetingCapture.assistant.accountIdentityProvider = assistant.accountIdentityProvider
        if store == nil && !UIPreview.isEnabled { assistant.synchronizeAccount() }
        assistant.requestTransport = { [weak self] in
            guard let self, !UIPreview.isEnabled, !self.settings.atlasDeviceToken.isEmpty,
                  let url = URL(string: self.settings.atlasBaseURL) else { throw AssistantError.message("Connect Atlas in Meeting setup first.") }
            return AssistantAtlasClient(baseURL: url, token: self.settings.atlasDeviceToken)
        }
        meetingCapture.assistant.bookmarkSync = { [weak self] request in
            guard let self else { throw AssistantError.message("Assistant is unavailable.") }
            var args: [String: Any] = ["requestId": request.requestID.uuidString, "meetingReference": request.meetingReference,
                                       "offsetMs": request.elapsedMilliseconds]
            if let label = request.label { args["label"] = label }
            let row = try await self.assistant.call("addBookmark", args)
            guard let reference = row["bookmarkReference"] as? String else { throw AssistantError.message("Atlas returned an invalid bookmark receipt.") }
            return reference
        }
        // Atlas has no note tool: typed notes travel as labelled bookmarks.
        meetingCapture.library.noteSync = meetingCapture.assistant.bookmarkSync
        meetingCapture.library.retention = { [weak resolvedSettings] in
            resolvedSettings?.meetingTranscriptRetention ?? .defaultValue
        }
        correctionMonitor.isEnabled = { [weak self] in
            guard let self else { return false }
            return self.settings.rememberCorrections && !UIPreview.isEnabled
        }
        correctionMonitor.onCorrections = { [weak self] changes, sessionID, application in
            self?.corrections.record(changes, sessionID: sessionID, application: application)
            self?.learnFromCorrections(changes)
        }
        live.onLevel = { [weak self] level, peak in
            guard let self else { return }
            audioLevel = level
            guard isRecording else { return }
            signalAssessor.ingest(level: level, peak: peak)
            // Per-buffer writes would re-run the HUD's show/layout on every buffer.
            if signalQuality != signalAssessor.quality { signalQuality = signalAssessor.quality }
        }
        live.onPartial = { [weak self] text in self?.liveText = text }
        if store == nil && !UIPreview.isEnabled {
            ParakeetTDTv3Engine.downloadProgress.setHandler { [weak self] fraction, startsNew, compiling in
                Task { @MainActor [weak self] in
                    guard let self, self.modelDownload.tracker != nil else { return }
                    self.modelDownload.tracker?.ingest(fraction: fraction, startsNewOperation: startsNew)
                    if self.modelDownload.isCompiling != compiling { self.modelDownload.isCompiling = compiling }
                }
            }
        }
        live.onConfigurationChange = { [weak self] in self?.handleAudioConfigurationChange() }
    }

    // MARK: - Derived state

    var statusMessage: String {
        switch status {
        case .idle:
            switch modelState {
            case .preparing: return "Preparing \(settings.engine.displayName.lowercased())…"
            case .failed(let message): return message
            default: return "Hold \(settings.hotkeyDisplayName) to dictate"
            }
        case .preparingMic: return "Preparing microphone…"
        case .recording: return "Recording…"
        case .transcribing: return "Transcribing…"
        case .delivering: return "Pasting…"
        case .success(let message): return message
        case .failure(let message): return message
        }
    }

    var hudPresentation: FloatingHUDPresentation {
        FloatingHUDPresentation.current(
            isRecording: isRecording,
            isTranscribing: isTranscribing,
            successMessage: status.hudNotificationMessage
        )
    }

    var retryQueue: [TranscriptRecord] {
        records.filter { $0.status.isFailed }
    }

    var filteredRecords: [TranscriptRecord] {
        records.matching(searchText)
    }

    var selectedRecord: TranscriptRecord? {
        guard let selectedRecordID else { return records.first }
        return records.first { $0.id == selectedRecordID }
    }

    var latestTranscript: TranscriptRecord? {
        records.first { $0.status == .transcribed } ?? ephemeralTranscript
    }

    /// The newest successful transcripts, or the in-memory one with history off.
    func recentTranscripts(limit: Int) -> [TranscriptRecord] {
        let saved = Array(records.lazy.filter { $0.status == .transcribed }.prefix(limit))
        if saved.isEmpty, let ephemeralTranscript { return [ephemeralTranscript] }
        return saved
    }

    var recordingElapsed: TimeInterval {
        guard let recordingStartedAt else { return 0 }
        return Date().timeIntervalSince(recordingStartedAt)
    }

    var microphoneControlsLocked: Bool {
        recordingCoordinator.phase.controlsAreLocked
    }

    var hasMicrophonePermission: Bool {
        microphonePermission.isGranted
    }

    var microphonePermissionDetail: String {
        microphonePermission.detail
    }

  var meetingStatus: MeetingMenuBarStatus { UIPreview.isEnabled ? (UIPreview.isRecordingMeeting ? .recording : .covered) : meetingCapture.status }
  var latestAtlasMeetingURL: URL? {
    guard !UIPreview.isEnabled, let id = meetingCapture.lastAtlasMeetingID,
          let base = URL(string: settings.atlasBaseURL) else { return nil }
    return base.appendingPathComponent("meetings").appendingPathComponent(id)
  }

  var meetingLibrary: MeetingLibraryController { meetingCapture.library }
  var activeMeetingSessionID: UUID? {
    UIPreview.isEnabled ? (UIPreview.isRecordingMeeting ? UIPreview.recordingSessionID : nil) : meetingCapture.activeCaptureSessionID
  }
  var activeMeetingElapsedMs: Int64? { UIPreview.isEnabled ? 7 * 60_000 : meetingCapture.activeCaptureElapsedMs }

  func atlasMeetingURL(for entry: MeetingLibraryEntry) -> URL? {
    guard let id = entry.atlasMeetingID, let base = URL(string: settings.atlasBaseURL) else { return nil }
    return base.appendingPathComponent("meetings").appendingPathComponent(id)
  }

  func addMeetingNote(_ text: String) throws -> MeetingLibraryNote {
    try meetingCapture.addNote(text)
  }

  // MARK: Detected calls and coaching

  var callPrompt: DetectedCallPrompt? { meetingCapture.callPrompt }

  #if DEBUG
  func showCallPromptForPreview() {
    let call = DetectedCall(platform: .googleMeet, appBundleID: "com.google.Chrome", isBrowser: true, meetingCode: "abc-defg-hij")
    let now = Int64(Date().timeIntervalSince1970 * 1_000)
    let intent = AtlasCaptureScheduleIntent(eventID: "preview", title: "Weekly design sync", startMs: now - 60_000,
                                            endMs: now + 1_800_000, meetingURL: "https://meet.google.com/abc-defg-hij",
                                            location: nil, existingMeetingID: nil, overlapsPrevious: false)
    meetingCapture.showCallPromptForPreview(DetectedCallPrompt(call: call, intent: intent))
  }
  #endif

  func acceptCallPrompt() {
    guard !UIPreview.isEnabled else { meetingCapture.declineCallPrompt(); return }
    meetingCapture.acceptCallPrompt()
  }

  func declineCallPrompt() { meetingCapture.declineCallPrompt() }

  func setAskToRecordCalls(_ enabled: Bool) {
    settings.askToRecordCalls = enabled
    meetingCapture.refreshConfiguration()
  }

  var isOnDeviceCoachModelAvailable: Bool { OnDeviceCoachModel.isAvailable }
  var onDeviceCoachModelUnavailableReason: String { OnDeviceCoachModel.unavailableReason }

  func setCoachLiveAnalysis(_ enabled: Bool) {
    settings.coachLiveAnalysis = enabled
    applyCoachSettings()
  }

  func setCoachAISuggestions(_ enabled: Bool) {
    settings.coachAISuggestions = enabled
    applyCoachSettings()
  }

  private func applyCoachSettings() {
    let assistant = meetingCapture.assistant
    assistant.isLiveAnalysisEnabled = settings.coachLiveAnalysis
    let suggestions = settings.coachAISuggestions && OnDeviceCoachModel.isAvailable
    if suggestions, assistant.suggester == nil { assistant.suggester = OnDeviceCoachModel.makeSuggester() }
    assistant.isAISuggestionsEnabled = suggestions
  }

  var meetingCoachTrends: MeetingCoachTrends { meetingCapture.library.coachTrends }

  func meetingLibraryExportFailed() {
    status = .failure("The meeting couldn’t be exported. Choose another folder and try again.")
  }

  func retryMeeting(_ sessionID: UUID) {
    guard !UIPreview.isEnabled else { return }
    meetingCapture.retryRecording(sessionID: sessionID)
  }

  func setMeetingTranscriptRetention(_ retention: MeetingTranscriptRetention) {
    settings.meetingTranscriptRetention = retention
    meetingCapture.library.applyRetention()
  }

  func refreshAtlasInsights(_ sessionID: UUID) async -> Bool {
    await meetingCapture.refreshAtlasInsights(sessionID: sessionID)
  }

  func retryMeetingDelivery() {
    guard !UIPreview.isEnabled else { return }
    meetingCapture.retryPendingRecordings()
  }

  var meetingStatusDetail: String { UIPreview.isEnabled ? "Visual preview. No audio is being captured or uploaded." : meetingCapture.statusDetail }
  var meetingSpeakerDetectionDetail: String { meetingCapture.speakerDetectionDetail }
  var activeMeetingTitle: String? { UIPreview.isEnabled ? (UIPreview.isRecordingMeeting ? "Product review" : nil) : meetingCapture.activeMeetingTitle }
  var isMeetingCapturing: Bool { UIPreview.isEnabled ? UIPreview.isRecordingMeeting : meetingCapture.isCapturing }
  var isMeetingCaptureTransitioning: Bool { meetingCapture.isCaptureTransitioning }
  var upcomingMeetings: [AtlasCaptureScheduleIntent] { UIPreview.isEnabled ? UIPreview.meetings.filter { $0.existingMeetingID == nil } : meetingCapture.upcomingMeetingIntents }
  var previousMeetings: [AtlasCaptureScheduleIntent] { UIPreview.isEnabled ? UIPreview.meetings.filter { $0.existingMeetingID != nil } : meetingCapture.previousMeetingIntents }

    var isAtlasPaired: Bool {
        if UIPreview.isEnabled { return UIPreview.isPaired }
        guard URL(string: settings.atlasBaseURL)?.scheme == "https" else { return false }
        return atlasTokenAvailable
    }

    nonisolated static func accountIdentity(forToken token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Reads the Keychain once — at launch, on activation and after sign-in —
    /// never on the render or hotkey paths.
    private func refreshAtlasAccountCache() {
        guard !UIPreview.isEnabled else { return }
        let token = settings.atlasDeviceToken
        if atlasTokenAvailable != !token.isEmpty { atlasTokenAvailable = !token.isEmpty }
        // A failed Keychain read (locked keychain, re-signed build, busy securityd)
        // looks exactly like "no token", and the app has no sign-out. Keep the last
        // known account so a transient failure cannot wipe the assistant's
        // per-account state; a real account change always arrives with a new token.
        guard !token.isEmpty else { return }
        let identity = Self.accountIdentity(forToken: token)
        if atlasAccountIdentity != identity { atlasAccountIdentity = identity }
    }

    var hasScreenRecordingPermission = false

    /// Cached, because the capacity query can synchronously wait on CacheDelete
    /// XPC; it is re-measured off the main thread by
    /// `refreshMeetingStorageAvailability()`. The coordinator re-checks before
    /// any capture starts, so the optimistic launch value never records on a
    /// full disk.
    private(set) var isMeetingStorageAvailable = true

    func refreshMeetingStorageAvailability() {
        guard !UIPreview.isEnabled, meetingStorageTask == nil else { return }
        meetingStorageTask = Task { @MainActor [weak self] in
            let state = await Task.detached(priority: .utility) {
                MeetingCaptureCoordinator.readLocalDiskState()
            }.value
            guard let self else { return }
            self.meetingStorageTask = nil
            let available = state == "ready"
            if self.isMeetingStorageAvailable != available { self.isMeetingStorageAvailable = available }
        }
    }

    private func startMeetingStoragePolling() {
        meetingStoragePollTask?.cancel()
        meetingStoragePollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.refreshMeetingStorageAvailability()
                try? await Task.sleep(nanoseconds: Self.meetingStorageRefreshSeconds * 1_000_000_000)
            }
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !UIPreview.isEnabled else { return }
        guard !hasStarted else { return }
        hasStarted = true

        // History is the only fallible step, and it must not take the rest of the
        // bootstrap down with it: an unreadable transcripts.json would otherwise
        // leave the app running with no hotkey monitor and no HUD — no way to
        // dictate at all — and `hasStarted` blocks any retry.
        store.retention = settings.historyRetention
        store.audioRetention = audioRetention
        do {
            try store.load()
            normalizeInterruptedRecords()
        } catch {
            lastError = error.localizedDescription
            status = .failure("Could not load transcript history")
            DiagnosticsService.capture(
                error: error,
                category: "storage",
                code: String((error as NSError).code)
            )
        }

        records = store.records
        selectedRecordID = records.first?.id
        dictionary.update { DictionaryLearning.demoteStale(&$0) }
        loadInsights()
        startRetentionPruning()
        refreshAccessibilityPermission()
        refreshMicrophonePermission()
        refreshScreenRecordingPermission()
        // SwiftUI's settings Form is backed by NSTableView. Publishing the initial
        // catalog synchronously while scene restoration is laying it out can
        // re-enter its delegate and crash AppKit; defer one actor turn.
        refreshDevices()
        sharedVocabulary.configureAgencyLibrary()
        sharedVocabulary.startPeriodicRefresh()
        startAudioDeviceMonitor()
        hotkeyReadinessActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Respond immediately to the dictation hotkey"
        )
        startHotkeyMonitor()
        prepareNextCapture()
        refreshMeetingStorageAvailability()
        meetingCapture.start()
        startMeetingStoragePolling()
        hudController = RecordingHUDController(appState: self)
        warmUpEngine()
        warmUpMeetingEngine()
    }

    func applyActivationPolicy() {
        NSApp.setActivationPolicy(settings.showDockIcon ? .regular : .accessory)
    }

    /// Whether quitting now would drop a recording or an unsaved transcript.
    var hasPendingWork: Bool {
        isRecording || recordingCoordinator.phase != .idle || meetingCapture.isBusy || !pendingPersistWork.isIdle
    }

    func stopMonitors() {
        if let hotkeyReadinessActivity {
            ProcessInfo.processInfo.endActivity(hotkeyReadinessActivity)
            self.hotkeyReadinessActivity = nil
        }
        correctionMonitor.stop()
        hotkeyMonitor?.stop()
        assistantHotkeyMonitors.forEach { $0.stop() }
        assistantHotkeyMonitors = []
        hotkeyMonitor = nil
        audioDeviceMonitor?.stop()
        audioDeviceMonitor = nil
        meetingStoragePollTask?.cancel()
        meetingStoragePollTask = nil
        meetingCapture.stopMonitoring()
    }

    /// Wind down for termination. Monitors go first so no new session can start,
    /// then everything still in flight shares one `shutdownDrainSeconds` budget —
    /// a wedged decode must not keep the process alive past it.
    func shutdown() async {
        stopMonitors()
        warmUpTask?.cancel()
        warmUpTask = nil
        meetingWarmUpTask?.cancel()
        meetingWarmUpTask = nil
        deviceRefreshTask?.cancel()
        deviceRefreshTask = nil
        await meetingCapture.shutdown()

        switch recordingCoordinator.phase {
        case .preparing:
            live.cancel()
            _ = recordingCoordinator.forceIdle()
            isRecording = false
        case .recording:
            // The token bridges the hop until `finishRecording` registers its own.
            let token = pendingPersistWork.begin()
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.finishRecording()
                self.pendingPersistWork.end(token)
            }
        case .finishing, .idle:
            break
        }

        guard await !pendingPersistWork.waitUntilIdle(timeout: Self.shutdownDrainSeconds) else { return }
        fileInFlightFinishesForRecovery()
    }

    /// A release whose live decode outlasted the quit drain has no record yet.
    /// File its audio as a failed record so it is in the retry queue on the next
    /// launch instead of becoming an orphan the sweep deletes. A finish that lands
    /// before the process exits completes that record rather than adding another.
    private func fileInFlightFinishesForRecovery() {
        for (sessionID, pending) in inFlightFinishAudio {
            let record = TranscriptRecord(
                text: "",
                audioFilePath: pending.url.path,
                createdAt: Date(),
                status: .failed(errorMessage: "WhiskerFlow quit before transcription finished. Retry this recording."),
                model: pending.configuration.model.rawValue,
                engine: pending.configuration.engine.rawValue,
                language: pending.configuration.language,
                appCategory: pending.configuration.writing.category
            )
            do {
                try store.add(record)
            } catch {
                noteHistoryFailure(error)
            }
            recoveryRecordIDs[sessionID] = record.id
            abandonedSessionIDs.insert(sessionID)
        }
        inFlightFinishAudio = [:]
        records = store.records
    }

    func warmUpEngine() {
        guard !UIPreview.isEnabled else { return }
        warmUpTask?.cancel()
        let engine = settings.engine
        let model = settings.model
        let language = settings.resolvedLanguage
        let allowFallback = settings.allowAppleFallback
        guard engine == .whisperKit || engine == .parakeetTDTv3 else {
            modelState = .ready
            return
        }
        modelState = .preparing
        if engine == .parakeetTDTv3 {
            let needsDownload = !ParakeetTDTv3Engine.isModelDownloaded
            modelDownload = ModelDownloadStatus(
                tracker: needsDownload ? .parakeetFirstDownload : .parakeetCachedLoad,
                needsDownload: needsDownload
            )
        }
        warmUpTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let ready = await transcription.prepare(kind: engine, model: model, language: language)
            if ready, engine == .parakeetTDTv3 { self.modelDownload.tracker?.finish() }
            await transcription.prepareHints(self.recognizerHints, kind: engine)
            guard !Task.isCancelled,
                  self.settings.engine == engine,
                  self.settings.model == model,
                  self.settings.resolvedLanguage == language else { return }
            if ready {
                DiagnosticsService.breadcrumb(category: "model", metadata: ["model": model.rawValue])
                self.modelState = .ready
            } else if allowFallback {
                self.modelState = .failed("Could not load \(model.displayName). Apple Speech will be used.")
            } else {
                self.modelState = .failed("Could not load \(model.displayName). Apple Speech fallback is off.")
            }
        }
    }

    func reloadHotkey() {
        guard !UIPreview.isEnabled else { return }
        hotkeyMonitor?.update(combo: settings.activeHotkeyCombo)
    }

    func warmUpMeetingEngine() {
        guard !UIPreview.isEnabled else { return }
        meetingWarmUpTask?.cancel()
        guard settings.meetingModeEnabled, isAtlasPaired else {
            meetingModelState = .unloaded
            return
        }
        let language = settings.resolvedLanguage
        meetingModelState = .preparing
        meetingWarmUpTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let ready = await transcription.prepareMeeting(language: language)
            guard !Task.isCancelled else { return }
            guard self.settings.resolvedLanguage == language else {
                // The language changed mid-warm-up and nothing else restarts it;
                // returning here would leave the state at `.preparing` for good.
                self.warmUpMeetingEngine()
                return
            }
            meetingModelState = ready
                ? .ready
                : .failed("Could not load the local meeting model. Encrypted audio will be retained for repair.")
        }
    }

    /// Suspend the live hotkey while the user is recording a new shortcut, so the
    /// keys they press to record don't start a real dictation session.
    func setHotkeyCaptureActive(_ active: Bool) {
        hotkeyMonitor?.setSuspended(active)
        assistantHotkeyMonitors.forEach { $0.setSuspended(active) }
    }

    /// The team glossary plus the user's personal rules, applied to every
    /// transcript. Personal rules override shared ones on conflict.
    var effectiveVocabulary: Vocabulary {
        Vocabulary.effective(shared: Vocabulary.effective(shared: sharedVocabulary.vocabulary, personal: assistant.vocabulary), personal: dictionary.vocabulary)
    }

    // MARK: - Dictionary

    /// The selected client's name, for labelling its read-only entries.
    var selectedClientName: String? {
        guard let reference = assistant.saved.selectedClient else { return nil }
        return assistant.saved.clients.first { $0.reference == reference }?.name ?? reference
    }

    /// Shared and client rules in the order they apply, for lint and display.
    var readOnlyDictionaryRules: [DictionaryRule] {
        let shared = sharedVocabulary.rules.map { DictionaryRule(rule: $0, source: .shared) }
        let client = selectedClientName.map { name in
            assistant.vocabulary.rules.map { DictionaryRule(rule: $0, source: .client(name)) }
        } ?? []
        return shared + client
    }

    var correctionObservations: [CorrectionObservation] {
        corrections.records.map {
            CorrectionObservation(pair: DictionaryPair(heard: $0.original, written: $0.replacement),
                                  sessionID: $0.sessionID, application: $0.application, date: $0.date)
        }
    }

    var dictionarySuggestions: [DictionarySuggestion] {
        DictionaryLearning.suggestions(observations: correctionObservations, dictionary: dictionary.dictionary,
                                       readOnly: readOnlyDictionaryRules)
    }

    /// Hints for the recognisers, from the Dictionary and the read-only libraries.
    var recognizerHints: RecognizerHints {
        RecognizerHints(
            terms: DictionaryBiasing.terms(personal: dictionary.entries, readOnly: readOnlyDictionaryRules.map(\.rule)),
            appleSpeech: settings.biasAppleSpeech,
            whisperKit: settings.biasWhisperKit,
            parakeet: settings.biasParakeet
        )
    }

    /// Promotes corrections that have now been seen often enough.
    private func learnFromCorrections(_ changes: [VocabularyCorrection]) {
        guard settings.rememberCorrections, settings.autoAddLearnedWords, !changes.isEmpty else { return }
        let pairs = changes.map { DictionaryPair(heard: $0.find, written: $0.replaceWith) }
        var learned: [DictionaryChange] = []
        let observations = correctionObservations
        let readOnly = readOnlyDictionaryRules
        dictionary.update { dictionary in
            learned = DictionaryLearning.learn(from: pairs, observations: observations, dictionary: &dictionary,
                                               readOnly: readOnly)
        }
        guard !learned.isEmpty else { return }
        dictionaryNotice = DictionaryNotice(changes: learned)
        // A short HUD note for users who fixed the word in another app; Undo lives
        // in the main window and the Dictionary, since the HUD takes no clicks.
        if !isRecording, !isTranscribing, status == .idle || status.hudNotificationMessage != nil, status != .delivering {
            status = .success(dictionaryNotice?.hudMessage ?? "Added to Dictionary")
        }
    }

    func undoDictionaryNotice() {
        guard let notice = dictionaryNotice else { return }
        dictionary.update { dictionary in
            for change in notice.changes.reversed() { DictionaryLearning.undo(change, in: &dictionary) }
        }
        dictionaryNotice = nil
    }

    func acceptDictionarySuggestion(_ suggestion: DictionarySuggestion) {
        dictionary.update { _ = DictionaryLearning.accept(suggestion, in: &$0) }
    }

    func dismissDictionarySuggestion(_ suggestion: DictionarySuggestion) {
        dictionary.update { DictionaryLearning.dismiss(suggestion, in: &$0) }
        corrections.remove(VocabularyCorrection(find: suggestion.pair.heard, replaceWith: suggestion.pair.written))
    }

    /// Counts which entries shaped a delivered transcript, then retires
    /// auto-added entries that have gone unused.
    /// Counting compiles a regex per entry, so it runs off the main actor and
    /// never delays the paste that follows the history save.
    private func recordDictionaryUsage(raw: String, final: String, configuration: TranscriptionJobConfiguration) {
        guard configuration.writing.tone != .literal, !raw.isEmpty else { return }
        let entries = dictionary.entries
        let readOnlyRules = readOnlyDictionaryRules.map(\.rule)
        Task.detached(priority: .utility) { [weak self] in
            let counts = DictionaryUsage.counts(for: entries, raw: raw, final: final)
            let readOnly = DictionaryUsage.counts(forReadOnly: readOnlyRules, raw: raw)
            await self?.applyDictionaryUsage(counts, readOnly: readOnly)
        }
    }

    private func applyDictionaryUsage(_ counts: [UUID: Int], readOnly: [String: Int]) {
        let now = Date()
        dictionary.update { dictionary in
            DictionaryUsage.record(counts, readOnly: readOnly, in: &dictionary, at: now)
            DictionaryLearning.demoteStale(&dictionary, at: now)
        }
    }

    func refreshSharedVocabulary() {
        guard !UIPreview.isEnabled else { return }
        sharedVocabulary.refresh()
    }

    func refreshDevices() {
        guard !UIPreview.isEnabled else { return }
        deviceRefreshTask?.cancel()
        deviceRefreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            let refreshed = CoreAudioDeviceCatalog.availableInputs()
            // Runs on every hotkey press; an unchanged list must not invalidate
            // the settings views observing it.
            if self.devices != refreshed { self.devices = refreshed }

            // Picker option and selection changes must not occur in the same
            // NSTableView delegate stack. Publish the selection one turn later.
            await Task.yield()
            guard !Task.isCancelled else { return }
            if let legacyID = self.settings.legacySelectedDeviceID {
                self.settings.finishLegacyMicrophoneMigration(
                    MicrophoneSelection.migrate(legacyDeviceID: legacyID, devices: refreshed)
                )
            }
            // Keep the preferred UID while disconnected; captureCandidates supplies
            // the temporary system-default fallback when recording starts.
        }
    }

    /// Keeps an engine ready for the preferred microphone. A press that ends up
    /// on a fallback device simply builds its engine on demand.
    private func prepareNextCapture() {
        guard !UIPreview.isEnabled, settings.legacySelectedDeviceID == nil,
              microphonePermission.authorizationState == .authorized,
              recordingCoordinator.phase == .idle else { return }
        live.voiceProcessing = settings.ignoreSpeakerAudio
        live.prepareCapture(selection: settings.selectedInput)
    }

    /// The speaker-audio preference changed: rebuild the ready engine to match.
    func microphoneProcessingChanged() {
        live.invalidatePreparedCapture()
        prepareNextCapture()
    }

    private func startAudioDeviceMonitor() {
        let monitor = AudioDeviceChangeMonitor { [weak self] in
            self?.refreshDevices()
            self?.live.invalidatePreparedCapture()
            self?.prepareNextCapture()
        }
        monitor.start()
        audioDeviceMonitor = monitor
    }

    // MARK: - Permissions

    func refreshAccessibilityPermission() {
        guard !UIPreview.isEnabled else { return }
        hasAccessibilityPermission = pasteService.hasAccessibilityPermission
    }

    func requestAccessibilityPermission() {
        guard !UIPreview.isEnabled else { return }
        pasteService.requestAccessibilityPermission()
        refreshAccessibilityPermission()
    }

    func refreshMicrophonePermission() {
        let previous = microphonePermission.authorizationState
        microphonePermission.refresh()
        handleMicrophoneAuthorizationTransition(from: previous)
    }

    func refreshPermissionsAfterActivation() {
        guard !UIPreview.isEnabled else { return }
        refreshAccessibilityPermission()
        refreshMicrophonePermission()
        refreshScreenRecordingPermission()
        refreshAtlasAccountCache()
        refreshMeetingStorageAvailability()
        meetingCapture.refreshConfiguration()
    }

    func requestMicrophonePermission() async {
        let previous = microphonePermission.authorizationState
        _ = await microphonePermission.requestIfNeeded()
        handleMicrophoneAuthorizationTransition(from: previous)
    }

    func refreshScreenRecordingPermission() {
        guard !UIPreview.isEnabled else { return }
        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
    }

    func requestScreenRecordingPermission() {
        guard !UIPreview.isEnabled else { return }
        _ = CGRequestScreenCaptureAccess()
        refreshScreenRecordingPermission()
    }

    func toggleMeetingCapture() {
        guard !UIPreview.isEnabled else { return }
        meetingCapture.toggleManualCapture()
    }

  func refreshMeetingConfiguration() {
        guard !UIPreview.isEnabled else { return }
        refreshAtlasAccountCache()
        refreshMeetingStorageAvailability()
        warmUpMeetingEngine()
        meetingCapture.refreshConfiguration()
  }

  func refreshMeetingSchedule() {
        guard !UIPreview.isEnabled else { return }
    meetingCapture.refreshSchedule()
  }

  func recordScheduledMeeting(_ intent: AtlasCaptureScheduleIntent) {
        guard !UIPreview.isEnabled else { return }
    meetingCapture.startScheduledCapture(intent)
  }

  func signInToAtlas() {
        guard !UIPreview.isEnabled else { return }
    guard !isSigningInToAtlas else { return }
    isSigningInToAtlas = true
    atlasSignInError = nil
    atlasSignInConfirmation = nil
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { isSigningInToAtlas = false }
      do {
        let token = try await atlasAuthSession.connect()
        settings.atlasDeviceToken = token
        refreshMeetingConfiguration()
        atlasSignInConfirmation = "Connected to Atlas. Meeting Mode is ready."
      } catch {
        atlasSignInError = error.localizedDescription
      }
    }
  }

    func requestSpeechPermission() async -> Bool {
        guard !UIPreview.isEnabled else { return false }
        return await transcription.requestAppleSpeechAuthorization()
    }

    // MARK: - Manual actions

    func copy(_ text: String) {
        guard !text.isEmpty else { return }
        pasteService.copy(text)
        status = .success("Copied to clipboard")
    }

    func exportHistory(as format: TranscriptExportFormat) throws -> Data {
        try TranscriptExporter.export(records, as: format)
    }

    func updateText(_ record: TranscriptRecord, to text: String) {
        let suggestions = VocabularyCorrectionDetector.corrections(
            original: record.text,
            edited: text,
            existingRules: effectiveVocabulary
        )
        do {
            try store.setText(id: record.id, text: text)
            records = store.records
            pendingVocabularySuggestions = suggestions
            if settings.rememberCorrections {
                let baseline = correctionEditBaselines[record.id] ?? record.text
                correctionEditBaselines[record.id] = baseline
                let changes = VocabularyCorrectionDetector.corrections(original: baseline, edited: text,
                                                                       maxSuggestions: 20, allowShortCorrections: true)
                corrections.record(changes, sessionID: record.id, application: "WhiskerFlow")
                learnFromCorrections(changes)
            }
        } catch {
            handleStorageError(error, message: "Could not save transcript changes")
        }
    }

    /// Saves an edit even if retention removed its source while the editor was open.
    /// Recovered text is a new record; a pruned audio path must never be resurrected.
    func saveEditedTranscript(_ record: TranscriptRecord, text: String) -> TranscriptRecord? {
        if records.contains(where: { $0.id == record.id }) {
            updateText(record, to: text)
            return records.first { $0.id == record.id && $0.text == text }
        }
        let recovered = TranscriptRecord(text: text, audioFilePath: "", status: .transcribed)
        do {
            try store.add(recovered)
            records = store.records
            return recovered
        } catch {
            handleStorageError(error, message: "Could not save the recovered transcript")
            return nil
        }
    }

    /// Editor Copy is literal, including intentional empty text and whitespace.
    func copyEditorText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status = .success("Copied to clipboard")
    }

    func acceptVocabularySuggestion(_ suggestion: VocabularyCorrection) {
        let pair = DictionaryPair(heard: suggestion.find, written: suggestion.replaceWith)
        let evaluation = DictionaryLearning.evaluate(pair, observations: correctionObservations,
                                                     dictionary: dictionary.dictionary, readOnly: readOnlyDictionaryRules)
        let accepted = DictionarySuggestion(pair: pair, proposed: evaluation.proposed, sightings: evaluation.sightings,
                                            lastSeen: nil, applications: [], demotedAt: nil, issues: evaluation.issues)
        acceptDictionarySuggestion(accepted)
        pendingVocabularySuggestions.removeAll { $0 == suggestion }
    }

    func dismissVocabularySuggestions() {
        pendingVocabularySuggestions = []
    }

    func delete(_ record: TranscriptRecord) {
        do {
            try store.delete(id: record.id)
        } catch {
            handleStorageError(error, message: "Could not delete transcript")
            return
        }
        records = store.records
        if selectedRecordID == record.id {
            selectedRecordID = records.first?.id
        }
    }

    // MARK: - History retention and Insights

    /// How many saved transcripts a switch to `retention` would delete now.
    func historyRemovalCount(for retention: HistoryRetention) -> Int {
        store.removalCount(for: retention)
    }

    func setHistoryRetention(_ retention: HistoryRetention) {
        settings.historyRetention = retention
        do {
            try store.applyRetention(retention)
        } catch {
            handleStorageError(error, message: "Could not apply the history setting")
        }
        records = store.records
        if let selectedRecordID, !records.contains(where: { $0.id == selectedRecordID }) {
            self.selectedRecordID = records.first?.id
        }
        if retention.savesTranscripts { clearEphemeralTranscript() }
    }

    private var audioRetention: TranscriptAudioRetention {
        settings.keepRecentRecordings ? .fourteenDays : .standard
    }

    func setKeepRecentRecordings(_ keep: Bool) {
        settings.keepRecentRecordings = keep
        do {
            try store.applyRetention(settings.historyRetention, audio: audioRetention)
        } catch {
            handleStorageError(error, message: "Could not apply the recordings setting")
        }
        records = store.records
    }

    /// Whether a saved transcript still has its recording on disk.
    func hasRecording(_ record: TranscriptRecord) -> Bool {
        !record.audioFilePath.isEmpty && FileManager.default.fileExists(atPath: record.audioFilePath)
    }

    /// Re-transcribes a saved recording with `engine` and replaces the transcript
    /// only if that succeeds; a failure leaves the existing text untouched. Never
    /// pastes, and is not a new dictation, so Insights don't count it.
    func retranscribe(_ record: TranscriptRecord, with engine: TranscriptionEngineKind) {
        guard !UIPreview.isEnabled, record.status == .transcribed, hasRecording(record), !isRecording,
              !activeTranscriptionIDs.contains(record.id) else { return }
        let configuration = makeTranscriptionConfiguration()
        let audioURL = URL(fileURLWithPath: record.audioFilePath)
        activeTranscriptionIDs.insert(record.id)
        isTranscribing = true
        status = .transcribing
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.activeTranscriptionIDs.remove(record.id)
                self.isTranscribing = !self.activeTranscriptionIDs.isEmpty
            }
            let transcription = self.transcription
            let backstop = Self.recognitionBackstopSeconds(forAudioSeconds: record.durationSeconds, engine: engine,
                                                           allowAppleFallback: false)
            do {
                let outcome = try await withAbandoningDeadline(seconds: backstop) {
                    try await transcription.transcribe(audioURL: audioURL, kind: engine, model: configuration.model,
                                                       language: configuration.language,
                                                       cliConfiguration: configuration.cliConfiguration,
                                                       allowAppleFallback: false)
                }
                let text = await Task.detached(priority: .userInitiated) {
                    AssistantTextProcessing.process(outcome.result.text, tone: configuration.writing.tone,
                                                    vocabulary: configuration.vocabulary, formatting: configuration.formatting,
                                                    recognizeCorrections: configuration.recognizeCorrections)
                }.value
                try self.store.markTranscribed(id: record.id, text: text, durationSeconds: outcome.result.duration,
                                               model: configuration.model.rawValue, engine: outcome.engine.rawValue,
                                               language: outcome.result.language, rawRecognition: outcome.result.text)
                self.records = self.store.records
                self.status = .success("Transcribed again with \(engine.displayName)")
            } catch {
                self.logger.warning("Re-transcription failed", metadata: [
                    "error.code": "\((error as NSError).code)", "transcription.engine": "\(engine.rawValue)"
                ])
                self.status = .failure("\(engine.displayName) couldn’t transcribe this recording. Your transcript is unchanged.")
            }
        }
    }

    func setTypingSpeed(_ wordsPerMinute: Int) {
        settings.typingWordsPerMinute = min(max(wordsPerMinute, InsightsSummary.typingWordsPerMinuteRange.lowerBound),
                                            InsightsSummary.typingWordsPerMinuteRange.upperBound)
        refreshInsightsSummary()
    }

    func resetInsights() {
        do {
            try insights.reset()
        } catch {
            handleStorageError(error, message: "Could not reset Insights")
        }
        refreshInsightsSummary()
    }

    func refreshInsightsSummary() {
        insightsSummary = insights.summary(typingWordsPerMinute: settings.typingWordsPerMinute)
    }

    /// Loads the aggregates and, on the first launch with Insights, seeds them
    /// from the history the user already has.
    private func loadInsights() {
        do {
            try insights.load()
            if try insights.backfillIfNeeded(from: store.records) {
                logger.info("Insights backfilled from history", metadata: ["records": "\(store.records.count)"])
            }
        } catch {
            logger.error("Insights unavailable", metadata: ["error.code": "\((error as NSError).code)"])
            DiagnosticsService.capture(error: error, category: "storage", code: String((error as NSError).code))
        }
        refreshInsightsSummary()
    }

    /// "24 hours" has to expire records even when nothing new is dictated.
    private func startRetentionPruning() {
        retentionPruneTask?.cancel()
        retentionPruneTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard !self.isRecording, !self.isTranscribing else { continue }
                let before = self.store.records.count
                do { try self.store.applyRetention(self.settings.historyRetention) } catch { continue }
                if self.store.records.count != before || self.store.records != self.records { self.records = self.store.records }
            }
        }
    }

    /// Every successful dictation is counted in Insights whatever the history
    /// setting. Only counts leave this method: the words are counted here and
    /// the correction passes run off the main actor.
    private func recordSuccessfulDictation(
        text: String,
        rawText: String,
        speakingSeconds: Double?,
        engine: String,
        appBundleID: String?,
        configuration: TranscriptionJobConfiguration
    ) {
        guard configuration.purpose == .dictation, !UIPreview.isEnabled else { return }
        let date = Date()
        if !settings.historyRetention.savesTranscripts {
            showEphemeralTranscript(TranscriptRecord(text: text, audioFilePath: "", createdAt: date, status: .transcribed,
                                                     durationSeconds: speakingSeconds, engine: engine))
        }
        let words = text.transcriptWordCount
        let tone = configuration.writing.tone
        let vocabulary = configuration.vocabulary
        let recognizeCorrections = configuration.recognizeCorrections
        Task { @MainActor [weak self] in
            let counts = await Task.detached(priority: .utility) {
                AssistantTextProcessing.correctionCounts(rawText, tone: tone, vocabulary: vocabulary,
                                                         recognizeCorrections: recognizeCorrections)
            }.value
            guard let self else { return }
            do {
                try self.insights.record(DictationInsight(
                    date: date, words: words, speakingSeconds: speakingSeconds ?? 0, appBundleID: appBundleID,
                    engine: engine, vocabularyReplacements: counts.vocabularyReplacements,
                    selfCorrections: counts.selfCorrections
                ))
            } catch {
                self.logger.error("Insights update failed", metadata: ["error.code": "\((error as NSError).code)"])
            }
            self.refreshInsightsSummary()
        }
    }

    private func showEphemeralTranscript(_ record: TranscriptRecord) {
        ephemeralTranscript = record
        ephemeralTranscriptExpiry?.cancel()
        ephemeralTranscriptExpiry = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.ephemeralTranscriptLifetimeSeconds * 1_000_000_000)
            guard !Task.isCancelled, self?.ephemeralTranscript?.id == record.id else { return }
            self?.clearEphemeralTranscript()
        }
    }

    private func clearEphemeralTranscript() {
        ephemeralTranscriptExpiry?.cancel()
        ephemeralTranscriptExpiry = nil
        ephemeralTranscript = nil
    }

    func retry(_ record: TranscriptRecord) {
        guard !UIPreview.isEnabled else { return }
        guard !activeTranscriptionIDs.contains(record.id) else { return }
        Task { await retryRecording(record) }
    }

    /// One record at a time: each retry is a full-file decode, and several at once
    /// would contend for the Neural Engine and memory on an 8 GB Mac.
    func retryAllFailed() {
        guard !UIPreview.isEnabled, retryAllTask == nil else { return }
        let queued = retryQueue.map(\.id)
        retryAllTask = Task { @MainActor [weak self] in
            for id in queued {
                guard let self, !Task.isCancelled else { break }
                // A record may have been retried, edited or deleted while earlier
                // ones decoded.
                guard let record = self.records.first(where: { $0.id == id }), record.status.isFailed,
                      !self.activeTranscriptionIDs.contains(id) else { continue }
                await self.retryRecording(record)
            }
            self?.retryAllTask = nil
        }
    }

    /// Re-transcribes into History only. A retry runs long after its dictation,
    /// so pasting at the cursor would drop an old transcript into whatever app is
    /// frontmost when the decode happens to finish.
    private func retryRecording(_ record: TranscriptRecord) async {
        var configuration = makeTranscriptionConfiguration()
        configuration.deliversText = false
        configuration.purpose = .dictation
        // The app is long gone: write the retry for the category it was dictated
        // into, or — for a recording from before categories — as it was then.
        configuration.writing = record.appCategory.map(assistant.writingStyles.resolve(category:))
            ?? WritingStyleResolution(category: .other, tone: .legacyStandard, source: .fallback)
        await transcribeRecording(
            record,
            pasteTarget: nil,
            configuration: configuration,
            sessionID: nil
        )
    }

    // MARK: - Recording

    private func startHotkeyMonitor() {
        let monitor = HotkeyMonitor(combo: settings.activeHotkeyCombo) { [weak self] pressed in
            guard let self else { return }
            switch self.settings.recordingMode {
            case .holdToTalk:
                if pressed {
                    self.recordingIntentActive = true
                    self.pasteTargetApplication = NSWorkspace.shared.frontmostApplication
                    if self.assistant.capturePurpose == .selectionInstruction, !self.assistant.captureSelection() {
                        self.recordingIntentActive = false
                        self.status = .failure(self.assistant.message ?? "Capture a selection first")
                        return
                    }
                    Task { await self.beginRecording() }
                } else {
                    self.recordingIntentActive = false
                    Task { await self.finishRecording() }
                }
            case .toggle:
                guard pressed else { return }
                if self.isRecording {
                    Task { await self.finishRecording() }
                } else {
                    self.recordingIntentActive = true
                    self.pasteTargetApplication = NSWorkspace.shared.frontmostApplication
                    if self.assistant.capturePurpose == .selectionInstruction, !self.assistant.captureSelection() {
                        self.recordingIntentActive = false
                        self.status = .failure(self.assistant.message ?? "Capture a selection first")
                        return
                    }
                    Task { await self.beginRecording() }
                }
            }
        }
        monitor.start()
        hotkeyMonitor = monitor
        for (combo, purpose) in [(Self.selectionShortcut, AssistantController.CapturePurpose.selectionInstruction),
                                 (Self.quickCaptureShortcut, AssistantController.CapturePurpose.quickCapture)] {
            let shortcut = HotkeyMonitor(combo: combo) { [weak self] pressed in
                guard let self, self.settings.activeHotkeyCombo != combo else { return }
                if pressed {
                    guard !self.isRecording, !self.isTranscribing, !self.assistant.busy,
                          !self.isMeetingCapturing, self.recordingCoordinator.phase == .idle,
                          self.assistant.synchronizeAccount() else { return }
                    if purpose == .selectionInstruction, !self.assistant.captureSelection() { return }
                    self.assistant.capturePurpose = purpose
                    self.assistantShortcutActive = true
                    self.recordingIntentActive = true
                    self.pasteTargetApplication = NSWorkspace.shared.frontmostApplication
                    Task { await self.beginRecording() }
                } else if self.assistantShortcutActive {
                    self.assistantShortcutActive = false
                    self.recordingIntentActive = false
                    Task { await self.finishRecording() }
                }
            }
            shortcut.start(); assistantHotkeyMonitors.append(shortcut)
        }
        let bookmark = HotkeyMonitor(combo: Self.bookmarkShortcut) { [weak self] pressed in
            guard let self, pressed, self.settings.activeHotkeyCombo != Self.bookmarkShortcut else { return }
            self.bookmarkMeeting()
        }
        bookmark.start(); assistantHotkeyMonitors.append(bookmark)
    }

    func bookmarkMeeting() {
        guard isMeetingCapturing else { return }
        do {
            let bookmark = try meetingAssistant.addBookmark(label: nil)
            assistant.message = "Bookmarked at \(Int(bookmark.elapsedMilliseconds / 1000)) seconds."
        } catch { assistant.message = "The bookmark could not be saved on this Mac." }
    }

    private func beginRecording() async {
        lifecycleLogger.info("Recording requested", metadata: ["event": "recording_requested"])
        guard let sessionID = recordingCoordinator.requestStart() else {
            lifecycleLogger.notice("Recording request blocked by active capture", metadata: ["event": "recording_rejected"])
            return
        }
        await Observability.tracer.spanBuilder(spanName: "dictation.start").withActiveSpan { span in
            await beginRecording(sessionID: sessionID, span: span)
        }
    }

    /// Begins or ends `dictationActivity` to match whether any dictation is in flight.
    private func updateDictationActivity() {
        let active = recordingCoordinator.phase != .idle || isTranscribing
        if active, dictationActivity == nil {
            dictationActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical],
                reason: "Dictation in progress"
            )
        } else if !active, let activity = dictationActivity {
            ProcessInfo.processInfo.endActivity(activity)
            dictationActivity = nil
        }
    }

    /// Keeps the dictation model warm from key press until release, so the
    /// release-time decode never pays a cold Neural Engine start.
    private func startDictationWarmUp(sessionID: UUID) {
        dictationWarmUpTask?.cancel()
        let engine = settings.engine
        guard engine == .parakeetTDTv3 else { return }
        let transcription = transcription
        // Live preview decodes keep the model warm on their own while held.
        let previewKeepsWarm = settings.liveTranscription
        dictationWarmUpTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await transcription.warmUpDictationInference(kind: engine)
                guard !previewKeepsWarm else { return }
                try? await Task.sleep(nanoseconds: Self.dictationWarmUpInterval)
                guard !Task.isCancelled, let self,
                      self.recordingCoordinator.phase == .preparing(sessionID)
                        || self.recordingCoordinator.phase == .recording(sessionID) else { return }
            }
        }
    }

    private func beginRecording(sessionID: UUID, span: any SpanBase) async {
        // Before the microphone: the warm-up runs on the Neural Engine while
        // capture starts on the main actor.
        startDictationWarmUp(sessionID: sessionID)
        startWebsiteLookup()
        updateDictationActivity()
        defer { updateDictationActivity() }
        var telemetryOutcome = "error"
        defer {
            span.setAttribute(key: "outcome", value: telemetryOutcome)
            Observability.dictationSessions.add(
                value: 1,
                attributes: [
                    "state": .string("start"),
                    "outcome": .string(telemetryOutcome)
                ]
            )
        }

        latestRecordingSessionID = sessionID
        latestDeliveryID = nil
        lifecycleLogger.info("Recording session started", metadata: ["event": "recording_started", "session": "\(sessionID)"])
        status = .preparingMic
        logger.info("Recording preparing")
        DiagnosticsService.breadcrumb(category: "recording", metadata: ["phase": "preparing"])

        // Re-querying TCC costs 20–60 ms on the main actor per press. Trust a
        // granted state here; it is re-checked after every dictation.
        let microphoneAuthorization = microphonePermission.authorizationState == .authorized
            ? .authorized
            : await microphonePermission.requestIfNeeded()
        guard recordingCoordinator.phase == .preparing(sessionID) else {
            telemetryOutcome = "cancelled"
            return
        }
        guard microphoneAuthorization == .authorized else {
            _ = recordingCoordinator.fail(sessionID)
            span.setAttribute(
                key: "error.type",
                value: "microphone_permission_\(microphoneAuthorization.rawValue)"
            )
            span.status = .error(description: "Microphone permission unavailable")
            DiagnosticsService.breadcrumb(
                category: "audio",
                metadata: ["phase": "permission_\(microphoneAuthorization.rawValue)"]
            )
            if let message = microphonePermission.captureFailureMessage {
                lastError = message
                status = .failure(message)
            }
            return
        }

        do {
            let currentDevices = CoreAudioDeviceCatalog.availableInputs()
            let preferredInputSelection: AudioInputSelection
            if let legacyID = settings.legacySelectedDeviceID {
                preferredInputSelection = MicrophoneSelection.migrate(
                    legacyDeviceID: legacyID,
                    devices: currentDevices
                )
            } else {
                preferredInputSelection = settings.selectedInput
            }
            refreshDevices()
            guard recordingCoordinator.phase == .preparing(sessionID) else {
                telemetryOutcome = "cancelled"
                return
            }
            liveText = ""
            signalAssessor.reset()
            signalQuality = .unknown
            let configuration = makeTranscriptionConfiguration()
            span.setAttributes([
                "transcription.engine": .string(configuration.engine.rawValue),
                "transcription.model": .string(configuration.model.rawValue),
                "recording.mode": .string(String(describing: settings.recordingMode)),
                "writing.category": .string(configuration.writing.category.rawValue)
            ])
            activeRecordingConfiguration = configuration
            assistant.capturePurpose = .dictation
            // Stream + decode live for WhisperKit; Parakeet decodes the captured
            // samples on release, with audio persistence following delivery.
            streamingActive = configuration.engine == .whisperKit && settings.liveTranscription
            var inputSelection: AudioInputSelection?
            var lastStartError: Error?
            live.voiceProcessing = settings.ignoreSpeakerAudio
            for candidate in MicrophoneSelection.captureCandidates(
                for: preferredInputSelection,
                devices: currentDevices
            ) {
                do {
                    try live.start(
                        selection: candidate,
                        language: configuration.language,
                        model: configuration.model,
                        vocabulary: configuration.vocabulary,
                        formatting: configuration.formatting,
                        streaming: streamingActive,
                        tone: configuration.writing.tone,
                        recognizeCorrections: configuration.recognizeCorrections,
                        hints: configuration.hints,
                        previewEngine: settings.liveTranscription ? configuration.engine : nil
                    )
                    inputSelection = candidate
                    break
                } catch {
                    live.cancel()
                    lastStartError = error
                }
            }
            guard let inputSelection else {
                throw lastStartError ?? AudioCaptureServiceError.deviceUnavailable
            }
            guard recordingCoordinator.didStart(sessionID) else {
                live.cancel()
                streamingActive = false
                activeRecordingConfiguration = nil
                telemetryOutcome = "cancelled"
                return
            }
            span.setAttribute(
                key: "audio.input.kind",
                value: inputSelection == .systemDefault ? "default" : "specific"
            )
            isRecording = true
            DiagnosticsService.breadcrumb(
                category: "recording",
                metadata: [
                    "phase": "recording",
                    "engine": settings.engine.rawValue,
                    "input_kind": inputSelection == .systemDefault ? "default" : "specific"
                ]
            )
            recordingStartedAt = Date()
            lastError = nil
            status = .recording
            meetingCapture.dictationStarted()
            telemetryOutcome = "success"
            span.status = .ok
            if settings.playSounds { soundService.play(.recordingStarted) }

            // Hold mode: if the key was already released while preparing, stop now.
            if settings.recordingMode == .holdToTalk, !recordingIntentActive {
                await finishRecording()
            }
        } catch {
            _ = recordingCoordinator.fail(sessionID)
            isRecording = false
            streamingActive = false
            activeRecordingConfiguration = nil
            let message = CaptureErrorPresentation.message(for: error)
            lastError = message
            span.setAttributes([
                "error.type": .string(String(describing: type(of: error))),
                "error.code": .int((error as NSError).code)
            ])
            span.status = .error(description: "Recording start failed")
            logger.error(
                "Recording start failed",
                metadata: ["error.code": "\((error as NSError).code)"]
            )
            DiagnosticsService.capture(
                error: error,
                category: "audio",
                code: String((error as NSError).code)
            )
            status = .failure(message)
        }
    }

    private func finishRecording(reason: CaptureStopReason = .userReleased) async {
        if case .preparing = recordingCoordinator.phase {
            status = .preparingMic
            return
        }
        guard case .recording(let sessionID) = recordingCoordinator.phase,
              recordingCoordinator.requestFinish(sessionID, reason: reason) else { return }
        await Observability.tracer.spanBuilder(spanName: "dictation.finish").withActiveSpan { span in
            await finishRecording(
                sessionID: sessionID,
                reason: reason,
                span: span
            )
        }
    }

    private func finishRecording(
        sessionID: UUID,
        reason: CaptureStopReason,
        span: any SpanBase
    ) async {
        defer {
            updateDictationActivity()
            scheduleAfterDictationUpkeep()
        }
        dictationWarmUpTask?.cancel()
        dictationWarmUpTask = nil
        let finishStarted = ProcessInfo.processInfo.systemUptime
        lifecycleLogger.info("Finishing recording", metadata: ["event": "finish_started", "session": "\(sessionID)"])
        defer { lifecycleLogger.info("Recording finish returned", metadata: ["event": "finish_returned", "session": "\(sessionID)", "elapsed_ms": "\((ProcessInfo.processInfo.systemUptime - finishStarted) * 1000)"]) }
        let capturedDuration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        var telemetryOutcome = "error"
        defer {
            span.setAttributes([
                "outcome": .string(telemetryOutcome),
                "recording.stop_reason": .string(String(describing: reason))
            ])
            Observability.dictationSessions.add(
                value: 1,
                attributes: [
                    "state": .string("finish"),
                    "outcome": .string(telemetryOutcome),
                    "stop_reason": .string(String(describing: reason))
                ]
            )
            if capturedDuration > 0 {
                Observability.recordingDuration.record(
                    value: capturedDuration,
                    attributes: [
                        "outcome": .string(telemetryOutcome),
                        "stop_reason": .string(String(describing: reason))
                    ]
                )
            }
        }

        // Registered for the whole finish, so a quit landing mid-finish waits for
        // the transcript instead of racing the store write. The watchdog needs to be
        // able to release it too, or a finish it gave up on would keep every later
        // quit waiting out the full drain budget for work that will never land.
        let workToken = pendingPersistWork.begin()
        finishWorkTokens[sessionID] = workToken
        defer {
            finishWorkTokens[sessionID] = nil
            inFlightFinishAudio[sessionID] = nil
            pendingPersistWork.end(workToken)
        }

        isRecording = false
        recordingStartedAt = nil
        meetingCapture.dictationEnded()
        status = .transcribing
        DiagnosticsService.breadcrumb(
            category: "recording",
            metadata: ["phase": "finishing", "stop_reason": String(describing: reason)]
        )
        // A wedged CoreML decode never returns, so nothing below can unstick the
        // UI on its own — this watchdog is the only way back to idle.
        let watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.finishWatchdogSeconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.abandonStuckFinish(sessionID: sessionID)
        }

        let wasStreaming = streamingActive
        streamingActive = false
        var configuration = activeRecordingConfiguration ?? makeTranscriptionConfiguration()
        activeRecordingConfiguration = nil
        let pasteTarget = pasteTargetApplication
        pasteTargetApplication = nil
        if let lookup = websiteLookup {
            // Normally finished long ago; bounded by the reader's own budget.
            websiteLookup = nil
            configuration.writing = assistant.resolveWritingStyle(await lookup.value)
            live.setTone(configuration.writing.tone)
        }
        if configuration.purpose == .dictation {
            lastWritingStyle = DictationStyleReceipt(resolution: configuration.writing, appName: pasteTarget?.localizedName)
        }
        if let url = live.currentAudioURL {
            inFlightFinishAudio[sessionID] = (url, configuration)
        }
        let result = await live.finish(reason: reason)
        lifecycleLogger.info("Live decode returned", metadata: ["event": "decode_returned", "session": "\(sessionID)", "elapsed_ms": "\((ProcessInfo.processInfo.systemUptime - finishStarted) * 1000)", "samples": "\(result.totalSampleCount)"])
        watchdog.cancel()
        let wasAbandoned = abandonedSessionIDs.remove(sessionID) != nil
        _ = recordingCoordinator.didFinish(sessionID)

        if wasAbandoned {
            // The watchdog already reported this session as timed out and released
            // the coordinator, so the HUD text, the status and the paste target may
            // all belong to a newer session by now. File the transcript so it isn't
            // lost, but deliver nothing and touch no lifecycle UI.
            logger.error("Finish returned after the watchdog")
            let recovered = !result.text.isEmpty && result.coversAllAudio
            DiagnosticsService.breadcrumb(
                category: "recording",
                metadata: [
                    "phase": "finish_late",
                    "recovered": String(recovered)
                ]
            )
            inFlightFinishAudio[sessionID] = nil
            if recovered {
                recordSuccessfulDictation(text: result.text, rawText: result.rawText,
                                          speakingSeconds: Double(result.totalSampleCount) / 16_000,
                                          engine: configuration.engine.rawValue, appBundleID: nil,
                                          configuration: configuration)
            }
            if let recordID = recoveryRecordIDs.removeValue(forKey: sessionID) {
                // Shutdown already filed this audio for retry; complete it in place.
                if recovered {
                    completeRecoveryRecord(recordID, text: result.text, rawText: result.rawText,
                                           totalSampleCount: result.totalSampleCount, configuration: configuration)
                }
            } else if recovered {
                persistLiveRecording(
                    text: result.text,
                    rawText: result.rawText,
                    capturedAudioURL: result.audioURL,
                    totalSampleCount: result.totalSampleCount,
                    configuration: configuration,
                    sessionID: sessionID
                )
            } else if let url = result.audioURL, result.totalSampleCount > 0 {
                // No usable transcript (a superseded or incomplete live decode, or
                // a file-based capture): the audio must still reach the retry queue.
                fileTimedOutRecording(url: url, totalSampleCount: result.totalSampleCount,
                                      configuration: configuration)
            }
            span.setAttribute(key: "error.type", value: "finish_timeout")
            span.status = .error(description: "Finish returned after timeout")
            return
        }

        if configuration.playSounds { soundService.play(.recordingStopped) }
        liveText = ""

        if wasStreaming, !result.text.isEmpty, result.coversAllAudio {
            // Streaming already produced the transcript — paste immediately, then
            // persist the audio + record off the critical path.
            let mayUpdateUI = canUpdateLifecycleUI(for: sessionID)
            if mayUpdateUI { status = .transcribing }
            await deliver(
                result.text,
                pasteTarget: pasteTarget,
                delivery: configuration.delivery,
                mayUpdateStatus: mayUpdateUI,
                purpose: configuration.purpose,
                quickKind: configuration.quickKind,
                clientReference: configuration.clientReference,
                accountIdentity: configuration.accountIdentity,
                sessionID: sessionID
            )
            inFlightFinishAudio[sessionID] = nil
            recordSuccessfulDictation(text: result.text, rawText: result.rawText,
                                      speakingSeconds: Double(result.totalSampleCount) / 16_000,
                                      engine: configuration.engine.rawValue,
                                      appBundleID: pasteTarget?.bundleIdentifier, configuration: configuration)
            if let recordID = recoveryRecordIDs.removeValue(forKey: sessionID) {
                abandonedSessionIDs.remove(sessionID)
                completeRecoveryRecord(recordID, text: result.text, rawText: result.rawText,
                                       totalSampleCount: result.totalSampleCount, configuration: configuration)
            } else {
                persistLiveRecording(
                    text: result.text,
                    rawText: result.rawText,
                    capturedAudioURL: result.audioURL,
                    totalSampleCount: result.totalSampleCount,
                    configuration: configuration,
                    sessionID: sessionID
                )
            }
        } else {
            // Non-streaming engine, streaming caught no speech, or the live
            // transcript is missing audio (its final pass failed or the tail left
            // memory): transcribe the file (includes the Apple Speech fallback)
            // rather than paste a transcript that silently drops the last words.
            inFlightFinishAudio[sessionID] = nil
            if canUpdateLifecycleUI(for: sessionID) { status = .transcribing }
            await transcribeCapturedSamples(
                result.samples,
                conversionFailures: result.conversionFailures,
                capturedAudioURL: result.audioURL,
                totalSampleCount: result.totalSampleCount,
                stopReason: reason,
                pasteTarget: pasteTarget,
                configuration: configuration,
                sessionID: sessionID
            )
        }

        if reason == .deviceDisconnected, canUpdateLifecycleUI(for: sessionID) {
            if CapturedAudioValidation.shouldDismissEmptyDeviceInterruption(
                stopReason: reason,
                totalSampleCount: result.totalSampleCount
            ) {
                // A route rebuild can stop AVAudioEngine before its first
                // usable buffer. It is a discarded tap, not a failed
                // transcription; leave the next hotkey press immediately
                // available and keep the interruption visible in diagnostics.
                lifecycleLogger.info(
                    "Capture discarded after microphone route interruption",
                    metadata: [
                        "event": "capture_discarded",
                        "reason": "device_interruption",
                        "conversion_failures": "\(result.conversionFailures)"
                    ]
                )
                DiagnosticsService.breadcrumb(
                    category: "recording",
                    metadata: [
                        "phase": "capture_discarded",
                        "reason": "device_interruption"
                    ]
                )
                status = .idle
            } else if case .failure = status {
                // Preserve the actionable transcription/storage failure.
            } else {
                status = .success("Microphone changed; partial transcript saved")
            }
        }

        if result.storageFailed, canUpdateLifecycleUI(for: sessionID) {
            // The spool stopped taking audio mid-recording (usually a full disk):
            // whatever was delivered covers only the audio before that point, and
            // an empty capture is a storage problem, not a microphone one.
            status = .failure(result.totalSampleCount == 0
                ? "Couldn't save the recording — free up disk space and try again"
                : "Disk full: the recording stopped early and later speech is missing")
        }

        if case .failure = status {
            span.setAttribute(key: "error.type", value: "dictation_failed")
            span.status = .error(description: "Dictation failed")
        } else {
            telemetryOutcome = "success"
            span.status = .ok
        }
    }

    /// Off the release-to-paste path: confirm the microphone grant the press
    /// trusted, then ready the engine for the next press.
    private func scheduleAfterDictationUpkeep() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard let self, self.recordingCoordinator.phase == .idle else { return }
            self.refreshMicrophonePermission()
            self.prepareNextCapture()
        }
    }

    private func abandonStuckFinish(sessionID: UUID) {
        guard recordingCoordinator.phase == .finishing(sessionID) else { return }
        lifecycleLogger.warning("Recording finish timed out", metadata: ["event": "finish_timeout", "session": "\(sessionID)"])
        recordingCoordinator.forceIdle()
        // Releasing the coordinator lets a new session start on top of this one, so
        // stamp the abandoned session: whatever its finish eventually returns must
        // not reach the pasteboard or the UI. Its drain token goes now too, or every
        // later quit waits out the full budget for work that never lands.
        abandonedSessionIDs.insert(sessionID)
        if let token = finishWorkTokens.removeValue(forKey: sessionID) {
            pendingPersistWork.end(token)
        }
        isRecording = false
        isTranscribing = false
        streamingActive = false
        activeRecordingConfiguration = nil
        logger.error(
            "Finish watchdog fired",
            metadata: ["timeout.seconds": "\(Self.finishWatchdogSeconds)"]
        )
        Observability.dictationSessions.add(
            value: 1,
            attributes: [
                "state": .string("watchdog"),
                "outcome": .string("error"),
                "error.type": .string("timeout")
            ]
        )
        DiagnosticsService.breadcrumb(
            category: "recording",
            metadata: ["phase": "finish_timeout"]
        )
        DiagnosticsService.capture(
            error: TranscriptionError.timedOut(seconds: Self.finishWatchdogSeconds),
            category: "recording"
        )
        status = .failure("Transcription timed out")
    }

    private func handleAudioConfigurationChange() {
        guard case .recording = recordingCoordinator.phase else { return }
        logger.error("Active microphone configuration changed")
        DiagnosticsService.breadcrumb(
            category: "audio",
            metadata: ["phase": "recording", "stop_reason": "device_disconnected"]
        )
        Task { await finishRecording(reason: .deviceDisconnected) }
    }

    private func handleMicrophoneAuthorizationTransition(
        from previous: MicrophoneAuthorizationState
    ) {
        let current = microphonePermission.authorizationState
        guard current != previous else { return }
        logger.info(
            "Microphone authorization changed",
            metadata: ["authorization.state": "\(current.rawValue)"]
        )
        if current == .authorized {
            refreshDevices()
            prepareNextCapture()
        }
    }

    /// Save a finished streaming transcript + its audio without blocking the
    /// paste. The WAV is encoded off the main actor; the store update hops back.
    private func persistLiveRecording(
        text: String,
        rawText: String,
        capturedAudioURL: URL?,
        totalSampleCount: Int,
        configuration: TranscriptionJobConfiguration,
        sessionID: UUID
    ) {
        recordDictionaryUsage(raw: rawText, final: text, configuration: configuration)
        let createdAt = Date()
        let duration = Double(totalSampleCount) / 16_000
        let model = configuration.model.rawValue
        let engine = configuration.engine.rawValue
        let language = configuration.language
        let category = configuration.writing.category
        guard let url = capturedAudioURL else {
            handleStorageError(CocoaError(.fileNoSuchFile), message: "Could not save recording")
            return
        }

        let workToken = pendingPersistWork.begin()
        Task.detached(priority: .utility) { [weak self] in
            defer {
                Task { @MainActor in self?.pendingPersistWork.end(workToken) }
            }
            await Observability.tracer.spanBuilder(spanName: "transcript.persist").withActiveSpan { span in
                var telemetryOutcome = "error"
                span.setAttributes([
                    "transcription.engine": .string(engine),
                    "transcription.model": .string(model)
                ])
                defer {
                    span.setAttribute(key: "outcome", value: telemetryOutcome)
                    Observability.transcriptPersistence.add(
                        value: 1,
                        attributes: [
                            "outcome": .string(telemetryOutcome),
                            "engine": .string(engine)
                        ]
                    )
                }
                let saved = await self?.appendRecord(
                        text: text,
                        rawText: rawText,
                        audioPath: url.path,
                        createdAt: createdAt,
                        duration: duration,
                        model: model,
                        engine: engine,
                        language: language,
                        category: category,
                        sessionID: sessionID
                ) ?? false
                if saved {
                    telemetryOutcome = "success"
                    span.status = .ok
                } else {
                    span.setAttribute(key: "error.type", value: "storage")
                    span.status = .error(description: "Could not save transcript")
                }
            }
        }
    }

    private func appendRecord(
        text: String,
        rawText: String,
        audioPath: String,
        createdAt: Date,
        duration: Double,
        model: String,
        engine: String,
        language: String?,
        category: AppCategory,
        sessionID: UUID
    ) -> Bool {
        let record = TranscriptRecord(
            text: text,
            audioFilePath: audioPath,
            createdAt: createdAt,
            status: .transcribed,
            durationSeconds: duration,
            model: model,
            engine: engine,
            language: language,
            updatedAt: createdAt,
            rawRecognition: rawText,
            appCategory: category
        )
        do {
            try store.add(record)
            records = store.records
            if canUpdateLifecycleUI(for: sessionID) {
                selectedRecordID = record.id
            }
            return true
        } catch {
            handleStorageError(error, message: "Could not save transcript")
            return false
        }
    }

    /// Files a late finish that produced no usable transcript as a retryable
    /// failure, so its audio stays in the retry queue instead of being orphaned.
    private func fileTimedOutRecording(url: URL, totalSampleCount: Int, configuration: TranscriptionJobConfiguration) {
        let record = TranscriptRecord(
            text: "",
            audioFilePath: url.path,
            createdAt: Date(),
            status: .failed(errorMessage: "Transcription timed out. Retry this recording."),
            durationSeconds: Double(totalSampleCount) / 16_000,
            model: configuration.model.rawValue,
            engine: configuration.engine.rawValue,
            language: configuration.language,
            appCategory: configuration.writing.category
        )
        do {
            try store.add(record)
        } catch {
            noteHistoryFailure(error)
        }
        records = store.records
    }

    private func completeRecoveryRecord(
        _ id: UUID,
        text: String,
        rawText: String,
        totalSampleCount: Int,
        configuration: TranscriptionJobConfiguration
    ) {
        do {
            try store.markTranscribed(
                id: id,
                text: text,
                durationSeconds: Double(totalSampleCount) / 16_000,
                model: configuration.model.rawValue,
                engine: configuration.engine.rawValue,
                language: configuration.language,
                rawRecognition: rawText,
                appCategory: configuration.writing.category
            )
            recordDictionaryUsage(raw: rawText, final: text, configuration: configuration)
        } catch {
            noteHistoryFailure(error)
        }
        records = store.records
    }

    /// Persist captured audio for interrupted-decode recovery, then let Parakeet
    /// use the existing samples without reading and converting the WAV again.
    private func transcribeCapturedSamples(
        _ samples: [Float],
        conversionFailures: Int,
        capturedAudioURL: URL?,
        totalSampleCount: Int,
        stopReason: CaptureStopReason,
        pasteTarget: NSRunningApplication?,
        configuration: TranscriptionJobConfiguration,
        sessionID: UUID
    ) async {
        guard totalSampleCount > 0 else {
            let isDeviceInterruption = stopReason == .deviceDisconnected
            // Buffers that all failed to convert look identical to silence at this
            // point, so the failure count is the only way to tell the user why.
            if conversionFailures > 0, !isDeviceInterruption {
                logger.error(
                    "Capture yielded no usable audio",
                    metadata: ["audio.conversion.failures": "\(conversionFailures)"]
                )
                DiagnosticsService.capture(
                    error: AudioCaptureServiceError.conversionFailed("all buffers"),
                    category: "audio",
                    code: String(conversionFailures)
                )
            } else {
                discardCapturedAudio(capturedAudioURL)
            }
            if canUpdateLifecycleUI(for: sessionID) {
                if conversionFailures > 0, !isDeviceInterruption {
                    status = .failure("Microphone audio could not be converted — try another microphone")
                } else {
                    status = .idle
                }
            }
            return
        }

        if conversionFailures == 0,
           let discardReason = CapturedAudioValidation.discardReason(
               totalSampleCount: totalSampleCount,
               residentSamples: samples
           ) {
            lifecycleLogger.info(
                "Capture discarded before transcription",
                metadata: [
                    "event": "capture_discarded",
                    "reason": "\(discardReason.rawValue)",
                    "samples": "\(totalSampleCount)"
                ]
            )
            DiagnosticsService.breadcrumb(
                category: "recording",
                metadata: [
                    "phase": "capture_discarded",
                    "reason": discardReason.rawValue
                ]
            )
            discardCapturedAudio(capturedAudioURL)
            if canUpdateLifecycleUI(for: sessionID) {
                // A short, silent capture: say so, or the hotkey looks ignored.
                status = discardReason == .silent ? .failure("No speech detected") : .idle
            }
            return
        }
        guard let url = capturedAudioURL else {
            handleStorageError(CocoaError(.fileNoSuchFile), message: "Recording failed")
            return
        }
        var configuration = configuration
        configuration.discardsWithoutSpeech = conversionFailures == 0
            && totalSampleCount == samples.count
            && !BoundedDecodeWindowPolicy.containsAudibleActivity(samples)
        let record = TranscriptRecord(
            text: "",
            audioFilePath: url.path,
            createdAt: Date(),
            status: .transcribing,
            durationSeconds: Double(totalSampleCount) / 16_000,
            model: configuration.model.rawValue,
            engine: configuration.engine.rawValue,
            language: configuration.language,
            appCategory: configuration.writing.category
        )
        // History is best-effort here: the audio is on disk and the recognizer
        // does not need the record, so a full disk or an unwritable history must
        // not stop the transcript from being delivered.
        do {
            try store.add(record)
        } catch {
            noteHistoryFailure(error)
        }
        records = store.records
        if canUpdateLifecycleUI(for: sessionID) {
            selectedRecordID = record.id
        }
        await transcribeRecording(
            record,
            pasteTarget: pasteTarget,
            configuration: configuration,
            sessionID: sessionID,
            capturedSamples: nil
        )
    }

    private func discardCapturedAudio(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func transcribeRecording(
        _ record: TranscriptRecord,
        pasteTarget: NSRunningApplication?,
        configuration: TranscriptionJobConfiguration,
        sessionID: UUID?,
        capturedSamples: [Float]? = nil
    ) async {
        guard !activeTranscriptionIDs.contains(record.id) else { return }
        await Observability.tracer.spanBuilder(spanName: "transcription.run").withActiveSpan { span in
            await transcribeRecording(
                record,
                pasteTarget: pasteTarget,
                configuration: configuration,
                sessionID: sessionID,
                span: span,
                capturedSamples: capturedSamples
            )
        }
    }

    private func transcribeRecording(
        _ record: TranscriptRecord,
        pasteTarget: NSRunningApplication?,
        configuration: TranscriptionJobConfiguration,
        sessionID: UUID?,
        span: any SpanBase,
        capturedSamples: [Float]?
    ) async {
        let telemetryStartedAt = Date()
        var telemetryOutcome = "error"
        let isRetry = sessionID == nil
        span.setAttributes([
            "transcription.engine": .string(configuration.engine.rawValue),
            "transcription.model": .string(configuration.model.rawValue),
            "transcription.retry": .bool(isRetry),
            "transcription.input": .string(capturedSamples == nil ? "file" : "samples")
        ])
        defer {
            let attributes: [String: AttributeValue] = [
                "engine": .string(configuration.engine.rawValue),
                "outcome": .string(telemetryOutcome),
                "retry": .bool(isRetry)
            ]
            Observability.transcriptionOperations.add(value: 1, attributes: attributes)
            Observability.transcriptionDuration.record(
                value: Date().timeIntervalSince(telemetryStartedAt),
                attributes: attributes
            )
        }

        activeTranscriptionIDs.insert(record.id)
        isTranscribing = true
        do {
            try store.markTranscribing(id: record.id)
        } catch {
            // Best-effort, like every history write on this path: the decode only
            // needs the audio file.
            span.setAttribute(key: "history.error.code", value: (error as NSError).code)
            noteHistoryFailure(error)
        }
        records = store.records
        if canUpdateLifecycleUI(for: sessionID) {
            status = .transcribing
        }

        defer {
            activeTranscriptionIDs.remove(record.id)
            isTranscribing = !activeTranscriptionIDs.isEmpty
        }

        do {
            let recognitionStarted = ProcessInfo.processInfo.systemUptime
            lifecycleLogger.info("Dictation stage started", metadata: ["event": "stage_started", "stage": "recognition", "session": "\(sessionID ?? record.id)"])
            let audioURL = URL(fileURLWithPath: record.audioFilePath)
            let backstop = Self.recognitionBackstopSeconds(
                forAudioSeconds: record.durationSeconds ?? Self.estimatedAudioSeconds(of: audioURL),
                engine: configuration.engine,
                allowAppleFallback: configuration.allowAppleFallback
            )
            let transcription = transcription
            let outcome: TranscriptionOutcome
            do {
                // The engines carry their own decode deadlines; this backstop sits
                // well above them so that nothing on the path — model preparation,
                // a decode that never returns, the Apple Speech fallback — can hold
                // `isTranscribing` and the HUD forever. A timed-out record fails
                // and stays retryable.
                outcome = try await withAbandoningDeadline(seconds: backstop) {
                    try await transcription.transcribe(
                        audioURL: audioURL,
                        kind: configuration.engine,
                        model: configuration.model,
                        language: configuration.language,
                        cliConfiguration: configuration.cliConfiguration,
                        allowAppleFallback: configuration.allowAppleFallback,
                        capturedSamples: capturedSamples,
                        hints: configuration.hints
                    )
                }
            } catch AsyncTimeoutError.timedOut {
                lifecycleLogger.warning("Recognition backstop fired", metadata: ["event": "recognition_timeout", "session": "\(sessionID ?? record.id)", "timeout.seconds": "\(Int(backstop))"])
                throw TranscriptionError.timedOut(seconds: Int(backstop))
            }
            lifecycleLogger.info("Dictation stage finished", metadata: ["event": "stage_finished", "stage": "recognition", "session": "\(sessionID ?? record.id)", "elapsed_ms": "\((ProcessInfo.processInfo.systemUptime - recognitionStarted) * 1000)"])
            let text_processingStarted = ProcessInfo.processInfo.systemUptime
            lifecycleLogger.info("Dictation stage started", metadata: ["event": "stage_started", "stage": "text_processing", "session": "\(sessionID ?? record.id)"])
            let processed = await Task.detached(priority: .userInitiated) {
                let started = ProcessInfo.processInfo.systemUptime
                let text = AssistantTextProcessing.process(outcome.result.text, tone: configuration.writing.tone,
                    vocabulary: configuration.vocabulary, formatting: configuration.formatting,
                    recognizeCorrections: configuration.recognizeCorrections)
                let completed = ProcessInfo.processInfo.systemUptime
                return (text: text, workSeconds: completed - started, completed: completed)
            }.value
            let resumed = ProcessInfo.processInfo.systemUptime
            let finalText = processed.text
            lifecycleLogger.info("Dictation stage finished", metadata: ["event": "stage_finished", "stage": "text_processing", "session": "\(sessionID ?? record.id)", "elapsed_ms": "\((resumed - text_processingStarted) * 1000)", "worker_elapsed_ms": "\(processed.workSeconds * 1000)", "resume_delay_ms": "\(max(0, resumed - processed.completed) * 1000)"])
            let history_saveStarted = ProcessInfo.processInfo.systemUptime
            lifecycleLogger.info("Dictation stage started", metadata: ["event": "stage_started", "stage": "history_save", "session": "\(sessionID ?? record.id)"])
            var historySaved = true
            do {
                try store.markTranscribed(
                    id: record.id,
                    text: finalText,
                    durationSeconds: outcome.result.duration,
                    model: configuration.model.rawValue,
                    engine: outcome.engine.rawValue,
                    language: outcome.result.language,
                    rawRecognition: outcome.result.text,
                    appCategory: configuration.writing.category
                )
                recordDictionaryUsage(raw: outcome.result.text, final: finalText, configuration: configuration)
            } catch {
                // A recognized transcript is still delivered; only History missed it.
                historySaved = false
                noteHistoryFailure(error)
            }
            lifecycleLogger.info("Dictation stage finished", metadata: ["event": "stage_finished", "stage": "history_save", "session": "\(sessionID ?? record.id)", "elapsed_ms": "\((ProcessInfo.processInfo.systemUptime - history_saveStarted) * 1000)"])
            let ui_updateStarted = ProcessInfo.processInfo.systemUptime
            lifecycleLogger.info("Dictation stage started", metadata: ["event": "stage_started", "stage": "ui_update", "session": "\(sessionID ?? record.id)"])
            records = store.records
            let mayUpdateUI = canUpdateLifecycleUI(for: sessionID)
            if mayUpdateUI {
                selectedRecordID = record.id
            }
            lifecycleLogger.info("Dictation stage finished", metadata: ["event": "stage_finished", "stage": "ui_update", "session": "\(sessionID ?? record.id)", "elapsed_ms": "\((ProcessInfo.processInfo.systemUptime - ui_updateStarted) * 1000)"])
            if configuration.playSounds, mayUpdateUI {
            let completion_soundStarted = ProcessInfo.processInfo.systemUptime
            lifecycleLogger.info("Dictation stage started", metadata: ["event": "stage_started", "stage": "completion_sound", "session": "\(sessionID ?? record.id)"])

                soundService.play(.transcriptionSucceeded)
            lifecycleLogger.info("Dictation stage finished", metadata: ["event": "stage_finished", "stage": "completion_sound", "session": "\(sessionID ?? record.id)", "elapsed_ms": "\((ProcessInfo.processInfo.systemUptime - completion_soundStarted) * 1000)"])
            }
            telemetryOutcome = "success"
            span.setAttribute(key: "transcription.actual_engine", value: outcome.engine.rawValue)
            span.setAttribute(key: "outcome", value: telemetryOutcome)
            span.status = .ok
            logger.info(
                "Transcription completed",
                metadata: [
                    "transcription.engine": "\(outcome.engine.rawValue)",
                    "transcription.retry": "\(isRetry)"
                ]
            )
            activeTranscriptionIDs.remove(record.id)
            isTranscribing = !activeTranscriptionIDs.isEmpty
            recordSuccessfulDictation(text: finalText, rawText: outcome.result.text,
                                      speakingSeconds: outcome.result.duration ?? record.durationSeconds,
                                      engine: outcome.engine.rawValue, appBundleID: pasteTarget?.bundleIdentifier,
                                      configuration: configuration)
            guard configuration.deliversText else {
                if mayUpdateUI {
                    status = historySaved ? .success("Retry saved to History") : .failure("Could not save transcript")
                }
                return
            }
            await deliver(
                finalText,
                pasteTarget: pasteTarget,
                delivery: configuration.delivery,
                mayUpdateStatus: mayUpdateUI,
                purpose: configuration.purpose,
                quickKind: configuration.quickKind,
                clientReference: configuration.clientReference,
                accountIdentity: configuration.accountIdentity,
                sessionID: sessionID
            )
        } catch let error where configuration.discardsWithoutSpeech && Self.isNoSpeechError(error) {
            // A quiet capture the recognizer also found empty (a held hotkey with
            // nothing said, a muted mic): nothing to recover, so no retry entry and
            // no failure sound — the same outcome as the pre-recognition discard.
            lifecycleLogger.info("Capture discarded after recognition", metadata: ["event": "capture_discarded", "reason": "silent", "session": "\(sessionID ?? record.id)"])
            do {
                try store.delete(id: record.id)
            } catch {
                noteHistoryFailure(error)
            }
            // The record may never have reached History; the audio still goes.
            discardCapturedAudio(URL(fileURLWithPath: record.audioFilePath))
            records = store.records
            if selectedRecordID == record.id {
                selectedRecordID = records.first?.id
            }
            telemetryOutcome = "discarded"
            span.setAttribute(key: "outcome", value: telemetryOutcome)
            if canUpdateLifecycleUI(for: sessionID) {
                status = .failure("No speech detected")
            }
        } catch {
            do {
                try store.markFailed(id: record.id, message: error.localizedDescription)
            } catch {
                handleStorageError(error, message: "Could not update failed transcript")
            }
            records = store.records
            let mayUpdateUI = canUpdateLifecycleUI(for: sessionID)
            if mayUpdateUI {
                selectedRecordID = record.id
                lastError = error.localizedDescription
            }
            let errorType = String(describing: type(of: error))
            span.setAttributes([
                "error.type": .string(errorType),
                "error.code": .int((error as NSError).code),
                "outcome": .string(telemetryOutcome)
            ])
            span.status = .error(description: "Transcription failed")
            logger.warning(
                "Transcription failed; queued for retry",
                metadata: [
                    "error.code": "\((error as NSError).code)",
                    "transcription.engine": "\(configuration.engine.rawValue)",
                    "transcription.retry": "\(isRetry)"
                ]
            )
            DiagnosticsService.capture(
                error: error,
                category: "recording",
                code: String((error as NSError).code)
            )
            if mayUpdateUI {
                status = .failure("Transcription failed; queued for retry")
                if configuration.playSounds { soundService.play(.transcriptionFailed) }
            }
        }
    }

    #if DEBUG
    /// Invoked only by the opt-in verification command; exercises the real paste path.
    func verifyCorrectionPaste() {
        guard let target = (NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "agency.thatworks.WhiskerFlow.AcceptanceEditor" }) ?? NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.TextEdit" })) else { return }
        guard let url = target.bundleURL else { return }
        Task { @MainActor in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            guard let opened = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration) else { return }
            await deliver("Please send the report to Mark before Friday.", pasteTarget: opened,
                    delivery: .pasteAtCursor, mayUpdateStatus: true)
        }
    }
    func verifySelectionPreview() {
        guard let target = (NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "agency.thatworks.WhiskerFlow.AcceptanceEditor" }) ?? NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.TextEdit" })),
              let url = target.bundleURL else { return }
        Task { @MainActor in
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            guard assistant.captureSelection(), assistant.rewriteInput == "Please send the report to Mark before Friday." else {
                assistant.clearSelection(); assistant.message = "Select the complete synthetic verification sentence in TextEdit."; return
            }
            assistant.rewritePreview = "Please send the summary to Marc before Thursday."
            assistant.message = "Synthetic preview for local replacement verification; no AI request was sent."
        }
    }
    #endif

    func deliver(
        _ text: String,
        pasteTarget: NSRunningApplication?,
        delivery: DeliveryMode,
        mayUpdateStatus: Bool,
        purpose: AssistantController.CapturePurpose = .dictation,
        quickKind: AssistantRecordKind = .note,
        clientReference: String? = nil,
        accountIdentity: String? = nil,
        sessionID: UUID? = nil
    ) async {
        let deliveryStarted = ProcessInfo.processInfo.systemUptime
        let deliveryID = UUID()
        var deliveryOutcome = "failed"
        // Recognition has completed. Destination verification is separate work
        // and must not keep dictation controls in their transcription state.
        if mayUpdateStatus && canUpdateLifecycleUI(for: sessionID) {
            latestDeliveryID = deliveryID
            isTranscribing = false
            status = .delivering
        }
        lifecycleLogger.info("Text delivery started", metadata: ["event": "paste_started", "session": "\(sessionID?.uuidString ?? "")"])
        defer { lifecycleLogger.info("Text delivery returned", metadata: ["event": "paste_returned", "session": "\(sessionID?.uuidString ?? "")", "outcome": "\(deliveryOutcome)", "elapsed_ms": "\((ProcessInfo.processInfo.systemUptime - deliveryStarted) * 1000)"]) }
        if purpose != .dictation {
            switch purpose {
            case .quickCapture:
                _ = assistant.saveLocalDraft(text, kind: quickKind, clientReference: clientReference, accountIdentity: accountIdentity)
            case .selectionInstruction:
                guard mayUpdateStatus else { return }
                // Spoken instructions are captured locally; the user explicitly requests the preview.
                assistantVoiceInstruction = String(text.prefix(500))
                assistant.message = "Instruction captured. Review it in Assistant, then generate a preview."
            case .dictation: break
            }
            deliveryOutcome = "success"
            if mayUpdateStatus && latestDeliveryID == deliveryID && canUpdateLifecycleUI(for: sessionID) { status = .success(assistant.message ?? "Ready in Assistant") }
            return
        }
        switch delivery {
        case .copyOnly:
            pasteService.copy(text)
            deliveryOutcome = "copied"
            if mayUpdateStatus && latestDeliveryID == deliveryID && canUpdateLifecycleUI(for: sessionID) { status = .success("Copied to clipboard") }
        case .pasteAtCursor:
            // The text lands as soon as the keystroke is posted; insertion
            // verification (and clipboard restoration) can take up to a second
            // more, so report the paste then rather than holding "Pasting…".
            let receipt = await pasteService.paste(text, into: pasteTarget, replacing: nil) { [weak self] in
                guard let self, mayUpdateStatus, self.latestDeliveryID == deliveryID,
                      self.canUpdateLifecycleUI(for: sessionID) else { return }
                self.status = .success("Pasted")
            }
            deliveryOutcome = receipt.state.rawValue
            hasAccessibilityPermission = pasteService.hasAccessibilityPermission
            if mayUpdateStatus && latestDeliveryID == deliveryID && canUpdateLifecycleUI(for: sessionID) {
                lastPasteReceipt = receipt
                let final: AppStatus = receipt.state == .failed ? .failure(receipt.message) : .success(receipt.message)
                // Reassigning an equal status would re-arm the HUD's hide timer.
                if status != final { status = final }
            }
        }
    }

    func retryFailedPaste() async {
        guard !isRecording, !isTranscribing, !assistant.busy, let receipt = lastPasteReceipt,
              receipt.state == .failed, let selection = receipt.retrySelection else { return }
        assistant.busy = true
        let next = await pasteService.paste(receipt.text, into: selection.application, replacing: selection)
        assistant.busy = false
        if !isRecording && !isTranscribing { lastPasteReceipt = next }
    }

    func replaceAssistantSelection() async {
        guard !assistant.busy, !isRecording, !isTranscribing,
              let selection = assistant.selection, !assistant.rewritePreview.isEmpty else { return }
        assistant.busy = true
        let receipt = await pasteService.paste(assistant.rewritePreview, into: selection.application, replacing: selection)
        assistant.busy = false
        assistant.message = receipt.message
        lastPasteReceipt = receipt
        if receipt.state == .verified { assistant.clearSelection() }
    }

    /// Starts reading the target browser's tab without delaying the microphone.
    private func startWebsiteLookup() {
        websiteLookup?.cancel()
        websiteLookup = nil
        guard let target = pasteTargetApplication,
              assistant.writingStyles.needsWebsiteLookup(bundleIdentifier: target.bundleIdentifier) else { return }
        let bundleIdentifier = target.bundleIdentifier
        let pid = target.processIdentifier
        websiteLookup = Task.detached(priority: .userInitiated) {
            AppContextReader.readBrowser(bundleIdentifier: bundleIdentifier, pid: pid)
        }
    }

    private func makeTranscriptionConfiguration() -> TranscriptionJobConfiguration {
        let accountReady = assistant.synchronizeAccount()
        return TranscriptionJobConfiguration(
            engine: settings.engine,
            model: settings.model,
            language: settings.resolvedLanguage,
            vocabulary: accountReady ? effectiveVocabulary : Vocabulary.effective(shared: sharedVocabulary.vocabulary, personal: dictionary.vocabulary),
            formatting: settings.formatting,
            cliConfiguration: settings.cliConfiguration,
            allowAppleFallback: settings.allowAppleFallback,
            delivery: settings.delivery,
            playSounds: settings.playSounds,
            writing: assistant.resolveWritingStyle(AppContext(bundleIdentifier: pasteTargetApplication?.bundleIdentifier)),
            recognizeCorrections: assistant.saved.recognizeCorrections,
            hints: recognizerHints,
            purpose: assistant.capturePurpose,
            quickKind: assistant.quickCaptureKind,
            clientReference: accountReady ? assistant.saved.selectedClient : nil,
            accountIdentity: accountReady ? assistant.saved.accountIdentity : nil
        )
    }

    private func canUpdateLifecycleUI(for sessionID: UUID?) -> Bool {
        guard recordingCoordinator.phase == .idle else { return false }
        // A background retry (no session) must not take the status over from a
        // dictation that is still transcribing or pasting after its release.
        guard let sessionID else { return finishWorkTokens.isEmpty }
        return latestRecordingSessionID == sessionID
    }

    /// Budget for one whole recognition call: the sum of every deadline the path
    /// can legitimately spend — a cold model load, the engine's own decode budget,
    /// and the Apple Speech fallback — so the backstop only ever catches a wait no
    /// engine bounds. Every term is hardware-scaled and none is clamped, since the
    /// long-form, windowed and CLI budgets grow with the recording.
    nonisolated static func recognitionBackstopSeconds(
        forAudioSeconds duration: Double?,
        engine: TranscriptionEngineKind = .parakeetTDTv3,
        allowAppleFallback: Bool = true
    ) -> Double {
        // Unknown length: size the budgets like the engines' own unknown-length
        // ceiling rather than for a short clip.
        let seconds = max(0, duration ?? DecodeTimeoutPolicy.baseMaximumTimeout)
        let queuedDecode = DecodeTimeoutPolicy.gateQueueWait
        let engineBudget: Double
        switch engine {
        case .parakeetTDTv3:
            // The captured-samples decode can fail over to the file decode.
            engineBudget = DecodeTimeoutPolicy.modelPreparationWait
                + 2 * (queuedDecode + DecodeTimeoutPolicy.longFormTimeout(forAudioSeconds: seconds))
        case .whisperKit:
            let windowSeconds = BoundedDecodeWindowPolicy.windowSeconds
            let windows = max(1, BoundedDecodeWindowPolicy.frameRanges(
                totalFrames: Int64(seconds * 16_000), sampleRate: 16_000
            ).count)
            let perWindow = queuedDecode + DecodeTimeoutPolicy.timeout(forAudioSeconds: min(seconds, windowSeconds))
            engineBudget = DecodeTimeoutPolicy.modelPreparationWait + Double(windows) * perWindow
        case .appleSpeech:
            engineBudget = DecodeTimeoutPolicy.appleSpeechTimeout(forAudioSeconds: seconds)
        case .whisperCLI:
            engineBudget = WhisperCLIEngine.effectiveTimeout(floor: 180, audioSeconds: seconds)
        }
        let fallbackBudget = allowAppleFallback && engine != .appleSpeech
            ? DecodeTimeoutPolicy.appleSpeechTimeout(forAudioSeconds: seconds) : 0
        let margin = 60 * DecodeTimeoutPolicy.hardwareScale
        return engineBudget + fallbackBudget + margin
    }

    /// The recognizer ran and found no words — as opposed to failing to run.
    nonisolated static func isNoSpeechError(_ error: any Error) -> Bool {
        switch error {
        case TranscriptionError.emptyTranscript, WhisperCLIError.emptyTranscript,
             BoundedTranscriptAssemblyError.emptyTranscript:
            return true
        default:
            return false
        }
    }

    /// Recordings are 16 kHz mono 16-bit WAV, so the size gives the duration
    /// without opening the file.
    nonisolated static func estimatedAudioSeconds(of url: URL) -> Double? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else {
            return nil
        }
        return max(0, size.doubleValue - 44) / 32_000
    }

    private func normalizeInterruptedRecords() {
        for record in store.records where record.status.isInProgress {
            do {
                try store.markFailed(
                    id: record.id,
                    message: "Interrupted before transcription finished. Retry this recording."
                )
            } catch {
                handleStorageError(error, message: "Could not recover interrupted transcript")
            }
        }
    }

    /// Reports a history write that failed on the dictation path without failing
    /// the dictation itself: the transcript is still delivered.
    private func noteHistoryFailure(_ error: Error) {
        logger.error(
            "History write failed",
            metadata: ["error.code": "\((error as NSError).code)"]
        )
        DiagnosticsService.capture(
            error: error,
            category: "storage",
            code: String((error as NSError).code)
        )
        lastError = error.localizedDescription
    }

    private func handleStorageError(_ error: Error, message: String) {
        logger.error(
            "Storage failure",
            metadata: ["error.code": "\((error as NSError).code)"]
        )
        DiagnosticsService.capture(
            error: error,
            category: "storage",
            code: String((error as NSError).code)
        )
        lastError = error.localizedDescription
        status = .failure(message)
    }
}

extension InsightsStore {
    static func defaultStore() -> InsightsStore {
        InsightsStore(databaseURL: StorageLocations.applicationSupportRootOrTemporary().appendingPathComponent("insights.sqlite"))
    }

    static func temporaryStore() -> InsightsStore {
        InsightsStore(databaseURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("WhiskerFlow-insights-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("insights.sqlite"))
    }
}

extension TranscriptStore {
    static func defaultStore() -> TranscriptStore {
        let root = StorageLocations.applicationSupportRootOrTemporary()
        return TranscriptStore(
            fileURL: root.appendingPathComponent("transcripts.json"),
            recordingsDirectory: AudioFileWriter.recordingsDirectoryURL()
        )
    }
}

/// How one dictation was written, for the Dictate screen.
struct DictationStyleReceipt: Equatable {
    var resolution: WritingStyleResolution
    var appName: String?
}

extension DictationStyleReceipt {
    var description: String {
        let style = "\(resolution.category.displayName) · \(resolution.tone.displayName)"
        guard let appName else { return "Written as \(style)" }
        switch resolution.source {
        case .website: return "Written as \(style) for a website in \(appName)"
        case .appOverride: return "Written as \(style) · your setting for \(appName)"
        case .builtInApp, .fallback: return "Written as \(style) for \(appName)"
        }
    }
}
