import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import Logging
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

    var hudFailureMessage: String? {
        guard case .failure(let message) = self else { return nil }
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
    struct TranscriptionJobConfiguration {
        let engine: TranscriptionEngineKind
        let language: String?
        /// Which recogniser hears the chosen language, and whether it's translated.
        var languagePlan = DictationLanguagePlan(language: "en", translateToEnglish: false)
        let vocabulary: Vocabulary
        let formatting: FormattingOptions
        let allowAppleFallback: Bool
        let delivery: DeliveryMode
        let playSounds: Bool
        /// Resolved from the app at key press; a browser's tab can refine it at release.
        var writing = WritingStyleResolution(category: .other, tone: .formal, source: .fallback)
        var recognizeCorrections = false
        var cleanupModel: CleanupModel?
        var cleanupVariety: CleanupEnglishVariety = .british
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
        /// Set when a toggle recording stopped itself: nobody may be at the
        /// keyboard, so the text goes to History and is never pasted.
        var autoStop: ToggleAutoStop?

        /// Kept on the History record, so a retry finishes an assistant capture.
        var captureIntent: TranscriptCaptureIntent? {
            switch purpose {
            case .dictation: return nil
            case .quickCapture:
                return TranscriptCaptureIntent(purpose: .quickCapture, quickKind: quickKind, clientReference: clientReference)
            case .selectionInstruction: return TranscriptCaptureIntent(purpose: .selectionInstruction)
            }
        }
    }

    /// Upper bound on how long quitting waits for a transcript to finish saving.
    /// A release-time decode can take far longer on a slow Mac; its record is
    /// already saved as transcribing, and the next launch marks it for retry.
    private static let shutdownDrainSeconds: TimeInterval = 5

    var records: [TranscriptRecord] = []
    var selectedRecordID: TranscriptRecord.ID?
    var status: AppStatus = .idle {
        didSet {
            lifecycleLogger.info("Dictation state changed", metadata: ["event": "state_changed", "state": "\(status.diagnosticName)", "session": "\(latestRecordingSessionID?.uuidString ?? "")", "recording": "\(isRecording)", "transcribing": "\(isTranscribing)"])
        }
    }
    var isRecording = false { didSet { automaticCorrections.setBusy(isRecording || isTranscribing) } }
    var isTranscribing = false { didSet { automaticCorrections.setBusy(isRecording || isTranscribing) } }
    var audioLevel: Float = 0
    /// Rolling verdict on the live input, surfaced as a HUD warning.
    var signalQuality: AudioSignalQuality = .unknown
    /// Live transcript shown in the HUD while streaming dictation is active.
    var liveText = ""
    var recordingStartedAt: Date?
    var modelState: ModelState = .unloaded
    var hasAccessibilityPermission = false
    private(set) var hasGlobeKeyConflict = false
    /// Another app's Secure Event Input is hiding the shortcut from WhiskerFlow.
    var isShortcutPausedBySecureInput = false
    private var secureInputHeldElsewhere = false
    private var secureInputMonitor: SecureInputMonitor?
    var devices: [AudioInputDescriptor] = []
    var lastError: String?
    var searchText = ""
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
    let store: TranscriptStore
    let transcription: TranscriptionService
    let meetingCapture: MeetingCaptureCoordinator
    private let atlasAuthSession = AtlasAuthSession()
    let live: LiveDictationSession
    let mediaPauser = DictationMediaPauser()
    let translator = DictationTranslator()
    /// Why the last dictation wasn't translated (a language still to download).
    var translationNotice: String?
    private var devicePrepareTask: Task<Void, Never>?
    let recordingCoordinator = RecordingCoordinator()
    /// The dictation lifecycle. Set once in `init`, as soon as `self` exists.
    @ObservationIgnored private(set) var dictation: DictationLifecycle!
    private(set) var pasteService: any TextDeliveryService
    var lastPasteReceipt: PasteDeliveryReceipt?
    var assistantVoiceInstruction = ""
    var meetingAssistant: MeetingAssistantController { meetingCapture.assistant }
    private var correctionEditBaselines: [UUID: String] = [:]
    /// What the latest paste or History edit added to the Dictionary.
    private var learnedBySession: [UUID: [DictionaryChange]] = [:]
    private var assessedPairsBySession: [UUID: [DictionaryPair]] = [:]
    let automaticCorrections = AutomaticCorrectionLearner()
    let assistant: AssistantController
    let dictionary: DictionaryStore
    let insights: InsightsStore
    /// The company board in Atlas: daily counts go up, everyone's come back.
    let leaderboard: LeaderboardController
    /// Recomputed when a dictation is recorded, on reset and on a typing-speed change.
    private(set) var insightsSummary = InsightsSummary(buckets: [], recentSamples: [])
    /// The latest dictation's Insights update, readable so tests can await it.
    private(set) var insightRecording: Task<Void, Never>?
    /// With history off, the last transcript stays in memory for a few minutes
    /// so Copy keeps working. It is never written to disk.
    private(set) var ephemeralTranscript: TranscriptRecord?
    private var ephemeralTranscriptExpiry: Task<Void, Never>?
    private var retentionPruneTask: Task<Void, Never>?
    nonisolated static let ephemeralTranscriptLifetimeSeconds: UInt64 = 10 * 60
    private let correctionMonitor = PasteCorrectionMonitor()
    let soundService = SoundService()
    let microphonePermission: MicrophonePermissionController
    let sharedVocabulary: SharedVocabularyService
    private var hotkeyMonitor: HotkeyMonitor?
    private let globeKeyShortcutOverride = GlobeKeyShortcutOverride()
    private var assistantHotkeyMonitors: [HotkeyMonitor] = []
    var assistantShortcutActive = false
    static let selectionShortcut = KeyCombo(keyCode: 14, modifiers: [.command, .option, .shift])
    static let quickCaptureShortcut = KeyCombo(keyCode: 45, modifiers: [.command, .option, .shift])
    static let bookmarkShortcut = KeyCombo(keyCode: 11, modifiers: [.command, .option, .shift])
    /// ⌥⇧⌘R, the same as the "Toggle Meeting Capture" menu command.
    static let meetingShortcut = KeyCombo(keyCode: 15, modifiers: [.command, .option, .shift])
    private var hotKeyRegistrar: CarbonHotKeyRegistrar?
    private var registeredShortcuts: RegisteredShortcutController?
    private var meetingShortcutPresses = ShortcutPressDeduplicator()
    private var meetingCoachHUD: MeetingCoachHUDController?
    private var callPromptHUD: CallPromptHUDController?
    private var hudController: RecordingHUDController?
    private var audioDeviceMonitor: AudioDeviceChangeMonitor?
    private var deviceRefreshTask: Task<Void, Never>?
    private var warmUpTask: Task<Void, Never>?
    let cleanup = CleanupService()
    private var meetingWarmUpTask: Task<Void, Never>?
    let pendingPersistWork = PendingWorkTracker()
    /// An injected history outside the UI preview: a test. It never touches
    /// the user's meetings, Cleanup model or Atlas.
    private let isTestFixture: Bool
    private var hasStarted = false
    var recordingIntentActive = false
    var pasteTargetApplication: NSRunningApplication?
    /// How the latest dictation was written, shown on the Dictate screen.
    var lastWritingStyle: DictationStyleReceipt?
    var activeTranscriptionIDs: Set<UUID> = []
    var latestRecordingSessionID: UUID?
    /// Readable so tests can await a Retry All instead of polling.
    private(set) var retryAllTask: Task<Void, Never>?
    private var meetingStorageTask: Task<Void, Never>?
    /// Cached Keychain state. Views and the hotkey path read these instead of the
    /// Keychain, which can block the main thread on a slow securityd or an ACL
    /// prompt; see `refreshAtlasAccountCache()`.
    private var atlasTokenAvailable = false
    private var atlasAccountIdentity: String?
    /// Why the latest toggle recording stopped by itself, for the Dictate screen.
    var autoStopNotice: AutoStopNotice?
    /// Keeps App Nap off while the hotkey is armed. A menu-bar utility with no
    /// visible window is otherwise napped: its queues are throttled and its
    /// priority lowered, which delays the first hotkey press after idle.
    private var hotkeyReadinessActivity: NSObjectProtocol?
    var isSigningInToAtlas = false
    var atlasSignInError: String?
    var atlasSignInConfirmation: String?
    /// Why the last sign-out didn't happen.
    var atlasSignOutError: String?

    init(
        settings: AppSettings? = nil,
        store: TranscriptStore? = nil,
        dictionaryStore: DictionaryStore? = nil,
        insightsStore: InsightsStore? = nil,
        microphonePermission: MicrophonePermissionController? = nil,
        pasteService: (any TextDeliveryService)? = nil,
        onboardingStore: (any OnboardingProgressStoring)? = nil,
        transcription: TranscriptionService? = nil,
        correctionAssessor: ((CorrectionEdit) async throws -> [VocabularyCorrection])? = nil
    ) {
        let resolvedSettings = settings ?? AppSettings()
        let resolvedMicrophonePermission = microphonePermission ?? MicrophonePermissionController(
            provider: AVCaptureMicrophoneAuthorizationProvider()
        )
        let transcription = transcription ?? TranscriptionService()
        self.settings = resolvedSettings
        self.store = store ?? .defaultStore()
        self.assistant = store == nil && !UIPreview.isEnabled ? .defaultStore() : AssistantController()
        self.dictionary = dictionaryStore ?? (store == nil
            ? .defaultStore(legacyVocabulary: resolvedSettings.vocabulary)
            : DictionaryStore(legacyVocabulary: resolvedSettings.vocabulary))
        // An injected history (tests, UI preview) never writes the real Insights.
        self.insights = insightsStore ?? (store == nil && !UIPreview.isEnabled ? .defaultStore() : .temporaryStore())
        self.microphonePermission = resolvedMicrophonePermission
        self.transcription = transcription
        let atlasTokenStore = resolvedSettings.atlasTokenStore
        isTestFixture = store != nil && !UIPreview.isEnabled
        // Tests keep meeting recordings in a temporary folder and never reach Atlas.
        let meetingTestRoot = isTestFixture
            ? FileManager.default.temporaryDirectory.appendingPathComponent("WhiskerFlowMeetings-\(UUID().uuidString)")
            : nil
        self.meetingCapture = MeetingCaptureCoordinator(
            settings: resolvedSettings,
            microphonePermission: resolvedMicrophonePermission,
            transcription: transcription,
            store: meetingTestRoot.map {
                EncryptedMeetingChunkStore(rootURL: $0.appendingPathComponent("MeetingRecordings", isDirectory: true),
                                           keyProvider: FixedMeetingChunkKeyProvider(key: SymmetricKey(size: .bits256)))
            },
            clientProvider: meetingTestRoot.map { _ in { nil } },
            // Tests and the UI preview must never read or write the user's meetings.
            library: store == nil && !UIPreview.isEnabled ? .production() : .ephemeral(),
            assistant: store == nil && !UIPreview.isEnabled ? nil : MeetingAssistantController(
                rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("WhiskerFlowAssistant-\(UUID().uuidString)")),
            // The same Keychain item as the settings, so a sign-out reaches both.
            tokenReader: { atlasTokenStore.read() },
            diskStateReader: meetingTestRoot.map { root in { MeetingCaptureCoordinator.readLocalDiskState(root: root) } }
                ?? { MeetingCaptureCoordinator.readLocalDiskState() }
        )
        let insights = self.insights
        // Tests and the UI preview never report to Atlas.
        let reportsUsage = store == nil && !UIPreview.isEnabled
        self.leaderboard = LeaderboardController(
            client: { [resolvedSettings] in
                guard reportsUsage, !resolvedSettings.atlasDeviceToken.isEmpty,
                      let url = URL(string: resolvedSettings.atlasBaseURL), url.scheme == "https" else { return nil }
                return LeaderboardAtlasClient(baseURL: url, token: resolvedSettings.atlasDeviceToken)
            },
            usageDays: { tally in LeaderboardReport.days(buckets: insights.buckets, meetings: tally) },
            defaults: resolvedSettings.userDefaults
        )
        self.sharedVocabulary = SharedVocabularyService(client: { [resolvedSettings] in
            guard reportsUsage, !resolvedSettings.atlasDeviceToken.isEmpty,
                  let url = URL(string: resolvedSettings.atlasBaseURL), url.scheme == "https" else { return nil }
            return GlossaryAtlasClient(baseURL: url, token: resolvedSettings.atlasDeviceToken)
        }, cacheURL: reportsUsage ? SharedVocabularyService.defaultCacheURL
            // Sign-out deletes this file: tests and the preview keep their own.
            : FileManager.default.temporaryDirectory.appendingPathComponent("WhiskerFlowGlossary-\(UUID().uuidString).json"))
        self.live = LiveDictationSession(transcription: transcription)
        enforcesAtlasSignIn = reportsUsage
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
        // The settings' defaults: `.standard` in the app, a test's own suite in tests.
        onboarding = OnboardingController(store: onboardingStore ?? UserDefaultsOnboardingStore(defaults: resolvedSettings.userDefaults))
        dictation = DictationLifecycle(app: self)
        if (store == nil && !UIPreview.isEnabled) || UIPreview.mode == "coach" {
            meetingCoachHUD = MeetingCoachHUDController(controller: meetingCapture.assistant, appState: self)
        }
        if (store == nil && !UIPreview.isEnabled) || UIPreview.mode == "call-prompt" || UIPreview.mode.hasPrefix("recording-notice") {
            callPromptHUD = CallPromptHUDController(appState: self)
        }
        applyCoachSettings()
        // Until the Keychain proves otherwise, the account is the one the
        // assistant state was last saved for.
        atlasAccountIdentity = assistant.saved.accountIdentity
        refreshAtlasAccountCache()
        assistant.accountIdentityProvider = { [weak self] in self?.atlasAccountIdentity }
        meetingCapture.assistant.accountIdentityProvider = assistant.accountIdentityProvider
        // After an explicit sign-out only: a token that merely can't be read
        // (locked Keychain, busy securityd) must not cost the user a meeting.
        meetingCapture.requiresSignIn = { [weak self] in self?.settings.signedOutOfAtlas ?? false }
        meetingCapture.library.onRecordingFinished = { [weak self] startedAt, durationMs in
            self?.leaderboard.recordMeeting(startedAt: startedAt, durationMs: durationMs)
        }
        if store == nil && !UIPreview.isEnabled { assistant.synchronizeAccount() }
        assistant.requestTransport = { [weak self] in
            guard let self, !UIPreview.isEnabled, !self.isTestFixture, !self.settings.atlasDeviceToken.isEmpty,
                  let url = URL(string: self.settings.atlasBaseURL) else { throw AssistantError.message("Connect Atlas in Meeting setup first.") }
            return AssistantAtlasClient(baseURL: url, token: self.settings.atlasDeviceToken)
        }
        meetingCapture.assistant.bookmarkSync = { [weak self] request in
            guard let self else { throw AssistantError.message("Assistant is unavailable.") }
            guard !self.earlierSignInMeetings.contains(request.localSessionID) else {
                throw AssistantError.message("Recorded under an earlier Atlas sign-in, so this stays on this Mac.")
            }
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
            return self.settings.cleanupEnabled && self.settings.rememberCorrections && !UIPreview.isEnabled
        }
        correctionMonitor.onEdit = { [weak self] original, edited, sessionID, application in
            self?.automaticCorrections.enqueue(original: original, edited: edited, sessionID: sessionID, application: application)
        }
        automaticCorrections.assess = correctionAssessor ?? { [weak self] edit in
            guard let self else { throw CancellationError() }
            return try await self.cleanup.assess(edit)
        }
        automaticCorrections.onValidated = { [weak self] edit, approved in self?.applyValidatedCorrections(edit, approved: approved) }
        automaticCorrections.configure(enabled: self.settings.cleanupEnabled && self.settings.rememberCorrections)
        dictation.observeLevels()
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
        live.onConfigurationChange = { [weak self] in self?.dictation.handleAudioConfigurationChange() }
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
            successMessage: status.hudNotificationMessage,
            failureMessage: status.hudFailureMessage
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

  // MARK: Telling the others they are being recorded

  var recordingReminder: MeetingRecordingReminder { meetingCapture.recordingReminder }
  var isRecordingReminderVisible: Bool { recordingReminder.isVisible(during: activeMeetingSessionID) }
  var meetingRecordingNoticeText: String { MeetingRecordingNotice.text(custom: settings.meetingRecordingNotice) }

  /// Puts the notice on the clipboard only when the user clicks Copy.
  func copyMeetingRecordingNotice() {
    recordingReminder.copy(meetingRecordingNoticeText, using: copy)
  }

  func dismissRecordingReminder() { recordingReminder.dismiss() }

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
    assistant.isCoachEnabled = settings.coachEnabled
    assistant.onCoachEnabledChange = { [weak self] enabled in
      guard let self, self.settings.coachEnabled != enabled else { return }
      self.settings.coachEnabled = enabled
    }
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

    /// Production builds need an Atlas sign-in before anything else works.
    /// Tests and the UI preview don't, unless a test turns it on.
    @ObservationIgnored var enforcesAtlasSignIn = false
    /// Bumped when a dictation press needs sign-in, to bring the window up.
    var atlasSignInRequests = 0

    var requiresAtlasSignIn: Bool {
        if UIPreview.isEnabled { return UIPreview.mode == "sign-in" }
        #if DEBUG
        if ProcessInfo.processInfo.environment["WHISKERFLOW_SKIP_ATLAS_SIGN_IN"] == "1" { return false }
        #endif
        return enforcesAtlasSignIn && !isAtlasPaired
    }

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
        // A sign-in or reconnect fetches the glossary now; a sign-out stops using the old token.
        sharedVocabulary.credentialsChanged()
        // A failed Keychain read (locked keychain, re-signed build, busy securityd)
        // looks exactly like "no token". Keep the last known account so a transient
        // failure cannot wipe the assistant's per-account state. Only an explicit
        // sign-out (`signOutOfAtlas()`) clears it, and a real account change always
        // arrives with a new token.
        guard !token.isEmpty else { return }
        // A token is a sign-in, however it got here.
        if settings.signedOutOfAtlas { settings.signedOutOfAtlas = false }
        let identity = Self.accountIdentity(forToken: token)
        if atlasAccountIdentity != identity { atlasAccountIdentity = identity }
    }

    var hasScreenRecordingPermission = false

    /// Cached, because the capacity query can synchronously wait on CacheDelete
    /// XPC; it is re-measured off the main thread by
    /// `refreshMeetingStorageAvailability()` at launch, on activation and
    /// every 30 s while the Meetings screen (its only reader) is showing. The
    /// coordinator re-checks before any capture starts, so the optimistic
    /// launch value never records on a full disk.
    private(set) var isMeetingStorageAvailable = true

    func refreshMeetingStorageAvailability() {
        guard !UIPreview.isEnabled, meetingStorageTask == nil else { return }
        let meetingCapture = meetingCapture
        meetingStorageTask = Task { @MainActor [weak self] in
            // The coordinator's reader, which runs off the main actor.
            let state = await meetingCapture.localDiskState()
            guard let self else { return }
            self.meetingStorageTask = nil
            let available = state == "ready"
            if self.isMeetingStorageAvailable != available { self.isMeetingStorageAvailable = available }
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
        loadInsights()
        startRetentionPruning()
        refreshAccessibilityPermission()
        refreshMicrophonePermission()
        refreshScreenRecordingPermission()
        // SwiftUI's settings Form is backed by NSTableView. Publishing the initial
        // catalog synchronously while scene restoration is laying it out can
        // re-enter its delegate and crash AppKit; defer one actor turn.
        refreshDevices()
        sharedVocabulary.start()
        sharedVocabulary.startPeriodicRefresh()
        startAudioDeviceMonitor()
        hotkeyReadinessActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Respond immediately to the dictation hotkey"
        )
        startHotkeyMonitor()
        startSecureInputMonitor()
        prepareNextCapture()
        refreshMeetingStorageAvailability()
        meetingCapture.start()
        hudController = RecordingHUDController(appState: self)
        warmUpEngine()
        configureCleanup()
        warmUpMeetingEngine()
        startLeaderboardReporting()
        // Whisper was removed; free the space its downloaded models took.
        Task.detached(priority: .background) { ModelStoragePaths.removeWhisperModels() }
    }

    /// The first report counts the meetings already in the library, so it
    /// waits for the library to load.
    private func startLeaderboardReporting() {
        Task { @MainActor [weak self] in
            for _ in 0..<120 where self?.meetingLibrary.isLoaded == false {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard let self else { return }
            if self.meetingLibrary.isLoaded {
                self.leaderboard.seedMeetingsIfNeeded(self.meetingLibrary.entries.map { ($0.startedAt, $0.durationMs ?? 0) })
            }
            self.leaderboard.startPeriodicReporting()
        }
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
        stopRegisteredShortcuts()
        hotkeyMonitor?.stop()
        assistantHotkeyMonitors.forEach { $0.stop() }
        assistantHotkeyMonitors = []
        hotkeyMonitor = nil
        secureInputMonitor?.stop()
        secureInputMonitor = nil
        if !globeKeyShortcutOverride.restore() {
            logger.error("Could not restore the macOS Globe-key action")
        }
        audioDeviceMonitor?.stop()
        audioDeviceMonitor = nil
        meetingCapture.stopMonitoring()
    }

    /// Wind down for termination. Monitors go first so no new session can start,
    /// then everything still in flight shares one `shutdownDrainSeconds` budget —
    /// a wedged decode must not keep the process alive past it.
    func shutdown() async {
        stopMonitors()
        automaticCorrections.stop()
        await cleanup.shutdown()
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
            mediaPauser.dictationEnded()
            _ = recordingCoordinator.forceIdle()
            isRecording = false
        case .recording:
            // The token bridges the hop until `finishRecording` registers its own.
            let token = pendingPersistWork.begin()
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.dictation.finishRecording()
                self.pendingPersistWork.end(token)
            }
        case .finishing, .idle:
            break
        }

        _ = await pendingPersistWork.waitUntilIdle(timeout: Self.shutdownDrainSeconds)
    }

    func warmUpEngine() {
        guard !UIPreview.isEnabled else { return }
        prepareDictationLanguage()
        warmUpTask?.cancel()
        let engine = settings.engine
        let language = settings.resolvedLanguage
        let allowFallback = settings.allowAppleFallback
        guard engine == .parakeetTDTv3 else {
            modelState = .ready
            return
        }
        modelState = .preparing
        let needsDownload = !ParakeetTDTv3Engine.isModelDownloaded
        modelDownload = ModelDownloadStatus(
            tracker: needsDownload ? .parakeetFirstDownload : .parakeetCachedLoad,
            needsDownload: needsDownload
        )
        warmUpTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let ready = await transcription.prepare(kind: engine, language: language)
            if ready { self.modelDownload.tracker?.finish() }
            await transcription.prepareHints(self.recognizerHints, kind: engine)
            guard !Task.isCancelled,
                  self.settings.engine == engine,
                  self.settings.resolvedLanguage == language else { return }
            if ready {
                DiagnosticsService.breadcrumb(category: "model", metadata: ["model": engine.modelIdentifier])
                self.modelState = .ready
            } else if allowFallback {
                self.modelState = .failed("Could not load Parakeet. Apple Speech will be used.")
            } else {
                self.modelState = .failed("Could not load Parakeet. Apple Speech fallback is off.")
            }
        }
    }

    func reloadHotkey() {
        guard !UIPreview.isEnabled, let hotkeyMonitor else { return }
        configureGlobeKeyShortcut()
        hotkeyMonitor.update(combo: settings.activeHotkeyCombo)
        registeredShortcuts?.setDictationCombo(settings.activeHotkeyCombo)
    }

    func warmUpMeetingEngine() {
        guard !UIPreview.isEnabled else { return }
        meetingWarmUpTask?.cancel()
        // Not gated on automatic recording: "Record" and "Record this
        // meeting?" work with it off, and share the dictation model.
        guard isAtlasPaired else {
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
        registeredShortcuts?.setSuspended(active)
    }

    /// The team glossary plus the user's personal rules, applied to every
    /// transcript. Personal rules override shared ones on conflict.
    var effectiveVocabulary: Vocabulary {
        dictationVocabulary(usesCleanup: settings.cleanupEnabled, includesClient: true)
    }

    func dictationVocabulary(usesCleanup: Bool, includesClient: Bool) -> Vocabulary {
        let shared = includesClient ? Vocabulary.effective(shared: sharedVocabulary.vocabulary, personal: assistant.vocabulary) : sharedVocabulary.vocabulary
        return Vocabulary.effective(shared: shared, personal: usesCleanup ? dictionary.vocabulary : dictionary.explicitVocabulary)
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

    /// Hints for the recognisers, from the Dictionary and the read-only libraries.
    var recognizerHints: RecognizerHints {
        RecognizerHints(
            terms: DictionaryBiasing.terms(personal: dictionary.entries, readOnly: readOnlyDictionaryRules.map(\.rule)),
            appleSpeech: settings.biasAppleSpeech && !settings.cleanupEnabled,
            parakeet: settings.biasParakeet && !settings.cleanupEnabled
        )
    }

    private func applyValidatedCorrections(_ edit: AutomaticCorrectionLearner.Pending, approved: [VocabularyCorrection]) {
        guard settings.cleanupEnabled, settings.rememberCorrections else { return }
        let pairs = approved.map { DictionaryPair(heard: $0.find, written: $0.replaceWith) }
        let earlier = learnedBySession[edit.sessionID] ?? []
        let superseded = earlier.filter { !pairs.contains($0.pair) }
        assessedPairsBySession[edit.sessionID] = pairs
        let confirmedElsewhere = Set(assessedPairsBySession.filter { $0.key != edit.sessionID }.flatMap(\.value))
        var learned: [DictionaryChange] = []
        dictionary.update { dictionary in
            for change in superseded.reversed() where !confirmedElsewhere.contains(change.pair)
                && dictionary.entries.contains(where: { $0.id == change.after.id && $0.origin == .learned && $0.pair == change.pair }) {
                DictionaryLearning.revert(change, in: &dictionary)
            }
            learned = DictionaryLearning.learnAssessed(pairs, in: &dictionary)
        }
        if learnedBySession.count >= 100 {
            learnedBySession.removeAll()
            assessedPairsBySession = [edit.sessionID: pairs]
        }
        learnedBySession[edit.sessionID] = earlier.filter { pairs.contains($0.pair) } + learned
        if let notice = dictionaryNotice, !superseded.isEmpty {
            let kept = notice.changes.filter { change in !superseded.contains { $0.after.id == change.after.id } }
            dictionaryNotice = kept.isEmpty ? nil : DictionaryNotice(changes: kept, isSaved: dictionary.errorMessage == nil)
        }
        lifecycleLogger.info("Corrections learned", metadata: ["event": "dictionary_learned", "corrections": "\(pairs.count)", "learned": "\(learned.count)"])
        if !learned.isEmpty { dictionaryNotice = DictionaryNotice(changes: learned, isSaved: dictionary.errorMessage == nil) }
    }

    func removeCorrection(_ entry: DictionaryEntry) {
        dictionary.update { dictionary in
            dictionary.entries.removeAll { $0.id == entry.id }
            for rule in entry.rules { dictionary.reject(DictionaryPair(heard: rule.find, written: rule.replaceWith)) }
        }
    }

    func undoDictionaryNotice() {
        guard let notice = dictionaryNotice else { return }
        dictionary.update { dictionary in
            for change in notice.changes.reversed() { DictionaryLearning.undo(change, in: &dictionary) }
        }
        dictionaryNotice = nil
    }

    /// Counts which entries shaped a delivered transcript, then retires
    /// auto-added entries that have gone unused.
    /// Counting compiles a regex per entry, so it runs off the main actor and
    /// never delays the paste that follows the history save.
    func recordDictionaryUsage(raw: String, final: String, configuration: TranscriptionJobConfiguration) {
        guard !raw.isEmpty else { return }
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
            guard let refreshed = try? await CoreAudioDeviceCatalog.availableInputsInBackground(),
                  !Task.isCancelled else { return }
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
    func prepareNextCapture() {
        guard !UIPreview.isEnabled, settings.legacySelectedDeviceID == nil,
              microphonePermission.authorizationState == .authorized,
              recordingCoordinator.phase == .idle else { return }
        live.prepareCapture(selection: settings.selectedInput)
    }

    private func startAudioDeviceMonitor() {
        let monitor = AudioDeviceChangeMonitor { [weak self] in
            guard let self else { return }
            self.refreshDevices()
            self.live.invalidatePreparedCapture()
            // A headset connecting posts a burst of changes over a few seconds;
            // building during it wedged engines on 2 October. Prepare once the
            // devices have been quiet for a moment.
            self.devicePrepareTask?.cancel()
            self.devicePrepareTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard !Task.isCancelled else { return }
                self?.prepareNextCapture()
            }
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
        if hotkeyMonitor != nil { configureGlobeKeyShortcut() }
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

    /// The "Toggle Meeting Capture" menu command. Chosen from the menu with
    /// the mouse it always toggles; by its key equivalent it toggles unless the
    /// registered ⌥⇧⌘R already did for that same key press.
    func toggleMeetingCaptureFromMenu() {
        let event = NSApp.currentEvent
        toggleMeetingCapture(keyPressedAt: event?.type == .keyDown ? event?.timestamp : nil)
    }

    private func toggleMeetingCapture(keyPressedAt eventTime: TimeInterval?) {
        guard meetingShortcutPresses.shouldAct(eventTime: eventTime) else { return }
        toggleMeetingCapture()
    }

  func refreshMeetingConfiguration() {
        guard !UIPreview.isEnabled else { return }
        refreshAtlasAccountCache()
        refreshMeetingStorageAvailability()
        warmUpMeetingEngine()
        meetingCapture.refreshConfiguration()
  }

  /// The answer to the one-time automatic recording notice in the main window.
  func answerAutomaticRecordingNotice(turnOn: Bool) {
        settings.answerMeetingModeChoice(enabled: turnOn)
        if turnOn { refreshMeetingConfiguration() }
  }

  func refreshMeetingSchedule() {
        guard !UIPreview.isEnabled else { return }
    meetingCapture.refreshSchedule()
  }

  /// For the Meetings screen as it opens: fetches only if the list is over a
  /// minute old.
  func refreshMeetingScheduleIfStale() {
        guard !UIPreview.isEnabled else { return }
    meetingCapture.refreshScheduleIfStale()
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
        completeAtlasSignIn(token: token)
        Task { await self.leaderboard.refresh() }
      } catch {
        atlasSignInError = error.localizedDescription
      }
    }
  }

    /// Stores a token Atlas returned and starts what needs it.
    func completeAtlasSignIn(token: String) {
        settings.atlasDeviceToken = token
        settings.signedOutOfAtlas = false
        refreshMeetingConfiguration()
        resumeAtlasWork()
        atlasSignOutError = nil
        atlasSignInConfirmation = "Connected to Atlas. Meeting Mode is ready."
        if case .failure = status { status = .idle }
    }

    /// Restarts the account-bound work `signOutOfAtlas()` stopped. Before
    /// `start()` there is nothing to restart: it starts everything itself.
    private func resumeAtlasWork() {
        guard hasStarted, isAtlasPaired else { return }
        sharedVocabulary.startPeriodicRefresh()
        leaderboard.startPeriodicReporting()
        meetingCapture.resumeAfterSignIn()
    }

    // MARK: - Atlas sign-out

    private var earlierSignInMeetings: AtlasEarlierSignInMeetings {
        AtlasEarlierSignInMeetings(defaults: settings.userDefaults)
    }

    /// Whether meeting recording is unavailable because of an explicit sign-out.
    var meetingRecordingRequiresSignIn: Bool { meetingCapture.requiresSignIn() }

    /// Why signing out has to wait, or nil when it can go ahead.
    var atlasSignOutBlocker: String? {
        if UIPreview.isEnabled {
            switch UIPreview.mode {
            case "sign-out-blocked": return AtlasSignOut.blocker(recording: false, unsentRecordings: 2)
            case "sign-out-checking": return AtlasSignOut.blocker(recording: false, unsentRecordings: 0, recordingCheck: .checking)
            case "sign-out-check-failed": return AtlasSignOut.blocker(recording: false, unsentRecordings: 0, recordingCheck: .failed)
            default: return nil
            }
        }
        return meetingCapture.signOutBlocker
    }

    /// Meeting notes and bookmarks saved on this Mac that Atlas doesn't have.
    var unsyncedMeetingItemCount: Int {
        meetingLibrary.entries.reduce(0) { $0 + $1.notes.filter { $0.syncState != .synced }.count }
            + meetingAssistant.bookmarks.filter { $0.syncState != .synced }.count
    }

    var atlasSignOutConfirmation: String {
        AtlasSignOut.confirmation(unsyncedMeetingItems: unsyncedMeetingItemCount)
    }

    /// Signs out of Atlas after the user confirmed. Removes the device token
    /// and everything on this Mac that came from the account, stops the work
    /// that used it and returns to the sign-in window. Local work (history,
    /// dictionary, Insights, settings, meeting transcripts and notes, drafts)
    /// stays. Atlas has no tool to revoke a device token, so the token stays
    /// valid in Atlas until it is removed there.
    @discardableResult
    func signOutOfAtlas() -> Bool {
        guard !UIPreview.isEnabled, !isSigningInToAtlas else { return false }
        if let blocker = atlasSignOutBlocker {
            atlasSignOutError = blocker
            return false
        }
        // Every meeting on this Mac so far belongs to this connection.
        let meetings = meetingLibrary.entries.map(\.sessionID) + meetingAssistant.bookmarks.map(\.sessionID)
        do {
            try settings.removeAtlasDeviceToken()
        } catch {
            logger.error("Atlas sign-out could not delete the token", metadata: ["error": "\(error)"])
            atlasSignOutError = "WhiskerFlow couldn’t remove the Atlas connection from the Keychain, so you’re still signed in. Try again."
            return false
        }
        earlierSignInMeetings.add(meetings)
        settings.signedOutOfAtlas = true
        atlasTokenAvailable = false
        atlasAccountIdentity = nil
        atlasSignOutError = nil
        atlasSignInError = nil
        atlasSignInConfirmation = nil
        settings.removeCachedMeetingSchedule()
        sharedVocabulary.signOut()
        leaderboard.signOut()
        meetingCapture.signOut()
        meetingLibrary.removeAtlasInsights()
        assistant.signOut()
        lifecycleLogger.notice("Signed out of Atlas", metadata: ["event": "atlas_signed_out"])
        return true
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
        do {
            try store.setText(id: record.id, text: text)
            records = store.records
            if settings.rememberCorrections {
                let baseline = correctionEditBaselines[record.id] ?? record.text
                correctionEditBaselines[record.id] = baseline
                automaticCorrections.enqueue(original: baseline, edited: text, sessionID: record.id, application: "WhiskerFlow")
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
    @discardableResult
    func retranscribe(_ record: TranscriptRecord, with engine: TranscriptionEngineKind) -> Task<Void, Never>? {
        guard !UIPreview.isEnabled, record.status == .transcribed, hasRecording(record), !isRecording,
              !activeTranscriptionIDs.contains(record.id) else { return nil }
        let configuration = makeTranscriptionConfiguration()
        let audioURL = URL(fileURLWithPath: record.audioFilePath)
        activeTranscriptionIDs.insert(record.id)
        isTranscribing = true
        // Not a dictation: a live one's status always wins.
        if canUpdateLifecycleUI(for: nil) { status = .transcribing }
        return Task { @MainActor [weak self] in
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
                    try await transcription.transcribe(audioURL: audioURL, kind: engine,
                                                       language: configuration.language,
                                                       allowAppleFallback: false)
                }
                let english = await self.englishText(for: outcome.result.text, configuration: configuration)
                let cleaned = await self.cleanupText(english.text, configuration: configuration)
                let text = await Task.detached(priority: .userInitiated) {
                    AssistantTextProcessing.finish(cleaned.text, usesCleanup: configuration.cleanupModel != nil, tone: configuration.writing.tone,
                                                    vocabulary: configuration.vocabulary, formatting: configuration.formatting,
                                                    recognizeCorrections: configuration.recognizeCorrections)
                }.value
                try self.store.markTranscribed(id: record.id, text: text, durationSeconds: outcome.result.duration,
                                               model: outcome.engine.modelIdentifier, engine: outcome.engine.rawValue,
                                               language: outcome.result.language, rawRecognition: outcome.result.text)
                self.records = self.store.records
                if self.canUpdateLifecycleUI(for: nil) {
                    self.status = .success("Transcribed again with \(engine.displayName)")
                }
            } catch {
                self.logger.warning("Re-transcription failed", metadata: [
                    "error.code": "\((error as NSError).code)", "transcription.engine": "\(engine.rawValue)"
                ])
                if self.canUpdateLifecycleUI(for: nil) {
                    self.status = .failure("\(engine.displayName) couldn’t transcribe this recording. Your transcript is unchanged.")
                }
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
    func recordSuccessfulDictation(
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
        insightRecording = Task { @MainActor [weak self] in
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

    /// Returns the retry, so tests can await it; the app does not.
    @discardableResult
    func retry(_ record: TranscriptRecord) -> Task<Void, Never>? {
        guard !UIPreview.isEnabled else { return nil }
        guard !activeTranscriptionIDs.contains(record.id) else { return nil }
        return Task { await retryRecording(record) }
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
        // An assistant capture finishes the job it was recorded for, and never
        // counts as dictation. A quick capture becomes its draft, which pastes
        // nothing; an instruction's selection is long gone, so it stays in History.
        switch record.captureIntent?.purpose {
        case .quickCapture?:
            configuration.purpose = .quickCapture
            configuration.quickKind = record.captureIntent?.quickKind ?? .note
            if configuration.accountIdentity != nil {
                configuration.clientReference = record.captureIntent?.clientReference
            }
            configuration.deliversText = true
        case .selectionInstruction?:
            configuration.purpose = .selectionInstruction
        case nil:
            break
        }
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

    /// Esc while a dictation is being prepared or recorded throws it away; see
    /// `DictationLifecycle.discardDictation()`. Returns whether one was discarded.
    @discardableResult
    func discardDictation() -> Bool {
        dictation.discardDictation()
    }

    private func startHotkeyMonitor() {
        #if DEBUG
        if DebugDictationTrigger.isEnabled {
            DebugDictationTrigger.install { [weak self] pressed in self?.dictation.handleDictationKey(pressed) }
            return
        }
        #endif
        configureGlobeKeyShortcut()
        let monitor = HotkeyMonitor(combo: settings.activeHotkeyCombo) { [weak self] pressed in
            self?.dictation.handleDictationKey(pressed)
        }
        monitor.onDiscardKey = { [weak self] in self?.discardDictation() }
        monitor.start()
        hotkeyMonitor = monitor
        startRegisteredShortcuts()
        for (combo, purpose) in [(Self.selectionShortcut, AssistantController.CapturePurpose.selectionInstruction),
                                 (Self.quickCaptureShortcut, AssistantController.CapturePurpose.quickCapture)] {
            let shortcut = HotkeyMonitor(combo: combo) { [weak self] pressed in
                guard let self, self.settings.activeHotkeyCombo != combo else { return }
                if pressed {
                    // Signed out, the press only opens the sign-in window; the
                    // Assistant must not adopt a missing account.
                    guard !self.requiresAtlasSignIn else { Task { await self.dictation.beginRecording() }; return }
                    guard !self.isRecording, !self.isTranscribing, !self.assistant.busy,
                          !self.isMeetingCapturing, self.recordingCoordinator.phase == .idle,
                          self.assistant.synchronizeAccount() else { return }
                    if purpose == .selectionInstruction, !self.assistant.captureSelection() { return }
                    self.assistant.capturePurpose = purpose
                    self.assistantShortcutActive = true
                    self.recordingIntentActive = true
                    self.dictation.capturePasteTarget()
                    Task { await self.dictation.beginRecording() }
                } else if self.assistantShortcutActive {
                    self.assistantShortcutActive = false
                    self.recordingIntentActive = false
                    Task { await self.dictation.finishRecording() }
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

    /// Registers the dictation shortcut (when it is a key or combination),
    /// ⌥⇧⌘R, and Esc while a dictation can be discarded, so the system
    /// consumes them; see `RegisteredShortcutController`. Whatever is not
    /// registered keeps the observing monitors above.
    private func startRegisteredShortcuts() {
        let registrar = CarbonHotKeyRegistrar()
        let shortcuts = RegisteredShortcutController(
            registrar: registrar, dictationCombo: settings.activeHotkeyCombo, meetingCombo: Self.meetingShortcut
        )
        registrar.onEvent = { [weak self] shortcut, pressed, eventTime in
            guard let self, let action = self.registeredShortcuts?.handle(shortcut, pressed: pressed) else { return }
            switch action {
            case .dictation(let pressed): self.hotkeyMonitor?.handleRegisteredHotKey(pressed: pressed, eventTime: eventTime)
            case .toggleMeeting: self.toggleMeetingCapture(keyPressedAt: eventTime)
            case .discard: self.discardDictation()
            }
        }
        shortcuts.onChange = { [weak self, weak shortcuts] in
            self?.hotkeyMonitor?.setRegistered(shortcuts?.isRegistered(.dictation) ?? false)
            self?.updateSecureInputNotice()
        }
        recordingCoordinator.onPhaseChange = { [weak self] _ in
            // Registering or removing Esc waits one main-queue turn, so the
            // system call never sits between a key event and the microphone
            // opening or the text being pasted. The phase is read again by
            // then. An Esc pressed in that one turn after a dictation ends is
            // swallowed and discards nothing.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.registeredShortcuts?.setDiscardWindowOpen(self.recordingCoordinator.phase.isDiscardable)
                }
            }
        }
        hotKeyRegistrar = registrar
        registeredShortcuts = shortcuts
        shortcuts.start()
    }

    private func stopRegisteredShortcuts() {
        recordingCoordinator.onPhaseChange = nil
        registeredShortcuts?.stop()
        registeredShortcuts = nil
        hotKeyRegistrar?.invalidate()
        hotKeyRegistrar = nil
        hotkeyMonitor?.setRegistered(false)
    }

    private func startSecureInputMonitor() {
        let monitor = SecureInputMonitor { [weak self] held in
            self?.secureInputHeldElsewhere = held
            self?.updateSecureInputNotice()
        }
        monitor.start()
        secureInputMonitor = monitor
    }

    /// Secure Input hides key events from other apps' monitors, so it pauses a
    /// shortcut WhiskerFlow only observes (fn/Globe, or one the system would
    /// not register). A registered hot key is matched by the system itself and
    /// keeps working, so the notice would be wrong for it.
    private func updateSecureInputNotice() {
        let paused = secureInputHeldElsewhere && !(registeredShortcuts?.isRegistered(.dictation) ?? false)
        if isShortcutPausedBySecureInput != paused { isShortcutPausedBySecureInput = paused }
    }

    /// Re-reads Secure Input when a view that shows its notice appears.
    func refreshSecureInputNotice() {
        secureInputMonitor?.refresh()
    }

    private func configureGlobeKeyShortcut() {
        let ready = globeKeyShortcutOverride.update(shortcut: settings.activeHotkeyCombo)
        hasGlobeKeyConflict = !ready && settings.activeHotkeyCombo == HotkeyTrigger.fn.presetCombo
        if !ready { logger.error("Could not update the macOS Globe-key action for the dictation shortcut") }
    }

    func bookmarkMeeting() {
        guard isMeetingCapturing else { return }
        do {
            let bookmark = try meetingAssistant.addBookmark(label: nil)
            assistant.message = "Bookmarked at \(CountPhrase.of(Int(bookmark.elapsedMilliseconds / 1000), "second"))."
        } catch { assistant.message = "The bookmark could not be saved on this Mac." }
    }

    #if DEBUG
    /// Tests only: runs a stopped capture through transcription and delivery; see
    /// `DictationLifecycle.completeCaptureForTesting`.
    func completeCaptureForTesting(samples: [Float], totalSampleCount: Int? = nil, audioURL: URL,
                                   stopReason: CaptureStopReason) async {
        await dictation.completeCaptureForTesting(samples: samples, totalSampleCount: totalSampleCount,
                                                  audioURL: audioURL, stopReason: stopReason)
    }
    #endif

    private func transcribeRecording(
        _ record: TranscriptRecord,
        pasteTarget: NSRunningApplication?,
        configuration: TranscriptionJobConfiguration,
        sessionID: UUID?
    ) async {
        await dictation.transcribeRecording(record, pasteTarget: pasteTarget, configuration: configuration,
                                            sessionID: sessionID)
    }

    private func englishText(for text: String, configuration: TranscriptionJobConfiguration) async
        -> (text: String, translated: Bool, notice: String?) {
        await dictation.englishText(for: text, configuration: configuration)
    }

    private func cleanupText(_ text: String, configuration: TranscriptionJobConfiguration) async -> CleanupResult {
        await dictation.cleanupText(text, configuration: configuration)
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

    /// Delivers recognised text; see `DictationLifecycle.deliver`.
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
        await dictation.deliver(text, pasteTarget: pasteTarget, delivery: delivery, mayUpdateStatus: mayUpdateStatus,
                                purpose: purpose, quickKind: quickKind, clientReference: clientReference,
                                accountIdentity: accountIdentity, sessionID: sessionID)
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

    func makeTranscriptionConfiguration() -> TranscriptionJobConfiguration {
        let accountReady = assistant.synchronizeAccount()
        let plan = settings.languagePlan
        var engine = settings.engine
        var language = settings.resolvedLanguage
        var allowAppleFallback = settings.allowAppleFallback
        // Before macOS 26 Apple's dictation model is missing, and the record
        // fails as retryable: Parakeet would return confident nonsense for a
        // language outside its catalog rather than throw.
        if case .appleDictation(let locale) = plan.route {
            engine = .appleDictation
            language = locale
            // The older Apple recogniser sends most languages to Apple's
            // servers; nothing leaves the Mac, so there is no fallback here.
            allowAppleFallback = false
        }
        var formatting = settings.formatting
        formatting.language = plan.outputLanguage
        let writing = assistant.resolveWritingStyle(AppContext(bundleIdentifier: pasteTargetApplication?.bundleIdentifier))
        let usesCleanup = settings.cleanupEnabled && assistant.capturePurpose != .selectionInstruction && writing.tone != .literal
        return TranscriptionJobConfiguration(
            engine: engine,
            language: language,
            languagePlan: plan,
            vocabulary: dictationVocabulary(usesCleanup: usesCleanup, includesClient: accountReady),
            formatting: formatting,
            allowAppleFallback: allowAppleFallback,
            delivery: settings.delivery,
            playSounds: settings.playSounds,
            writing: writing,
            recognizeCorrections: assistant.saved.recognizeCorrections,
            cleanupModel: usesCleanup ? .gemma4E2B : nil,
            cleanupVariety: settings.cleanupVariety,
            hints: recognizerHints,
            purpose: assistant.capturePurpose,
            quickKind: assistant.quickCaptureKind,
            clientReference: accountReady ? assistant.saved.selectedClient : nil,
            accountIdentity: accountReady ? assistant.saved.accountIdentity : nil
        )
    }

    func configureCleanup() {
        cleanup.configure(model: .gemma4E2B, enabled: settings.cleanupEnabled)
        automaticCorrections.configure(enabled: settings.cleanupEnabled && settings.rememberCorrections)
        if settings.cleanupEnabled && !UIPreview.isEnabled && !isTestFixture { cleanup.prewarm(.gemma4E2B) }
    }

    /// Apple's speech model for the chosen language, if it isn't Parakeet's.
    private(set) var languageModelState: LanguageModelState = .notNeeded

    enum LanguageModelState: Equatable { case notNeeded, downloading, ready, unavailable }

    /// Readies the chosen language: downloads Apple's speech model for it when
    /// Parakeet doesn't speak it, and loads its translation model.
    func prepareDictationLanguage() {
        guard !UIPreview.isEnabled else { return }
        if case .appleDictation(let locale) = settings.languagePlan.route {
            languageModelState = .downloading
            let transcription = transcription
            Task { @MainActor [weak self] in
                let ready = await transcription.prepare(kind: .appleDictation, language: locale)
                guard let self, self.settings.languagePlan.route == .appleDictation(locale: locale) else { return }
                self.languageModelState = ready ? .ready : .unavailable
            }
        } else {
            languageModelState = .notNeeded
        }
        if let code = translationWarmUpLanguage {
            let translator = translator
            Task.detached(priority: .utility) { await translator.warmUp(from: code) }
        }
    }

    /// The language to warm the translator for, when one is chosen.
    var translationWarmUpLanguage: String? {
        if case .language(let code) = settings.languagePlan.translationSource { return code }
        return nil
    }

    private func canUpdateLifecycleUI(for sessionID: UUID?) -> Bool {
        dictation.canUpdateLifecycleUI(for: sessionID)
    }

    #if DEBUG
    /// Tests only: stands in for a live dictation without a microphone; see
    /// `DictationLifecycle.holdLiveDictationForTesting(finishing:)`.
    func holdLiveDictationForTesting(finishing: Bool) {
        dictation.holdLiveDictationForTesting(finishing: finishing)
    }
    #endif

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
            // Sized for two decodes, from when a captured-samples decode could
            // fail over to the file decode; kept so the backstop is unchanged.
            engineBudget = DecodeTimeoutPolicy.modelPreparationWait
                + 2 * (queuedDecode + DecodeTimeoutPolicy.longFormTimeout(forAudioSeconds: seconds))
        case .appleSpeech:
            engineBudget = DecodeTimeoutPolicy.appleSpeechTimeout(forAudioSeconds: seconds)
        case .appleDictation:
            // A first use downloads the language's model.
            engineBudget = DecodeTimeoutPolicy.modelPreparationWait
                + DecodeTimeoutPolicy.appleSpeechTimeout(forAudioSeconds: seconds)
        }
        let fallbackBudget = allowAppleFallback && engine != .appleSpeech
            ? DecodeTimeoutPolicy.appleSpeechTimeout(forAudioSeconds: seconds) : 0
        let margin = 60 * DecodeTimeoutPolicy.hardwareScale
        return engineBudget + fallbackBudget + margin
    }

    /// The recognizer ran and found no words — as opposed to failing to run.
    nonisolated static func isNoSpeechError(_ error: any Error) -> Bool {
        switch error {
        case TranscriptionError.emptyTranscript:
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
    /// `updatesUI: false` logs without touching a live dictation's error.
    func noteHistoryFailure(_ error: Error, updatesUI: Bool = true) {
        logger.error(
            "History write failed",
            metadata: ["error.code": "\((error as NSError).code)"]
        )
        DiagnosticsService.capture(
            error: error,
            category: "storage",
            code: String((error as NSError).code)
        )
        if updatesUI { lastError = error.localizedDescription }
    }

    func handleStorageError(_ error: Error, message: String, updatesUI: Bool = true) {
        logger.error(
            "Storage failure",
            metadata: ["error.code": "\((error as NSError).code)"]
        )
        DiagnosticsService.capture(
            error: error,
            category: "storage",
            code: String((error as NSError).code)
        )
        guard updatesUI else { return }
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

/// A quick capture was transcribed but its draft couldn't be saved, so the
/// History record fails and stays retryable instead of reporting success.
struct QuickCaptureDraftError: LocalizedError {
    var reason: String?
    var errorDescription: String? { "The draft wasn't saved. \(reason ?? "")".trimmingCharacters(in: .whitespaces) }
}
