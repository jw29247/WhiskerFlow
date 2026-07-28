import XCTest
import WhiskerFlowCore
@testable import WhiskerFlowAppSupport

/// Guards the two checked-in copies of the agency glossary. The repo-root copy is
/// what every installed app fetches at runtime, so a bad rule there ships without
/// a release.
final class SharedGlossaryValidationTests: XCTestCase {
    private struct Projection: Equatable, CustomStringConvertible {
        let find: String
        let replaceWith: String
        let caseSensitive: Bool
        let wholeWord: Bool

        init(_ rule: VocabularyRule) {
            find = rule.find
            replaceWith = rule.replaceWith
            caseSensitive = rule.caseSensitive
            wholeWord = rule.wholeWord
        }

        var description: String { "\(find) -> \(replaceWith) [\(caseSensitive), \(wholeWord)]" }
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static var fetchedCopyURL: URL {
        repositoryRoot.appendingPathComponent("shared-vocabulary.json")
    }

    private static var bundledCopyURL: URL {
        repositoryRoot
            .appendingPathComponent("Sources/WhiskerFlow/Resources/shared-vocabulary.json")
    }

    private func report(_ url: URL) throws -> AgencyVocabularyDecodeReport {
        try AgencyVocabularyPolicy.decodeReport(try Data(contentsOf: url))
    }

    func testBothCopiesDecode() throws {
        XCTAssertFalse(try report(Self.fetchedCopyURL).vocabulary.rules.isEmpty)
        XCTAssertFalse(try report(Self.bundledCopyURL).vocabulary.rules.isEmpty)
    }

    func testBothCopiesHoldTheSameRules() throws {
        // Decoded rules get fresh UUIDs and the two files differ in blank lines, so
        // compare the meaningful fields rather than rules or bytes.
        XCTAssertEqual(
            try report(Self.fetchedCopyURL).vocabulary.rules.map(Projection.init),
            try report(Self.bundledCopyURL).vocabulary.rules.map(Projection.init)
        )
    }

    func testShippedRulesSurviveTheSanitizer() throws {
        XCTAssertEqual(try report(Self.fetchedCopyURL).droppedRuleCount, 0)
        XCTAssertEqual(try report(Self.bundledCopyURL).droppedRuleCount, 0)
    }

    func testShippedRulesAreLintClean() throws {
        for url in [Self.fetchedCopyURL, Self.bundledCopyURL] {
            let flags = GlossaryLint.flags(for: try report(url).vocabulary)
            XCTAssertEqual(flags, [], "\(url.lastPathComponent) at \(url.path)")
        }
    }

    func testShippedRulesAreWellFormed() throws {
        for url in [Self.fetchedCopyURL, Self.bundledCopyURL] {
            let rules = try report(url).vocabulary.rules
            for rule in rules {
                XCTAssertFalse(rule.find.isEmpty, "empty find in \(url.path)")
                // Casing-only rules ("otty" -> "Otty") are the point of the glossary,
                // so only an exactly identical replacement is a no-op.
                XCTAssertNotEqual(rule.find, rule.replaceWith, "no-op rule in \(url.path)")
            }
            let finds = rules.map { $0.find.lowercased() }
            XCTAssertEqual(finds.count, Set(finds).count, "duplicate find in \(url.path)")
        }
    }
}
