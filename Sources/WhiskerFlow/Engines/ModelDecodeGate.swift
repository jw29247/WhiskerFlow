import Foundation
import WhiskerFlowAppSupport

/// Admits one model decode at a time and time-boxes it; see
/// `ParakeetTDTv3Engine.decodeGate`.
enum ModelDecodeGateError: Error, Equatable {
    case occupied
}

actor ModelDecodeGate {
    private var activeOperationID: UUID?
    /// FIFO queue of callers waiting for the gate; `finish` hands it straight
    /// to the next one so a fail-fast caller cannot jump the queue.
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    /// Set while the holder is an operation its caller already abandoned (a
    /// possibly wedged prediction). Waiters, bounded or not, fail fast instead
    /// of sitting out their wait behind something that may never return.
    private var abandonedOperationID: UUID?

    var isOccupied: Bool { activeOperationID != nil }
    /// A timed-out operation still holds the gate.
    var isHeldByAbandonedOperation: Bool { abandonedOperationID != nil }

    /// Fails with `occupied` instead of waiting when anything holds the gate.
    func runExclusive(
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await runQueued(waitingUpTo: 0, operation: operation)
    }

    /// Like `runExclusive`, but waits up to `seconds` (nil: indefinitely) for
    /// the gate before failing with `occupied`. Behind an abandoned holder every
    /// caller fails with `occupied`.
    func runQueued(
        waitingUpTo seconds: TimeInterval?,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        let operationID = try await acquire(waitingUpTo: seconds)
        do {
            try await operation()
            finish(operationID)
        } catch {
            finish(operationID)
            throw error
        }
    }

    func run<T: Sendable>(
        seconds: TimeInterval,
        waitingUpTo queueSeconds: TimeInterval = 0,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let operationID = try await acquire(waitingUpTo: queueSeconds)
        let work = Task { try await operation() }
        do {
            let value = try await withAbandoningDeadline(seconds: seconds) {
                try await work.value
            }
            finish(operationID)
            return value
        } catch AsyncTimeoutError.timedOut {
            work.cancel()
            retainOccupancy(untilSettled: work, operationID: operationID, abandoned: true)
            throw AsyncTimeoutError.timedOut
        } catch {
            // Treat every non-success as potentially abandoning a
            // non-cooperative provider operation. If it has already settled,
            // this clears immediately; otherwise retries remain excluded.
            work.cancel()
            retainOccupancy(untilSettled: work, operationID: operationID, abandoned: false)
            throw error
        }
    }

    private func acquire(waitingUpTo seconds: TimeInterval?) async throws -> UUID {
        let operationID = UUID()
        if activeOperationID == nil, waiters.isEmpty {
            activeOperationID = operationID
            return operationID
        }
        // Nothing queues behind an abandoned (possibly wedged) holder, not even an
        // unbounded load: it may never return, and every later caller would join it.
        if abandonedOperationID != nil { throw ModelDecodeGateError.occupied }
        if let seconds, seconds <= 0 { throw ModelDecodeGateError.occupied }
        let expiry = seconds.map { seconds in
            Task { [weak self] in
                try await Task.sleep(nanoseconds: UInt64(min(seconds, 86_400) * 1_000_000_000))
                await self?.dropWaiter(operationID, error: ModelDecodeGateError.occupied)
            }
        }
        defer { expiry?.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append((operationID, continuation))
                }
            }
        } onCancel: {
            Task { await self.dropWaiter(operationID, error: CancellationError()) }
        }
        return operationID
    }

    private func dropWaiter(_ operationID: UUID, error: Error) {
        guard let index = waiters.firstIndex(where: { $0.id == operationID }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: error)
    }

    private func retainOccupancy<T: Sendable>(
        untilSettled work: Task<T, Error>,
        operationID: UUID,
        abandoned: Bool
    ) {
        if abandoned, activeOperationID == operationID {
            abandonedOperationID = operationID
            // Callers already queued behind it fail now too, as later ones will.
            let queued = waiters
            waiters.removeAll()
            queued.forEach { $0.continuation.resume(throwing: ModelDecodeGateError.occupied) }
        }
        Task { [weak self] in
            _ = try? await work.value
            await self?.finish(operationID)
        }
    }

    private func finish(_ operationID: UUID) {
        guard activeOperationID == operationID else { return }
        abandonedOperationID = nil
        if waiters.isEmpty {
            activeOperationID = nil
        } else {
            let next = waiters.removeFirst()
            activeOperationID = next.id
            next.continuation.resume()
        }
    }
}
