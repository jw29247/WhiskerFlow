import XCTest
@testable import WhiskerFlowAppSupport
final class MeetingCaptionEvidenceTests: XCTestCase {
    func testSmallRecognitionDifferenceNeedsNinetyPercentSupportedWords() {
        let text = "We should review the complete recording tomorrow and then share the final report together"
        let rows = [MeetingCaptionEvidence(speaker: "Example Person", text: "We should review the complete recording tomorrow and then share the final report today")]
        XCTAssertEqual(MeetingCaptionMatcher.identity(for: text, evidence: rows)?.displayName, "Example Person")
        XCTAssertNil(MeetingCaptionMatcher.identity(for: "We should review the complete recording tomorrow and cancel everything else immediately", evidence: rows))
    }
    func testNamesRequireUniqueSubstantialCaptionMatch() {
        let phrase = "We should review the complete recording tomorrow"
        let rows = [MeetingCaptionEvidence(speaker: "Example Person", text: phrase)]
        XCTAssertEqual(MeetingCaptionMatcher.identity(for: phrase, evidence: rows)?.displayName, "Example Person")
        XCTAssertEqual(MeetingCaptionMatcher.identity(for: phrase, evidence: rows)?.resolution, .googleMeet)
        XCTAssertNil(MeetingCaptionMatcher.identity(for: "Yes", evidence: rows))
        XCTAssertNil(MeetingCaptionMatcher.identity(for: phrase, evidence: rows + [.init(speaker: "Another Person", text: phrase)]))
        XCTAssertNil(MeetingCaptionMatcher.identity(for: "Different words that do not match captions", evidence: rows))
    }
}
