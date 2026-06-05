import Foundation
import WhiskerFlowCore

/// Runs a subprocess without the classic pipe-buffer deadlock: stdout and stderr
/// are drained concurrently, and the call supports a timeout + cooperative cancellation.
enum ProcessRunner {
    struct Output: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    static func run(
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

        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading

        try process.run()

        return try await withTaskCancellationHandler {
            // Drain both pipes concurrently so a full buffer never blocks the child.
            async let outData = drain(outHandle)
            async let errData = drain(errHandle)

            let timedOut = await waitForExit(process, timeout: timeout)
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
            process.terminate()
        }
    }

    private static func drain(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
            let box = DataBox()
            handle.readabilityHandler = { fileHandle in
                let chunk = fileHandle.availableData
                if chunk.isEmpty {
                    fileHandle.readabilityHandler = nil
                    continuation.resume(returning: box.snapshot())
                } else {
                    box.append(chunk)
                }
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
                    process.terminate()
                    continuation.resume(returning: true)
                }
            }
        }
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
final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func fire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
