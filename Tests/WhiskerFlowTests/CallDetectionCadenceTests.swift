import Foundation
import XCTest
@testable import WhiskerFlow
import WhiskerFlowAppSupport

/// Virtual time for a polling loop: every sleep waits until the test fires
/// it, so no assertion depends on how fast the machine is.
final class VirtualSleeper: @unchecked Sendable {
    private struct Pending {
        let id: UUID
        let seconds: TimeInterval
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var pending: [Pending] = []
    private var cancelled: Set<UUID> = []
    private var requests: [TimeInterval] = []
    private var fired: TimeInterval = 0

    /// Virtual time: the sum of the sleeps fired so far.
    var now: TimeInterval { lock.withLock { fired } }

    /// Every wait asked for, in order, including ones later cut short.
    var requested: [TimeInterval] { lock.withLock { requests } }
    var pendingSeconds: [TimeInterval] { lock.withLock { pending.map(\.seconds) } }

    func sleep(_ seconds: TimeInterval) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock { () -> Bool in
                    requests.append(seconds)
                    if cancelled.remove(id) != nil { return true }
                    pending.append(Pending(id: id, seconds: seconds, continuation: continuation))
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                guard let index = pending.firstIndex(where: { $0.id == id }) else {
                    cancelled.insert(id)
                    return nil
                }
                return pending.remove(at: index).continuation
            }
            continuation?.resume()
        }
    }

    /// Lets the oldest pending sleep finish, as if its time had passed.
    /// Returns how long it was.
    @discardableResult
    func fireNext() -> TimeInterval? {
        let next = lock.withLock { () -> Pending? in
            guard !pending.isEmpty else { return nil }
            let next = pending.removeFirst()
            fired += next.seconds
            return next
        }
        next?.continuation.resume()
        return next?.seconds
    }

    /// Waits (in real time, only for progress) until `count` sleeps were asked for.
    func waitForRequests(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<5_000 {
            if lock.withLock({ requests.count >= count && !pending.isEmpty }) { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Expected \(count) sleep requests, got \(requested)", file: file, line: line)
    }
}

@MainActor
private final class FakeMicrophoneActivity: MicrophoneActivitySource {
    let observable: Bool
    private(set) var starts = 0
    private(set) var stops = 0
    private var onChange: (@MainActor () -> Void)?

    init(observable: Bool = true) { self.observable = observable }

    func start(onChange: @escaping @MainActor () -> Void) -> Bool {
        starts += 1
        self.onChange = onChange
        return observable
    }

    func stop() {
        stops += 1
        onChange = nil
    }

    func microphoneChanged() { onChange?() }
}

private final class Signals: @unchecked Sendable {
    private let lock = NSLock()
    private var value = CallDetectionSignals(inputs: [], windows: [])
    private var count = 0
    var reads: Int { lock.withLock { count } }
    var current: CallDetectionSignals {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }

    func read() -> CallDetectionSignals {
        lock.withLock {
            count += 1
            return value
        }
    }
}

@MainActor
final class CallDetectionCadenceTests: XCTestCase {
    private let teams = CallDetectionSignals(inputs: [AudioInputProcess(pid: 7, bundleID: "com.microsoft.teams2")], windows: [])
    private let ownCapture = CallDetectionSignals(
        inputs: [AudioInputProcess(pid: 9, bundleID: "agency.thatworks.WhiskerFlow")], windows: []
    )

    private func detector(
        activity: FakeMicrophoneActivity?, signals: Signals, sleeper: VirtualSleeper
    ) -> CallDetectionService {
        let detector = CallDetectionService(
            ownBundleID: "agency.thatworks.WhiskerFlow", readSignals: { signals.read() },
            microphoneActivity: activity, sleep: { await sleeper.sleep($0) }, now: { sleeper.now }
        )
        addTeardownBlock { @MainActor in detector.stop() }
        return detector
    }

    func testPolicyIsIdleOnlyWhileNothingElseUsesTheMicrophoneAndChangesAreObserved() {
        XCTAssertEqual(CallDetectionCadence.interval(otherAppsUseMicrophone: false, tracksCalls: false, observesMicrophone: true), 30)
        XCTAssertEqual(CallDetectionCadence.interval(otherAppsUseMicrophone: true, tracksCalls: false, observesMicrophone: true), 3)
        XCTAssertEqual(CallDetectionCadence.interval(otherAppsUseMicrophone: false, tracksCalls: true, observesMicrophone: true), 3)
        XCTAssertEqual(CallDetectionCadence.interval(otherAppsUseMicrophone: false, tracksCalls: false, observesMicrophone: false), 3)
    }

    func testWithoutAListenerItPollsEveryThreeSecondsAsBefore() async {
        let (signals, sleeper) = (Signals(), VirtualSleeper())
        let detector = detector(activity: nil, signals: signals, sleeper: sleeper)
        detector.start()
        await sleeper.waitForRequests(1)
        sleeper.fireNext()
        await sleeper.waitForRequests(2)
        XCTAssertEqual(sleeper.requested, [3, 3])
        XCTAssertEqual(signals.reads, 2)
    }

    func testIdleDetectorWaitsThirtySecondsAndACallStartingIsReportedFourSecondsLater() async {
        let (signals, sleeper, activity) = (Signals(), VirtualSleeper(), FakeMicrophoneActivity())
        let detector = detector(activity: activity, signals: signals, sleeper: sleeper)
        var events: [CallSessionTracker.Event] = []
        detector.onEvent = { events.append($0) }
        detector.start()
        await sleeper.waitForRequests(1)
        XCTAssertEqual(sleeper.pendingSeconds, [30], "Nothing uses the microphone: the safety poll is 30 s away")
        XCTAssertEqual(signals.reads, 1)

        // Teams opens the microphone during the idle wait.
        signals.current = teams
        activity.microphoneChanged()
        await sleeper.waitForRequests(2)
        XCTAssertEqual(sleeper.pendingSeconds, [1], "The change cuts the 30 s wait to a 1 s settle")
        activity.microphoneChanged()
        XCTAssertEqual(sleeper.pendingSeconds, [1], "A burst of changes is one poll")

        var elapsed = sleeper.fireNext() ?? 0
        await sleeper.waitForRequests(3)
        XCTAssertEqual(signals.reads, 2)
        XCTAssertTrue(events.isEmpty, "A call needs two polls to be confirmed")
        XCTAssertEqual(sleeper.pendingSeconds, [3], "Another app uses the microphone: active cadence")
        elapsed += sleeper.fireNext() ?? 0
        await sleeper.waitForRequests(4)
        XCTAssertEqual(events.map(\.isStart), [true])
        XCTAssertEqual(elapsed, 4, "Reported 4 s after the microphone opened; the fixed 3 s poll took 3–6 s")
    }

    func testTrackedCallKeepsTheActiveCadenceUntilItsEndIsReported() async {
        let (signals, sleeper, activity) = (Signals(), VirtualSleeper(), FakeMicrophoneActivity())
        let detector = detector(activity: activity, signals: signals, sleeper: sleeper)
        var events: [CallSessionTracker.Event] = []
        detector.onEvent = { events.append($0) }
        signals.current = teams
        detector.start()
        await sleeper.waitForRequests(1)
        sleeper.fireNext()
        await sleeper.waitForRequests(2)
        XCTAssertEqual(events.map(\.isStart), [true])

        signals.current = CallDetectionSignals(inputs: [], windows: [])
        activity.microphoneChanged()
        // The end is reported after 15 s without the call, so polling stays
        // at 3 s through the grace period rather than waiting 30 s.
        let lastSeen = sleeper.now
        var requests = 3
        while requests < 20 {
            await sleeper.waitForRequests(requests)
            if events.count == 2 { break }
            XCTAssertNotEqual(sleeper.pendingSeconds, [30], "Idle cadence before the end was reported")
            sleeper.fireNext()
            requests += 1
        }
        XCTAssertEqual(events.map(\.isStart), [true, false])
        XCTAssertLessThanOrEqual(sleeper.now - lastSeen, 15 + 3, "The end is reported within one poll of the 15 s grace")
        XCTAssertEqual(sleeper.pendingSeconds, [30], "Once the call has ended, the detector idles again")
    }

    func testOwnDictationDoesNotKeepTheActiveCadence() async {
        let (signals, sleeper, activity) = (Signals(), VirtualSleeper(), FakeMicrophoneActivity())
        let detector = detector(activity: activity, signals: signals, sleeper: sleeper)
        detector.start()
        await sleeper.waitForRequests(1)
        signals.current = ownCapture
        activity.microphoneChanged()
        await sleeper.waitForRequests(2)
        sleeper.fireNext()
        await sleeper.waitForRequests(3)
        XCTAssertEqual(sleeper.pendingSeconds, [30])
        XCTAssertTrue(detector.observesMicrophone)
    }

    func testAMicrophoneStartTheListenerMissedRevertsToTheActiveCadence() async {
        let (signals, sleeper, activity) = (Signals(), VirtualSleeper(), FakeMicrophoneActivity())
        let detector = detector(activity: activity, signals: signals, sleeper: sleeper)
        var events: [CallSessionTracker.Event] = []
        detector.onEvent = { events.append($0) }
        detector.start()
        await sleeper.waitForRequests(1)
        // Teams opens the microphone and no change is reported.
        signals.current = teams
        XCTAssertEqual(sleeper.fireNext(), 30)
        await sleeper.waitForRequests(2)
        XCTAssertFalse(detector.observesMicrophone)
        XCTAssertEqual(activity.stops, 1)
        XCTAssertEqual(sleeper.pendingSeconds, [3])
        sleeper.fireNext()
        await sleeper.waitForRequests(3)
        XCTAssertEqual(events.map(\.isStart), [true], "At worst 33 s late, once")

        signals.current = CallDetectionSignals(inputs: [], windows: [])
        for request in 4..<12 {
            sleeper.fireNext()
            await sleeper.waitForRequests(request)
            XCTAssertEqual(sleeper.pendingSeconds, [3], "Without a trusted listener it never idles")
        }
    }

    func testAChangeDuringAPollShortensTheNextWait() async {
        let sleeper = VirtualSleeper()
        let pause = CallDetectionPause(settleSeconds: 1, sleep: { await sleeper.sleep($0) })
        pause.wake()
        let woken = Task { await pause.wait(seconds: 30) }
        await sleeper.waitForRequests(1)
        XCTAssertEqual(sleeper.pendingSeconds, [1])
        sleeper.fireNext()
        let wasWoken = await woken.value
        XCTAssertTrue(wasWoken)

        let timed = Task { await pause.wait(seconds: 30) }
        await sleeper.waitForRequests(2)
        sleeper.fireNext()
        let timedOut = await timed.value
        XCTAssertFalse(timedOut)
    }

    func testStopEndsTheWaitAndTheListener() async {
        let (signals, sleeper, activity) = (Signals(), VirtualSleeper(), FakeMicrophoneActivity())
        let detector = detector(activity: activity, signals: signals, sleeper: sleeper)
        detector.start()
        await sleeper.waitForRequests(1)
        detector.stop()
        XCTAssertFalse(detector.isRunning)
        XCTAssertEqual(activity.stops, 1)
        activity.microphoneChanged()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(signals.reads, 1, "A stopped detector does not poll again")
    }
}

private extension CallSessionTracker.Event {
    var isStart: Bool {
        if case .started = self { return true }
        return false
    }
}
