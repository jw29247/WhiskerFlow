import XCTest
import WhiskerFlowAppSupport

final class CallDetectionTests: XCTestCase {
    private let own = "agency.thatworks.WhiskerFlow"

    private func detect(_ inputs: [String?], _ windows: [AppWindowTitles] = []) -> [DetectedCall] {
        CallDetectionRules.detect(
            inputs: inputs.enumerated().map { AudioInputProcess(pid: Int32(100 + $0.offset), bundleID: $0.element) },
            windows: windows, ownBundleID: own
        )
    }

    func testNativeCallAppsUsingTheMicrophoneAreCalls() {
        XCTAssertEqual(detect(["us.zoom.xos"]).map(\.platform), [.zoom])
        XCTAssertEqual(detect(["com.microsoft.teams2"]).map(\.platform), [.teams])
        XCTAssertEqual(detect(["com.tinyspeck.slackmacgap.helper"]).map(\.platform), [.slackHuddle], "Electron helpers map to their app")
        XCTAssertEqual(detect(["Cisco-Systems.Spark"]).map(\.platform), [.webex])
        XCTAssertTrue(detect(["us.zoom.xos"]).allSatisfy { !$0.isBrowser })
    }

    func testAppsNotUsingTheMicrophoneOrUnknownAppsAreNotCalls() {
        XCTAssertTrue(detect([], [AppWindowTitles(bundleID: "us.zoom.xos", titles: ["Zoom Meeting"])]).isEmpty)
        XCTAssertTrue(detect(["com.apple.VoiceMemos", nil, ""]).isEmpty)
        XCTAssertTrue(detect([own, own + ".helper"]).isEmpty, "WhiskerFlow's own capture is never a call")
    }

    func testBrowserCallsNeedAMatchingWindowOrTabTitle() {
        let chrome = AppWindowTitles(bundleID: "com.google.Chrome", titles: [
            "Inbox (3) - Gmail", "Meet – abc-defg-hij – Camera and microphone recording - Google Chrome – Jacob",
        ])
        let call = detect(["com.google.Chrome.helper"], [chrome])
        XCTAssertEqual(call.map(\.platform), [.googleMeet])
        XCTAssertEqual(call.first?.meetingCode, "abc-defg-hij")
        XCTAssertEqual(call.first?.appBundleID, "com.google.Chrome")
        XCTAssertTrue(call.first?.isBrowser == true)
        XCTAssertTrue(detect(["com.google.Chrome.helper"], [AppWindowTitles(bundleID: "com.google.Chrome", titles: ["Voice notes – Docs"])]).isEmpty,
                      "A browser using the mic for something else is not a call")
    }

    func testEachBrowserAndWebPlatform() {
        let cases: [(String, String, String, CallPlatform)] = [
            ("com.microsoft.edgemac.helper", "com.microsoft.edgemac", "Meeting with Priya | Microsoft Teams", .teams),
            ("company.thebrowser.Browser.helper", "company.thebrowser.Browser", "Zoom Meeting", .zoom),
            ("com.brave.Browser.helper", "com.brave.Browser", "Webex Meetings", .webex),
            ("org.mozilla.firefox", "org.mozilla.firefox", "Huddle in #design - Slack", .slackHuddle),
            ("com.google.Chrome.helper", "com.google.Chrome", "Google Meet", .googleMeet),
        ]
        for (process, browser, title, platform) in cases {
            let calls = detect([process], [AppWindowTitles(bundleID: browser, titles: [title])])
            XCTAssertEqual(calls.map(\.platform), [platform], title)
            XCTAssertEqual(calls.first?.appBundleID, browser, title)
        }
    }

    func testSafariCaptureInSharedWebKitProcessIsAttributedToSafari() {
        let safari = AppWindowTitles(bundleID: "com.apple.Safari", titles: ["Meet - xyz-abcd-efg"])
        let chrome = AppWindowTitles(bundleID: "com.google.Chrome", titles: ["Meet – aaa-bbbb-ccc"])
        let calls = detect(["com.apple.WebKit.GPU"], [chrome, safari])
        XCTAssertEqual(calls.map(\.appBundleID), ["com.apple.Safari"], "WebKit capture belongs to a WebKit browser, never Chrome")
        XCTAssertEqual(calls.first?.meetingCode, "xyz-abcd-efg")
    }

    func testCapturingTabIsPreferredOverBackgroundCallTabs() {
        let chrome = AppWindowTitles(bundleID: "com.google.Chrome", titles: [
            "Weekly | Microsoft Teams", "Meet – abc-defg-hij – Microphone recording",
        ])
        XCTAssertEqual(detect(["com.google.Chrome.helper"], [chrome]).map(\.platform), [.googleMeet])
    }

    func testMeetCodeParsing() {
        XCTAssertEqual(CallDetectionRules.meetCode(in: "Meet – ABC-defg-hij"), "abc-defg-hij")
        XCTAssertNil(CallDetectionRules.meetCode(in: "abcd-defg-hij"))
        XCTAssertNil(CallDetectionRules.webCall(inTitle: "state-of-the-art review"), "A code-shaped phrase needs the word Meet")
        XCTAssertNil(CallDetectionRules.owningApp(ofProcessBundleID: "com.google.Chromecast"), "Prefix matching needs a dot boundary")
    }

    // MARK: Tracker

    func testCallStartsAfterConsecutivePollsAndEndsAfterGrace() {
        var tracker = CallSessionTracker(startConfirmations: 2, endGraceSeconds: 15)
        let zoom = DetectedCall(platform: .zoom, appBundleID: "us.zoom.xos", isBrowser: false)
        XCTAssertEqual(tracker.observe([zoom], appsUsingMicrophone: ["us.zoom.xos"], at: 0), [])
        XCTAssertEqual(tracker.observe([zoom], appsUsingMicrophone: ["us.zoom.xos"], at: 3), [.started(zoom)])
        XCTAssertEqual(tracker.observe([zoom], appsUsingMicrophone: ["us.zoom.xos"], at: 6), [], "Started once")
        XCTAssertEqual(tracker.observe([], appsUsingMicrophone: [], at: 9), [], "A brief drop within the grace keeps the call")
        XCTAssertEqual(tracker.observe([zoom], appsUsingMicrophone: ["us.zoom.xos"], at: 12), [])
        XCTAssertEqual(tracker.observe([], appsUsingMicrophone: [], at: 15), [])
        XCTAssertEqual(tracker.observe([], appsUsingMicrophone: [], at: 27), [.ended(zoom)])
        XCTAssertTrue(tracker.activeCalls.isEmpty)
    }

    func testOneBlipNeverPrompts() {
        var tracker = CallSessionTracker()
        let slack = DetectedCall(platform: .slackHuddle, appBundleID: "com.tinyspeck.slackmacgap", isBrowser: false)
        XCTAssertEqual(tracker.observe([slack], appsUsingMicrophone: [], at: 0), [])
        XCTAssertEqual(tracker.observe([], appsUsingMicrophone: [], at: 3), [])
        XCTAssertEqual(tracker.observe([slack], appsUsingMicrophone: [], at: 6), [], "Confirmations must be consecutive")
    }

    func testStartedBrowserCallSurvivesAnUnreadableTitleWhileTheMicStaysOpen() {
        var tracker = CallSessionTracker(startConfirmations: 1, endGraceSeconds: 10)
        let meet = DetectedCall(platform: .googleMeet, appBundleID: "com.google.Chrome", isBrowser: true, meetingCode: "abc-defg-hij")
        XCTAssertEqual(tracker.observe([meet], appsUsingMicrophone: ["com.google.Chrome"], at: 0), [.started(meet)])
        XCTAssertEqual(tracker.observe([], appsUsingMicrophone: ["com.google.Chrome"], at: 30), [])
        let codeless = DetectedCall(platform: .googleMeet, appBundleID: "com.google.Chrome", isBrowser: true)
        _ = tracker.observe([codeless], appsUsingMicrophone: ["com.google.Chrome"], at: 33)
        XCTAssertEqual(tracker.activeCalls.first?.meetingCode, "abc-defg-hij", "A later title without the code keeps the known code")
        XCTAssertEqual(tracker.observe([], appsUsingMicrophone: [], at: 50), [.ended(meet)])
    }

    // MARK: Calendar

    private func intent(_ id: String, url: String?, start: Int64, end: Int64, location: String? = nil) -> AtlasCaptureScheduleIntent {
        AtlasCaptureScheduleIntent(eventID: id, title: id, startMs: start, endMs: end, meetingURL: url, location: location,
                                   existingMeetingID: nil, overlapsPrevious: false)
    }

    func testMeetCodeMatchesTheExactEventAtAnyTime() {
        let meet = DetectedCall(platform: .googleMeet, appBundleID: "com.google.Chrome", isBrowser: true, meetingCode: "abc-defg-hij")
        let events = [intent("other", url: "https://meet.google.com/zzz-zzzz-zzz", start: 0, end: 1_000),
                      intent("sync", url: "https://meet.google.com/abc-defg-hij", start: 5_000_000, end: 6_000_000)]
        XCTAssertEqual(CallCalendarMatcher.match(meet, intents: events, nowMs: 500)?.eventID, "sync")
        let unknown = DetectedCall(platform: .googleMeet, appBundleID: "com.google.Chrome", isBrowser: true, meetingCode: "qqq-qqqq-qqq")
        XCTAssertNil(CallCalendarMatcher.match(unknown, intents: events, nowMs: 500), "A different Meet code is a different call")
    }

    func testOtherPlatformsMatchACurrentEventByJoinHost() {
        let zoom = DetectedCall(platform: .zoom, appBundleID: "us.zoom.xos", isBrowser: false)
        let now: Int64 = 10_000_000
        let events = [
            intent("teams", url: "https://teams.microsoft.com/l/meetup-join/x", start: now - 60_000, end: now + 1_800_000),
            intent("zoom-later", url: "https://us02web.zoom.us/j/123", start: now + 3_600_000, end: now + 5_400_000),
            intent("zoom-now", url: nil, start: now - 120_000, end: now + 1_800_000,
                   location: "Join: https://us02web.zoom.us/j/987?pwd=abc, Room 4"),
        ]
        XCTAssertEqual(CallCalendarMatcher.match(zoom, intents: events, nowMs: now)?.eventID, "zoom-now")
        let teams = DetectedCall(platform: .teams, appBundleID: "com.microsoft.teams2", isBrowser: false)
        XCTAssertEqual(CallCalendarMatcher.match(teams, intents: events, nowMs: now)?.eventID, "teams")
        let webex = DetectedCall(platform: .webex, appBundleID: "Cisco-Systems.Spark", isBrowser: false)
        XCTAssertNil(CallCalendarMatcher.match(webex, intents: events, nowMs: now))
        XCTAssertNil(CallCalendarMatcher.match(zoom, intents: [events[1]], nowMs: now), "A later event is not this call")
    }
}
