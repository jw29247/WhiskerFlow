import Foundation
import WhiskerFlowCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// What the experimental coach model sees: only your own recent words (from
/// your microphone), the goal you typed, and a few numbers.
struct MeetingCoachSuggestionRequest: Equatable, Sendable {
    var recentOwnWords: String
    var goal: String
    var talkSharePercent: Int?
    var currentTurnSeconds: Int
    var wordsPerMinute: Int?
}

protocol MeetingCoachSuggesting: Sendable {
    /// The model's yes/no judgements, or `nil` if it declined or failed.
    /// Must never throw into the meeting.
    func judgement(for request: MeetingCoachSuggestionRequest) async -> MeetingCoachJudgement?
}

extension MeetingCoachSuggesting {
    /// The advice to show, combining the model with countable signals.
    func advice(for request: MeetingCoachSuggestionRequest) async -> MeetingCoachAdvice {
        MeetingCoachJudgement.advice(
            judgement: await judgement(for: request), recentWords: request.recentOwnWords, goal: request.goal
        )
    }
}

/// Apple's on-device foundation model (macOS 26 with Apple Intelligence).
/// Nothing is downloaded or installed by WhiskerFlow, and nothing leaves the Mac.
enum OnDeviceCoachModel {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// A reason to show when the model can't be used, in plain words.
    static var unavailableReason: String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return ""
            case .unavailable(.deviceNotEligible): return "This Mac doesn’t support Apple Intelligence."
            case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in System Settings to use this."
            case .unavailable(.modelNotReady): return "Apple Intelligence is still preparing its model."
            case .unavailable: return "The on-device model isn’t available right now."
            }
        }
        #endif
        return "Needs macOS 26 with Apple Intelligence."
    }

    static func makeSuggester() -> (any MeetingCoachSuggesting)? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), isAvailable { return FoundationModelsCoachSuggester() }
        #endif
        return nil
    }

    static let instructions = """
    You read a few minutes of what one person said aloud in a live meeting and \
    answer one yes/no question about it. Say yes only when it is clearly true; \
    ordinary, constructive speech gets no.
    """

    static func prompt(for request: MeetingCoachSuggestionRequest) -> String {
        var lines: [String] = []
        if !request.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Their stated goal for this meeting: \(request.goal.prefix(300))")
        }
        lines.append("What they said recently:\n\(request.recentOwnWords)")
        return lines.joined(separator: "\n")
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
struct CoachYesNo {
    @Guide(description: "Your yes/no answer to the question.")
    var answer: Bool
}

@available(macOS 26.0, *)
@Generable
enum CoachTone {
    case calm
    case neutral
    case enthusiastic
    /// Firm or disagreeing, but respectful. Not something to coach.
    case assertive
    case frustrated
    case defensive
}

@available(macOS 26.0, *)
@Generable
struct CoachToneAnswer {
    @Guide(description: "The tone that best describes how the speaker comes across.")
    var tone: CoachTone
}

@available(macOS 26.0, *)
struct FoundationModelsCoachSuggester: MeetingCoachSuggesting {
    func judgement(for request: MeetingCoachSuggestionRequest) async -> MeetingCoachJudgement? {
        let hasGoal = !request.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var judgement = MeetingCoachJudgement()
        var answered = false
        // One question per request. A single answer with several fields made
        // the small model say yes to the first field almost every time, and
        // negatively worded questions ("unrelated to…") confused it.
        if let tone = await ask(request, question: "How does the speaker come across?", as: CoachToneAnswer.self) {
            answered = true
            judgement.defensiveTone = tone.tone == .frustrated || tone.tone == .defensive
        }
        if hasGoal, let relevant = await ask(request, question: "Is what they said relevant to their stated goal for the meeting?", as: CoachYesNo.self) {
            answered = true
            judgement.offGoal = !relevant.answer
        }
        if let jargon = await ask(request, question: "Do they use dense technical jargon or acronyms that a non-specialist listener could not follow?", as: CoachYesNo.self) {
            answered = true
            judgement.heavyJargon = jargon.answer
        }
        return answered ? judgement : nil
    }

    private func ask<Answer: Generable>(_ request: MeetingCoachSuggestionRequest, question: String, as type: Answer.Type) async -> Answer? {
        // A fresh session per question: nothing from earlier in the meeting is
        // retained by the model.
        let session = LanguageModelSession(instructions: OnDeviceCoachModel.instructions)
        do {
            let response = try await session.respond(
                to: OnDeviceCoachModel.prompt(for: request) + "\n\nQuestion: " + question,
                generating: type,
                options: GenerationOptions(sampling: .greedy)
            )
            return response.content
        } catch {
            // Guardrail refusals, context limits and model errors are silent.
            return nil
        }
    }
}
#endif
