import XCTest
import WhiskerFlowCore

final class MeetingCoachAnalyticsTests: XCTestCase {
    /// One-second samples from a compact script: y = you, o = others,
    /// b = both, s = silence, ? = a missing track.
    private func inputs(_ script: String, from start: TimeInterval = 0) -> [MeetingActivityInput] {
        script.enumerated().map { index, symbol in
            let own: Bool? = symbol == "?" ? nil : (symbol == "y" || symbol == "b")
            let system: Bool? = symbol == "?" ? nil : (symbol == "o" || symbol == "b")
            return MeetingActivityInput(elapsedSeconds: start + Double(index), durationSeconds: 1,
                                        ownMicActivity: own, systemActivity: system)
        }
    }

    func testTalkShareExcludesCrosstalkAndNeedsEnoughSpeech() {
        var talk = MeetingTalkTime()
        inputs(String(repeating: "y", count: 10) + String(repeating: "o", count: 10)).forEach { talk.ingest($0) }
        XCTAssertNil(talk.talkShare, "20 s of speech is too little to judge")
        inputs(String(repeating: "y", count: 20) + "bbbbb" + "sssss" + "??", from: 20).forEach { talk.ingest($0) }
        XCTAssertEqual(talk.youSeconds, 30)
        XCTAssertEqual(talk.othersSeconds, 10)
        XCTAssertEqual(talk.overlapSeconds, 5)
        XCTAssertEqual(talk.silenceSeconds, 5)
        XCTAssertEqual(talk.unknownSeconds, 2)
        XCTAssertEqual(talk.talkShare!, 0.75, accuracy: 0.0001)
    }

    func testRecentTalkShareForgetsOlderMinutes() {
        var talk = MeetingTalkTime()
        inputs(String(repeating: "y", count: 300)).forEach { talk.ingest($0) }
        inputs(String(repeating: "o", count: 300), from: 300).forEach { talk.ingest($0) }
        XCTAssertEqual(talk.talkShare!, 0.5, accuracy: 0.0001)
        XCTAssertEqual(talk.recentTalkShare!, 0, accuracy: 0.0001)
    }

    func testMonologueAlertsOnceAfterNinetySecondsDespiteShortPausesAndBackchannels() {
        var tracker = MeetingMonologueTracker()
        // You talk, with 2 s pauses and a 1 s "mm-hm" every 20 seconds.
        let block = String(repeating: "y", count: 17) + "ss" + "o"
        var alerts = 0
        for (index, input) in inputs(String(repeating: block, count: 6)).enumerated() {
            if tracker.ingest(input) {
                alerts += 1
                XCTAssertGreaterThanOrEqual(Double(index + 1), MeetingMonologueTracker.alertAfterSeconds)
            }
        }
        XCTAssertEqual(alerts, 1)
        XCTAssertEqual(tracker.monologueCount, 1)
        XCTAssertGreaterThanOrEqual(tracker.longestRunSeconds, 110)
    }

    func testTurnEndsWhenOthersTakeTheFloorOrYouStop() {
        var tracker = MeetingMonologueTracker()
        inputs(String(repeating: "y", count: 60) + "oo").forEach { tracker.ingest($0) }
        XCTAssertEqual(tracker.currentRunSeconds, 0, "Two seconds of someone else is an interruption")
        inputs(String(repeating: "y", count: 60) + "ssss", from: 62).forEach { tracker.ingest($0) }
        XCTAssertEqual(tracker.currentRunSeconds, 0, "Four seconds of your silence ends the turn")
        inputs(String(repeating: "y", count: 60) + "osos", from: 126).forEach { tracker.ingest($0) }
        XCTAssertEqual(tracker.currentRunSeconds, 0, "Alternating noise can't keep a finished turn alive")
        XCTAssertEqual(tracker.monologueCount, 0)
        XCTAssertEqual(tracker.longestRunSeconds, 60, accuracy: 0.001)
    }

    func testTalkingOverOthersContinuesYourTurn() {
        var tracker = MeetingMonologueTracker()
        let fired = inputs(String(repeating: "yb", count: 46)).map { tracker.ingest($0) }
        XCTAssertEqual(fired.filter { $0 }.count, 1)
    }

    func testPaceUsesSpeechTimeAndRecentWindow() {
        var pace = MeetingSpeakingPace()
        pace.ingest(words: 30, speechSeconds: 10, at: 20)
        XCTAssertNil(pace.recentWordsPerMinute, "Under 20 s of speech")
        pace.ingest(words: 40, speechSeconds: 15, at: 40)
        XCTAssertEqual(pace.recentWordsPerMinute!, 168, accuracy: 0.001)
        pace.ingest(words: 20, speechSeconds: 20, at: 400)
        XCTAssertEqual(pace.recentWordsPerMinute!, 60, accuracy: 0.001, "Older windows fall out of the recent rate")
        XCTAssertEqual(pace.averageWordsPerMinute!, 120, accuracy: 0.001)
        XCTAssertEqual(MeetingPaceBand.band(wordsPerMinute: 90), .slow)
        XCTAssertEqual(MeetingPaceBand.band(wordsPerMinute: 150), .comfortable)
        XCTAssertEqual(MeetingPaceBand.band(wordsPerMinute: 190), .fast)
    }

    func testWordCount() {
        XCTAssertEqual(MeetingSpeakingPace.wordCount("We'll ship it on Monday — at 9, OK?"), 8)
        XCTAssertEqual(MeetingSpeakingPace.wordCount("  … — "), 0)
    }

    func testSummaryAndTrends() {
        func summary(you: Double, others: Double, monologues: Int, wpm: Double?) -> MeetingCoachSummary {
            MeetingCoachSummary(durationSeconds: 1_800, youSeconds: you, othersSeconds: others, overlapSeconds: 0,
                                longestMonologueSeconds: Double(monologues) * 100, monologueCount: monologues,
                                averageWordsPerMinute: wpm, promptsShown: 0)
        }
        // Newest first: talking more lately.
        let summaries = [summary(you: 700, others: 300, monologues: 2, wpm: 170),
                         summary(you: 600, others: 400, monologues: 1, wpm: 160),
                         summary(you: 650, others: 350, monologues: 1, wpm: nil),
                         summary(you: 300, others: 700, monologues: 0, wpm: 140),
                         summary(you: 400, others: 600, monologues: 0, wpm: 130),
                         summary(you: 350, others: 650, monologues: 0, wpm: 150)]
        let trends = MeetingCoachTrends(summaries)
        XCTAssertEqual(trends.meetingCount, 6)
        XCTAssertEqual(trends.averageTalkShare!, 0.5, accuracy: 0.0001)
        XCTAssertEqual(trends.averageWordsPerMinute!, 150, accuracy: 0.0001)
        XCTAssertEqual(trends.monologuesPerMeeting, 4.0 / 6, accuracy: 0.0001)
        XCTAssertEqual(trends.longestMonologueSeconds, 200)
        XCTAssertEqual(trends.talkShareDirection, .up)
        XCTAssertNil(MeetingCoachTrends(Array(summaries.prefix(3))).talkShareDirection, "Needs two groups to compare")
        XCTAssertEqual(MeetingCoachTrends([]).meetingCount, 0)
    }
}

final class MeetingCoachSuggestionPolicyTests: XCTestCase {
    func testLiveTranscriptionSkipsQuietOrMostlyRemoteWindows() {
        XCTAssertTrue(MeetingLiveTranscriptionPolicy.shouldTranscribe(youSeconds: 12, bothSeconds: 2, othersSeconds: 3))
        XCTAssertFalse(MeetingLiveTranscriptionPolicy.shouldTranscribe(youSeconds: 3, bothSeconds: 1, othersSeconds: 0), "Too little speech")
        XCTAssertFalse(MeetingLiveTranscriptionPolicy.shouldTranscribe(youSeconds: 6, bothSeconds: 6, othersSeconds: 8), "Mostly the call, not you")
    }

    func testRequestsNeedTimeNewWordsAndSpacing() {
        typealias P = MeetingCoachSuggestionPolicy
        XCTAssertFalse(P.shouldRequest(elapsedSeconds: 60, lastRequestElapsedSeconds: nil, newWords: 200), "Not in the first two minutes")
        XCTAssertFalse(P.shouldRequest(elapsedSeconds: 300, lastRequestElapsedSeconds: nil, newWords: 59))
        XCTAssertTrue(P.shouldRequest(elapsedSeconds: 300, lastRequestElapsedSeconds: nil, newWords: 60))
        XCTAssertFalse(P.shouldRequest(elapsedSeconds: 400, lastRequestElapsedSeconds: 300, newWords: 100))
        XCTAssertTrue(P.shouldRequest(elapsedSeconds: 480, lastRequestElapsedSeconds: 300, newWords: 100))
    }

    func testContextKeepsTheNewestWords() {
        let fragments = (1...300).map { "w\($0)" }
        let context = MeetingCoachSuggestionPolicy.context(from: fragments)
        XCTAssertEqual(context.split(separator: " ").count, 250)
        XCTAssertTrue(context.hasPrefix("w51 ") && context.hasSuffix(" w300"))
    }

    func testSanitizeAcceptsOneShortSentenceOnly() {
        typealias P = MeetingCoachSuggestionPolicy
        XCTAssertEqual(P.sanitize("  \"ask the group what they think\" "), "Ask the group what they think.")
        XCTAssertEqual(P.sanitize("Try a quick summary?"), "Try a quick summary?")
        XCTAssertNil(P.sanitize("NONE."))
        XCTAssertNil(P.sanitize(""))
        XCTAssertNil(P.sanitize(nil))
        XCTAssertNil(P.sanitize("First.\nSecond."))
        XCTAssertNil(P.sanitize(String(repeating: "word ", count: 40)))
    }
}

final class MeetingCoachAdviceTests: XCTestCase {
    func testEveryAdviceHasFixedShortWordingAndNoneIsSilent() {
        for advice in MeetingCoachAdvice.allCases where advice != .none && advice != .returnToGoal {
            let message = advice.message(goal: "")
            XCTAssertNotNil(message, advice.rawValue)
            XCTAssertLessThanOrEqual(message!.count, MeetingCoachSuggestionPolicy.maximumSuggestionCharacters)
        }
        XCTAssertNil(MeetingCoachAdvice.none.message(goal: "x"))
        XCTAssertNil(MeetingCoachAdvice.returnToGoal.message(goal: "  "), "No goal typed, nothing to steer back to")
        XCTAssertEqual(MeetingCoachAdvice.returnToGoal.message(goal: "Agree the Q4 budget"), "Steer back to your goal: Agree the Q4 budget")
        XCTAssertEqual(MeetingCoachAdvice.returnToGoal.message(goal: String(repeating: "a", count: 100))?.count,
                       "Steer back to your goal: ".count + 60)
    }
}

final class MeetingCoachTextSignalTests: XCTestCase {
    func testFillerRateCountsFillersButNotOrdinaryLike() {
        XCTAssertGreaterThan(MeetingCoachTextSignals.fillerRate("Um, so, like, basically, you know, we kind of need to, um, decide."), 30)
        XCTAssertEqual(MeetingCoachTextSignals.fillerRate("I like the new design and would like to ship it."), 0)
        XCTAssertEqual(MeetingCoachTextSignals.fillerRate(""), 0)
    }

    func testVagueCommitmentsNeedTwoPhrases() {
        let vague = "Someone should follow up with the vendor. We'll circle back on the contract later."
        XCTAssertEqual(MeetingCoachTextSignals.vagueCommitmentCount(vague), 2)
        XCTAssertEqual(MeetingCoachJudgement.advice(judgement: nil, recentWords: vague, goal: ""), .agreeOwnersAndDates)
        XCTAssertEqual(MeetingCoachJudgement.advice(judgement: nil, recentWords: "Sam sends the quote by Tuesday. We'll see.", goal: ""), .none)
    }

    func testAdvicePriorityAndCountableRules() {
        let long = Array(repeating: "the rollout covers every region and every service", count: 20).joined(separator: " ")
        XCTAssertEqual(MeetingCoachJudgement.advice(judgement: nil, recentWords: long, goal: ""), .askForInput)
        XCTAssertEqual(MeetingCoachJudgement.advice(judgement: nil, recentWords: long + " any concerns?", goal: ""), .none)
        XCTAssertEqual(MeetingCoachJudgement.advice(judgement: .init(offGoal: true), recentWords: "coffee", goal: ""), .none,
                       "No goal typed, so there's nothing to drift from")
        XCTAssertEqual(MeetingCoachJudgement.advice(judgement: .init(defensiveTone: true, offGoal: true), recentWords: "x", goal: "Budget"),
                       .acknowledgeConcerns)
        let fillers = Array(repeating: "um so basically you know we should decide", count: 5).joined(separator: " ")
        XCTAssertEqual(MeetingCoachJudgement.advice(judgement: .init(heavyJargon: true), recentWords: fillers, goal: ""), .reduceFillerWords)
    }
}

final class MeetingSpeakerActivityClassifierTests: XCTestCase {
    /// One second of constant-level frames (RMS = amplitude).
    private func second(_ amplitudes: [Float]) -> [Float] {
        amplitudes.flatMap { Array(repeating: $0, count: MeetingSpeakerActivityClassifier.frameSamples) }
    }
    private func constant(_ amplitude: Float) -> [Float] { second(Array(repeating: amplitude, count: 10)) }

    func testOthersOnTheMacSpeakersAreNotCountedAsYou() {
        var classifier = MeetingSpeakerActivityClassifier()
        let noise: Float = 0.02, others: Float = 0.08, bleed: Float = 0.06, you: Float = 0.25
        // Warm up: room noise, then the others talking through the speakers.
        for _ in 0..<5 { _ = classifier.classify(microphone: constant(noise), system: constant(0)) }
        var counted = 0
        for _ in 0..<20 {
            let result = classifier.classify(microphone: constant(bleed), system: constant(others))
            if result.you == true { counted += 1 }
            XCTAssertEqual(result.others, true)
        }
        XCTAssertLessThanOrEqual(counted, 2, "Speaker leak alone isn't you (the first seconds may still be learning)")
        let alone = classifier.classify(microphone: constant(you), system: constant(0))
        XCTAssertEqual(alone.you, true)
        XCTAssertEqual(alone.others, false)
        let both = classifier.classify(microphone: constant(you), system: constant(others))
        XCTAssertEqual(both.you, true, "You talking over the others is still you")
        XCTAssertEqual(both.others, true)
        let quiet = classifier.classify(microphone: constant(noise), system: constant(0))
        XCTAssertEqual(quiet.you, false, "A noisy room isn't speech")
    }

    func testNoisyRoomRaisesTheMicrophoneFloor() {
        var classifier = MeetingSpeakerActivityClassifier()
        XCTAssertEqual(classifier.classify(microphone: constant(0.04), system: constant(0)).you, true,
                       "With nothing learnt yet, the fixed floor applies")
        for _ in 0..<10 {
            XCTAssertEqual(classifier.classify(microphone: constant(0.04), system: constant(0)).you, false,
                           "A steady hum above the fixed floor stops counting once learnt")
        }
        XCTAssertEqual(classifier.classify(microphone: constant(0.2), system: constant(0)).you, true)
        // Long speech keeps counting: the pauses between words hold the floor down.
        let speech = second([0.25, 0.3, 0.02, 0.28, 0.3, 0.02, 0.27, 0.3, 0.26, 0.02])
        for _ in 0..<90 { XCTAssertEqual(classifier.classify(microphone: speech, system: constant(0)).you, true) }
    }

    func testMissingTracksAreUnknown() {
        var classifier = MeetingSpeakerActivityClassifier()
        let result = classifier.classify(microphone: constant(0.2), system: nil)
        XCTAssertEqual(result.you, true)
        XCTAssertNil(result.others)
        XCTAssertEqual(MeetingSpeechState(.init(elapsedSeconds: 0, durationSeconds: 1, ownMicActivity: true, systemActivity: nil)), .unknown,
                       "Without Mac audio, microphone sound may be the others on the speakers")
    }
}
