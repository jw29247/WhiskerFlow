import Foundation
import WhiskerFlowCore

/// Runs a subprocess without the classic pipe-buffer deadlock: stdout and stderr
/// are drained concurrently, and the call supports a timeout + cooperative cancellation.
public enum ProcessRunner {
    public struct Output: Sendable {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String
    }

    public static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) async throws -> Output {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = outPipe
        process.standardError = errPipe

        let outDrainer = PipeDrainer(outPipe.fileHandleForReading)
        let errDrainer = PipeDrainer(errPipe.fileHandleForReading)

        try process.run()

        return try await withTaskCancellationHandler {
            // Drain both pipes concurrently so a full buffer never blocks the child.
            async let outData = outDrainer.value()
            async let errData = errDrainer.value()

            let timedOut = await waitForExit(process, timeout: timeout)
            // A grandchild can inherit the pipe write end, so EOF may never arrive
            // once the child is gone: bound the drain instead of awaiting forever.
            DispatchQueue.global().asyncAfter(deadline: .now() + drainGrace) {
                outDrainer.forceFinish()
                errDrainer.forceFinish()
            }
            let out = await outData
            let err = await errData

            if timedOut { throw TranscriptionError.timedOut(seconds: Int(timeout)) }
            if Task.isCancelled { throw TranscriptionError.cancelled }

            return Output(
                exitCode: process.terminationStatus,
                stdout: String(decoding: out, as: UTF8.self),
                stderr: String(decoding: err, as: UTF8.self)
            )
        } onCancel: {
            terminateThenKill(process)
        }
    }

    private static let drainGrace: TimeInterval = 1
    private static let killGrace: TimeInterval = 2

    private static func terminateThenKill(_ process: Process) {
        process.terminate()
        // SIGTERM can be trapped or ignored; escalate so we never leak a child.
        DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    private static func waitForExit(_ process: Process, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let guardOnce = ResumeGuard()
            process.terminationHandler = { _ in
                if guardOnce.fire() { continuation.resume(returning: false) }
            }
            // Cover the race where the process exits before the handler was attached.
            if !process.isRunning, guardOnce.fire() {
                continuation.resume(returning: false)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if guardOnce.fire() {
                    terminateThenKill(process)
                    continuation.resume(returning: true)
                }
            }
        }
    }
}

/// Accumulates one pipe's output and hands it over exactly once, either at EOF or
/// when `forceFinish()` gives up on an EOF that is never coming.
final class PipeDrainer: @unchecked Sendable {
    private let handle: FileHandle
    private let box = DataBox()
    private let once = ResumeGuard()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Never>?
    private var finishedBeforeAwait = false

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func value() async -> Data {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
            lock.lock()
            if finishedBeforeAwait {
                lock.unlock()
                continuation.resume(returning: box.snapshot())
                return
            }
            self.continuation = continuation
            lock.unlock()

            handle.readabilityHandler = { [weak self] fileHandle in
                guard let self, !self.once.hasFired else { return }
                let chunk = fileHandle.availableData
                if chunk.isEmpty {
                    fileHandle.readabilityHandler = nil
                    self.finish()
                } else {
                    self.box.append(chunk)
                }
            }
        }
    }

    func forceFinish() {
        handle.readabilityHandler = nil
        finish()
        try? handle.close()
    }

    private func finish() {
        guard once.fire() else { return }
        lock.lock()
        let pending = continuation
        continuation = nil
        if pending == nil { finishedBeforeAwait = true }
        lock.unlock()
        pending?.resume(returning: box.snapshot())
    }
}

/// Thread-safe accumulating buffer for pipe reads.
final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

/// Ensures a continuation is resumed exactly once across competing callbacks.
public final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    public init() {}

    public func fire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }

    var hasFired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }
}
