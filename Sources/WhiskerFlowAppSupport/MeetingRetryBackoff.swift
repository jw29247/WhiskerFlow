import Foundation

/// Failed recordings retry independently; a bad recording must not consume the
/// decoder every minute or delay a newly completed meeting.
public struct MeetingRetryBackoff: Sendable {
    private var failures: [UUID: (count: Int, deadline: TimeInterval)] = [:]
    public init() {}
    public mutating func failed(_ id: UUID, now: TimeInterval) {
        let count = min(4, (failures[id]?.count ?? 0) + 1)
        let delay: TimeInterval = [60, 300, 900, 3600][count - 1]
        failures[id] = (count, now + delay)
    }
    public func isReady(_ id: UUID, now: TimeInterval) -> Bool {
        failures[id].map { now >= $0.deadline } ?? true
    }
    public mutating func succeeded(_ id: UUID) { failures[id] = nil }
    public mutating func reset() { failures.removeAll() }
}
