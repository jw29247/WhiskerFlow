import AppKit
import CoreGraphics
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
    case success(String)
    case failure(String)

    var isBusy: Bool {
        switch self {
        case .preparingMic, .recording, .transcribing: return true
        case .idle, .success, .failure: return false
        }
    }
}

extension AppStatus {
    var hudNotificationMessage: String? {
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
    }

    /// How long a `.finishing` session may take before the UI is force-recovered.
    /// Derived from the decode budget it backstops — a release can serially await
    /// several live decodes — plus a margin, so only a genuine wedge trips it and a
    /// merely slow decode is never reported as a timeout.
    private static let finishWatchdogSeconds = Int(DecodeTimeoutPolicy.liveFinishBudget) + 15
    /// Upper bound on how long quitting waits for a transcript to finish saving.
    private static let shutdownDrainSeconds: TimeInterval = 5

    var records: [TranscriptRecord] = []
    var selectedRecordID: TranscriptRecord.ID?
    var status: AppStatus = .idle
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
    var meetingModelState: ModelState = .unloaded

    var settings: AppSettings

    private let logger = Logging.Logger(
        label: "agency.thatworks.WhiskerFlow.AppState"
    )
    private let store: TranscriptStore
    private let transcription: TranscriptionService
    private let meetingCapture: MeetingCaptureCoordinator
    private let atlasAuthSession = AtlasAuthSession()
    private let live: LiveDictationSession
    private let recordingCoordinator = RecordingCoordinator()
    private let pasteService = PasteService()
    private let soundService = SoundService()
    let microphonePermission: MicrophonePermissionController
    let sharedVocabulary = SharedVocabularyService()
    private var hotkeyMonitor: HotkeyMonitor?
    private var hudController: RecordingHUDController?
    private var audioDeviceMonitor: AudioDeviceChangeMonitor?
    private var deviceRefreshTask: Task<Void, Never>?
    private var warmUpTask: Task<Void, Never>?
    private var meetingWarmUpTask: Task<Void, Never>?
    private let pendingPersistWork = PendingWorkTracker()
    private var hasStarted = false
    private var recordingIntentActive = false
    private var pasteTargetApplication: NSRunningApplication?
    private var activeTranscriptionIDs: Set<UUID> = []
    private var latestRecordingSessionID: UUID?
    /// The shutdown-drain token each in-flight finish holds, so the watchdog can
    /// release it when it gives up on that finish instead of leaking it for the rest
    /// of the process's life.
    private var finishWorkTokens: [UUID: UUID] = [:]
    /// Sessions the finish watchdog gave up on. A finish that returns after its
    /// session was abandoned must not paste, must not touch lifecycle UI a newer
    /// session owns, and must not play sounds — it only files the transcript.
    private var abandonedSessionIDs: Set<UUID> = []
    private var activeRecordingConfiguration: TranscriptionJobConfiguration?
    /// Whether the most recent recording streamed live (vs. file-based capture).
    private var streamingActive = false
    private var signalAssessor = AudioSignalAssessor()
    var isSigningInToAtlas = false
    var atlasSignInError: String?
    var atlasSignInConfirmation: String?

    init(
        settings: AppSettings? = nil,
        store: TranscriptStore = .defaultStore(),
        microphonePermission: MicrophonePermissionController? = nil
    ) {
        let resolvedSettings = settings ?? AppSettings()
        let resolvedMicrophonePermission = microphonePermission ?? MicrophonePermissionController(
            provider: AVCaptureMicrophoneAuthorizationProvider()
        )
        let transcription = TranscriptionService()
        self.settings = resolvedSettings
        self.store = store
        self.microphonePermission = resolvedMicrophonePermission
        self.transcription = transcription
        self.meetingCapture = MeetingCaptureCoordinator(
            settings: resolvedSettings,
            microphonePermission: resolvedMicrophonePermission,
            transcription: transcription
        )
        self.live = LiveDictationSession(transcription: transcription)
        live.onLevel = { [weak self] level, peak in
            guard let self else { return }
            audioLevel = level
            guard isRecording else { return }
            signalAssessor.ingest(level: level, peak: peak)
            signalQuality = signalAssessor.quality
        }
        live.onPartial = { [weak self] text in self?.liveText = text }
        live.onConfigurationChange = { [weak self] in self?.handleAudioConfigurationChange() }
    }

    // MARK: - Derived state

    var statusMessage: String {
        switch status {
        case .idle:
            switch modelState {
            case .preparing: return "Preparing \(settings.model.displayName.lowercased())…"
            case .failed(let message): return message
            default: return "Hold \(settings.hotkeyDisplayName) to dictate"
            }
        case .preparingMic: return "Preparing microphone…"
        case .recording: return "Recording…"
        case .transcribing: return "Transcribing…"
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
        records.first { $0.status == .transcribed }
    }

    var analytics: TranscriptAnalytics {
        TranscriptAnalytics(records: records)
    }

    var dailyWordCounts: [DailyWordCount] {
        records.dailyWordCounts(days: 14)
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

  var meetingStatus: MeetingMenuBarStatus { meetingCapture.status }
  var meetingStatusDetail: String { meetingCapture.statusDetail }
  var activeMeetingTitle: String? { meetingCapture.activeMeetingTitle }
  var isMeetingCapturing: Bool { meetingCapture.isCapturing }
  var upcomingMeetings: [AtlasCaptureScheduleIntent] { meetingCapture.upcomingMeetingIntents }
  var previousMeetings: [AtlasCaptureScheduleIntent] { meetingCapture.previousMeetingIntents }

    var isAtlasPaired: Bool {
        guard URL(string: settings.atlasBaseURL)?.scheme == "https" else { return false }
        return !settings.atlasDeviceToken.isEmpty
    }

    var hasScreenRecordingPermission = false

    var isMeetingStorageAvailable: Bool {
        let root = StorageLocations.applicationSupportRootOrTemporary()
            .appendingPathComponent("MeetingRecordings", isDirectory: true)
        guard let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage else { return false }
        return capacity >= 500 * 1024 * 1024
    }

    // MARK: - Lifecycle

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        // History is the only fallible step, and it must not take the rest of the
        // bootstrap down with it: an unreadable transcripts.json would otherwise
        // leave the app running with no hotkey monitor and no HUD — no way to
        // dictate at all — and `hasStarted` blocks any retry.
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
        startHotkeyMonitor()
        meetingCapture.start()
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
        hotkeyMonitor?.stop()
        hotkeyMonitor = nil
        audioDeviceMonitor?.stop()
        audioDeviceMonitor = nil
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

        _ = await pendingPersistWork.waitUntilIdle(timeout: Self.shutdownDrainSeconds)
    }

    func warmUpEngine() {
        warmUpTask?.cancel()
        let engine = settings.engine
        let model = settings.model
        let language = settings.resolvedLanguage
        let allowFallback = settings.allowAppleFallback
        guard engine == .whisperKit else {
            modelState = .ready
            return
        }
        modelState = .preparing
        warmUpTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let ready = await transcription.prepare(kind: engine, model: model, language: language)
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
        hotkeyMonitor?.update(combo: settings.activeHotkeyCombo)
    }

    func warmUpMeetingEngine() {
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
            guard !Task.isCancelled, self.settings.resolvedLanguage == language else { return }
            meetingModelState = ready
                ? .ready
                : .failed("Could not load the local meeting model. Encrypted audio will be retained for repair.")
        }
    }

    /// Suspend the live hotkey while the user is recording a new shortcut, so the
    /// keys they press to record don't start a real dictation session.
    func setHotkeyCaptureActive(_ active: Bool) {
        hotkeyMonitor?.setSuspended(active)
    }

    /// The team glossary plus the user's personal rules, applied to every
    /// transcript. Personal rules override shared ones on conflict.
    var effectiveVocabulary: Vocabulary {
        Vocabulary.effective(shared: sharedVocabulary.vocabulary, personal: settings.vocabulary)
    }

    func refreshSharedVocabulary() {
        sharedVocabulary.refresh()
    }

    func refreshDevices() {
        deviceRefreshTask?.cancel()
        deviceRefreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            let refreshed = Microphone.availableInputDevices()
            self.devices = refreshed

            // Picker option and selection changes must not occur in the same
            // NSTableView delegate stack. Publish the selection one turn later.
            await Task.yield()
            guard !Task.isCancelled else { return }
            if let legacyID = self.settings.legacySelectedDeviceID {
                self.settings.finishLegacyMicrophoneMigration(
                    MicrophoneSelection.migrate(legacyDeviceID: legacyID, devices: refreshed)
                )
            } else {
                self.settings.selectedInput = MicrophoneSelection.reconcile(
                    self.settings.selectedInput,
                    devices: refreshed
                )
            }
        }
    }

    private func startAudioDeviceMonitor() {
        let monitor = AudioDeviceChangeMonitor { [weak self] in self?.refreshDevices() }
        monitor.start()
        audioDeviceMonitor = monitor
    }

    // MARK: - Permissions

    func refreshAccessibilityPermission() {
        hasAccessibilityPermission = pasteService.hasAccessibilityPermission
    }

    func requestAccessibilityPermission() {
        pasteService.requestAccessibilityPermission()
        refreshAccessibilityPermission()
    }

    func refreshMicrophonePermission() {
        let previous = microphonePermission.authorizationState
        microphonePermission.refresh()
        handleMicrophoneAuthorizationTransition(from: previous)
    }

    func refreshPermissionsAfterActivation() {
        refreshAccessibilityPermission()
        let previous = microphonePermission.authorizationState
        microphonePermission.refreshForApplicationActivation()
        handleMicrophoneAuthorizationTransition(from: previous)
        refreshScreenRecordingPermission()
        meetingCapture.refreshConfiguration()
    }

    func requestMicrophonePermission() async {
        let previous = microphonePermission.authorizationState
        _ = await microphonePermission.requestIfNeeded()
        handleMicrophoneAuthorizationTransition(from: previous)
    }

    func refreshScreenRecordingPermission() {
        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
    }

    func requestScreenRecordingPermission() {
        _ = CGRequestScreenCaptureAccess()
        refreshScreenRecordingPermission()
    }

    func toggleMeetingCapture() {
        meetingCapture.toggleManualCapture()
    }

  func refreshMeetingConfiguration() {
        warmUpMeetingEngine()
        meetingCapture.refreshConfiguration()
  }

  func refreshMeetingSchedule() {
    meetingCapture.refreshSchedule()
  }

  func recordScheduledMeeting(_ intent: AtlasCaptureScheduleIntent) {
    meetingCapture.startScheduledCapture(intent)
  }

  func signInToAtlas() {
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
        await transcription.requestAppleSpeechAuthorization()
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
        } catch {
            handleStorageError(error, message: "Could not save transcript changes")
        }
    }

    func acceptVocabularySuggestion(_ suggestion: VocabularyCorrection) {
        settings.vocabulary.rules.append(
            VocabularyRule(find: suggestion.find, replaceWith: suggestion.replaceWith)
        )
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

    func retry(_ record: TranscriptRecord) {
        guard !activeTranscriptionIDs.contains(record.id) else { return }
        let configuration = makeTranscriptionConfiguration()
        Task {
            await transcribeRecording(
                record,
                pasteTarget: nil,
                configuration: configuration,
                sessionID: nil
            )
        }
    }

    func retryAllFailed() {
        for record in retryQueue where !activeTranscriptionIDs.contains(record.id) {
            retry(record)
        }
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
                    Task { await self.beginRecording() }
                }
            }
        }
        monitor.start()
        hotkeyMonitor = monitor
    }

    private func beginRecording() async {
        guard let sessionID = recordingCoordinator.requestStart() else { return }
        await Observability.tracer.spanBuilder(spanName: "dictation.start").withActiveSpan { span in
            await beginRecording(sessionID: sessionID, span: span)
        }
    }

    private func beginRecording(sessionID: UUID, span: any SpanBase) async {
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
        status = .preparingMic
        logger.info("Recording preparing")
        DiagnosticsService.breadcrumb(category: "recording", metadata: ["phase": "preparing"])

        let microphoneAuthorization = await microphonePermission.requestIfNeeded()
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
            let currentDevices = Microphone.availableInputDevices()
            let preferredInputSelection: AudioInputSelection
            if let legacyID = settings.legacySelectedDeviceID {
                preferredInputSelection = MicrophoneSelection.migrate(
                    legacyDeviceID: legacyID,
                    devices: currentDevices
                )
            } else {
                preferredInputSelection = MicrophoneSelection.reconcile(
                    settings.selectedInput,
                    devices: currentDevices
                )
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
                "recording.mode": .string(String(describing: settings.recordingMode))
            ])
            activeRecordingConfiguration = configuration
            // Stream + decode live for the WhisperKit engine; other engines stay
            // file-based (captured here, transcribed from the WAV on release).
            streamingActive = configuration.engine == .whisperKit && settings.liveTranscription
            var inputSelection: AudioInputSelection?
            var lastStartError: Error?
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
                        streaming: streamingActive
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
            pendingPersistWork.end(workToken)
        }

        isRecording = false
        recordingStartedAt = nil
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
        let configuration = activeRecordingConfiguration ?? makeTranscriptionConfiguration()
        activeRecordingConfiguration = nil
        let pasteTarget = pasteTargetApplication
        pasteTargetApplication = nil
        let result = await live.finish(reason: reason)
        watchdog.cancel()
        let wasAbandoned = abandonedSessionIDs.remove(sessionID) != nil
        _ = recordingCoordinator.didFinish(sessionID)

        if wasAbandoned {
            // The watchdog already reported this session as timed out and released
            // the coordinator, so the HUD text, the status and the paste target may
            // all belong to a newer session by now. File the transcript so it isn't
            // lost, but deliver nothing and touch no lifecycle UI.
            logger.error("Finish returned after the watchdog")
            DiagnosticsService.breadcrumb(
                category: "recording",
                metadata: [
                    "phase": "finish_late",
                    "recovered": String(!result.text.isEmpty)
                ]
            )
            if !result.text.isEmpty {
                persistLiveRecording(
                    text: result.text,
                    samples: result.samples,
                    configuration: configuration,
                    sessionID: sessionID
                )
            }
            span.setAttribute(key: "error.type", value: "finish_timeout")
            span.status = .error(description: "Finish returned after timeout")
            return
        }

        if configuration.playSounds { soundService.play(.recordingStopped) }
        liveText = ""

        if wasStreaming, !result.text.isEmpty {
            // Streaming already produced the transcript — paste immediately, then
            // persist the audio + record off the critical path.
            let mayUpdateUI = canUpdateLifecycleUI(for: sessionID)
            if mayUpdateUI { status = .transcribing }
            deliver(
                result.text,
                pasteTarget: pasteTarget,
                delivery: configuration.delivery,
                mayUpdateStatus: mayUpdateUI
            )
            persistLiveRecording(
                text: result.text,
                samples: result.samples,
                configuration: configuration,
                sessionID: sessionID
            )
        } else {
            // Non-streaming engine, or streaming caught no speech: fall back to the
            // standard file-based path (includes the Apple Speech fallback).
            if canUpdateLifecycleUI(for: sessionID) { status = .transcribing }
            await transcribeCapturedSamples(
                result.samples,
                conversionFailures: result.conversionFailures,
                pasteTarget: pasteTarget,
                configuration: configuration,
                sessionID: sessionID
            )
        }

        if reason == .deviceDisconnected, canUpdateLifecycleUI(for: sessionID) {
            if result.samples.isEmpty {
                status = .failure("Microphone disconnected; try again")
            } else if case .failure = status {
                // Preserve the actionable transcription/storage failure.
            } else {
                status = .success("Microphone changed; partial transcript saved")
            }
        }

        if case .failure = status {
            span.setAttribute(key: "error.type", value: "dictation_failed")
            span.status = .error(description: "Dictation failed")
        } else {
            telemetryOutcome = "success"
            span.status = .ok
        }
    }

    private func abandonStuckFinish(sessionID: UUID) {
        guard recordingCoordinator.phase == .finishing(sessionID) else { return }
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
        }
    }

    /// Save a finished streaming transcript + its audio without blocking the
    /// paste. The WAV is encoded off the main actor; the store update hops back.
    private func persistLiveRecording(
        text: String,
        samples: [Float],
        configuration: TranscriptionJobConfiguration,
        sessionID: UUID
    ) {
        let createdAt = Date()
        let duration = Double(samples.count) / 16_000
        let model = configuration.model.rawValue
        let engine = configuration.engine.rawValue
        let language = configuration.language
        let url: URL
        do {
            url = try AudioFileWriter.makeRecordingURL()
        } catch {
            handleStorageError(error, message: "Could not create recording file")
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
                do {
                    try AudioFileWriter.writeWAV(samples: samples, to: url)
                    let saved = await self?.appendRecord(
                        text: text,
                        audioPath: url.path,
                        createdAt: createdAt,
                        duration: duration,
                        model: model,
                        engine: engine,
                        language: language,
                        sessionID: sessionID
                    ) ?? false
                    if saved {
                        telemetryOutcome = "success"
                        span.status = .ok
                    } else {
                        span.setAttribute(key: "error.type", value: "storage")
                        span.status = .error(description: "Could not save transcript")
                    }
                } catch {
                    span.setAttributes([
                        "error.type": .string("storage"),
                        "error.code": .int((error as NSError).code)
                    ])
                    span.status = .error(description: "Could not save recording")
                    await self?.handleStorageError(error, message: "Could not save recording")
                }
            }
        }
    }

    private func appendRecord(
        text: String,
        audioPath: String,
        createdAt: Date,
        duration: Double,
        model: String,
        engine: String,
        language: String?,
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
            updatedAt: createdAt
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

    /// Write captured samples to a WAV and transcribe via the standard engine
    /// path (used for non-streaming engines and the streaming-empty fallback).
    private func transcribeCapturedSamples(
        _ samples: [Float],
        conversionFailures: Int,
        pasteTarget: NSRunningApplication?,
        configuration: TranscriptionJobConfiguration,
        sessionID: UUID
    ) async {
        guard !samples.isEmpty else {
            // Buffers that all failed to convert look identical to silence at this
            // point, so the failure count is the only way to tell the user why.
            if conversionFailures > 0 {
                logger.error(
                    "Capture yielded no usable audio",
                    metadata: ["audio.conversion.failures": "\(conversionFailures)"]
                )
                DiagnosticsService.capture(
                    error: AudioCaptureServiceError.conversionFailed("all buffers"),
                    category: "audio",
                    code: String(conversionFailures)
                )
            }
            if canUpdateLifecycleUI(for: sessionID) {
                status = .failure(
                    conversionFailures > 0
                        ? "Microphone audio could not be converted — try another microphone"
                        : "No speech was detected"
                )
            }
            return
        }
        do {
            let url = try AudioFileWriter.makeRecordingURL()
            try AudioFileWriter.writeWAV(samples: samples, to: url)
            let record = TranscriptRecord(
                text: "",
                audioFilePath: url.path,
                createdAt: Date(),
                status: .transcribing,
                model: configuration.model.rawValue,
                engine: configuration.engine.rawValue,
                language: configuration.language
            )
            try store.add(record)
            records = store.records
            if canUpdateLifecycleUI(for: sessionID) {
                selectedRecordID = record.id
            }
            await transcribeRecording(
                record,
                pasteTarget: pasteTarget,
                configuration: configuration,
                sessionID: sessionID
            )
        } catch {
            handleStorageError(error, message: "Recording failed")
        }
    }

    private func transcribeRecording(
        _ record: TranscriptRecord,
        pasteTarget: NSRunningApplication?,
        configuration: TranscriptionJobConfiguration,
        sessionID: UUID?
    ) async {
        guard !activeTranscriptionIDs.contains(record.id) else { return }
        await Observability.tracer.spanBuilder(spanName: "transcription.run").withActiveSpan { span in
            await transcribeRecording(
                record,
                pasteTarget: pasteTarget,
                configuration: configuration,
                sessionID: sessionID,
                span: span
            )
        }
    }

    private func transcribeRecording(
        _ record: TranscriptRecord,
        pasteTarget: NSRunningApplication?,
        configuration: TranscriptionJobConfiguration,
        sessionID: UUID?,
        span: any SpanBase
    ) async {
        let telemetryStartedAt = Date()
        var telemetryOutcome = "error"
        let isRetry = sessionID == nil
        span.setAttributes([
            "transcription.engine": .string(configuration.engine.rawValue),
            "transcription.model": .string(configuration.model.rawValue),
            "transcription.retry": .bool(isRetry)
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
            span.setAttributes([
                "error.type": .string("storage"),
                "error.code": .int((error as NSError).code)
            ])
            span.status = .error(description: "Could not mark transcript as transcribing")
            handleStorageError(error, message: "Could not update transcript")
            activeTranscriptionIDs.remove(record.id)
            isTranscribing = !activeTranscriptionIDs.isEmpty
            return
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
            let outcome = try await transcription.transcribe(
                audioURL: URL(fileURLWithPath: record.audioFilePath),
                kind: configuration.engine,
                model: configuration.model,
                language: configuration.language,
                initialPrompt: nil,
                cliConfiguration: configuration.cliConfiguration,
                allowAppleFallback: configuration.allowAppleFallback
            )
            let finalText = TranscriptFormatter.format(
                configuration.vocabulary.apply(to: outcome.result.text),
                options: configuration.formatting
            )
            try store.markTranscribed(
                id: record.id,
                text: finalText,
                durationSeconds: outcome.result.duration,
                model: configuration.model.rawValue,
                engine: outcome.engine.rawValue,
                language: outcome.result.language
            )
            records = store.records
            let mayUpdateUI = canUpdateLifecycleUI(for: sessionID)
            if mayUpdateUI {
                selectedRecordID = record.id
            }
            if configuration.playSounds, mayUpdateUI {
                soundService.play(.transcriptionSucceeded)
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
            deliver(
                finalText,
                pasteTarget: pasteTarget,
                delivery: configuration.delivery,
                mayUpdateStatus: mayUpdateUI
            )
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

    private func deliver(
        _ text: String,
        pasteTarget: NSRunningApplication?,
        delivery: DeliveryMode,
        mayUpdateStatus: Bool
    ) {
        switch delivery {
        case .copyOnly:
            pasteService.copy(text)
            if mayUpdateStatus { status = .success("Copied to clipboard") }
        case .pasteAtCursor:
            if pasteService.paste(text, into: pasteTarget) {
                hasAccessibilityPermission = true
                if mayUpdateStatus { status = .success("Pasted transcript") }
            } else {
                hasAccessibilityPermission = false
                if mayUpdateStatus {
                    status = .success("Transcript copied; allow Accessibility to auto-paste")
                }
            }
        }
    }

    private func makeTranscriptionConfiguration() -> TranscriptionJobConfiguration {
        TranscriptionJobConfiguration(
            engine: settings.engine,
            model: settings.model,
            language: settings.resolvedLanguage,
            vocabulary: effectiveVocabulary,
            formatting: settings.formatting,
            cliConfiguration: settings.cliConfiguration,
            allowAppleFallback: settings.allowAppleFallback,
            delivery: settings.delivery,
            playSounds: settings.playSounds
        )
    }

    private func canUpdateLifecycleUI(for sessionID: UUID?) -> Bool {
        guard recordingCoordinator.phase == .idle else { return false }
        guard let sessionID else { return true }
        return latestRecordingSessionID == sessionID
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

extension TranscriptStore {
    static func defaultStore() -> TranscriptStore {
        let root = StorageLocations.applicationSupportRootOrTemporary()
        return TranscriptStore(fileURL: root.appendingPathComponent("transcripts.json"))
    }
}
