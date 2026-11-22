import XCTest
@testable import WhiskerFlow

/// The named text styles in `FlowStyle`.
final class FlowStyleTypeScaleTests: XCTestCase {
    func testNoStyleIsBelowElevenPoints() {
        for style in FlowStyle.TypeScale.all {
            XCTAssertGreaterThanOrEqual(style.size, 11, "a \(style.size) pt style is too small to read")
        }
    }

    func testStylesRunFromLargestToSmallestWithoutRepeats() {
        let sizes = FlowStyle.TypeScale.all.map(\.size)
        XCTAssertEqual(sizes, sizes.sorted(by: >))
        XCTAssertEqual(Set(sizes).count, sizes.count)
    }
}
