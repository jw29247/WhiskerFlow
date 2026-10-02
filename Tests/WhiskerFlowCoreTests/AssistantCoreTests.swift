import Foundation
import XCTest
@testable import WhiskerFlowCore

final class AssistantCoreTests: XCTestCase {
    func testSpokenCorrectionReplacesOnlyExplicitDelimitedRepair() {
        XCTAssertEqual(SpokenSelfCorrection.resolve("Meet on Thursday, sorry, Friday."), "Meet on Friday.")
        XCTAssertEqual(SpokenSelfCorrection.resolve("I am sorry about Friday."), "I am sorry about Friday.")
        XCTAssertEqual(SpokenSelfCorrection.resolve("Do not remove the backup."), "Do not remove the backup.")
    }

    func testSpokenCorrectionPreservesAmbiguousAndNegatedRepairs() {
        XCTAssertEqual(SpokenSelfCorrection.resolve("Thursday sorry Friday"), "Thursday sorry Friday")
        XCTAssertEqual(SpokenSelfCorrection.resolve("Do not use Thursday, sorry, Friday."), "Do not use Thursday, sorry, Friday.")
        XCTAssertEqual(SpokenSelfCorrection.resolve("Meet Thursday, sorry, Friday, or Saturday."), "Meet Thursday, sorry, Friday, or Saturday.")
    }

    func testSpokenCorrectionSupportsNaturalIMeanAndBoundedScratchThat() {
        XCTAssertEqual(SpokenSelfCorrection.resolve("Meet on Thursday, I mean Friday."), "Meet on Friday.")
        XCTAssertEqual(SpokenSelfCorrection.resolve("Send the old version, scratch that, send the new version."), "Send the new version.")
        XCTAssertEqual(SpokenSelfCorrection.resolve("She wrote “Thursday,” I mean Friday."), "She wrote “Thursday,” I mean Friday.")
        XCTAssertEqual(SpokenSelfCorrection.resolve("Do not send the old version, scratch that, send the new version."), "Do not send the old version, scratch that, send the new version.")
    }

    func testBareRepairsAndSentenceBoundaries() {
        XCTAssertEqual(SpokenSelfCorrection.resolve("Thursday, sorry, Friday."), "Friday.")
        XCTAssertEqual(SpokenSelfCorrection.resolve("Thursday, I mean, Friday."), "Friday.")
        let multiple = "Keep this sentence. Send the old version, scratch that, send the new version."
        XCTAssertEqual(SpokenSelfCorrection.resolve(multiple), "Keep this sentence. Send the new version.")
    }

    func testSpokenCorrectionInRecognizedAcceptanceParagraph() {
        let input = "This is a synthetic acceptance test. On Tuesday, sorry, Thursday. Do not publish it. The budget is £15 no £50. Please send the report to Mark."
        let expected = "This is a synthetic acceptance test. On Thursday. Do not publish it. The budget is £15 no £50. Please send the report to Mark."
        XCTAssertEqual(SpokenSelfCorrection.resolve(input), expected)
    }

    func testSentenceRepairsPreserveOtherNegationAndWhitespace() {
        XCTAssertEqual(
            SpokenSelfCorrection.resolve("  Do not publish it.  On Tuesday, sorry, Thursday.\nNever delete backups.\tMeet Monday, I mean Friday.  "),
            "  Do not publish it.  On Thursday.\nNever delete backups.\tMeet Friday.  "
        )
    }

    func testIndependentRepairsRespectQuestionAndExclamationBoundaries() {
        XCTAssertEqual(
            SpokenSelfCorrection.resolve("Ready? On Tuesday, sorry, Thursday! Meet Monday, I mean Friday. Keep this sentence."),
            "Ready? On Thursday! Meet Friday. Keep this sentence."
        )
    }

    func testSentenceRepairsPreserveDecimalsAndAbbreviations() {
        XCTAssertEqual(
            SpokenSelfCorrection.resolve("The budget is £15.50 no £50. Meet Dr. Smith on Tuesday, sorry, Thursday. Keep 3.14 unchanged."),
            "The budget is £15.50 no £50. Meet Dr. Smith on Thursday. Keep 3.14 unchanged."
        )
        for input in [
            "Do not use Dr. Tuesday, sorry, Thursday.",
            "Never book at 9 a.m. Tuesday, sorry, Thursday.",
            "Do not use J. Tuesday, sorry, Thursday."
        ] {
            XCTAssertEqual(SpokenSelfCorrection.resolve(input), input)
        }
    }

    func testSentenceRepairsPreserveQuotesAndAmbiguousClauses() {
        for input in [
            "She said \"Tuesday, sorry, Thursday.\" Do not change that.",
            "She said “Tuesday, sorry, Thursday.” Keep this sentence.",
            "Use Tuesday, sorry, Thursday, and Mark, sorry, John.",
            "Keep the backup, meet Tuesday, sorry, Thursday.",
            "The budget is £15 no £50. I am sorry about Friday.",
            "Keep this sentence. No, sorry, yes."
        ] {
            XCTAssertEqual(SpokenSelfCorrection.resolve(input), input)
        }
    }

    func testSpokenCorrectionKeepsEmphaticAndAddressingPhrases() {
        for input in [
            "Thank you so much, I mean it.",
            "Yes, I mean it.",
            "Great work, I mean that.",
            "Hey, sorry, Tom.",
            "Hi, sorry, Sarah!"
        ] {
            XCTAssertEqual(SpokenSelfCorrection.resolve(input), input)
        }
        XCTAssertEqual(SpokenSelfCorrection.resolve("Send it to Mark, sorry, Mike."), "Send it to Mike.")
    }

    func testWritingAndRecordModelsRoundTripThroughCodable() throws {
        let now = Date(timeIntervalSince1970: 1_725_552_000)
        let draft = PendingQuickCaptureDraft(id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!, rawText: "Call Acme tomorrow", kind: .taskDraft, createdAt: now, updatedAt: now, syncState: .pending)
        XCTAssertEqual(try JSONDecoder().decode(PendingQuickCaptureDraft.self, from: JSONEncoder().encode(draft)), draft)
        let profile = ClientVocabularyProfile(id: "acme", clientIdentifier: "com.acme.client", vocabulary: Vocabulary(rules: [.init(find: "ack me", replaceWith: "Acme")]), createdAt: now, updatedAt: now, syncState: .synced)
        XCTAssertEqual(try JSONDecoder().decode(ClientVocabularyProfile.self, from: JSONEncoder().encode(profile)), profile)
        XCTAssertEqual(WritingProfile(bundleIdentifier: "com.apple.mail", style: .polished).style, .polished)
    }

    func testMeetingMetricsBoundWindowAndReportOverlapUncertainty() {
        let result = MeetingCoachMetrics.accumulate(inputs: [
            .init(elapsedSeconds: 0, durationSeconds: 40, ownMicActivity: true, systemActivity: false),
            .init(elapsedSeconds: 40, durationSeconds: 30, ownMicActivity: true, systemActivity: true)
        ])
        XCTAssertEqual(result.windowDurationSeconds, 60)
        XCTAssertEqual(result.ownMicActiveSeconds, 60)
        XCTAssertEqual(result.systemActiveSeconds, 30)
        XCTAssertEqual(result.overlapSeconds, 30)
        XCTAssertEqual(result.certainty, .uncertainOverlap)
    }

    func testMeetingMetricsReportMissingSourcesAndPromptCooldown() {
        let result = MeetingCoachMetrics.accumulate(inputs: [.init(elapsedSeconds: 0, durationSeconds: 10, ownMicActivity: true, systemActivity: nil)])
        XCTAssertEqual(result.certainty, .missingSystemTrack)
        XCTAssertFalse(MeetingCoachMetrics.canPrompt(elapsedSeconds: 59.9, lastPromptElapsedSeconds: 0))
        XCTAssertTrue(MeetingCoachMetrics.canPrompt(elapsedSeconds: 60, lastPromptElapsedSeconds: 0))
        XCTAssertTrue(MeetingCoachMetrics.canPrompt(elapsedSeconds: 0, lastPromptElapsedSeconds: nil))
    }

    func testMeetingMetricsDoNotDoubleCountOverlappingInputs() {
        let result = MeetingCoachMetrics.accumulate(inputs: [
            .init(elapsedSeconds: 0, durationSeconds: 40, ownMicActivity: true, systemActivity: false),
            .init(elapsedSeconds: 20, durationSeconds: 40, ownMicActivity: true, systemActivity: false)
        ])
        XCTAssertEqual(result.ownMicActiveSeconds, 60)
        XCTAssertEqual(result.systemActiveSeconds, 0)
        XCTAssertEqual(result.overlapSeconds, 0)
    }

    func testInferencePolicyDeniesEveryUnsafeConditionWithoutFallback() {
        XCTAssertEqual(AssistantInferencePolicy.evaluate(.init(isDictating: true)), .denied(.activeDictation))
        XCTAssertEqual(AssistantInferencePolicy.evaluate(.init(isMeetingRecording: true)), .denied(.activeMeetingRecording))
        XCTAssertEqual(AssistantInferencePolicy.evaluate(.init(isASRRunning: true)), .denied(.simultaneousASR))
        XCTAssertEqual(AssistantInferencePolicy.evaluate(.init(isModelAvailable: false)), .denied(.modelUnavailable))
        XCTAssertEqual(AssistantInferencePolicy.evaluate(.init(inputByteCount: 1_001, maximumInputByteCount: 1_000)), .denied(.excessiveInput))
        XCTAssertEqual(AssistantInferencePolicy.evaluate(.init(isMemoryPressureHigh: true)), .denied(.memoryPressure))
        XCTAssertEqual(AssistantInferencePolicy.evaluate(.init()), .allowedLocal)
    }
}
