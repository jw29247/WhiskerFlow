import AppKit
import AVFoundation
import Foundation
import Observation
import WhiskerFlowCore

@MainActor
@Observable
final class AppState {
    var records: [TranscriptRecord] = []
    var selectedRecordID: TranscriptRecord.ID?
    var isRecording = false
    var isTranscribing = false
    var statusMessage = "Hold fn to dictate"
    var lastError: String?
    var hasAccessibilityPermission = false
    var devices: [AudioInputDevice] = []

    var selectedDeviceID: String {
        get { UserDefaults.standard.string(forKey: Defaults.selectedDeviceID) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Defaults.selectedDeviceID) }
    }

    var whisperCommand: String {
        get { UserDefaults.standard.string(forKey: Defaults.whisperCommand) ?? Self.defaultWhisperCommand }
        set { UserDefaults.standard.set(newValue, forKey: Defaults.whisperCommand) }
    }

    var whisperArguments: String {
        get {
            UserDefaults.standard.string(forKey: Defaults.whisperArguments)
                ?? Self.defaultWhisperArguments
        }
        set { UserDefaults.standard.set(newValue, forKey: Defaults.whisperArguments) }
    }

    private let store: TranscriptStore
    private let recorder = AudioCaptureService()
    private let whisperRunner = WhisperRunner()
    private let pasteService = PasteService()
    private let soundService = SoundService()
    private var functionKeyMonitor: FunctionKeyMonitor?
    private var hasStarted = false
    private var isPreparingRecording = false
    private var recordingIntentActive = false
    private var pasteTargetApplication: NSRunningApplication?
    private var activeTranscriptionIDs: Set<TranscriptRecord.ID> = []

    init(store: TranscriptStore = .defaultStore()) {
        self.store = store
    }

    var retryQueue: [TranscriptRecord] {
        records.filter { record in
            if case .failed = record.status {
                return true
            }
            return false
        }
    }

    var selectedRecord: TranscriptRecord? {
        guard let selectedRecordID else { return records.first }
        return records.first { $0.id == selectedRecordID }
    }

    var latestTranscript: TranscriptRecord? {
        records.first { $0.status == .transcribed }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        do {
            migrateWhisperDefaultsIfNeeded()
            try store.load()
            normalizeInterruptedRecords()
            records = store.records
            selectedRecordID = records.first?.id
            refreshAccessibilityPermission()
            refreshDevices()
            startFunctionKeyMonitor()
        } catch {
            lastError = error.localizedDescription
            statusMessage = "Could not load transcript history"
        }
    }

    func refreshDevices() {
        devices = AudioCaptureService.availableInputDevices()
        if selectedDeviceID.isEmpty {
            selectedDeviceID = devices.first?.id ?? ""
        }
    }

    func refreshAccessibilityPermission() {
        hasAccessibilityPermission = pasteService.hasAccessibilityPermission
    }

    func requestAccessibilityPermission() {
        pasteService.requestAccessibilityPermission()
        refreshAccessibilityPermission()
    }

    func retry(_ record: TranscriptRecord) {
        guard !activeTranscriptionIDs.contains(record.id) else { return }

        Task {
            await transcribeRecording(record)
        }
    }

    func retryAllFailed() {
        for record in retryQueue where !activeTranscriptionIDs.contains(record.id) {
            retry(record)
        }
    }

    func paste(_ text: String) {
        if !pasteService.paste(text, into: nil) {
            hasAccessibilityPermission = false
            statusMessage = "Allow Accessibility permission to auto-paste"
        }
    }

    private func startFunctionKeyMonitor() {
        functionKeyMonitor = FunctionKeyMonitor { [weak self] isPressed in
            guard let self else { return }
            if isPressed {
                self.recordingIntentActive = true
                self.pasteTargetApplication = NSWorkspace.shared.frontmostApplication
                Task { await self.beginRecording() }
            } else {
                self.recordingIntentActive = false
                Task { await self.finishRecording() }
            }
        }
        functionKeyMonitor?.start()
    }

    private func beginRecording() async {
        guard !isRecording, !isPreparingRecording, !isTranscribing else { return }
        isPreparingRecording = true

        do {
            let allowed = await AudioCaptureService.requestMicrophoneAccess()
            guard allowed else {
                isPreparingRecording = false
                statusMessage = "Microphone access is required"
                return
            }

            try recorder.start(deviceID: selectedDeviceID.isEmpty ? nil : selectedDeviceID)
            isPreparingRecording = false
            isRecording = true
            lastError = nil
            statusMessage = "Recording..."
            soundService.play(.recordingStarted)

            if !recordingIntentActive {
                await finishRecording()
            }
        } catch {
            isPreparingRecording = false
            isRecording = false
            lastError = error.localizedDescription
            statusMessage = "Could not start recording"
        }
    }

    private func finishRecording() async {
        if isPreparingRecording {
            statusMessage = "Preparing microphone..."
            return
        }

        guard isRecording else { return }
        isRecording = false
        statusMessage = "Transcribing..."
        soundService.play(.recordingStopped)

        do {
            let audioURL = try await recorder.stop()
            let record = TranscriptRecord(
                text: "",
                audioFilePath: audioURL.path,
                createdAt: Date(),
                status: .failed(errorMessage: "Transcribing...")
            )
            try store.add(record)
            records = store.records
            selectedRecordID = record.id
            await transcribeRecording(record)
        } catch {
            lastError = error.localizedDescription
            statusMessage = "Recording failed"
        }
    }

    private func transcribeRecording(_ record: TranscriptRecord) async {
        guard !activeTranscriptionIDs.contains(record.id) else { return }

        activeTranscriptionIDs.insert(record.id)
        isTranscribing = true
        defer {
            activeTranscriptionIDs.remove(record.id)
            isTranscribing = !activeTranscriptionIDs.isEmpty
        }

        do {
            let text = try await whisperRunner.transcribe(
                audioURL: URL(fileURLWithPath: record.audioFilePath),
                configuration: WhisperConfiguration(command: whisperCommand, argumentsTemplate: whisperArguments)
            )
            try store.markTranscribed(id: record.id, text: text)
            records = store.records
            selectedRecordID = record.id
            soundService.play(.transcriptionSucceeded)
            if pasteService.paste(text, into: pasteTargetApplication) {
                hasAccessibilityPermission = true
                statusMessage = "Pasted transcript"
            } else {
                hasAccessibilityPermission = false
                statusMessage = "Transcript copied; allow Accessibility to auto-paste"
            }
            pasteTargetApplication = nil
        } catch {
            try? store.markFailed(id: record.id, message: error.localizedDescription)
            records = store.records
            selectedRecordID = record.id
            lastError = error.localizedDescription
            statusMessage = "Transcription failed; queued for retry"
            soundService.play(.transcriptionFailed)
            pasteTargetApplication = nil
        }
    }

    private func normalizeInterruptedRecords() {
        for record in store.retryQueue {
            guard case .failed(let message) = record.status else { continue }
            guard message == "Transcribing..." || message == "Queued for transcription" else { continue }

            try? store.markFailed(
                id: record.id,
                message: "Interrupted before Whisper finished. Retry this recording."
            )
        }
    }

    private func migrateWhisperDefaultsIfNeeded() {
        let oldDefaultArguments = "\"{audio}\" --output_format txt --output_dir \"{output}\""
        let currentCommand = UserDefaults.standard.string(forKey: Defaults.whisperCommand)
        let currentArguments = UserDefaults.standard.string(forKey: Defaults.whisperArguments)

        if shouldResetWhisperCommand(currentCommand) {
            UserDefaults.standard.set(Self.defaultWhisperCommand, forKey: Defaults.whisperCommand)
        }

        if currentArguments == nil || currentArguments == oldDefaultArguments {
            UserDefaults.standard.set(Self.defaultWhisperArguments, forKey: Defaults.whisperArguments)
        }
    }

    private static var defaultWhisperCommand: String {
        let commonPaths = [
            "/opt/homebrew/bin/whisper",
            "/usr/local/bin/whisper"
        ]

        return commonPaths.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "whisper"
    }

    private func shouldResetWhisperCommand(_ command: String?) -> Bool {
        guard let command = command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
            return true
        }

        if command == "whisper" {
            return true
        }

        if command.contains("/") {
            return !FileManager.default.isExecutableFile(atPath: command)
        }

        let homebrewCommand = "/opt/homebrew/bin/\(command)"
        let intelHomebrewCommand = "/usr/local/bin/\(command)"
        return !FileManager.default.isExecutableFile(atPath: homebrewCommand)
            && !FileManager.default.isExecutableFile(atPath: intelHomebrewCommand)
    }

    private static var defaultWhisperArguments: String {
        "\"{audio}\" --model tiny --language en --fp16 False --output_format txt --output_dir \"{output}\""
    }
}

private enum Defaults {
    static let selectedDeviceID = "selectedDeviceID"
    static let whisperCommand = "whisperCommand"
    static let whisperArguments = "whisperArguments"
}

extension TranscriptStore {
    static func defaultStore() -> TranscriptStore {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("WhiskerFlow", isDirectory: true)

        return TranscriptStore(fileURL: root.appendingPathComponent("transcripts.json"))
    }
}
