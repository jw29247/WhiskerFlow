import Foundation
import XCTest
@testable import WhiskerFlow
import WhiskerFlowCore

/// Opt-in evaluation of the experimental on-device coach model on scripted,
/// invented meeting speech. Text only: no audio, microphone or network.
/// Run with `WHISKERFLOW_COACH_MODEL_EVAL=1 swift test --filter CoachSuggestionEvaluationTests`.
final class CoachSuggestionEvaluationTests: XCTestCase {
    struct Scenario {
        let name: String
        /// Acceptable answers from a good coach.
        let acceptable: Set<MeetingCoachAdvice>
        let request: MeetingCoachSuggestionRequest
    }

    static let scenarios: [Scenario] = [
        Scenario(name: "long technical monologue", acceptable: [.askForInput, .simplifyLanguage], request: .init(
            recentOwnWords: "So the ingestion layer batches events every thirty seconds and then the worker pool picks them up, and the retry queue uses exponential backoff with jitter, and then we fan out to the three regional stores, and the reconciliation job runs nightly and compares checksums, and if anything drifts we page the on-call, and the dashboards show latency per region, and we also added the circuit breaker last sprint so the upstream timeouts don't cascade, and the next thing is the schema migration which touches every table.",
            goal: "Get sign-off on the migration plan", talkSharePercent: 86, currentTurnSeconds: 150, wordsPerMinute: 168)),
        Scenario(name: "filler heavy", acceptable: [.reduceFillerWords], request: .init(
            recentOwnWords: "Um, so, like, basically what I'm saying is, you know, we kind of, um, need to sort of think about, like, the timeline, and, um, basically, you know, the budget thing is, like, kind of important, um, I guess.",
            goal: "", talkSharePercent: 55, currentTurnSeconds: 40, wordsPerMinute: 150)),
        Scenario(name: "vague next steps", acceptable: [.agreeOwnersAndDates], request: .init(
            recentOwnWords: "Yeah that sounds good, we should probably look into that at some point. Someone should follow up with the vendor about the pricing. We'll circle back on the contract stuff later, maybe next week or the week after. Let's keep it in mind and revisit it when things calm down.",
            goal: "Agree owners and dates for the vendor work", talkSharePercent: 48, currentTurnSeconds: 25, wordsPerMinute: 140)),
        Scenario(name: "balanced and asking questions", acceptable: [.none], request: .init(
            recentOwnWords: "That makes sense. What would you need from us to hit Thursday? Okay, so Priya owns the draft and I'll review it by Wednesday. Does anyone see a risk with that date? Great, let's lock it in and I'll send a short summary after the call.",
            goal: "Agree the launch date", talkSharePercent: 38, currentTurnSeconds: 12, wordsPerMinute: 135)),
        Scenario(name: "dense numbers", acceptable: [.none, .summariseSoFar, .askForInput, .simplifyLanguage], request: .init(
            recentOwnWords: "Okay quickly the numbers are up twelve percent quarter on quarter the churn is down to three point one the new pricing page converts at four percent and the enterprise pipeline has six deals in legal and two of them close this month and then we need to hire two more engineers and the design contractor starts Monday.",
            goal: "", talkSharePercent: 70, currentTurnSeconds: 60, wordsPerMinute: 205)),
        Scenario(name: "defensive", acceptable: [.acknowledgeConcerns], request: .init(
            recentOwnWords: "No, that's not what happened. I already explained this twice. The delay was not on our side, we delivered everything on time and honestly I don't see why we keep going over it. It's frustrating that this keeps coming up.",
            goal: "Repair the relationship with the client", talkSharePercent: 60, currentTurnSeconds: 35, wordsPerMinute: 160)),
        Scenario(name: "off goal", acceptable: [.returnToGoal], request: .init(
            recentOwnWords: "Oh and did you see the new office coffee machine? It does these oat milk flat whites now. Also the parking situation has been a nightmare this week, I had to park two streets away. Anyway the weekend was great, we went up to the lakes.",
            goal: "Agree the Q4 budget", talkSharePercent: 65, currentTurnSeconds: 45, wordsPerMinute: 150)),
        Scenario(name: "short and fine", acceptable: [.none], request: .init(
            recentOwnWords: "Thanks, that's clear. I agree with the plan. I'll send the updated deck to everyone by end of day tomorrow and we can review it on Friday's call.",
            goal: "", talkSharePercent: 30, currentTurnSeconds: 10, wordsPerMinute: 130)),
        Scenario(name: "acronym soup", acceptable: [.simplifyLanguage, .askForInput], request: .init(
            recentOwnWords: "So the P99 on the ALB is fine but the ENI churn on the EKS nodes is killing our IOPS, and the CDC pipeline into the OLAP store lags because the WAL retention is too short, so the SLO burn rate trips the PagerDuty SEV2 before the HPA can react.",
            goal: "Explain the outage to the client", talkSharePercent: 60, currentTurnSeconds: 40, wordsPerMinute: 150)),
        Scenario(name: "clear plan with owners", acceptable: [.none], request: .init(
            recentOwnWords: "Right, to recap: Sam sends the revised quote by Tuesday, I book the site visit for the ninth, and Priya checks the permits this week. If any of that slips we'll flag it in the channel. Does that work for everyone?",
            goal: "Agree the next steps", talkSharePercent: 45, currentTurnSeconds: 20, wordsPerMinute: 140)),
        Scenario(name: "small talk with no goal", acceptable: [.none], request: .init(
            recentOwnWords: "Morning! How was the weekend? We finally got out on the bikes, the weather was brilliant. Anyway, shall we get started?",
            goal: "", talkSharePercent: 50, currentTurnSeconds: 10, wordsPerMinute: 140)),
        Scenario(name: "calm disagreement", acceptable: [.none], request: .init(
            recentOwnWords: "I see it a bit differently. I think the risk is on the integration side rather than the design, because the vendor hasn't confirmed their API limits. Could we get that in writing before we commit to the date?",
            goal: "Decide on the launch date", talkSharePercent: 40, currentTurnSeconds: 18, wordsPerMinute: 135)),
        Scenario(name: "holdout: polite status update", acceptable: [.none], request: .init(
            recentOwnWords: "Quick update from my side. The designs went to review on Monday, we had two rounds of feedback, and the final files are with engineering now. The only open item is the icon set, which Mia is finishing tomorrow.",
            goal: "Share project status", talkSharePercent: 40, currentTurnSeconds: 20, wordsPerMinute: 140)),
        Scenario(name: "holdout: irritated", acceptable: [.acknowledgeConcerns], request: .init(
            recentOwnWords: "Look, I've said this in the last three meetings. Nobody reads the tickets. We keep getting blamed for things that aren't our fault and frankly I'm tired of it.",
            goal: "", talkSharePercent: 55, currentTurnSeconds: 25, wordsPerMinute: 165)),
        Scenario(name: "holdout: drifting to holiday", acceptable: [.returnToGoal], request: .init(
            recentOwnWords: "We're thinking Portugal this summer, maybe the Algarve, although my partner wants to do a city break in Lisbon first. Have you been? The food there is incredible and the flights are cheap if you book early.",
            goal: "Finalise the hiring plan", talkSharePercent: 60, currentTurnSeconds: 30, wordsPerMinute: 150)),
        Scenario(name: "holdout: on-topic technical but plain", acceptable: [.none], request: .init(
            recentOwnWords: "The main change is that orders now save as soon as you add an item, so nothing is lost if the page reloads. We tested it on slow connections and it held up. Next week we'll turn it on for everyone. Any questions?",
            goal: "Explain the checkout change", talkSharePercent: 50, currentTurnSeconds: 25, wordsPerMinute: 140)),
    ]

    func testEvaluateOnDeviceCoachModel() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WHISKERFLOW_COACH_MODEL_EVAL"] == "1",
                          "Set WHISKERFLOW_COACH_MODEL_EVAL=1 to evaluate the on-device model.")
        guard let suggester = OnDeviceCoachModel.makeSuggester() else {
            throw XCTSkip("On-device model unavailable: \(OnDeviceCoachModel.unavailableReason)")
        }
        var agreements = 0
        var baselineAgreements = 0
        var latencies: [Double] = []
        for scenario in Self.scenarios {
            let start = Date()
            let judgement = await suggester.judgement(for: scenario.request)
            let seconds = Date().timeIntervalSince(start)
            latencies.append(seconds)
            let advice = MeetingCoachJudgement.advice(judgement: judgement, recentWords: scenario.request.recentOwnWords, goal: scenario.request.goal)
            let baseline = MeetingCoachJudgement.advice(judgement: nil, recentWords: scenario.request.recentOwnWords, goal: scenario.request.goal)
            let agreed = scenario.acceptable.contains(advice)
            if agreed { agreements += 1 }
            if scenario.acceptable.contains(baseline) { baselineAgreements += 1 }
            let flags = judgement.map { "vague=\($0.vagueNextSteps) defensive=\($0.defensiveTone) offGoal=\($0.offGoal) jargon=\($0.heavyJargon)" } ?? "declined"
            print("COACH_EVAL: \(scenario.name) | got=\(advice.rawValue) | agreed=\(agreed) | rules-only=\(baseline.rawValue) | \(String(format: "%.2f", seconds))s | \(flags)")
        }
        print("COACH_EVAL_BASELINE: rules-only agreement=\(baselineAgreements)/\(Self.scenarios.count)")
        let sorted = latencies.sorted()
        print("COACH_EVAL_SUMMARY: agreement=\(agreements)/\(Self.scenarios.count) median_s=\(String(format: "%.2f", sorted[sorted.count / 2])) max_s=\(String(format: "%.2f", sorted.last ?? 0))")
    }
}
