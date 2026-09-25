import XCTest
import WhiskerFlowAppSupport
@testable import WhiskerFlow

final class MeetingScheduleCacheTests: XCTestCase {
    @MainActor
    func testRepeatedScheduleDoesNotRewriteDefaultsButChangesPersist() {
        let name = "ScheduleCache.\(UUID())"
        let defaults = CountingScheduleDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults, meetingTokenStore: MeetingCaptureTokenStore(service: name))
        let intent = AtlasCaptureScheduleIntent(eventID: "test", title: "Test", startMs: 1, endMs: 2,
            meetingURL: nil, location: nil, existingMeetingID: nil, overlapsPrevious: false)
        defaults.dataWrites = 0
        settings.cacheMeetingSchedule([intent])
        XCTAssertEqual(defaults.dataWrites, 1)
        settings.cacheMeetingSchedule([intent])
        XCTAssertEqual(defaults.dataWrites, 1, "Unchanged polls must not trigger preference writes or KVO")
        settings.cacheMeetingSchedule([])
        XCTAssertEqual(defaults.dataWrites, 2)
        XCTAssertEqual(settings.cachedMeetingSchedule(), [])
    }
}

private final class CountingScheduleDefaults: UserDefaults, @unchecked Sendable {
    var dataWrites = 0
    override func set(_ value: Any?, forKey defaultName: String) {
        if value is Data { dataWrites += 1 }
        super.set(value, forKey: defaultName)
    }
}
