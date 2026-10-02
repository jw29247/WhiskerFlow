import XCTest
@testable import WhiskerFlowCore

final class TranscriptPhraseSegmenterTests: XCTestCase {
    private func word(_ text: String, _ start: Double, _ end: Double) -> TranscriptionSegment {
        TranscriptionSegment(text: text, start: start, end: end)
    }

    func testSentenceEndingPunctuationClosesAPhrase() {
        let phrases = TranscriptPhraseSegmenter.phrases(from: [
            word("Hello", 0.0, 0.3), word("there.", 0.35, 0.7),
            word("How", 0.8, 1.0), word("are", 1.05, 1.2), word("you?", 1.25, 1.5),
        ])
        XCTAssertEqual(phrases, [
            TranscriptionSegment(text: "Hello there.", start: 0.0, end: 0.7),
            TranscriptionSegment(text: "How are you?", start: 0.8, end: 1.5),
        ])
    }

    func testLongPauseClosesAPhraseWithoutPunctuation() {
        let phrases = TranscriptPhraseSegmenter.phrases(from: [
            word("so", 0.0, 0.2), word("anyway", 0.25, 0.6),
            word("right", 2.0, 2.3),
        ])
        XCTAssertEqual(phrases.map(\.text), ["so anyway", "right"])
    }

    func testShortPauseKeepsThePhraseTogether() {
        let phrases = TranscriptPhraseSegmenter.phrases(from: [
            word("one", 0.0, 0.2), word("two", 0.6, 0.8), word("three", 1.2, 1.4),
        ])
        XCTAssertEqual(phrases.map(\.text), ["one two three"])
    }

    func testRunOnSpeechIsCappedInDuration() {
        let words = (0..<100).map { word("w\($0)", Double($0) * 0.4, Double($0) * 0.4 + 0.3) }
        let phrases = TranscriptPhraseSegmenter.phrases(from: words, maximumDuration: 10)
        XCTAssertGreaterThan(phrases.count, 1)
        for phrase in phrases { XCTAssertLessThanOrEqual(phrase.end - phrase.start, 10.0001) }
        XCTAssertEqual(phrases.flatMap { $0.text.split(separator: " ").map(String.init) }, words.map(\.text))
    }

    func testAbbreviationsAndDecimalsDoNotEndASentence() {
        let phrases = TranscriptPhraseSegmenter.phrases(from: [
            word("Mr.", 0.0, 0.2), word("Smith", 0.25, 0.5), word("paid", 0.55, 0.8),
            word("3.5", 0.85, 1.1), word("percent.", 1.15, 1.5),
        ])
        XCTAssertEqual(phrases.map(\.text), ["Mr. Smith paid 3.5 percent."])
    }

    func testBlankWordsAreDroppedAndEmptyInputIsEmpty() {
        XCTAssertEqual(TranscriptPhraseSegmenter.phrases(from: []), [])
        let phrases = TranscriptPhraseSegmenter.phrases(from: [word(" ", 0, 0.1), word("ok", 0.2, 0.4)])
        XCTAssertEqual(phrases, [TranscriptionSegment(text: "ok", start: 0.2, end: 0.4)])
    }

    func testTrailingPunctuationTokensAttachToThePreviousWord() {
        let phrases = TranscriptPhraseSegmenter.phrases(from: [
            word("Yes", 0.0, 0.3), word(",", 0.3, 0.3), word("fine", 0.4, 0.7), word(".", 0.7, 0.7),
            word("Next", 0.9, 1.2),
        ])
        XCTAssertEqual(phrases.map(\.text), ["Yes, fine.", "Next"])
    }
}
