import XCTest
@testable import WhiskerFlowAppSupport

final class AudioFormatValidationTests: XCTestCase {
    func testRejectsZeroSampleRateAndZeroChannels() {
        XCTAssertThrowsError(try AudioFormatValidator.validate(sampleRate: 0, channelCount: 1))
        XCTAssertThrowsError(try AudioFormatValidator.validate(sampleRate: 48_000, channelCount: 0))
    }

    func testAcceptsFinitePositiveFormat() {
        XCTAssertNoThrow(try AudioFormatValidator.validate(sampleRate: 96_000, channelCount: 3))
    }

    func testRejectsNonFiniteSampleRate() {
        XCTAssertThrowsError(try AudioFormatValidator.validate(sampleRate: .infinity, channelCount: 1))
        XCTAssertThrowsError(try AudioFormatValidator.validate(sampleRate: .nan, channelCount: 1))
    }
}
