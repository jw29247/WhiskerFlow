import XCTest
@testable import WhiskerFlow

/// The setup's Done step lists the screen shortcuts as a range; it said
/// "⌘1 – ⌘5" after the sidebar had grown to seven screens.
@MainActor
final class ScreenShortcutTests: XCTestCase {
    func testRangeLabelCoversEveryScreen() {
        XCTAssertEqual(FlowDestination.shortcutRangeLabel, "⌘1 – ⌘\(FlowDestination.allCases.count)")
    }

    func testScreenShortcutsAreContiguousFromOne() {
        let labels = FlowDestination.allCases.map(\.shortcutLabel).sorted()
        XCTAssertEqual(labels, (1...FlowDestination.allCases.count).map(String.init))
        for item in FlowDestination.allCases {
            XCTAssertEqual(String(item.shortcut.character), item.shortcutLabel)
        }
    }
}
