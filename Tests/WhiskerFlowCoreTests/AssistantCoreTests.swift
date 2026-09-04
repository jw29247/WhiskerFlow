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
