import XCTest
@testable import WhiskerFlowCore

final class ShellArgumentsTests: XCTestCase {
    func testSplitsOnWhitespaceAndCollapsesRuns() throws {
        XCTAssertEqual(try ShellArguments.split("a   b\tc"), ["a", "b", "c"])
    }

    func testHonorsDoubleAndSingleQuotes() throws {
        let result = try ShellArguments.split("--out \"/tmp/my dir\" '--flag value'")
        XCTAssertEqual(result, ["--out", "/tmp/my dir", "--flag value"])
    }

    func testKeepsEmptyQuotedArgument() throws {
        XCTAssertEqual(try ShellArguments.split("a \"\" b"), ["a", "", "b"])
    }

    func testBackslashEscapesNextCharacter() throws {
        XCTAssertEqual(try ShellArguments.split("a\\ b"), ["a b"])
    }

    func testUnterminatedQuoteThrows() {
        XCTAssertThrowsError(try ShellArguments.split("--out \"/tmp/oops")) { error in
            XCTAssertEqual(error as? WhisperCLIError, .unterminatedQuote)
        }
    }

    func testConfigurationSubstitutesPlaceholders() throws {
        let config = WhisperConfiguration(
            command: "whisper",
            argumentsTemplate: "\"{audio}\" --output_dir \"{output}\""
        )
        let args = try config.resolvedArguments(audioPath: "/tmp/a b.m4a", outputPath: "/tmp/out")
        XCTAssertEqual(args, ["/tmp/a b.m4a", "--output_dir", "/tmp/out"])
    }
}
