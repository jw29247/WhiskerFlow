import XCTest
@testable import WhiskerFlowCore

final class TranscriptFormatterTests: XCTestCase {
    private let allOptions = FormattingOptions(
        spokenLineCommands: true,
        capitalizeSentences: true,
        removeFillerWords: true
    )

    func testEveryOptionDefaultsToOffAndFormattingIsIdentity() {
        let options = FormattingOptions()
        XCTAssertFalse(options.spokenLineCommands)
        XCTAssertFalse(options.capitalizeSentences)
        XCTAssertFalse(options.removeFillerWords)

        let text = "  um, hello new line world  "
        XCTAssertEqual(TranscriptFormatter.format(text, options: options), text)
    }

    func testSpokenCommandAtStartMiddleAndEnd() {
        let options = FormattingOptions(spokenLineCommands: true)

        XCTAssertEqual(
            TranscriptFormatter.format("new line hello world", options: options),
            "hello world"
        )
        XCTAssertEqual(
            TranscriptFormatter.format("hello new line world", options: options),
            "hello\nworld"
        )
        XCTAssertEqual(
            TranscriptFormatter.format("hello world new line", options: options),
            "hello world"
        )
    }

    func testSpokenCommandAbsorbsAdjacentPunctuation() {
        let options = FormattingOptions(spokenLineCommands: true)

        XCTAssertEqual(
            TranscriptFormatter.format("hello. New Line. next", options: options),
            "hello.\nnext"
        )
        XCTAssertEqual(
            TranscriptFormatter.format("hello, new line next", options: options),
            "hello\nnext"
        )
    }

    func testNewParagraphInsertsBlankLine() {
        let options = FormattingOptions(spokenLineCommands: true)

        XCTAssertEqual(
            TranscriptFormatter.format("first thought. New paragraph second thought.", options: options),
            "first thought.\n\nsecond thought."
        )
    }

    func testSpokenCommandsLeaveSimilarPhrasesAlone() {
        let options = FormattingOptions(spokenLineCommands: true)

        XCTAssertEqual(
            TranscriptFormatter.format("we shipped new lines and a new lineup", options: options),
            "we shipped new lines and a new lineup"
        )
    }

    func testFillerWordsRemovedWithSpacingTidiedUp() {
        let options = FormattingOptions(removeFillerWords: true)

        XCTAssertEqual(
            TranscriptFormatter.format("Well, um, this is um good.", options: options),
            "Well, this is good."
        )
        XCTAssertEqual(
            TranscriptFormatter.format("Um, hello there uh.", options: options),
            "hello there."
        )
        XCTAssertEqual(
            TranscriptFormatter.format("Erm, so uhm the plan", options: options),
            "so the plan"
        )
    }

    func testFillerRemovalDoesNotMatchInsideOtherWords() {
        let options = FormattingOptions(removeFillerWords: true)

        XCTAssertEqual(
            TranscriptFormatter.format("the umbrella and uhuru summer", options: options),
            "the umbrella and uhuru summer"
        )
    }

    func testCapitalizationAfterTerminatorsAndNewlines() {
        let options = FormattingOptions(capitalizeSentences: true)

        XCTAssertEqual(
            TranscriptFormatter.format("hello world. how are you? fine! good\nnext one", options: options),
            "Hello world. How are you? Fine! Good\nNext one"
        )
    }

    func testCapitalizationLeavesMidSentenceWordsAlone() {
        let options = FormattingOptions(capitalizeSentences: true)

        XCTAssertEqual(
            TranscriptFormatter.format("i met dr. smith and mrs. jones", options: options),
            "I met dr. Smith and mrs. Jones"
        )
    }

    func testFillerRemovalLeavesHyphenatedWordsIntact() {
        let options = FormattingOptions(removeFillerWords: true)

        // A hyphen is a word boundary to `\b`, which used to strip the "uh" out of
        // "uh-huh" and paste a stray leading hyphen into the user's document.
        XCTAssertEqual(
            TranscriptFormatter.format("uh-huh, that works", options: options),
            "uh-huh, that works"
        )
        XCTAssertEqual(
            TranscriptFormatter.format("um-hmm, agreed", options: options),
            "um-hmm, agreed"
        )
    }

    func testCapitalizationLeavesDomainsFilenamesAndAbbreviationsAlone() {
        let options = FormattingOptions(capitalizeSentences: true)

        XCTAssertEqual(
            TranscriptFormatter.format("go to example.com now", options: options),
            "Go to example.com now"
        )
        XCTAssertEqual(
            TranscriptFormatter.format("send it to www.example.com, e.g. tomorrow", options: options),
            "Send it to www.example.com, e.g. tomorrow"
        )
        XCTAssertEqual(
            TranscriptFormatter.format("attach report.pdf to the email", options: options),
            "Attach report.pdf to the email"
        )
        XCTAssertEqual(
            TranscriptFormatter.format("ask the p.m. about it", options: options),
            "Ask the p.m. about it"
        )
    }

    func testFullPipelineAppliesFillerThenCommandsThenCapitalization() {
        XCTAssertEqual(
            TranscriptFormatter.format(
                "um, hello world. New line uh how are you? um fine",
                options: allOptions
            ),
            "Hello world.\nHow are you? Fine"
        )
    }

    func testFormattingIsIdempotent() {
        let samples = [
            "um, hello world. New line uh how are you? um fine",
            "hello. New Line. next new paragraph and, um, done.",
            "new line new paragraph trailing new line",
            "Erm the umbrella, uh, is new lineup ready?"
        ]

        for sample in samples {
            let once = TranscriptFormatter.format(sample, options: allOptions)
            XCTAssertEqual(TranscriptFormatter.format(once, options: allOptions), once, sample)
        }
    }
}
