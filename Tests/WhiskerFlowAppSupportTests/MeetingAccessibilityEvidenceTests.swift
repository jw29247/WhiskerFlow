import XCTest
@testable import WhiskerFlowAppSupport

final class MeetingAccessibilityEvidenceTests: XCTestCase {
    func testCalendarBoundaryStopsOnlyWhenTheExpectedCallIsGone() {
        XCTAssertTrue(MeetingCaptureStopPolicy.shouldStopAtCalendarBoundary(.noMeeting))
        XCTAssertTrue(MeetingCaptureStopPolicy.shouldStopAtCalendarBoundary(.notJoined))
        XCTAssertFalse(MeetingCaptureStopPolicy.shouldStopAtCalendarBoundary(.available))
        XCTAssertFalse(MeetingCaptureStopPolicy.shouldStopAtCalendarBoundary(.multipleMeetings))
        XCTAssertFalse(MeetingCaptureStopPolicy.shouldStopAtCalendarBoundary(.unavailable))
    }

    private func meet(_ children: [MeetingAccessibilityNode], url: String = "https://meet.google.com/abc-defg-hij") -> MeetingAccessibilityNode {
        .init(id: "meet", role: "AXWebArea", url: url, children: children + [.init(id: "leave", role: "AXButton", label: "Leave call")])
    }
    func testVisualNamesRemainCandidatesUntilPixelEvidence() {
        let tile = MeetingAccessibilityNode(id: "tile", role: "AXGroup", frame: CGRect(x: 20,y: 100,width: 300,height: 200), children: [
            .init(id: "name",role: "AXStaticText",label: "Participant A",frame: CGRect(x: 30,y: 275,width: 80,height: 15))
        ])
        let roster = MeetingAccessibilityNode(id: "roster",role: "AXGroup",frame: CGRect(x: 20,y: 100,width: 300,height: 200),children:[
            .init(id:"rosterName",role:"AXStaticText",label:"Participant B",frame:CGRect(x:30,y:110,width:80,height:15))
        ])
        let root = MeetingAccessibilityNode(id:"123:window",role:"AXWindow",frame:CGRect(x:0,y:0,width:800,height:600),children:[meet([tile,roster])])
        let snapshot = MeetingAccessibilityEvidence.snapshot(roots:[root])
        XCTAssertEqual(snapshot?.visualTiles.map(\.id), ["tile", "roster"])
        XCTAssertEqual(snapshot?.processID,123)
        XCTAssertEqual(snapshot?.speakers,[:], "A visible name without activity must never become speaker evidence")
    }
    func testAvailabilitySeparatesMissingAmbiguousPrejoinAndEmptyActivity() {
        XCTAssertEqual(MeetingAccessibilityEvidence.assess(roots: []).availability, .noMeeting)
        XCTAssertEqual(MeetingAccessibilityEvidence.assess(roots: [meet([]), meet([])]).availability, .multipleMeetings)
        let prejoin = MeetingAccessibilityNode(id: "prejoin", role: "AXWebArea", url: "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(MeetingAccessibilityEvidence.assess(roots: [prejoin]).availability, .notJoined)
        let joined = MeetingAccessibilityEvidence.assess(roots: [meet([])])
        XCTAssertEqual(joined.availability, .available)
        XCTAssertEqual(joined.snapshot?.speakers, [:])
        XCTAssertEqual(MeetingAccessibilityEvidence.assess(roots: [meet([], url: "https://meet.google.com.evil/abc-defg-hij")]).availability, .noMeeting)
    }
    func testPrejoinScreenNeverCountsAsJoinedCall() {
        let prejoin = MeetingAccessibilityNode(id: "meet", role: "AXWebArea", url: "https://meet.google.com/abc-defg-hij", children: [.init(id: "join", role: "AXButton", label: "Join now")])
        XCTAssertNil(MeetingAccessibilityEvidence.snapshot(roots: [prejoin]))
    }
    func testExplicitActivityProducesNameWithoutCaptions() {
        let snapshot = MeetingAccessibilityEvidence.snapshot(roots: [meet([.init(id: "p1", role: "AXImage", label: "Alice is speaking")])])
        XCTAssertEqual(snapshot?.speakers, ["p1": "Alice"])
    }

    func testChromiumStaticTextSpeakingAnnouncementProducesName() {
        let snapshot = MeetingAccessibilityEvidence.snapshot(roots: [
            meet([.init(id: "p1", role: "AXStaticText", label: "Alice is speaking")])
        ])
        XCTAssertEqual(snapshot?.speakers, ["p1": "Alice"])
    }

    func testCaptionRegionVariantsRemainExcluded() {
        let snapshot = MeetingAccessibilityEvidence.snapshot(roots: [
            meet([.init(id: "captions", role: "AXGroup", label: "Live captions", children: [
                .init(id: "caption", role: "AXStaticText", label: "Alice is speaking")
            ])])
        ])
        XCTAssertEqual(snapshot?.speakers, [:])
    }
    func testRosterUnmutedAndCaptionTextNeverProduceActivity() {
        let snapshot = MeetingAccessibilityEvidence.snapshot(roots: [meet([
            .init(id: "1", role: "AXStaticText", label: "Alice"),
            .init(id: "2", role: "AXImage", label: "Bob microphone on"),
            .init(id: "3", role: "AXGroup", label: "Captions", children: [.init(id: "4", role: "AXStaticText", label: "Eve is speaking")]),
            .init(id: "5", role: "AXTextArea", label: "Mallory is speaking")
        ])])
        XCTAssertEqual(snapshot?.speakers, [:])
    }
    func testMultipleCallsOrWrongOriginAreUnavailable() {
        XCTAssertNil(MeetingAccessibilityEvidence.snapshot(roots: [meet([]), meet([])]))
        XCTAssertNil(MeetingAccessibilityEvidence.snapshot(roots: [meet([], url: "https://meet.google.com.evil/abc-defg-hij")]))
        XCTAssertNil(MeetingAccessibilityEvidence.snapshot(roots: [meet([], url: "https://meet.google.com/")]))
    }
    func testTimelineNeedsConsecutiveEvidenceAndBreaksAtGapsAndCallChanges() {
        var timeline = MeetingAccessibilityTimeline()
        let alice = MeetingAccessibilitySnapshot(meetingID: "one", speakers: ["a": "Alice"])
        XCTAssertTrue(timeline.observe(alice, atMs: 0).isEmpty)
        XCTAssertEqual(timeline.observe(alice, atMs: 500).first?.startMs, 0)
        XCTAssertTrue(timeline.observe(nil, atMs: 600).isEmpty)
        XCTAssertTrue(timeline.observe(alice, atMs: 1000).isEmpty)
        XCTAssertTrue(timeline.observe(alice, atMs: 3000).isEmpty)
        XCTAssertTrue(timeline.observe(.init(meetingID: "two", speakers: ["a": "Alice"]), atMs: 3500).isEmpty)
    }
    func testOverlapRemainsAmbiguousAndChangedNameIsNotBridged() {
        var timeline = MeetingAccessibilityTimeline()
        let pair = MeetingAccessibilitySnapshot(meetingID: "one", speakers: ["a": "Alice", "b": "Bob"])
        _ = timeline.observe(pair, atMs: 0)
        let rows = timeline.observe(pair, atMs: 500)
        XCTAssertEqual(rows.count, 2)
        XCTAssertNil(MeetingSpeakerEvidenceMatcher.identity(startMs: 0, endMs: 500, evidence: rows))
        XCTAssertTrue(timeline.observe(.init(meetingID: "one", speakers: ["a": "Other"]), atMs: 1000).isEmpty)
    }
}
