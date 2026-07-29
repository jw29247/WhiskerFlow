import Foundation

/// Counts in-flight background work so shutdown can wait for it to land instead
/// of losing it. Waiting polls rather than parking a continuation, so `end` stays
/// callable from any main-actor context without resume bookkeeping.
@MainActor
public final class PendingWorkTracker {
    private static let pollInterval: TimeInterval = 0.02

    private var active: Set<UUID> = []

    public init() {}

    public var isIdle: Bool { active.isEmpty }

    public func begin() -> UUID {
        let token = UUID()
        active.insert(token)
        return token
    }

    public func end(_ token: UUID) {
        active.remove(token)
    }

    /// `true` once nothing is outstanding, `false` if `timeout` elapsed first.
    public func waitUntilIdle(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while !active.isEmpty {
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
        }
        return true
    }
}
