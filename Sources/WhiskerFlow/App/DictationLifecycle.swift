import AppKit
import Foundation
import Logging
import WhiskerFlowAppSupport
import WhiskerFlowCore

/// One dictation from key press to delivered text: begin, finish, transcribe
/// and deliver. `AppState` owns it and forwards to it.
///
/// Everything here runs on the main actor and is called synchronously, as it
/// was inside `AppState`. State a view reads stays on `AppState` (which is
/// `@Observable`) and is reached through the forwarding properties below, so
/// every SwiftUI read still registers; state only the lifecycle reads lives
/// here.
@MainActor
final class DictationLifecycle {
    /// `AppState` owns this object and lives for the whole process.
    unowned let app: AppState

    /// The same labels as `AppState`'s loggers, so every event reaches the
    /// same diagnostics under the same name.
    private let logger = Logging.Logger(
        label: "agency.thatworks.WhiskerFlow.AppState"
    )
    private let lifecycleLogger = Logging.Logger(label: "agency.thatworks.WhiskerFlow.DictationLifecycle")
    /// The browser-tab read for the current recording. Accessibility IPC can be
    /// slow, so it runs beside the recording and is applied at formatting time.
    private var websiteLookup: Task<AppContext, Never>?
    /// The shutdown-drain token each in-flight finish holds. Non-empty while a
    /// dictation is still finishing, which keeps background retries off the status.
    private var finishWorkTokens: [UUID: UUID] = [:]
    private var activeRecordingConfiguration: AppState.TranscriptionJobConfiguration?
    /// Whether the most recent recording streamed live (vs. file-based capture).
    private var signalAssessor = AudioSignalAssessor()
    /// Toggle recordings only. The level callback just sets the flag; a
    /// once-a-second check reads it (see `startToggleLimits`).
    private var toggleLimits: ToggleRecordingLimits?
    private var toggleSpeechHeard = false
    private var toggleLimitsTask: Task<Void, Never>?
    /// Held from hotkey press until the transcript is delivered, so timers and
    /// I/O on the capture, decode and paste path are not coalesced.
    private var dictationActivity: NSObjectProtocol?
    private var dictationWarmUpTask: Task<Void, Never>?
    /// Neural Engine state decays within seconds; re-warm during long holds.
    private static let dictationWarmUpInterval: UInt64 = 4_000_000_000

    init(app: AppState) {
        self.app = app
    }

    // MARK: - AppState's state and services

    // Plain synchronous forwarders: each reads or writes the same stored
    // property on `AppState` the code used before it moved here, so
    // observation, `didSet` and ordering are unchanged.

    private var settings: AppSettings { app.settings }
    private var assistant: AssistantController { app.assistant }
    private var cleanup: CleanupService { app.cleanup }
    private var microphonePermission: MicrophonePermissionController { app.microphonePermission }
    private var transcription: TranscriptionService { app.transcription }
    private var translator: DictationTranslator { app.translator }
    private var live: LiveDictationSession { app.live }
    private var mediaPauser: DictationMediaPauser { app.mediaPauser }
    private var meetingCapture: MeetingCaptureCoordinator { app.meetingCapture }
    private var recordingCoordinator: RecordingCoordinator { app.recordingCoordinator }
    private var soundService: SoundService { app.soundService }
    private var requiresAtlasSignIn: Bool { app.requiresAtlasSignIn }
    private var translationWarmUpLanguage: String? { app.translationWarmUpLanguage }

    private var status: AppStatus {
        get { app.status }
        set { app.status = newValue }
    }

    private var isRecording: Bool {
        get { app.isRecording }
        set { app.isRecording = newValue }
    }

    private var isTranscribing: Bool {
        get { app.isTranscribing }
        set { app.isTranscribing = newValue }
    }

    private var liveText: String {
        get { app.liveText }
        set { app.liveText = newValue }
    }

    private var signalQuality: AudioSignalQuality {
        get { app.signalQuality }
        set { app.signalQuality = newValue }
    }

    private var recordingStartedAt: Date? {
        get { app.recordingStartedAt }
        set { app.recordingStartedAt = newValue }
    }

    private var lastError: String? {
        get { app.lastError }
        set { app.lastError = newValue }
    }

    private var audioLevel: Float {
        get { app.audioLevel }
        set { app.audioLevel = newValue }
    }

    private var autoStopNotice: AutoStopNotice? {
        get { app.autoStopNotice }
        set { app.autoStopNotice = newValue }
    }

    private var atlasSignInRequests: Int {
        get { app.atlasSignInRequests }
        set { app.atlasSignInRequests = newValue }
    }

    private var assistantShortcutActive: Bool {
        get { app.assistantShortcutActive }
        set { app.assistantShortcutActive = newValue }
    }

    private var recordingIntentActive: Bool {
        get { app.recordingIntentActive }
        set { app.recordingIntentActive = newValue }
    }

    private var pasteTargetApplication: NSRunningApplication? {
        get { app.pasteTargetApplication }
        set { app.pasteTargetApplication = newValue }
    }

    private var latestRecordingSessionID: UUID? {
        get { app.latestRecordingSessionID }
        set { app.latestRecordingSessionID = newValue }
    }

    private var latestDeliveryID: UUID? {
        get { app.latestDeliveryID }
        set { app.latestDeliveryID = newValue }
    }

    private func refreshDevices() { app.refreshDevices() }

    private func makeTranscriptionConfiguration() -> AppState.TranscriptionJobConfiguration {
        app.makeTranscriptionConfiguration()
    }

    private var pendingPersistWork: PendingWorkTracker { app.pendingPersistWork }

    private var lastWritingStyle: DictationStyleReceipt? {
        get { app.lastWritingStyle }
        set { app.lastWritingStyle = newValue }
    }

    private func refreshMicrophonePermission() { app.refreshMicrophonePermission() }

    private func prepareNextCapture() { app.prepareNextCapture() }

    typealias TranscriptionJobConfiguration = AppState.TranscriptionJobConfiguration

    private var store: TranscriptStore { app.store }

    private var records: [TranscriptRecord] {
        get { app.records }
        set { app.records = newValue }
    }

    private var selectedRecordID: TranscriptRecord.ID? {
        get { app.selectedRecordID }
        set { app.selectedRecordID = newValue }
    }

    private var activeTranscriptionIDs: Set<UUID> {
        get { app.activeTranscriptionIDs }
        set { app.activeTranscriptionIDs = newValue }
    }

    private var translationNotice: String? {
        get { app.translationNotice }
        set { app.translationNotice = newValue }
    }

    private func noteHistoryFailure(_ error: Error, updatesUI: Bool = true) {
        app.noteHistoryFailure(error, updatesUI: updatesUI)
    }

    private func handleStorageError(_ error: Error, message: String, updatesUI: Bool = true) {
        app.handleStorageError(error, message: message, updatesUI: updatesUI)
    }

    private func recordDictionaryUsage(raw: String, final: String, configuration: TranscriptionJobConfiguration) {
        app.recordDictionaryUsage(raw: raw, final: final, configuration: configuration)
    }

    private func recordSuccessfulDictation(
        text: String,
        rawText: String,
        speakingSeconds: Double?,
        engine: String,
        appBundleID: String?,
        configuration: TranscriptionJobConfiguration
    ) {
        app.recordSuccessfulDictation(text: text, rawText: rawText, speakingSeconds: speakingSeconds, engine: engine,
                                      appBundleID: appBundleID, configuration: configuration)
    }

    private nonisolated static func recognitionBackstopSeconds(
        forAudioSeconds duration: Double?,
        engine: TranscriptionEngineKind,
        allowAppleFallback: Bool
    ) -> Double {
        AppState.recognitionBackstopSeconds(forAudioSeconds: duration, engine: engine,
                                            allowAppleFallback: allowAppleFallback)
    }

    private nonisolated static func isNoSpeechError(_ error: any Error) -> Bool {
        AppState.isNoSpeechError(error)
    }

    private nonisolated static func estimatedAudioSeconds(of url: URL) -> Double? {
        AppState.estimatedAudioSeconds(of: url)
    }

    private func deliverAutoStopped(_ text: String, autoStop: ToggleAutoStop, configuration: TranscriptionJobConfiguration,
                                    recordID: UUID?, mayUpdateUI: Bool) {
        app.deliverAutoStopped(text, autoStop: autoStop, configuration: configuration, recordID: recordID,
                               mayUpdateUI: mayUpdateUI)
    }

    private func deliver(
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
        await app.deliver(text, pasteTarget: pasteTarget, delivery: delivery, mayUpdateStatus: mayUpdateStatus,
                          purpose: purpose, quickKind: quickKind, clientReference: clientReference,
                          accountIdentity: accountIdentity, sessionID: sessionID)
    }

    // MARK: - Begin

    /// Set once, from `AppState.init`: the capture's level callback.
    func observeLevels() {
        live.onLevel = { [weak self] level, peak in
            guard let self else { return }
            audioLevel = level
            guard isRecording else { return }
            signalAssessor.ingest(level: level, peak: peak)
            if toggleLimits != nil, level >= ToggleRecordingLimits.speechLevel { toggleSpeechHeard = true }
            // Per-buffer writes would re-run the HUD's show/layout on every buffer.
            if signalQuality != signalAssessor.quality { signalQuality = signalAssessor.quality }
        }
    }

    func handleDictationKey(_ pressed: Bool) {
        switch settings.recordingMode {
        case .holdToTalk:
            if pressed {
                recordingIntentActive = true
                capturePasteTarget()
                if assistant.capturePurpose == .selectionInstruction, !assistant.captureSelection() {
                    recordingIntentActive = false
                    status = .failure(assistant.message ?? "Capture a selection first")
                    return
                }
                Task { await beginRecording() }
            } else {
                recordingIntentActive = false
                Task { await finishRecording() }
            }
        case .toggle:
            guard pressed else { return }
            if isRecording {
                Task { await finishRecording() }
            } else {
                recordingIntentActive = true
                capturePasteTarget()
                if assistant.capturePurpose == .selectionInstruction, !assistant.captureSelection() {
                    recordingIntentActive = false
                    status = .failure(assistant.message ?? "Capture a selection first")
                    return
                }
                Task { await beginRecording() }
            }
        }
    }

    /// Esc while a dictation is being prepared or recorded throws it away:
    /// nothing is transcribed, pasted or stored, the microphone is released and
    /// paused media resumes. Meeting recordings are separate and never touched.
    /// Returns whether a dictation was discarded.
    @discardableResult
    func discardDictation() -> Bool {
        guard let discard = recordingCoordinator.requestDiscard() else { return false }
        recordingIntentActive = false
        assistantShortcutActive = false
        dictationWarmUpTask?.cancel()
        dictationWarmUpTask = nil
        // A discard skips `finishRecording`, which normally ends the toggle limits.
        toggleLimitsTask?.cancel()
        toggleLimitsTask = nil
        toggleLimits = nil
        websiteLookup?.cancel()
        websiteLookup = nil
        pasteTargetApplication = nil
        liveText = ""
        if case .recording(let sessionID) = discard {
            // While the microphone was still opening, the start in flight sees
            // its session ended, closes the capture, resumes media and then
            // releases the session.
            let captured = live.finish(reason: .cancelled)
            discardCapturedAudio(captured.audioURL)
            activeRecordingConfiguration = nil
            isRecording = false
            recordingStartedAt = nil
            meetingCapture.dictationEnded()
            mediaPauser.dictationEnded()
            _ = recordingCoordinator.didFinish(sessionID)
            if settings.playSounds { soundService.play(.recordingStopped) }
        }
        lifecycleLogger.info("Capture discarded by the user", metadata: [
            "event": "capture_discarded", "reason": "user_cancelled"
        ])
        updateDictationActivity()
        status = .success("Recording discarded")
        return true
    }

    /// Remembers where the dictation goes and asks it for its text fields now,
    /// so an Electron destination has built them by the time the text lands.
    func capturePasteTarget() {
        pasteTargetApplication = NSWorkspace.shared.frontmostApplication
        guard let pid = pasteTargetApplication?.processIdentifier, !UIPreview.isEnabled else { return }
        DispatchQueue.global(qos: .userInitiated).async { TextFieldSnapshot.exposeAccessibilityTree(pid) }
    }

    func beginRecording() async {
        if requiresAtlasSignIn {
            lifecycleLogger.notice("Recording request needs Atlas sign-in", metadata: ["event": "recording_rejected"])
            status = .failure("Sign in with Atlas to start dictating.")
            atlasSignInRequests &+= 1
            return
        }
        lifecycleLogger.info("Recording requested", metadata: ["event": "recording_requested"])
        guard let sessionID = recordingCoordinator.requestStart() else {
            lifecycleLogger.notice("Recording request blocked by active capture", metadata: ["event": "recording_rejected"])
            return
        }
        await beginRecording(sessionID: sessionID)
    }

    /// Begins or ends `dictationActivity` to match whether any dictation is in flight.
    func updateDictationActivity() {
        let active = recordingCoordinator.phase != .idle || isTranscribing
        if active, dictationActivity == nil {
            dictationActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical],
                reason: "Dictation in progress"
            )
            LocalDiagnostics.setDictationActive(true)
        } else if !active, let activity = dictationActivity {
            ProcessInfo.processInfo.endActivity(activity)
            dictationActivity = nil
            LocalDiagnostics.setDictationActive(false)
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

    private func beginRecording(sessionID: UUID) async {
        // Esc while the microphone opened holds the session until this start
        // has cleaned up, so its cleanup can never touch a newer dictation.
        // Declared first, so it runs after the activity update below, which
        // still saw the session finishing: update it again once it is released,
        // or the latency-critical activity would be held with nothing recording.
        defer { if recordingCoordinator.completeDiscard(sessionID) { updateDictationActivity() } }
        // Before the microphone: the warm-up runs on the Neural Engine while
        // capture starts on the main actor.
        startDictationWarmUp(sessionID: sessionID)
        startWebsiteLookup()
        updateDictationActivity()
        defer { updateDictationActivity() }

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
            return
        }
        guard microphoneAuthorization == .authorized else {
            _ = recordingCoordinator.fail(sessionID)
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
            let currentDevices = try await CoreAudioDeviceCatalog.availableInputsInBackground()
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
                return
            }
            liveText = ""
            signalAssessor.reset()
            signalQuality = .unknown
            let configuration = makeTranscriptionConfiguration()
            activeRecordingConfiguration = configuration
            if let model = configuration.cleanupModel { cleanup.prewarm(model, foreground: true) }
            assistant.capturePurpose = .dictation
            if let code = translationWarmUpLanguage {
                let translator = translator
                Task.detached(priority: .userInitiated) { await translator.warmUp(from: code) }
            }
            if settings.pauseMediaWhileDictating {
                mediaPauser.dictationStarted(inCall: meetingCapture.isCapturing || !meetingCapture.callDetector.activeCalls.isEmpty)
            }
            // The engine decodes the captured samples on release, with audio
            // persistence following delivery.
            var inputSelection: AudioInputSelection?
            var lastStartError: Error?
            lifecycleLogger.info("Opening microphone", metadata: [
                "event": "capture_opening", "session": "\(sessionID)"
            ])
            for candidate in MicrophoneSelection.captureCandidates(
                for: preferredInputSelection,
                devices: currentDevices
            ) {
                do {
                    try await live.start(
                        selection: candidate,
                        language: configuration.language,
                        vocabulary: configuration.vocabulary,
                        formatting: configuration.formatting,
                        tone: configuration.writing.tone,
                        recognizeCorrections: configuration.recognizeCorrections,
                        previewEngine: settings.liveTranscription ? configuration.engine : nil
                    )
                    inputSelection = candidate
                    break
                } catch {
                    live.cancel()
                    lastStartError = error
                    // Stopped while it started, or CoreAudio is stuck: another
                    // device won't help.
                    if error is CancellationError { break }
                    if case AudioCaptureServiceError.engineTimedOut = error { break }
                }
            }
            guard let inputSelection else {
                throw lastStartError ?? AudioCaptureServiceError.deviceUnavailable
            }
            guard recordingCoordinator.didStart(sessionID) else {
                live.cancel()
                mediaPauser.dictationEnded()
                activeRecordingConfiguration = nil
                return
            }
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
            autoStopNotice = nil
            status = .recording
            meetingCapture.dictationStarted()
            if settings.playSounds { soundService.play(.recordingStarted) }

            // Hold mode: if the key was already released while preparing, stop now.
            if settings.recordingMode == .holdToTalk, !recordingIntentActive {
                await finishRecording()
            } else if ToggleRecordingLimits.apply(to: settings.recordingMode, assistantShortcut: assistantShortcutActive) {
                startToggleLimits(sessionID: sessionID)
            }
        } catch {
            _ = recordingCoordinator.fail(sessionID)
            isRecording = false
            mediaPauser.dictationEnded()
            activeRecordingConfiguration = nil
            let message = CaptureErrorPresentation.message(for: error)
            lastError = message
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

    /// Stops a forgotten toggle recording at `ToggleRecordingLimits`. Checks once
    /// a second; the level callback only sets `toggleSpeechHeard`.
    private func startToggleLimits(sessionID: UUID) {
        toggleLimitsTask?.cancel()
        toggleSpeechHeard = false
        toggleLimits = ToggleRecordingLimits(startedAt: ProcessInfo.processInfo.systemUptime)
        toggleLimitsTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self, self.recordingCoordinator.phase == .recording(sessionID),
                      var limits = self.toggleLimits else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if self.toggleSpeechHeard {
                    limits.noteSpeech(at: now)
                    self.toggleSpeechHeard = false
                    self.toggleLimits = limits
                }
                guard let limit = limits.autoStop(at: now) else { continue }
                self.lifecycleLogger.notice("Toggle recording stopped automatically", metadata: [
                    "event": "recording_auto_stopped", "session": "\(sessionID)", "auto_stop": "\(limit.rawValue)",
                    "elapsed_ms": "\((now - limits.startedAt) * 1000)"
                ])
                // Its own task: the finish cancels this one.
                Task { await self.finishRecording(reason: .autoStopped(limit)) }
                return
            }
        }
    }

    func handleAudioConfigurationChange() {
        guard case .recording = recordingCoordinator.phase else { return }
        logger.error("Active microphone configuration changed")
        DiagnosticsService.breadcrumb(
            category: "audio",
            metadata: ["phase": "recording", "stop_reason": "device_disconnected"]
        )
        Task { await finishRecording(reason: .deviceDisconnected) }
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

    // MARK: - Finish

    func finishRecording(reason: CaptureStopReason = .userReleased) async {
        if case .preparing = recordingCoordinator.phase {
            status = .preparingMic
            return
        }
        guard case .recording(let sessionID) = recordingCoordinator.phase,
              recordingCoordinator.requestFinish(sessionID, reason: reason) else { return }
        await finishRecording(sessionID: sessionID, reason: reason)
    }

    private func finishRecording(sessionID: UUID, reason: CaptureStopReason) async {
        defer {
            updateDictationActivity()
            scheduleAfterDictationUpkeep()
        }
        dictationWarmUpTask?.cancel()
        dictationWarmUpTask = nil
        toggleLimitsTask?.cancel()
        toggleLimitsTask = nil
        toggleLimits = nil
        let finishStarted = ProcessInfo.processInfo.systemUptime
        lifecycleLogger.info("Finishing recording", metadata: ["event": "finish_started", "session": "\(sessionID)"])
        defer { lifecycleLogger.info("Recording finish returned", metadata: ["event": "finish_returned", "session": "\(sessionID)", "elapsed_ms": "\((ProcessInfo.processInfo.systemUptime - finishStarted) * 1000)"]) }

        // Registered for the whole finish, so a quit landing mid-finish waits for
        // the transcript instead of racing the store write.
        let workToken = pendingPersistWork.begin()
        finishWorkTokens[sessionID] = workToken
        defer {
            finishWorkTokens[sessionID] = nil
            pendingPersistWork.end(workToken)
        }

        isRecording = false
        recordingStartedAt = nil
        meetingCapture.dictationEnded()
        mediaPauser.dictationEnded()
        status = .transcribing
        DiagnosticsService.breadcrumb(
            category: "recording",
            metadata: ["phase": "finishing", "stop_reason": reason.diagnosticName]
        )

        var configuration = activeRecordingConfiguration ?? makeTranscriptionConfiguration()
        activeRecordingConfiguration = nil
        let pasteTarget = pasteTargetApplication
        pasteTargetApplication = nil
        if let lookup = websiteLookup {
            // Normally finished long ago; bounded by the reader's own budget.
            websiteLookup = nil
            configuration.writing = await assistant.resolveWritingStyle(lookup.value)
            live.setTone(configuration.writing.tone)
        }
        if configuration.purpose == .dictation {
            lastWritingStyle = DictationStyleReceipt(resolution: configuration.writing, appName: pasteTarget?.localizedName)
        }
        let result = live.finish(reason: reason)
        lifecycleLogger.info("Capture stopped", metadata: ["event": "decode_returned", "session": "\(sessionID)", "elapsed_ms": "\((ProcessInfo.processInfo.systemUptime - finishStarted) * 1000)", "samples": "\(result.totalSampleCount)"])
        _ = recordingCoordinator.didFinish(sessionID)

        if configuration.playSounds { soundService.play(.recordingStopped) }
        liveText = ""

        // Transcribe the captured samples (includes the Apple Speech fallback).
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

        if reason == .deviceDisconnected, canUpdateLifecycleUI(for: sessionID) {
            if CapturedAudioValidation.shouldDismissEmptyDeviceInterruption(
                stopReason: reason,
                totalSampleCount: result.totalSampleCount
            ) {
                // A device change can end the capture before its first
                // usable buffer. It is a discarded capture, not a failed
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

    func canUpdateLifecycleUI(for sessionID: UUID?) -> Bool {
        guard recordingCoordinator.phase == .idle else { return false }
        // A background retry (no session) must not take the status over from a
        // dictation that is still transcribing or pasting after its release.
        guard let sessionID else { return finishWorkTokens.isEmpty }
        return latestRecordingSessionID == sessionID
    }

    #if DEBUG
    /// Tests only: stands in for a live dictation without a microphone. It is
    /// recording, or (`finishing`) released and still transcribing or pasting.
    func holdLiveDictationForTesting(finishing: Bool) {
        if finishing {
            let sessionID = UUID()
            latestRecordingSessionID = sessionID
            finishWorkTokens[sessionID] = UUID()
        } else if let sessionID = recordingCoordinator.requestStart() {
            latestRecordingSessionID = sessionID
            _ = recordingCoordinator.didStart(sessionID)
        }
    }
    #endif

    // MARK: - Transcribe

    #if DEBUG
    /// Tests only: runs a stopped capture through transcription and delivery the
    /// way `finishRecording` does, without a microphone.
    func completeCaptureForTesting(samples: [Float], totalSampleCount: Int? = nil, audioURL: URL,
                                   stopReason: CaptureStopReason) async {
        let sessionID = UUID()
        latestRecordingSessionID = sessionID
        await transcribeCapturedSamples(
            samples, conversionFailures: 0, capturedAudioURL: audioURL,
            totalSampleCount: totalSampleCount ?? samples.count, stopReason: stopReason,
            pasteTarget: nil, configuration: makeTranscriptionConfiguration(), sessionID: sessionID
        )
    }
    #endif

    /// Persist captured audio for interrupted-decode recovery, then transcribe
    /// the saved file.
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
        if case .autoStopped(let limit) = stopReason {
            configuration.autoStop = limit
            // Nothing reached the speech line: if the recognizer agrees, it is an
            // ordinary empty recording, not a failure to retry.
            if limit == .noSpeech { configuration.discardsWithoutSpeech = true }
        }
        let record = TranscriptRecord(
            text: "",
            audioFilePath: url.path,
            createdAt: Date(),
            status: .transcribing,
            durationSeconds: Double(totalSampleCount) / 16_000,
            model: configuration.engine.modelIdentifier,
            engine: configuration.engine.rawValue,
            language: configuration.language,
            appCategory: configuration.writing.category,
            captureIntent: configuration.captureIntent
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
            sessionID: sessionID
        )
    }

    private func discardCapturedAudio(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func transcribeRecording(
        _ record: TranscriptRecord,
        pasteTarget: NSRunningApplication?,
        configuration: TranscriptionJobConfiguration,
        sessionID: UUID?
    ) async {
        guard !activeTranscriptionIDs.contains(record.id) else { return }
        let isRetry = sessionID == nil

        activeTranscriptionIDs.insert(record.id)
        isTranscribing = true
        do {
            try store.markTranscribing(id: record.id)
        } catch {
            // Best-effort, like every history write on this path: the decode only
            // needs the audio file.
            noteHistoryFailure(error, updatesUI: canUpdateLifecycleUI(for: sessionID))
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
                        language: configuration.language,
                        allowAppleFallback: configuration.allowAppleFallback,
                        hints: configuration.hints
                    )
                }
            } catch AsyncTimeoutError.timedOut {
                lifecycleLogger.warning("Recognition backstop fired", metadata: ["event": "recognition_timeout", "session": "\(sessionID ?? record.id)", "timeout.seconds": "\(Int(backstop))"])
                throw TranscriptionError.timedOut(seconds: Int(backstop))
            }
            lifecycleLogger.info("Dictation stage finished", metadata: ["event": "stage_finished", "stage": "recognition", "session": "\(sessionID ?? record.id)", "elapsed_ms": "\((ProcessInfo.processInfo.systemUptime - recognitionStarted) * 1000)"])
            let translationStarted = ProcessInfo.processInfo.systemUptime
            let english = await englishText(for: outcome.result.text, configuration: configuration)
            if english.translated || english.notice != nil {
                lifecycleLogger.info("Dictation stage finished", metadata: ["event": "stage_finished", "stage": "translation", "session": "\(sessionID ?? record.id)", "elapsed_ms": "\((ProcessInfo.processInfo.systemUptime - translationStarted) * 1000)", "outcome": english.translated ? "translated" : "kept"])
            }
            let cleaned = await cleanupText(english.text, configuration: configuration)
            let text_processingStarted = ProcessInfo.processInfo.systemUptime
            lifecycleLogger.info("Dictation stage started", metadata: ["event": "stage_started", "stage": "text_processing", "session": "\(sessionID ?? record.id)"])
            let processed = await Task.detached(priority: .userInitiated) {
                let started = ProcessInfo.processInfo.systemUptime
                let text = AssistantTextProcessing.finish(cleaned.text, usesCleanup: configuration.cleanupModel != nil, tone: configuration.writing.tone,
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
            // A quick capture's draft is its delivery. Save it before History
            // marks the record done (and "Don't save history" drops its audio),
            // so a draft that can't be saved leaves a failed, retryable record.
            if configuration.deliversText, configuration.purpose == .quickCapture {
                guard assistant.saveLocalDraft(finalText, kind: configuration.quickKind,
                                               clientReference: configuration.clientReference,
                                               accountIdentity: configuration.accountIdentity) != nil else {
                    throw QuickCaptureDraftError(reason: assistant.message)
                }
            }
            var historySaved = true
            do {
                try store.markTranscribed(
                    id: record.id,
                    text: finalText,
                    durationSeconds: outcome.result.duration,
                    model: outcome.engine.modelIdentifier,
                    engine: outcome.engine.rawValue,
                    language: outcome.result.language,
                    rawRecognition: outcome.result.text,
                    appCategory: configuration.writing.category
                )
                recordDictionaryUsage(raw: outcome.result.text, final: finalText, configuration: configuration)
            } catch {
                // A recognized transcript is still delivered; only History missed it.
                historySaved = false
                noteHistoryFailure(error, updatesUI: canUpdateLifecycleUI(for: sessionID))
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
            if let autoStop = configuration.autoStop, configuration.purpose == .dictation {
                deliverAutoStopped(finalText, autoStop: autoStop, configuration: configuration,
                                   recordID: historySaved ? record.id : nil, mayUpdateUI: mayUpdateUI)
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
                noteHistoryFailure(error, updatesUI: canUpdateLifecycleUI(for: sessionID))
            }
            // The record may never have reached History; the audio still goes.
            discardCapturedAudio(URL(fileURLWithPath: record.audioFilePath))
            records = store.records
            if selectedRecordID == record.id {
                selectedRecordID = records.first?.id
            }
            if canUpdateLifecycleUI(for: sessionID) {
                if let autoStop = configuration.autoStop {
                    status = .success(autoStop.nothingSaidMessage)
                    autoStopNotice = AutoStopNotice(message: autoStop.nothingSaidMessage, recordID: nil)
                } else {
                    status = .failure("No speech detected")
                }
            }
        } catch {
            do {
                try store.markFailed(id: record.id, message: error.localizedDescription)
            } catch {
                handleStorageError(error, message: "Could not update failed transcript",
                                   updatesUI: canUpdateLifecycleUI(for: sessionID))
            }
            records = store.records
            let mayUpdateUI = canUpdateLifecycleUI(for: sessionID)
            if mayUpdateUI {
                selectedRecordID = record.id
                lastError = error.localizedDescription
            }
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
                status = .failure(error is QuickCaptureDraftError
                    ? "Draft not saved; queued for retry" : "Transcription failed; queued for retry")
                if configuration.playSounds { soundService.play(.transcriptionFailed) }
            }
        }
    }

    func cleanupText(_ text: String, configuration: TranscriptionJobConfiguration) async -> CleanupResult {
        guard let model = configuration.cleanupModel, configuration.writing.tone != .literal,
              configuration.purpose != .selectionInstruction else { return CleanupResult(text: text, outcome: "skipped") }
        return await cleanup.clean(text, model: model, vocabulary: configuration.vocabulary, variety: configuration.cleanupVariety)
    }

    /// The transcript in English when the dictation language asks for it.
    /// Text that already reads as English is left alone (bilingual people
    /// switch). A failed translation keeps the words as heard, with a notice.
    func englishText(for text: String, configuration: TranscriptionJobConfiguration) async
        -> (text: String, translated: Bool, notice: String?) {
        guard let source = configuration.languagePlan.translationSource else { return (text, false, nil) }
        let detected = DictationTextLanguage.detect(text)
        if detected == "en" { return (text, false, nil) }
        let code: String
        switch source {
        case .language(let chosen): code = chosen
        case .detected:
            guard let detected else { return (text, false, nil) }
            code = detected
        }
        let name = Locale(identifier: "en").localizedString(forIdentifier: code) ?? code
        do {
            let english = try await translator.translate(text, from: code, displayName: name,
                                                         keep: configuration.hints.terms)
            return (english, true, nil)
        } catch {
            logger.warning("Translation failed", metadata: ["error.code": "\((error as NSError).code)"])
            let notice = (error as? LocalizedError)?.errorDescription ?? "Couldn't translate into English; pasted as heard."
            translationNotice = notice
            return (text, false, notice)
        }
    }
}
