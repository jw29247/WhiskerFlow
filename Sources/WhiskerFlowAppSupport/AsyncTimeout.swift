import Foundation

public enum AsyncTimeoutError: Error, Equatable, Sendable {
    case timedOut
}

public func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
            try await Task.sleep(nanoseconds: nanoseconds)
            throw AsyncTimeoutError.timedOut
        }
        guard let result = try await group.next() else {
            throw AsyncTimeoutError.timedOut
        }
        group.cancelAll()
        return result
    }
}

/// Time-box `operation` without waiting for it. On timeout the operation task is
/// cancelled and then abandoned: it may keep running to completion, and that is
/// the point — a wedged, non-cancellable decode can no longer hold the caller
/// (and the whole app) hostage the way `withTimeout` would while awaiting its
/// child task. Cancelling the caller abandons the operation the same way and
/// throws `CancellationError` immediately.
public func withAbandoningDeadline<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await abandoningWait(seconds: seconds, operation: operation)
}

/// Await `operation` with no deadline, but stop waiting as soon as the caller
/// is cancelled. For joining shared, non-cancellable work (a model load other
/// callers also wait on) without tying the caller's lifetime to it.
public func withAbandoningCancellation<T: Sendable>(
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await abandoningWait(seconds: nil, operation: operation)
}

private func abandoningWait<T: Sendable>(
    seconds: TimeInterval?,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    // The work and timer are unstructured so a non-cooperative operation can be
    // left behind; they therefore do not inherit the caller's cancellation, and
    // the handler below forwards it explicitly.
    let wait = AbandonableWait<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            wait.start(continuation: continuation, seconds: seconds, operation: operation)
        }
    } onCancel: {
        wait.cancel()
    }
}

private final class AbandonableWait<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var isCancelled = false

    func start(
        continuation: CheckedContinuation<T, Error>,
        seconds: TimeInterval?,
        operation: @escaping @Sendable () async throws -> T
    ) {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        work = Task {
            do {
                self.resume(with: .success(try await operation()))
            } catch {
                self.resume(with: .failure(error))
            }
        }
        if let seconds {
            timer = Task {
                let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                self.resume(with: .failure(AsyncTimeoutError.timedOut))
            }
        }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
        resume(with: .failure(CancellationError()))
    }

    private func resume(with result: Result<T, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        let work = work
        let timer = timer
        lock.unlock()
        guard let continuation else { return }
        timer?.cancel()
        if case .failure = result { work?.cancel() }
        continuation.resume(with: result)
    }
}
