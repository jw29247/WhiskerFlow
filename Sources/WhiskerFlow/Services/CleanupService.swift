import Foundation
import Logging
import Observation
import OpenTelemetryApi
import WhiskerFlowAppSupport
import WhiskerFlowCore

struct CleanupResult: Sendable {
    let text: String
    let outcome: String
}

@MainActor
@Observable
final class CleanupService {
    private(set) var status = "Off"
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
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.releaseForPressure() }
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

    func prewarm(_ model: CleanupModel) {
        guard configuredModel == model, warmTask == nil, !running, canRun(model), installed(model) else { return }
        let identifier = configurationID
        needsShutdown = true
        status = "Warming up"
        warmTask = Task { [weak self] in
            guard let self else { return }
            defer { self.warmTask = nil }
            do {
                try await self.worker.prepare(model)
                guard !Task.isCancelled, self.configurationID == identifier else { return }
                if !self.running { self.status = "Warm and ready" }
                self.scheduleSleep(model)
            } catch {
                guard self.configurationID == identifier else { return }
                self.status = "Model couldn't load. Dictation still works."
            }
        }
    }

    func clean(_ original: String, model: CleanupModel) async -> CleanupResult {
        guard configuredModel == model, !running, !downloading, canRun(model), installed(model),
              !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              original.count <= TranscriptCleanup.maximumCharacters else {
            return CleanupResult(text: original, outcome: "skipped")
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
                self.logger.info("Cleanup finished", metadata: ["outcome": "\(outcome)", "model": "\(model.rawValue)"])
            }
            do {
                let worker = self.worker
                let seconds: TimeInterval = original.count > 800 ? 8 : 3
                let candidate = try await withAbandoningDeadline(seconds: seconds) {
                    try await worker.generate(original, model: model, seconds: seconds)
                }
                guard self.configurationID == identifier, !Task.isCancelled else {
                    outcome = "cancelled"
                    return CleanupResult(text: original, outcome: outcome)
                }
                guard let text = TranscriptCleanup.accepted(candidate, original: original) else {
                    outcome = "rejected"
                    span.status = .ok
                    return CleanupResult(text: original, outcome: outcome)
                }
                outcome = text == original ? "unchanged" : "cleaned"
                span.status = .ok
                return CleanupResult(text: text, outcome: outcome)
            } catch {
                outcome = error is CancellationError ? "cancelled" : "fallback"
                span.status = .error(description: "Local cleanup unavailable")
                span.addEvent(name: "exception", attributes: ["exception.type": .string(String(describing: type(of: error)))])
                span.addEvent(name: "cleanup.fallback", attributes: ["reason": .string(outcome)])
                return CleanupResult(text: original, outcome: outcome)
            }
        }
        running = false
        if configurationID == identifier {
            status = result.outcome == "fallback" ? "Used original transcript" : "Warm and ready"
            scheduleSleep(model)
        }
        return result
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
            && Date() >= pressureUntil && process.thermalState != .serious && process.thermalState != .critical
    }

    private func releaseForPressure() {
        pressureUntil = Date().addingTimeInterval(60)
        configurationID = UUID()
        warmTask?.cancel()
        sleepNow()
        if configuredModel != nil { status = "Paused while your Mac needs memory" }
    }

    private func scheduleSleep(_ model: CleanupModel) {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(model.idleSeconds * 1_000_000_000)) }
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
