import Foundation

/// How often the main-thread watchdog ticks. Each tick can enqueue a probe on
/// the main queue, so each tick wakes two threads.
///
/// While a dictation is in flight or audio is being captured it ticks every
/// 250 ms, so any stall of 2.25 s or more is reported. Otherwise it ticks once
/// a second: a stall of 3 s or more is still always reported, and one of 2–3 s
/// is reported when it starts within a second of a probe.
enum MainThreadHealthCadence {
    static let activeTick: TimeInterval = 0.25
    static let idleTick: TimeInterval = 1

    static func tick(active: Bool) -> TimeInterval { active ? activeTick : idleTick }

    /// The timer's allowed lateness, so the system can coalesce its wake-ups.
    static func leeway(forTick tick: TimeInterval) -> TimeInterval { tick / 5 }
}

/// When the watchdog logs its periodic rows. Measured in time rather than
/// ticks so a change of tick interval doesn't change them.
///
/// Resource snapshots are written every 15 s while a dictation is in flight
/// or audio is captured, and every 60 s otherwise; a stall row carries its
/// own snapshot either way.
struct MainThreadHealthLogSchedule {
    static func resourceInterval(active: Bool) -> TimeInterval { active ? 15 : 60 }
    static let heartbeatInterval: TimeInterval = 60

    private var lastResources: TimeInterval
    private var lastHeartbeat: TimeInterval

    /// `start` is when monitoring began and resources were first logged.
    init(start: TimeInterval) {
        lastResources = start
        lastHeartbeat = start
    }

    mutating func due(at now: TimeInterval, active: Bool) -> (resources: Bool, heartbeat: Bool) {
        let resources = now - lastResources >= Self.resourceInterval(active: active)
        let heartbeat = now - lastHeartbeat >= Self.heartbeatInterval
        if resources { lastResources = now }
        if heartbeat { lastHeartbeat = now }
        return (resources, heartbeat)
    }
}
