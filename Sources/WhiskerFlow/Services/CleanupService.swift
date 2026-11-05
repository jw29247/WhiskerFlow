import Foundation
import Logging
import Observation
import OpenTelemetryApi
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
    private(set) var configuredModel: CleanupModel?
    private(set) var needsShutdown = false
    @ObservationIgnored private let worker = CleanupWorker()
    @ObservationIgnored private let logger = Logging.Logger(label: "agency.thatworks.WhiskerFlow.Cleanup")
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
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

    init() {
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

    func installed(_ model: CleanupModel) -> Bool { CleanupWorker.isInstalled(model) }

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

    func clean(_ original: String, model: CleanupModel, vocabulary: Vocabulary = Vocabulary()) async -> CleanupResult {
        guard configuredModel == model, !running, !downloading, canRun(model), installed(model),
              !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              original.count <= TranscriptCleanup.maximumCharacters else {
            let outcome = original.count > TranscriptCleanup.maximumCharacters ? "too_long"
                : configuredModel != model || running || downloading ? "skipped" : "unavailable"
            let result = CleanupResult(text: original, outcome: outcome)
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
        let result = await Observability.tracer.spanBuilder(spanName: "cleanup.run").withActiveSpan { span in
            span.setAttributes([
                "gen_ai.provider.name": .string("local.gemma"),
                "gen_ai.request.model": .string(model.rawValue),
                "app.gen_ai.use_case": .string("transcript_cleanup"),
                "app.gen_ai.call_site": .string("cleanup.run"),
                "input.characters": .int(original.count)
            ])
            var outcome = "failed"
            defer {
                let attributes: [String: AttributeValue] = ["model": .string(model.rawValue), "outcome": .string(outcome)]
                Observability.cleanupOperations.add(value: 1, attributes: attributes)
                Observability.cleanupDuration.record(value: ProcessInfo.processInfo.systemUptime - started, attributes: attributes)
                span.setAttribute(key: "outcome", value: outcome)
                self.logger.info("Cleanup finished", metadata: ["event": "cleanup_finished", "cleanup_outcome": "\(outcome)", "elapsed_ms": "\((ProcessInfo.processInfo.systemUptime - started) * 1000)"])
            }
            do {
                let worker = self.worker
                let seconds: TimeInterval = original.count > 800 ? 8 : 3
                let attempt = try await withAbandoningDeadline(seconds: seconds) {
                    try await worker.cleanTranscript(original, model: model, seconds: seconds, vocabulary: vocabulary)
                }
                guard self.configurationID == identifier, !Task.isCancelled else {
                    outcome = "cancelled"
                    return CleanupResult(text: original, outcome: outcome)
                }
                let text = attempt.text
                span.setAttribute(key: "rejected_segments", value: attempt.rejectedSegments)
                outcome = text == original ? (attempt.rejectedSegments > 0 ? "rejected" : "unchanged")
                    : (attempt.rejectedSegments > 0 ? "partial" : "cleaned")
                if text == original && attempt.incomplete { outcome = "fallback" }
                span.status = .ok
                return CleanupResult(text: text, outcome: outcome)
            } catch {
                switch error {
                case is CancellationError: outcome = "cancelled"
                case CleanupFailure.unavailable: outcome = "unavailable"
                default: outcome = "fallback"
                }
                span.status = .error(description: "Local cleanup unavailable")
                span.addEvent(name: "exception", attributes: ["exception.type": .string(String(describing: type(of: error)))])
                span.addEvent(name: "cleanup.fallback", attributes: ["reason": .string(outcome)])
                return CleanupResult(text: original, outcome: outcome)
            }
        }
        running = false
        lastRun = result.summary
        if configurationID == identifier {
            status = result.outcome == "unavailable" ? "Paused to save resources"
                : result.outcome == "fallback" ? "Used original transcript" : "Warm and ready"
            scheduleSleep(model)
        }
        return result
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
        let started = ProcessInfo.processInfo.systemUptime
        return try await Observability.tracer.spanBuilder(spanName: "corrections.assess").withActiveSpan { span in
            span.setAttributes([
                "gen_ai.provider.name": .string("local.gemma"), "gen_ai.request.model": .string(model.rawValue),
                "app.gen_ai.use_case": .string("correction_learning"), "app.gen_ai.call_site": .string("corrections.assess"),
                "candidates.count": .int(edit.candidates.count)
            ])
            var outcome = "failed"
            defer {
                let dimensions: [String: AttributeValue] = ["outcome": .string(outcome), "use_case": .string("correction_learning")]
                Observability.cleanupOperations.add(value: 1, attributes: dimensions)
                Observability.cleanupDuration.record(value: ProcessInfo.processInfo.systemUptime - started, attributes: dimensions)
                span.setAttribute(key: "outcome", value: outcome)
                self.logger.info("Correction assessment finished", metadata: ["event": "correction_assessed", "cleanup_outcome": "\(outcome)"])
            }
            do {
                var approved: [VocabularyCorrection] = []
                for candidate in edit.candidates {
                    try Task.checkCancellation()
                    let response = try await self.worker.generatePrompt(CorrectionAssessment.prompt(for: candidate, edit: edit, model: model),
                                                                        model: model, tokenLimit: 12, seconds: 2, foreground: false)
                    guard self.configurationID == identifier else { throw CancellationError() }
                    if CorrectionAssessment.approved(response) { approved.append(candidate) }
                }
                try Task.checkCancellation()
                span.setAttribute(key: "approved.count", value: approved.count)
                span.status = .ok
                outcome = approved.isEmpty ? "unchanged" : "approved"
                return approved
            } catch {
                outcome = error is CancellationError ? "cancelled" : "unavailable"
                span.status = .error(description: "Local correction assessment interrupted")
                span.addEvent(name: "exception", attributes: ["exception.type": .string(String(describing: type(of: error)))])
                throw error
            }
        }
    }

    func download(_ model: CleanupModel, completion: @escaping @MainActor () -> Void) {
        guard !downloading else { return }
        downloading = true
        needsShutdown = true
        downloadProgress = 0
        status = "Downloading \(model.name)"
        downloadTask = Task { [weak self] in
            guard let self else { return }
            defer { self.downloading = false; self.downloadTask = nil }
            do {
                let download = CleanupDownload { [weak self] progress in
                    Task { @MainActor in self?.downloadProgress = progress }
                }
                let temporary = try await download.fetch(model.downloadURL)
                defer { try? FileManager.default.removeItem(at: temporary) }
                self.status = "Checking download"
                let validation = Task.detached(priority: .utility) { try CleanupWorker.validate(temporary, model: model) }
                try await withTaskCancellationHandler { try await validation.value } onCancel: { validation.cancel() }
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: CleanupWorker.directory, withIntermediateDirectories: true)
                let destination = CleanupWorker.file(for: model)
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                } else {
                    try FileManager.default.moveItem(at: temporary, to: destination)
                }
                self.status = "Downloaded"
                completion()
            } catch {
                self.status = Task.isCancelled ? "Download cancelled" : "Download failed. Try again."
            }
        }
    }

    func cancelDownload() { downloadTask?.cancel() }

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

private final class CleanupDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void
    init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }
    func fetch(_ url: URL) async throws -> URL {
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (temporary, response) = try await session.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return temporary
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
