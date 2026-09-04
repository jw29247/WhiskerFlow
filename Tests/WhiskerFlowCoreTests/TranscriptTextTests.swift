import XCTest
@testable import WhiskerFlowCore

final class TranscriptTextTests: XCTestCase {
    func testPlainTranscriptTextCollapsesLineBreaksAndSpacing() {
        let text = "Hello,\n\nworld.  This\tis\nWhiskerFlow."

        XCTAssertEqual(text.plainTranscriptText, "Hello, world. This is WhiskerFlow.")
    }

    func testNormalizedForDeliveryPreservesLineBreaksAndCollapsesSpaceRuns() {
        let text = "  Hello,   world.\n\nThis\tis \n WhiskerFlow.  "

        XCTAssertEqual(text.normalizedForDelivery, "Hello, world.\n\nThis is\nWhiskerFlow.")
    }

    func testDeliveryAndWordCountMatchExistingUnicodeSemantics() {
        let pieces = ["hello", "世界", "👩🏽‍💻", "e\u{301}", " ", "  ", "\t", "\n", "\r\n", "\u{00a0}", "\u{2028}", "\u{2003}", "\u{000b}", "\u{000c}"]
        for first in pieces {
            for second in pieces {
                for third in pieces {
                    let input = first + second + third
                    let expected = input.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
                        .replacingOccurrences(of: "[ \t]*\n[ \t]*", with: "\n", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    XCTAssertEqual(input.normalizedForDelivery, expected, input.debugDescription)
                    XCTAssertEqual(input.transcriptWordCount, input.plainTranscriptText.split(separator: " ").count, input.debugDescription)
                }
            }
        }
    }
}
