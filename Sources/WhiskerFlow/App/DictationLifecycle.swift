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

    private var websiteLookup: Task<AppContext, Never>? {
        get { app.websiteLookup }
        set { app.websiteLookup = newValue }
    }

    private var latestRecordingSessionID: UUID? {
        get { app.latestRecordingSessionID }
        set { app.latestRecordingSessionID = newValue }
    }

    private var latestDeliveryID: UUID? {
        get { app.latestDeliveryID }
        set { app.latestDeliveryID = newValue }
    }

    private var activeRecordingConfiguration: AppState.TranscriptionJobConfiguration? {
        get { app.activeRecordingConfiguration }
        set { app.activeRecordingConfiguration = newValue }
    }

    private var signalAssessor: AudioSignalAssessor {
        get { app.signalAssessor }
        set { app.signalAssessor = newValue }
    }

    private var toggleLimits: ToggleRecordingLimits? {
        get { app.toggleLimits }
        set { app.toggleLimits = newValue }
    }

    private var toggleSpeechHeard: Bool {
        get { app.toggleSpeechHeard }
        set { app.toggleSpeechHeard = newValue }
    }

    private var toggleLimitsTask: Task<Void, Never>? {
        get { app.toggleLimitsTask }
        set { app.toggleLimitsTask = newValue }
    }

    private var dictationActivity: NSObjectProtocol? {
        get { app.dictationActivity }
        set { app.dictationActivity = newValue }
    }

    private var dictationWarmUpTask: Task<Void, Never>? {
        get { app.dictationWarmUpTask }
        set { app.dictationWarmUpTask = newValue }
    }

    private func refreshDevices() { app.refreshDevices() }

    private func makeTranscriptionConfiguration() -> AppState.TranscriptionJobConfiguration {
        app.makeTranscriptionConfiguration()
    }

    private func discardCapturedAudio(_ url: URL?) { app.discardCapturedAudio(url) }

    private func finishRecording(reason: CaptureStopReason = .userReleased) async {
        await app.finishRecording(reason: reason)
    }

    // MARK: - Begin

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
}
