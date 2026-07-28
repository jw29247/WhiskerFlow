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
/// child task.
public func withAbandoningDeadline<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let once = ResumeGuard()
    return try await withCheckedThrowingContinuation { continuation in
        let work = Task {
            do {
                let value = try await operation()
                if once.fire() { continuation.resume(returning: value) }
            } catch {
                if once.fire() { continuation.resume(throwing: error) }
            }
        }
        Task {
            let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            if once.fire() {
                work.cancel()
                continuation.resume(throwing: AsyncTimeoutError.timedOut)
            }
        }
    }
}
