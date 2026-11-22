import XCTest
@testable import WhiskerFlowCore

final class CountPhraseTests: XCTestCase {
    func testOneTakesTheSingular() {
        XCTAssertEqual(CountPhrase.of(1, "recording"), "1 recording")
        XCTAssertEqual(CountPhrase.of(1, "word"), "1 word")
    }

    func testZeroAndManyTakeThePlural() {
        XCTAssertEqual(CountPhrase.of(0, "saved correction"), "0 saved corrections")
        XCTAssertEqual(CountPhrase.of(2, "dictation"), "2 dictations")
        XCTAssertEqual(CountPhrase.of(42, "second"), "42 seconds")
    }

    func testIrregularPlural() {
        XCTAssertEqual(CountPhrase.of(1, "day", plural: "days"), "1 day")
        XCTAssertEqual(CountPhrase.of(3, "person", plural: "people"), "3 people")
    }

    func testNounAlone() {
        XCTAssertEqual(CountPhrase.noun(1, "recording"), "recording")
        XCTAssertEqual(CountPhrase.noun(0, "recording"), "recordings")
    }
}
