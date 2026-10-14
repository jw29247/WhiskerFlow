import Foundation

/// Serializes running-state queries with invalidation before the unit is disposed.
final class AudioUnitRunningState: @unchecked Sendable {
    private let queue: DispatchQueue
    private let query: () -> Bool?
    private let lifetimeLock = NSLock()
    private var invalidated = false
    private let stateLock = NSLock()
    private var running = false

    init(queue: DispatchQueue = DispatchQueue(label: "WhiskerFlow.capture-running-state"),
         query: @escaping () -> Bool?) {
        self.queue = queue
        self.query = query
    }

    var isRunning: Bool { stateLock.withLock { running } }
    func setRunning(_ value: Bool) { stateLock.withLock { running = value } }

    func propertyChanged() {
        // CoreAudio can notify on its I/O thread while holding a HAL lock.
        // Re-entering AudioUnitGetProperty there can deadlock teardown.
        queue.async { [self] in refresh() }
    }

    private func refresh() {
        lifetimeLock.withLock {
            guard !invalidated, let value = query() else { return }
            setRunning(value)
        }
    }

    /// Called on the engine queue before stopping or disposing the unit.
    /// Pending notifications then cannot query a freed AudioUnit.
    func invalidate() {
        lifetimeLock.withLock {
            invalidated = true
            setRunning(false)
        }
    }
}
