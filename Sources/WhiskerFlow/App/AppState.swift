import AppKit
import Foundation
import Observation
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

enum ModelState: Equatable {
    case unloaded
    case preparing
    case ready
    case failed(String)
}

@MainActor
@Observable
final class AppState {
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
    var devices: [AudioInputDevice] = []
    var lastError: String?
    var searchText = ""

    var settings: AppSettings

    private let store: TranscriptStore
    private let transcription = TranscriptionService()
    private let live: LiveDictationSession
    private let pasteService = PasteService()
    private let soundService = SoundService()
    private var hotkeyMonitor: HotkeyMonitor?
    private var hudController: RecordingHUDController?
    private var hasStarted = false
    private var isPreparingRecording = false
    private var recordingIntentActive = false
    private var pasteTargetApplication: NSRunningApplication?
    private var activeTranscriptionIDs: Set<UUID> = []
    /// Whether the most recent recording streamed live (vs. file-based capture).
    private var streamingActive = false

    init(settings: AppSettings? = nil, store: TranscriptStore = .defaultStore()) {
        self.settings = settings ?? AppSettings()
        self.store = store
        self.live = LiveDictationSession(transcription: transcription)
        live.onLevel = { [weak self] level in self?.audioLevel = level }
        live.onPartial = { [weak self] text in self?.liveText = text }
    }

    // MARK: - Derived state

    var statusMessage: String {
        switch status {
        case .idle:
            switch modelState {
            case .preparing: return "Preparing \(settings.model.displayName.lowercased())…"
            case .failed(let message): return message
            default: return "Hold \(settings.hotkey.displayName) to dictate"
            }
        case .preparingMic: return "Preparing microphone…"
        case .recording: return "Recording…"
        case .transcribing: return "Transcribing…"
        case .success(let message): return message
        case .failure(let message): return message
        }
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
            refreshDevices()
            startHotkeyMonitor()
            hudController = RecordingHUDController(appState: self)
            warmUpEngine()
        } catch {
            lastError = error.localizedDescription
            status = .failure("Could not load transcript history")
        }
    }

    func warmUpEngine() {
        guard settings.engine == .whisperKit else {
            modelState = .ready
            return
        }
        modelState = .preparing
        Task {
            let ready = await transcription.prepare(kind: settings.engine, model: settings.model)
            modelState = ready ? .ready : .failed("Could not load \(settings.model.displayName). Apple Speech will be used.")
        }
    }

    func reloadHotkey() {
        hotkeyMonitor?.update(trigger: settings.hotkey)
    }

    func refreshDevices() {
        devices = Microphone.availableInputDevices()
        if settings.selectedDeviceID.isEmpty || !devices.contains(where: { $0.id == settings.selectedDeviceID }) {
            settings.selectedDeviceID = devices.first?.id ?? ""
        }
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
        try? store.setText(id: record.id, text: text)
        records = store.records
    }

    func delete(_ record: TranscriptRecord) {
        try? store.delete(id: record.id)
        records = store.records
        if selectedRecordID == record.id {
            selectedRecordID = records.first?.id
        }
    }

    func retry(_ record: TranscriptRecord) {
        guard !activeTranscriptionIDs.contains(record.id) else { return }
        Task { await transcribeRecording(record) }
    }

    func retryAllFailed() {
        for record in retryQueue where !activeTranscriptionIDs.contains(record.id) {
            retry(record)
        }
    }

    // MARK: - Recording

    private func startHotkeyMonitor() {
        let monitor = HotkeyMonitor(trigger: settings.hotkey) { [weak self] pressed in
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
        guard !isRecording, !isPreparingRecording else { return }
        isPreparingRecording = true

        let allowed = await Microphone.requestAccess()
        hasMicrophonePermission = allowed
        guard allowed else {
            isPreparingRecording = false
            status = .failure("Microphone access is required")
            return
        }

        do {
            liveText = ""
            // Stream + decode live for the WhisperKit engine; other engines stay
            // file-based (captured here, transcribed from the WAV on release).
            streamingActive = settings.engine == .whisperKit && settings.liveTranscription
            try live.start(
                deviceID: settings.selectedDeviceID,
                language: settings.resolvedLanguage,
                model: settings.model,
                vocabulary: settings.vocabulary,
                streaming: streamingActive
            )
            isPreparingRecording = false
            isRecording = true
            recordingStartedAt = Date()
            lastError = nil
            status = .recording
            if settings.playSounds { soundService.play(.recordingStarted) }

            // Hold mode: if the key was already released while preparing, stop now.
            if settings.recordingMode == .holdToTalk, !recordingIntentActive {
                await finishRecording()
            }
        } catch {
            isPreparingRecording = false
            isRecording = false
            streamingActive = false
            lastError = error.localizedDescription
            status = .failure("Could not start recording")
        }
    }

    private func finishRecording() async {
        if isPreparingRecording {
            status = .preparingMic
            return
        }
        guard isRecording else { return }

        isRecording = false
        recordingStartedAt = nil
        if settings.playSounds { soundService.play(.recordingStopped) }

        let wasStreaming = streamingActive
        streamingActive = false
        let result = await live.finish()
        liveText = ""

        if wasStreaming, !result.text.isEmpty {
            // Streaming already produced the transcript — paste immediately, then
            // persist the audio + record off the critical path.
            status = .transcribing
            deliver(result.text)
            persistLiveRecording(text: result.text, samples: result.samples)
        } else {
            // Non-streaming engine, or streaming caught no speech: fall back to the
            // standard file-based path (includes the Apple Speech fallback).
            status = .transcribing
            await transcribeCapturedSamples(result.samples)
        }
    }

    /// Save a finished streaming transcript + its audio without blocking the
    /// paste. The WAV is encoded off the main actor; the store update hops back.
    private func persistLiveRecording(text: String, samples: [Float]) {
        let createdAt = Date()
        let duration = Double(samples.count) / 16_000
        let model = settings.model.rawValue
        let engine = settings.engine.rawValue
        let language = settings.resolvedLanguage
        guard let url = try? AudioFileWriter.makeRecordingURL() else { return }

        Task.detached(priority: .utility) { [weak self] in
            try? AudioFileWriter.writeWAV(samples: samples, to: url)
            await self?.appendRecord(
                text: text,
                audioPath: url.path,
                createdAt: createdAt,
                duration: duration,
                model: model,
                engine: engine,
                language: language
            )
        }
    }

    private func appendRecord(
        text: String,
        audioPath: String,
        createdAt: Date,
        duration: Double,
        model: String,
        engine: String,
        language: String?
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
        try? store.add(record)
        records = store.records
        selectedRecordID = record.id
    }

    /// Write captured samples to a WAV and transcribe via the standard engine
    /// path (used for non-streaming engines and the streaming-empty fallback).
    private func transcribeCapturedSamples(_ samples: [Float]) async {
        guard !samples.isEmpty else {
            status = .failure("No speech was detected")
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
                model: settings.model.rawValue,
                engine: settings.engine.rawValue,
                language: settings.resolvedLanguage
            )
            try store.add(record)
            records = store.records
            selectedRecordID = record.id
            await transcribeRecording(record)
        } catch {
            lastError = error.localizedDescription
            status = .failure("Recording failed")
        }
    }

    private func transcribeRecording(_ record: TranscriptRecord) async {
        guard !activeTranscriptionIDs.contains(record.id) else { return }

        activeTranscriptionIDs.insert(record.id)
        isTranscribing = true
        try? store.markTranscribing(id: record.id)
        records = store.records
        status = .transcribing

        defer {
            activeTranscriptionIDs.remove(record.id)
            isTranscribing = !activeTranscriptionIDs.isEmpty
        }

        do {
            let outcome = try await transcription.transcribe(
                audioURL: URL(fileURLWithPath: record.audioFilePath),
                kind: settings.engine,
                model: settings.model,
                language: settings.resolvedLanguage,
                initialPrompt: nil,
                cliConfiguration: settings.cliConfiguration,
                allowAppleFallback: settings.allowAppleFallback
            )
            let finalText = settings.vocabulary.apply(to: outcome.result.text)
            try store.markTranscribed(
                id: record.id,
                text: finalText,
                durationSeconds: outcome.result.duration,
                model: settings.model.rawValue,
                engine: outcome.engine.rawValue,
                language: outcome.result.language
            )
            records = store.records
            selectedRecordID = record.id
            if settings.playSounds { soundService.play(.transcriptionSucceeded) }
            deliver(finalText)
        } catch {
            try? store.markFailed(id: record.id, message: error.localizedDescription)
            records = store.records
            selectedRecordID = record.id
            lastError = error.localizedDescription
            status = .failure("Transcription failed; queued for retry")
            if settings.playSounds { soundService.play(.transcriptionFailed) }
            pasteTargetApplication = nil
        }
    }

    private func deliver(_ text: String) {
        switch settings.delivery {
        case .copyOnly:
            pasteService.copy(text)
            status = .success("Copied to clipboard")
            pasteTargetApplication = nil
        case .pasteAtCursor:
            if pasteService.paste(text, into: pasteTargetApplication) {
                hasAccessibilityPermission = true
                status = .success("Pasted transcript")
            } else {
                hasAccessibilityPermission = false
                status = .success("Transcript copied; allow Accessibility to auto-paste")
            }
            pasteTargetApplication = nil
        }
    }

    private func normalizeInterruptedRecords() {
        for record in store.records where record.status.isInProgress {
            try? store.markFailed(
                id: record.id,
                message: "Interrupted before transcription finished. Retry this recording."
            )
        }
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
