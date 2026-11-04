import CryptoKit
import Foundation
import Logging
import Observation
import OpenTelemetryApi
import WhiskerFlowAppSupport
import WhiskerFlowCore

enum LocalCleanupModel {
    static let identifier = "gemma-4-E2B-it"
    static let byteCount: Int64 = 2_588_147_712
    static let sha256 = "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c"
    static let downloadURL = URL(string: "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/c658da437244f072bf2f1cabc916b60d66d97663/gemma-4-E2B-it.litertlm")!
    static var directory: URL {
        StorageLocations.applicationSupportRootOrTemporary()
            .appendingPathComponent("Models/DictationCleanup", isDirectory: true)
    }
    static var fileURL: URL { directory.appendingPathComponent("gemma-4-E2B-it.litertlm") }

    static func isDownloaded(at url: URL = fileURL) -> Bool {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(byteCount)
    }

    static func verify(_ url: URL) throws {
        guard isDownloaded(at: url) else { throw LocalCleanupError.invalidDownload }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw LocalCleanupError.invalidDownload
        }
    }
}

struct LocalCleanupResult: Equatable, Sendable {
    let text: String
    let applied: Bool
    let message: String
    let seconds: TimeInterval
}

@MainActor
@Observable
final class LocalCleanupController {
    enum State: Equatable {
        case notDownloaded, downloaded, downloading(Double), loading, ready, failed(String)
    }

    private(set) var state: State = LocalCleanupModel.isDownloaded() ? .downloaded : .notDownloaded
    private(set) var lastResult: LocalCleanupResult?
    private(set) var isCleaning = false
    @ObservationIgnored private let engine = LocalCleanupEngine()
    @ObservationIgnored private let cleanerOverride: (any DictationCleaning)?
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let logger = Logging.Logger(label: "agency.thatworks.WhiskerFlow.Cleanup")

    init(cleaner: (any DictationCleaning)? = nil) {
        cleanerOverride = cleaner
        if cleaner != nil { state = .ready }
    }

    var isPreparing: Bool {
        switch state { case .downloading, .loading: return true; default: return false }
    }

    func prepare(download: Bool = false) {
        guard preparation == nil, state != .ready else { return }
        guard download || LocalCleanupModel.isDownloaded() else { state = .notDownloaded; return }
        let token = UUID()
        generation = token
        state = LocalCleanupModel.isDownloaded() ? .loading : .downloading(0)
        let engine = engine
        preparation = Task { [weak self] in
            do {
                if !LocalCleanupModel.isDownloaded() {
                    let progress = CleanupDownloadProgress { fraction in
                        Task { @MainActor [weak self] in
                            guard let self, self.generation == token, case .downloading = self.state else { return }
                            self.state = .downloading(fraction)
                        }
                    }
                    let configuration = URLSessionConfiguration.ephemeral
                    configuration.timeoutIntervalForRequest = 120
                    configuration.timeoutIntervalForResource = 7200
                    let session = URLSession(configuration: configuration)
                    defer { session.invalidateAndCancel() }
                    let (temporary, response) = try await session.download(from: LocalCleanupModel.downloadURL, delegate: progress)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw LocalCleanupError.invalidDownload }
                    try await Task.detached(priority: .utility) { try LocalCleanupModel.verify(temporary) }.value
                    try Task.checkCancellation()
                    try FileManager.default.createDirectory(at: LocalCleanupModel.directory, withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: temporary, to: LocalCleanupModel.fileURL)
                }
                try Task.checkCancellation()
                guard self?.generation == token else { return }
                self?.state = .loading
                try await engine.prepare(modelURL: LocalCleanupModel.fileURL)
                try Task.checkCancellation()
                guard self?.generation == token else { return }
                self?.state = .ready
            } catch {
                guard self?.generation == token else { return }
                if Task.isCancelled {
                    self?.state = LocalCleanupModel.isDownloaded() ? .downloaded : .notDownloaded
                } else {
                    self?.state = .failed("Couldn’t prepare the cleanup model. Check your connection and free disk space, then retry.")
                    self?.logger.warning("Local cleanup preparation failed", metadata: ["error.type": "model_preparation"])
                }
            }
            if self?.generation == token { self?.preparation = nil }
        }
    }

    func cancelPreparation() {
        preparation?.cancel()
        // Keep the task registered until native loading/hash work has drained;
        // a quick cancel/retry must not initialize two engines in parallel.
        if preparation == nil { state = LocalCleanupModel.isDownloaded() ? .downloaded : .notDownloaded }
        Task { await engine.unload() }
    }

    func disable() { cancelPreparation() }

    /// Dictation and the Settings preview share this exact operation. No model
    /// download or initialization ever happens on the paste path.
    func clean(_ request: DictationCleanupRequest, fallback: String,
               deadline: TimeInterval = DictationCleanupRequest.deadlineSeconds) async -> LocalCleanupResult {
        let started = Date()
        guard request.isEligible else { return finish(fallback, applied: false, "Kept original: text is empty or too long for this preview.", started: started) }
        guard !isCleaning else { return finish(fallback, applied: false, "Kept original: cleanup is busy.", started: started) }
        guard state == .ready else {
            return finish(fallback, applied: false, "Kept original: cleanup model isn’t ready. Open Settings → Text to prepare it.", started: started)
        }
        isCleaning = true
        defer { isCleaning = false }
        let selected: any DictationCleaning = cleanerOverride ?? engine
        return await Observability.tracer.spanBuilder(spanName: "dictation.cleanup").withActiveSpan { span in
            span.setAttributes([
                "gen_ai.provider.name": .string("google"),
                "gen_ai.request.model": .string(LocalCleanupModel.identifier),
                "app.gen_ai.use_case": .string("dictation_cleanup"),
                "app.gen_ai.call_site": .string("LocalCleanupController.clean"),
                "input.bytes": .int(request.text.utf8.count)
            ])
            var outcome = "error"
            defer {
                span.setAttribute(key: "outcome", value: outcome)
                let attributes: [String: AttributeValue] = ["outcome": .string(outcome)]
                Observability.cleanupOperations.add(value: 1, attributes: attributes)
                Observability.cleanupDuration.record(value: Date().timeIntervalSince(started), attributes: attributes)
            }
            do {
                let output = try await withAbandoningDeadline(seconds: deadline) { try await selected.clean(request) }
                guard let text = request.validated(output) else { throw LocalCleanupError.invalidOutput }
                outcome = "success"
                span.status = .ok
                logger.info("Local dictation cleanup completed", metadata: ["outcome": "success"])
                return finish(text, applied: true, "Cleaned on this Mac with Gemma 4 E2B.", started: started)
            } catch {
                let timedOut = (error as? AsyncTimeoutError) == .timedOut
                let category = timedOut ? "timeout" : (error is CancellationError ? "cancelled" : "generation_failed")
                span.status = .error(description: category)
                span.addEvent(name: "exception", attributes: ["exception.type": .string(category)])
                logger.warning("Local cleanup kept the original text", metadata: ["error.type": "\(category)"])
                return finish(fallback, applied: false,
                              timedOut ? "Kept original: cleanup took too long." : "Kept original: cleanup couldn’t finish.", started: started)
            }
        }
    }

    private func finish(_ text: String, applied: Bool, _ message: String, started: Date) -> LocalCleanupResult {
        let result = LocalCleanupResult(text: text, applied: applied, message: message, seconds: Date().timeIntervalSince(started))
        lastResult = result
        return result
    }
}

private final class CleanupDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let update: @Sendable (Double) -> Void
    init(update: @escaping @Sendable (Double) -> Void) { self.update = update }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        update(min(1, Double(totalBytesWritten) / Double(LocalCleanupModel.byteCount)))
    }
}
