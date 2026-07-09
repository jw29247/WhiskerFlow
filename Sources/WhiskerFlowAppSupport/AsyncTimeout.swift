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
