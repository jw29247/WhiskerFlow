import Observation

/// Returns once `condition` holds, re-checking only when an observed property
/// it reads changes. Use it for state an `@Observable` object updates in a
/// task the test cannot reach; there is no polling and no timeout.
@MainActor
func until(_ condition: @escaping @MainActor () -> Bool) async {
    while !condition() {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = condition()
            } onChange: {
                continuation.resume()
            }
        }
    }
}
