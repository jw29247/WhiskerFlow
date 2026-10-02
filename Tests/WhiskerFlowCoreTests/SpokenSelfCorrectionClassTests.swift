import XCTest
@testable import WhiskerFlowCore

final class SpokenSelfCorrectionClassTests: XCTestCase {
    func testRepairsBetweenWordsOfTheSameKind() {
        XCTAssertEqual(SpokenSelfCorrection.resolve("Send it to him, sorry, her."), "Send it to her.")
        XCTAssertEqual(SpokenSelfCorrection.resolve("Give it to me, sorry, you."), "Give it to you.")
        XCTAssertEqual(SpokenSelfCorrection.resolve("Put it here, I mean there."), "Put it there.")
        XCTAssertEqual(SpokenSelfCorrection.resolve("Turn right, sorry, left."), "Turn left.")
        XCTAssertEqual(SpokenSelfCorrection.resolve("That sounds right, I mean fine."), "That sounds fine.")
    }

    func testKeepsPhrasesWhereTheReplacementIsNotASubstitute() {
        for input in [
            "Thank you, I mean it.",
            "Thank you, I mean that.",
            "Right, sorry, Tom.",
            "Well, sorry, Sam."
        ] {
            XCTAssertEqual(SpokenSelfCorrection.resolve(input), input)
        }
    }
}
