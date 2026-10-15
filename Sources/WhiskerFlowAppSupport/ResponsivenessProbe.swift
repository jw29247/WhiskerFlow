import Foundation

struct ResponsivenessProbe {
    enum Event: Equatable {
        case enqueue(UInt64)
        case stalled(TimeInterval)
        case recovered(TimeInterval)
        case monitoringGap(TimeInterval)
    }

    private enum State {
        case ready
        case waiting(UInt64, TimeInterval)
        case stalled(UInt64, TimeInterval)
    }

    private var state = State.ready
    private var sequence: UInt64 = 0
    private var lastTick: TimeInterval?
    private let stallThreshold: TimeInterval = 2
    private let schedulingGapThreshold: TimeInterval = 5

    mutating func reset() {
        state = .ready
        lastTick = nil
    }

    mutating func tick(at now: TimeInterval) -> [Event] {
        var events = resetAfterSchedulingGap(at: now)
        lastTick = now
        switch state {
        case .ready:
            sequence &+= 1
            state = .waiting(sequence, now)
            events.append(.enqueue(sequence))
        case let .waiting(id, since) where now - since >= stallThreshold:
            state = .stalled(id, since)
            events.append(.stalled(now - since))
        case .waiting, .stalled:
            break
        }
        return events
    }

    mutating func acknowledge(_ id: UInt64, at now: TimeInterval) -> [Event] {
        switch state {
        case let .waiting(pendingID, since) where pendingID == id:
            let gaps = resetAfterSchedulingGap(at: now)
            state = .ready
            guard gaps.isEmpty else { return gaps }
            let elapsed = now - since
            return elapsed >= stallThreshold ? [.stalled(elapsed), .recovered(elapsed)] : []
        case let .stalled(pendingID, since) where pendingID == id:
            let gaps = resetAfterSchedulingGap(at: now)
            state = .ready
            return gaps.isEmpty ? [.recovered(now - since)] : gaps
        default:
            return []
        }
    }

    private mutating func resetAfterSchedulingGap(at now: TimeInterval) -> [Event] {
        guard let lastTick, now - lastTick >= schedulingGapThreshold else { return [] }
        state = .ready
        self.lastTick = now
        return [.monitoringGap(now - lastTick)]
    }
}
