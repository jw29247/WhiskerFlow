import AppKit
import Foundation
import OSLog
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
        let cliConfiguration: WhisperConfiguration
        let allowAppleFallback: Bool
        let delivery: DeliveryMode
        let playSounds: Bool
    }

    var records: [TranscriptRecord] = []
    var selectedRecordID: TranscriptRecord.ID?
    var status: AppStatus = .idle
    var isRecording = false
    var isTranscribing = false
    var audioLevel: Float = 0
    /// Live transcript shown in the HUD while streaming dictation is active.
    var liveText = ""
    var recordingStartedAt: Date?
    var modelState: ModelState = .unloaded
    var hasAccessibilityPermission = false
    var hasMicrophonePermission = false
    var devices: [AudioInputDescriptor] = []
    var lastError: String?
    var searchText = ""

    var settings: AppSettings

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "agency.thatworks.WhiskerFlow",
        category: "AppState"
    )
    private let store: TranscriptStore
    private let transcription = TranscriptionService()
    private let live: LiveDictationSession
    private let recordingCoordinator = RecordingCoordinator()
    private let pasteService = PasteService()
    private let soundService = SoundService()
    let sharedVocabulary = SharedVocabularyService()
    private var hotkeyMonitor: HotkeyMonitor?
    private var hudController: RecordingHUDController?
    private var audioDeviceMonitor: AudioDeviceChangeMonitor?
    private var deviceRefreshTask: Task<Void, Never>?
    private var warmUpTask: Task<Void, Never>?
    private var hasStarted = false
    private var recordingIntentActive = false
    private var pasteTargetApplication: NSRunningApplication?
    private var activeTranscriptionIDs: Set<UUID> = []
    private var latestRecordingSessionID: UUID?
    private var activeRecordingConfiguration: TranscriptionJobConfiguration?
    /// Whether the most recent recording streamed live (vs. file-based capture).
    private var streamingActive = false

    init(settings: AppSettings? = nil, store: TranscriptStore = .defaultStore()) {
        self.settings = settings ?? AppSettings()
        self.store = store
        self.live = LiveDictationSession(transcription: transcription)
        live.onLevel = { [weak self] level in self?.audioLevel = level }
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

    // MARK: - Lifecycle

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        do {
            try store.load()
            normalizeInterruptedRecords()
            records = store.records
            selectedRecordID = records.first?.id
            refreshAccessibilityPermission()
            // SwiftUI's settings Form is backed by NSTableView. Publishing the
            // initial catalog synchronously while scene restoration is laying it
            // out can re-enter its delegate and crash AppKit; defer one actor turn.
            refreshDevices()
            sharedVocabulary.configureAgencyLibrary()
            sharedVocabulary.startPeriodicRefresh()
            startAudioDeviceMonitor()
            startHotkeyMonitor()
            hudController = RecordingHUDController(appState: self)
            warmUpEngine()
        } catch {
            lastError = error.localizedDescription
            status = .failure("Could not load transcript history")
        }
    }

    func warmUpEngine() {
        warmUpTask?.cancel()
        let engine = settings.engine
        let model = settings.model
        let allowFallback = settings.allowAppleFallback
        guard engine == .whisperKit else {
            modelState = .ready
            return
        }
        modelState = .preparing
        warmUpTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let ready = await transcription.prepare(kind: engine, model: model)
            guard !Task.isCancelled,
                  self.settings.engine == engine,
                  self.settings.model == model else { return }
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

    func requestMicrophonePermission() async {
        hasMicrophonePermission = await Microphone.requestAccess()
        if hasMicrophonePermission {
            refreshDevices()
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

    func updateText(_ record: TranscriptRecord, to text: String) {
        do {
            try store.setText(id: record.id, text: text)
            records = store.records
        } catch {
            handleStorageError(error, message: "Could not save transcript changes")
        }
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
        latestRecordingSessionID = sessionID
        status = .preparingMic
        logger.info("Recording preparing session=\(sessionID.uuidString, privacy: .public)")
        DiagnosticsService.breadcrumb(category: "recording", metadata: ["phase": "preparing"])

        let allowed = await Microphone.requestAccess()
        hasMicrophonePermission = allowed
        guard recordingCoordinator.phase == .preparing(sessionID) else { return }
        guard allowed else {
            _ = recordingCoordinator.fail(sessionID)
            status = .failure("Microphone access is required")
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
            guard recordingCoordinator.phase == .preparing(sessionID) else { return }
            liveText = ""
            let configuration = makeTranscriptionConfiguration()
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
            status = .recording
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
            lastError = error.localizedDescription
            logger.error("Recording start failed error=\(error.localizedDescription, privacy: .public)")
            DiagnosticsService.capture(
                error: error,
                category: "audio",
                code: String((error as NSError).code)
            )
            status = .failure("Could not start recording")
        }
    }

    private func finishRecording(reason: CaptureStopReason = .userReleased) async {
        if case .preparing = recordingCoordinator.phase {
            status = .preparingMic
            return
        }
        guard case .recording(let sessionID) = recordingCoordinator.phase,
              recordingCoordinator.requestFinish(sessionID, reason: reason) else { return }

        isRecording = false
        recordingStartedAt = nil
        status = .transcribing
        DiagnosticsService.breadcrumb(
            category: "recording",
            metadata: ["phase": "finishing", "stop_reason": String(describing: reason)]
        )

        let wasStreaming = streamingActive
        streamingActive = false
        let configuration = activeRecordingConfiguration ?? makeTranscriptionConfiguration()
        activeRecordingConfiguration = nil
        let pasteTarget = pasteTargetApplication
        pasteTargetApplication = nil
        let result = await live.finish(reason: reason)
        _ = recordingCoordinator.didFinish(sessionID)
        if configuration.playSounds { soundService.play(.recordingStopped) }
        liveText = ""

        if wasStreaming, !result.text.isEmpty {
            // Streaming already produced the transcript — paste immediately, then
            // persist the audio + record off the critical path.
            status = .transcribing
            deliver(
                result.text,
                pasteTarget: pasteTarget,
                delivery: configuration.delivery,
                mayUpdateStatus: canUpdateLifecycleUI(for: sessionID)
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
            status = .transcribing
            await transcribeCapturedSamples(
                result.samples,
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

        Task.detached(priority: .utility) { [weak self] in
            do {
                try AudioFileWriter.writeWAV(samples: samples, to: url)
                await self?.appendRecord(
                    text: text,
                    audioPath: url.path,
                    createdAt: createdAt,
                    duration: duration,
                    model: model,
                    engine: engine,
                    language: language,
                    sessionID: sessionID
                )
            } catch {
                await self?.handleStorageError(error, message: "Could not save recording")
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
    ) {
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
        } catch {
            handleStorageError(error, message: "Could not save transcript")
        }
    }

    /// Write captured samples to a WAV and transcribe via the standard engine
    /// path (used for non-streaming engines and the streaming-empty fallback).
    private func transcribeCapturedSamples(
        _ samples: [Float],
        pasteTarget: NSRunningApplication?,
        configuration: TranscriptionJobConfiguration,
        sessionID: UUID
    ) async {
        guard !samples.isEmpty else {
            if canUpdateLifecycleUI(for: sessionID) {
                status = .failure("No speech was detected")
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

        activeTranscriptionIDs.insert(record.id)
        isTranscribing = true
        do {
            try store.markTranscribing(id: record.id)
        } catch {
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
            let finalText = configuration.vocabulary.apply(to: outcome.result.text)
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
        logger.error("Storage failure error=\(error.localizedDescription, privacy: .public)")
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
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("WhiskerFlow", isDirectory: true)

        return TranscriptStore(fileURL: root.appendingPathComponent("transcripts.json"))
    }
}
