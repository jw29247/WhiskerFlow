import Foundation
import WhiskerFlowAppSupport

/// A deadline the test ends: `sleep` records each request and returns when
/// the test calls `fire()`, when its task is cancelled, or, as a backstop for
/// a broken implementation, once the real duration has passed. A passing
/// test therefore never waits on real time.
final class ManualDeadline: @unchecked Sendable {
    private struct Request {
        let nanoseconds: UInt64
        let continuation: CheckedContinuation<Void, Never>
        let backstop: Task<Void, Never>
    }

    private let lock = NSLock()
    private var pending: [UUID: Request] = [:]
    private var requestCount = 0
    private var countWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var recorded: [UInt64] = []

    /// Every duration asked for so far, in order.
    var requested: [UInt64] { lock.withLock { recorded } }

    var sleep: DeadlineSleep {
        { [self] nanoseconds in await wait(nanoseconds) }
    }

    /// Returns once `count` sleeps have been asked for in total.
    func untilRequested(_ count: Int) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if requestCount >= count {
                lock.unlock()
                continuation.resume()
            } else {
                countWaiters.append((count, continuation))
                lock.unlock()
            }
        }
    }

    /// Ends every sleep under way, as if its duration had passed.
    func fire() {
        let ids = lock.withLock { Array(pending.keys) }
        ids.forEach(end)
    }

    private func wait(_ nanoseconds: UInt64) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let backstop = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: nanoseconds)
                    self?.end(id)
                }
                lock.lock()
                pending[id] = Request(nanoseconds: nanoseconds, continuation: continuation, backstop: backstop)
                recorded.append(nanoseconds)
                requestCount += 1
                let ready = countWaiters.filter { $0.count <= requestCount }
                countWaiters.removeAll { $0.count <= requestCount }
                lock.unlock()
                ready.forEach { $0.continuation.resume() }
                // Cancelled before the request was registered.
                if Task.isCancelled { end(id) }
            }
        } onCancel: {
            end(id)
        }
    }

    private func end(_ id: UUID) {
        guard let request = lock.withLock({ pending.removeValue(forKey: id) }) else { return }
        request.backstop.cancel()
        request.continuation.resume()
    }
}
