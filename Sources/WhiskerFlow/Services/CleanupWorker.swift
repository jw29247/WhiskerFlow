import CryptoKit
import Foundation
import WhiskerFlowCleanupSupport
import WhiskerFlowCore

enum CleanupFailure: Error { case invalidModel, unavailable, interrupted, incomplete }

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

    static func validate(_ url: URL, model: CleanupModel) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == model.sha256 else {
            throw CleanupFailure.invalidModel
        }
    }

    func prepare(_ model: CleanupModel) async throws {
        let control = CleanupControl()
        register(control)
        defer { unregister(control) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do { try self.load(model, control: control); continuation.resume() }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { control.cancel() }
    }

    func generate(_ text: String, model: CleanupModel, seconds: TimeInterval) async throws -> String {
        let control = CleanupControl()
        register(control)
        defer { unregister(control) }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        guard !control.isCancelled else { throw CancellationError() }
                        try self.load(model, control: control)
                        guard !control.isCancelled else { throw CancellationError() }
                        var buffer = [CChar](repeating: 0, count: 24_000)
                        let tokenLimit = min(900, max(80, text.utf8.count / 2 + 40))
                        let result = wf_cleanup_generate(self.handle, TranscriptCleanup.prompt(for: text),
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

    private func load(_ model: CleanupModel, control: CleanupControl) throws {
        guard !control.isCancelled else { throw CancellationError() }
        if loaded == model, handle != nil { return }
        wf_cleanup_free(handle)
        handle = nil
        loaded = nil
        guard Self.isInstalled(model) else { throw CleanupFailure.invalidModel }
        guard wf_cleanup_has_headroom(UInt64(model.byteCount)) != 0 else { throw CleanupFailure.unavailable }
        if !verified.contains(model) {
            try Self.validate(Self.file(for: model), model: model)
            verified.insert(model)
        }
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
