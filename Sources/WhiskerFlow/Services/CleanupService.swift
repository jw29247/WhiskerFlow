import Foundation
import Logging
import Observation
import WhiskerFlowAppSupport
import WhiskerFlowCore

struct CleanupResult: Sendable {
    let text: String
    let outcome: String

    var summary: String {
        switch outcome {
        case "cleaned": return "Cleaned up the transcript"
        case "partial": return "Cleaned up the transcript. Kept some wording to preserve your meaning."
        case "unchanged": return "Checked the transcript. No changes needed."
        case "formatted": return "Formatted numbers. Kept the rest of the recognised wording."
        case "rejected": return "Kept the original because the proposed edit changed too much."
        case "cancelled": return "Cleanup was interrupted. Kept the original."
        case "too_long": return "Transcript exceeds the preview limit. Kept the original."
        case "unavailable": return "Cleanup is paused or the model isn't ready. Kept the original."
        case "skipped": return "Cleanup is off or busy. Kept the original."
        default: return "Cleanup couldn't finish in time. Kept the original."
        }
    }
}

@MainActor
@Observable
final class CleanupService {
    private(set) var status = "Off"
    private(set) var lastRun = "No transcript checked yet"
    private(set) var downloading = false
    private(set) var running = false
    private(set) var downloadProgress: Double = 0
    /// How much of an interrupted download is on disk, from 0 to 1.
    private(set) var resumableFraction: Double = 0
    private(set) var configuredModel: CleanupModel?
    private(set) var needsShutdown = false
    @ObservationIgnored private let worker = CleanupWorker()
    @ObservationIgnored private let logger = Logging.Logger(label: "agency.thatworks.WhiskerFlow.Cleanup")
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var activeDownload: ResumableModelDownload?
    @ObservationIgnored private var discardingDownload = false
    @ObservationIgnored private let downloadTransport: ModelDownloadTransport
    @ObservationIgnored private var warmTask: Task<Void, Never>?
    @ObservationIgnored private var pressure: DispatchSourceMemoryPressure?
    @ObservationIgnored private var pressureUntil = Date.distantPast
    @ObservationIgnored private var configurationID = UUID()

    static var supported: Bool {
        #if arch(arm64)
        ProcessInfo.processInfo.physicalMemory >= 8 * 1_073_741_824
        #else
        false
        #endif
    }

    init(downloadTransport: ModelDownloadTransport = URLSessionModelDownloadTransport()) {
        self.downloadTransport = downloadTransport
        // Only looks for a partial file; a download never starts by itself.
        resumableFraction = Self.modelDownload(.gemma4E2B, transport: downloadTransport).resumableFraction
        #if DEBUG
        // `--ui-state=cleanup-partial` and `cleanup-downloading` preview an interrupted download.
        if UIPreview.mode == "cleanup-partial" { resumableFraction = 0.42 }
        if UIPreview.mode == "cleanup-downloading" { downloading = true; downloadProgress = 0.42; status = "Resuming Gemma 4 E2B download" }
        #endif
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.memoryPressureChanged() }
        }
        source.resume()
        pressure = source
    }

    func configure(model: CleanupModel?, enabled: Bool) {
        let next = enabled ? model : nil
        guard next != configuredModel else { return }
        configurationID = UUID()
        configuredModel = next
        warmTask?.cancel()
        idleTask?.cancel()
        worker.unload()
        status = next.map { CleanupWorker.isInstalled($0) ? "Ready on next dictation" : "Download needed" } ?? "Off"
    }

    func installed(_ model: CleanupModel) -> Bool {
        // `--ui-state=cleanup-missing` previews Settings before the download.
        if ["cleanup-missing", "cleanup-partial", "cleanup-downloading"].contains(UIPreview.mode) { return false }
        return CleanupWorker.isInstalled(model)
    }

    func prewarm(_ model: CleanupModel, foreground: Bool = false) {
        guard configuredModel == model, warmTask == nil, !running, canRun(model), installed(model) else { return }
        let identifier = configurationID
        needsShutdown = true
        status = "Warming up"
        warmTask = Task { [weak self] in
            guard let self else { return }
            defer { self.warmTask = nil }
            do {
                try await self.worker.prepare(model, foreground: foreground)
                guard !Task.isCancelled, self.configurationID == identifier else { return }
                if !self.running {
                    self.status = "Warm and ready"
                    self.scheduleSleep(model, prewarming: true)
                }
            } catch {
                guard self.configurationID == identifier else { return }
                self.status = CleanupWorker.memoryPressure == 2 ? "Ready on next dictation. Background warming is paused."
                    : "Model couldn't load. Dictation still works."
            }
        }
    }

    func clean(_ raw: String, model: CleanupModel, vocabulary: Vocabulary = Vocabulary()) async -> CleanupResult {
        let original = configuredModel == model ? DictatedNumberFormatter.format(raw) : raw
        guard configuredModel == model, !running, !downloading, canRun(model), installed(model),
              !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              original.count <= TranscriptCleanup.maximumCharacters else {
            let outcome = original.count > TranscriptCleanup.maximumCharacters ? "too_long"
                : configuredModel != model || running || downloading ? "skipped" : "unavailable"
            let result = CleanupResult(text: original, outcome: original != raw ? "formatted" : outcome)
            lastRun = result.summary
            logger.info("Cleanup skipped", metadata: ["event": "cleanup_finished", "cleanup_outcome": "\(outcome)"])
            return result
        }
        running = true
        needsShutdown = true
        idleTask?.cancel()
        status = "Cleaning up"
        let identifier = configurationID
        let started = ProcessInfo.processInfo.systemUptime
        let result = await runCleanup(original, raw: raw, model: model, vocabulary: vocabulary,
                                      identifier: identifier, started: started)
        running = false
        lastRun = result.summary
        if configurationID == identifier {
            status = result.outcome == "unavailable" ? "Paused to save resources"
                : result.outcome == "formatted" ? "Ready on next dictation"
                : result.outcome == "fallback" ? "Used original transcript" : "Warm and ready"
            scheduleSleep(model)
        }
        return result
    }

    private func runCleanup(_ original: String, raw: String, model: CleanupModel, vocabulary: Vocabulary,
                            identifier: UUID, started: TimeInterval) async -> CleanupResult {
        var outcome = "failed"
        defer {
            logger.info("Cleanup finished", metadata: ["event": "cleanup_finished", "cleanup_outcome": "\(outcome)", "elapsed_ms": "\((ProcessInfo.processInfo.systemUptime - started) * 1000)"])
        }
        do {
            let worker = self.worker
            let seconds: TimeInterval = original.count > 800 ? 8 : 3
            let attempt = try await withAbandoningDeadline(seconds: seconds) {
                try await worker.cleanTranscript(original, model: model, seconds: seconds, vocabulary: vocabulary)
            }
            guard configurationID == identifier, !Task.isCancelled else {
                outcome = "cancelled"
                return CleanupResult(text: original, outcome: original != raw ? "formatted" : outcome)
            }
            let text = attempt.text
            outcome = text == raw ? (attempt.rejectedSegments > 0 ? "rejected" : "unchanged")
                : (attempt.rejectedSegments > 0 ? "partial" : "cleaned")
            if text == raw && attempt.incomplete { outcome = "fallback" }
            return CleanupResult(text: text, outcome: outcome)
        } catch {
            switch error {
            case is CancellationError: outcome = "cancelled"
            case CleanupFailure.unavailable: outcome = "unavailable"
            default: outcome = "fallback"
            }
            return CleanupResult(text: original, outcome: original != raw ? "formatted" : outcome)
        }
    }

    /// Background learning shares the warmed model and is cancelled by the
    /// caller as soon as foreground dictation starts.
    func assess(_ edit: CorrectionEdit) async throws -> [VocabularyCorrection] {
        guard let model = configuredModel, !running, !downloading, canRun(model), CleanupWorker.memoryPressure == 1, installed(model) else {
            throw CleanupFailure.unavailable
        }
        let identifier = configurationID
        needsShutdown = true
        idleTask?.cancel()
        defer { if configurationID == identifier { scheduleSleep(model) } }
        var outcome = "failed"
        defer {
            logger.info("Correction assessment finished", metadata: ["event": "correction_assessed", "cleanup_outcome": "\(outcome)"])
        }
        do {
            var approved: [VocabularyCorrection] = []
            for candidate in edit.candidates {
                try Task.checkCancellation()
                let response = try await worker.generatePrompt(CorrectionAssessment.prompt(for: candidate, edit: edit, model: model),
                                                               model: model, tokenLimit: 12, seconds: 2, foreground: false)
                guard configurationID == identifier else { throw CancellationError() }
                if CorrectionAssessment.approved(response) { approved.append(candidate) }
            }
            try Task.checkCancellation()
            outcome = approved.isEmpty ? "unchanged" : "approved"
            return approved
        } catch {
            outcome = error is CancellationError ? "cancelled" : "unavailable"
            throw error
        }
    }

    static func modelDownload(_ model: CleanupModel, transport: ModelDownloadTransport) -> ResumableModelDownload {
        ResumableModelDownload(source: model.downloadURL, byteCount: model.byteCount,
                               destination: CleanupWorker.file(for: model), transport: transport)
    }

    /// Starts the download, or resumes an interrupted one from the bytes
    /// already on disk. Only runs when the person asks for it.
    func download(_ model: CleanupModel, completion: @escaping @MainActor () -> Void) {
        guard !downloading else { return }
        let download = Self.modelDownload(model, transport: downloadTransport)
        let resumed = download.resumableFraction
        downloading = true
        discardingDownload = false
        needsShutdown = true
        activeDownload = download
        downloadProgress = resumed
        status = resumed > 0 ? "Resuming \(model.name) download" : "Downloading \(model.name)"
        downloadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.downloading = false
                self.downloadTask = nil
                self.activeDownload = nil
                self.resumableFraction = download.resumableFraction
            }
            do {
                // The finished file is checked against the pinned SHA-256
                // before it replaces anything; a mismatch is deleted.
                try await download.install(verify: { try CleanupWorker.validate($0, model: model) },
                                           verifying: { @MainActor [weak self] in self?.status = "Checking download" },
                                           progress: { [weak self] progress in
                                               Task { @MainActor in
                                                   guard let self, self.downloading else { return }
                                                   self.downloadProgress = max(self.downloadProgress, progress)
                                               }
                                           })
                self.status = "Downloaded"
                completion()
            } catch {
                if Task.isCancelled {
                    self.status = self.discardingDownload ? "Download cancelled" : "Download paused"
                } else if (error as? ResumableModelDownloadError) == .verificationFailed {
                    self.status = "The download didn't match the expected file and was deleted. Try again."
                } else {
                    self.status = download.resumableBytes > 0 ? "Download stopped. Resume to carry on where it left off."
                        : "Download failed. Try again."
                }
            }
        }
    }

    /// Stops the download and deletes what has downloaded so far.
    func cancelDownload() {
        discardingDownload = true
        activeDownload?.requestDiscard()
        downloadTask?.cancel()
    }

    /// Deletes an interrupted download that isn't running.
    func discardPartialDownload(_ model: CleanupModel) {
        guard !downloading else { return }
        let download = Self.modelDownload(model, transport: downloadTransport)
        download.discardPartial()
        resumableFraction = download.resumableFraction
        status = "Download cancelled"
    }

    func shutdown() async {
        configure(model: nil, enabled: false)
        downloadTask?.cancel()
        warmTask?.cancel()
        await worker.unloadAndWait()
        needsShutdown = false
    }

    func sleepNow() {
        idleTask?.cancel()
        worker.unload()
        if configuredModel != nil { status = "Sleeping to save memory" }
    }

    private func canRun(_ model: CleanupModel) -> Bool {
        let process = ProcessInfo.processInfo
        return Self.supported && process.physicalMemory >= model.minimumMemory
            && Date() >= pressureUntil && CleanupWorker.memoryPressure != 4
            && process.thermalState != .serious && process.thermalState != .critical
    }

    private func memoryPressureChanged() {
        guard let event = pressure?.data else { return }
        if !event.contains(.warning), !event.contains(.critical) {
            if configuredModel != nil && !running { status = "Ready on next dictation" }
            return
        }
        let critical = event.contains(.critical) || !CleanupWorker.hasEmergencyReserve
        // Warning sheds idle warming and learning. A finite foreground request
        // may finish when the measured headroom remains sufficient.
        guard critical || !running else { return }
        if critical { pressureUntil = Date().addingTimeInterval(60) }
        configurationID = UUID()
        warmTask?.cancel()
        sleepNow()
        if configuredModel != nil { status = "Paused while your Mac needs memory" }
    }

    private func scheduleSleep(_ model: CleanupModel, prewarming: Bool = false) {
        idleTask?.cancel()
        if CleanupWorker.memoryPressure != 1 && !prewarming { sleepNow(); return }
        let seconds = CleanupWorker.memoryPressure == 1 ? model.idleSeconds : 5
        idleTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            catch { return }
            self?.sleepNow()
        }
    }

    deinit { pressure?.cancel(); idleTask?.cancel(); downloadTask?.cancel(); warmTask?.cancel(); worker.unload() }
}
