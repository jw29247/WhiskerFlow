import CryptoKit
import Foundation
import WhiskerFlowCleanupSupport
import WhiskerFlowCore

enum CleanupFailure: Error { case invalidModel, unavailable, interrupted, incomplete }

struct CleanupAttempt: Sendable {
    let candidate: String
    let text: String
    let rejectedSegments: Int
    let incomplete: Bool
}

/// All model ownership and inference live on one utility queue. The cancellation
/// handle is separate so a deadline or pressure event can interrupt a decode.
final class CleanupWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "agency.thatworks.WhiskerFlow.cleanup", qos: .utility, autoreleaseFrequency: .workItem)
    private var handle: OpaquePointer?
    private var loaded: CleanupModel?
    private var verified = Set<CleanupModel>()
    private let controlLock = NSLock()
    private var controls: [CleanupControl] = []

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhiskerFlow/Models/Cleanup", isDirectory: true)
    }

    static func file(for model: CleanupModel) -> URL { directory.appendingPathComponent(model.filename) }

    static func isInstalled(_ model: CleanupModel) -> Bool {
        (try? file(for: model).resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(model.byteCount)
    }

    static func validate(_ url: URL, model: CleanupModel, cancelled: () -> Bool = { false }) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            if cancelled() { throw CancellationError() }
            // FileHandle can autorelease its NSData backing. Drain each chunk
            // instead of retaining the entire model until this queue item ends.
            let hasData = try autoreleasepool {
                guard let data = try file.read(upToCount: 4 * 1024 * 1024), !data.isEmpty else { return false }
                hash.update(data: data)
                return true
            }
            if !hasData { break }
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == model.sha256 else {
            throw CleanupFailure.invalidModel
        }
    }

    static var memoryPressure: Int32 { wf_cleanup_memory_state().pressure }
    static var hasEmergencyReserve: Bool { wf_cleanup_memory_state().available_bytes >= 512 * 1024 * 1024 }

    func prepare(_ model: CleanupModel, foreground: Bool = true) async throws {
        let control = CleanupControl()
        register(control)
        defer { unregister(control) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do { try self.load(model, control: control, foreground: foreground); continuation.resume() }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { control.cancel() }
    }

    func generate(_ text: String, model: CleanupModel, seconds: TimeInterval, vocabulary: Vocabulary = Vocabulary()) async throws -> String {
        try await generatePrompt(TranscriptCleanup.prompt(for: text, vocabulary: vocabulary, model: model), model: model,
                                 tokenLimit: min(1800, max(80, text.utf8.count / 2 + 40)), seconds: seconds)
    }

    func cleanTranscript(_ raw: String, model: CleanupModel, seconds: TimeInterval, vocabulary: Vocabulary) async throws -> CleanupAttempt {
        let text = DictatedNumberFormatter.format(raw)
        let started = ProcessInfo.processInfo.systemUptime
        var candidates = "", delivered = "", rejected = 0
        let segments = TranscriptCleanup.segments(for: text)
        for (index, segment) in segments.enumerated() {
            try Task.checkCancellation()
            let remaining = seconds - (ProcessInfo.processInfo.systemUptime - started)
            let candidate: String
            do {
                guard remaining > 0.15 else { throw CleanupFailure.interrupted }
                candidate = try await generate(segment.text, model: model, seconds: remaining - 0.1, vocabulary: vocabulary)
            } catch CleanupFailure.interrupted {
                try Task.checkCancellation()
                let untouched = segments[index...].map { $0.text + $0.suffix }.joined()
                return CleanupAttempt(candidate: candidates, text: delivered + untouched,
                                      rejectedSegments: rejected + segments.count - index, incomplete: true)
            } catch CleanupFailure.incomplete {
                let untouched = segments[index...].map { $0.text + $0.suffix }.joined()
                return CleanupAttempt(candidate: candidates, text: delivered + untouched,
                                      rejectedSegments: rejected + segments.count - index, incomplete: true)
            }
            let accepted = TranscriptCleanup.accepted(candidate, original: segment.text, vocabulary: vocabulary)
            candidates += candidate + segment.suffix
            delivered += (accepted ?? TranscriptCleanup.acceptedSentenceEdits(candidate, original: segment.text, vocabulary: vocabulary)
                ?? segment.text) + segment.suffix
            if accepted == nil { rejected += 1 }
        }
        return CleanupAttempt(candidate: candidates, text: delivered, rejectedSegments: rejected, incomplete: false)
    }

    func generatePrompt(_ prompt: String, model: CleanupModel, tokenLimit: Int, seconds: TimeInterval, foreground: Bool = true) async throws -> String {
        let control = CleanupControl()
        register(control)
        defer { unregister(control) }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        guard !control.isCancelled else { throw CancellationError() }
                        try self.load(model, control: control, foreground: foreground)
                        guard !control.isCancelled else { throw CancellationError() }
                        var buffer = [CChar](repeating: 0, count: 24_000)
                        let result = wf_cleanup_generate(self.handle, prompt,
                                                         &buffer, Int32(buffer.count), Int32(tokenLimit), seconds, control.pointer)
                        guard result == 0 else {
                            throw result == 1 ? CleanupFailure.interrupted : CleanupFailure.incomplete
                        }
                        continuation.resume(returning: String(cString: buffer))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { control.cancel() }
    }

    func unload() {
        controlLock.lock()
        controls.forEach { $0.cancel() }
        controlLock.unlock()
        queue.async {
            wf_cleanup_free(self.handle)
            self.handle = nil
            self.loaded = nil
        }
    }

    func unloadAndWait() async {
        unload()
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    private func load(_ model: CleanupModel, control: CleanupControl, foreground: Bool) throws {
        guard !control.isCancelled else { throw CancellationError() }
        let pressure = Self.memoryPressure
        guard pressure == 1 || pressure == 2 else { throw CleanupFailure.unavailable }
        if loaded == model, handle != nil {
            guard (foreground || pressure == 1), Self.hasEmergencyReserve else { throw CleanupFailure.unavailable }
            return
        }
        wf_cleanup_free(handle)
        handle = nil
        loaded = nil
        guard Self.isInstalled(model) else { throw CleanupFailure.invalidModel }
        if !verified.contains(model) {
            try Self.validate(Self.file(for: model), model: model, cancelled: { control.isCancelled })
            verified.insert(model)
        }
        guard wf_cleanup_has_headroom(model.workingSetBytes, foreground ? 1 : 0) != 0 else { throw CleanupFailure.unavailable }
        guard !control.isCancelled else { throw CancellationError() }
        handle = wf_cleanup_load(Self.file(for: model).path, 2, control.pointer)
        guard handle != nil else { throw CleanupFailure.unavailable }
        loaded = model
    }

    private func register(_ control: CleanupControl) {
        controlLock.lock()
        controls.append(control)
        controlLock.unlock()
    }

    private func unregister(_ control: CleanupControl) {
        controlLock.lock()
        controls.removeAll { $0 === control }
        controlLock.unlock()
    }
}

private final class CleanupControl: @unchecked Sendable {
    let pointer = wf_cleanup_control_create()!
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
    func cancel() {
        lock.lock()
        cancelled = true
        wf_cleanup_control_cancel(pointer)
        lock.unlock()
    }
    deinit { wf_cleanup_control_free(pointer) }
}
