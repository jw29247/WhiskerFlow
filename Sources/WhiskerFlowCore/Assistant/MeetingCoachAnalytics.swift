import Foundation

/// Who was audible in one activity sample, from the separate microphone
/// ("you") and Mac-audio ("others") tracks.
public enum MeetingSpeechState: Equatable, Sendable {
    case you
    case others
    case both
    case silence
    case unknown

    public init(_ input: MeetingActivityInput) {
        switch (input.ownMicActivity, input.systemActivity) {
        case (true, true): self = .both
        case (true, _): self = .you
        case (_, true): self = .others
        case (false, false): self = .silence
        default: self = .unknown
        }
    }
}

/// Cumulative talk time for the whole meeting, plus a recent window.
public struct MeetingTalkTime: Equatable, Sendable {
    public static let recentWindowSeconds: TimeInterval = 300
    /// Below this much speech in total, a ratio says nothing useful.
    public static let minimumSpeechSeconds: TimeInterval = 30

    public private(set) var youSeconds: TimeInterval = 0
    public private(set) var othersSeconds: TimeInterval = 0
    public private(set) var overlapSeconds: TimeInterval = 0
    public private(set) var silenceSeconds: TimeInterval = 0
    public private(set) var unknownSeconds: TimeInterval = 0
    private var recent: [(end: TimeInterval, state: MeetingSpeechState, duration: TimeInterval)] = []

    public init() {}

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.youSeconds == rhs.youSeconds && lhs.othersSeconds == rhs.othersSeconds
            && lhs.overlapSeconds == rhs.overlapSeconds && lhs.silenceSeconds == rhs.silenceSeconds
            && lhs.unknownSeconds == rhs.unknownSeconds
    }

    public mutating func ingest(_ input: MeetingActivityInput) {
        guard input.durationSeconds.isFinite, input.durationSeconds > 0, input.elapsedSeconds.isFinite else { return }
        let state = MeetingSpeechState(input)
        let duration = input.durationSeconds
        switch state {
        case .you: youSeconds += duration
        case .others: othersSeconds += duration
        case .both: overlapSeconds += duration
        case .silence: silenceSeconds += duration
        case .unknown: unknownSeconds += duration
        }
        let end = input.elapsedSeconds + duration
        recent.append((end, state, duration))
        recent.removeAll { $0.end <= end - Self.recentWindowSeconds }
    }

    /// Your share of the talking: you ÷ (you + others). Crosstalk counts for
    /// neither side. `nil` until there is enough speech to judge.
    public var talkShare: Double? { Self.share(you: youSeconds, others: othersSeconds) }

    /// Seconds of speech (you or others, not crosstalk) in the last five minutes.
    public var recentSpeechSeconds: TimeInterval {
        recent.filter { $0.state == .you || $0.state == .others }.reduce(0) { $0 + $1.duration }
    }

    /// Your share over the last five minutes.
    public var recentTalkShare: Double? {
        let you = recent.filter { $0.state == .you }.reduce(0) { $0 + $1.duration }
        let others = recent.filter { $0.state == .others }.reduce(0) { $0 + $1.duration }
        return Self.share(you: you, others: others)
    }

    static func share(you: TimeInterval, others: TimeInterval) -> Double? {
        let total = you + others
        guard total >= minimumSpeechSeconds else { return nil }
        return you / total
    }
}

/// Tracks your continuous speaking turns. A turn survives your own short
/// pauses and the others' brief backchannels ("mm-hm"), and ends when you
/// stop for a while or someone else takes the floor.
public struct MeetingMonologueTracker: Equatable, Sendable {
    public static let alertAfterSeconds: TimeInterval = 90
    public static let pauseToleranceSeconds: TimeInterval = 3
    public static let interruptionSeconds: TimeInterval = 2

    public private(set) var currentRunSeconds: TimeInterval = 0
    public private(set) var longestRunSeconds: TimeInterval = 0
    /// Turns that reached the alert length.
    public private(set) var monologueCount = 0
    private var ownSilence: TimeInterval = 0
    private var othersStreak: TimeInterval = 0
    private var alertedThisRun = false
    private var countedThisRun = false

    public init() {}

    /// Returns `true` once per turn, when it first passes the alert length.
    @discardableResult
    public mutating func ingest(_ input: MeetingActivityInput) -> Bool {
        guard input.durationSeconds.isFinite, input.durationSeconds > 0 else { return false }
        let duration = input.durationSeconds
        switch MeetingSpeechState(input) {
        case .you, .both:
            currentRunSeconds += duration + (currentRunSeconds > 0 ? ownSilence : 0)
            ownSilence = 0
            othersStreak = 0
        case .others:
            othersStreak += duration
            ownSilence += duration
            if othersStreak >= Self.interruptionSeconds || ownSilence > Self.pauseToleranceSeconds { endRun() }
        case .silence, .unknown:
            othersStreak = 0
            ownSilence += duration
            if ownSilence > Self.pauseToleranceSeconds { endRun() }
        }
        longestRunSeconds = max(longestRunSeconds, currentRunSeconds)
        if currentRunSeconds >= Self.alertAfterSeconds, !countedThisRun {
            countedThisRun = true
            monologueCount += 1
        }
        if currentRunSeconds >= Self.alertAfterSeconds, !alertedThisRun {
            alertedThisRun = true
            return true
        }
        return false
    }

    private mutating func endRun() {
        currentRunSeconds = 0
        ownSilence = 0
        alertedThisRun = false
        countedThisRun = false
    }
}

public enum MeetingPaceBand: String, Codable, Equatable, Sendable {
    case slow
    case comfortable
    case fast

    /// Conversational English usually runs at 120–160 words a minute.
    public static func band(wordsPerMinute: Double) -> Self {
        if wordsPerMinute < 100 { return .slow }
        if wordsPerMinute > 175 { return .fast }
        return .comfortable
    }
}

/// Your speaking pace, from on-device transcription of your microphone,
/// measured over the time you were actually speaking.
public struct MeetingSpeakingPace: Equatable, Sendable {
    public static let windowSeconds: TimeInterval = 180
    public static let minimumSpeechSeconds: TimeInterval = 20

    private var samples: [Sample] = []
    public private(set) var totalWords = 0
    public private(set) var totalSpeechSeconds: TimeInterval = 0

    private struct Sample: Equatable, Sendable {
        let at: TimeInterval
        let words: Int
        let speechSeconds: TimeInterval
    }

    public init() {}

    public mutating func ingest(words: Int, speechSeconds: TimeInterval, at elapsed: TimeInterval) {
        guard words >= 0, speechSeconds.isFinite, speechSeconds > 0, elapsed.isFinite else { return }
        samples.append(Sample(at: elapsed, words: words, speechSeconds: speechSeconds))
        samples.removeAll { $0.at < elapsed - Self.windowSeconds }
        totalWords += words
        totalSpeechSeconds += speechSeconds
    }

    /// Recent words per minute of your own speech.
    public var recentWordsPerMinute: Double? {
        Self.rate(words: samples.reduce(0) { $0 + $1.words }, seconds: samples.reduce(0) { $0 + $1.speechSeconds })
    }

    public var averageWordsPerMinute: Double? { Self.rate(words: totalWords, seconds: totalSpeechSeconds) }

    public static func rate(words: Int, seconds: TimeInterval) -> Double? {
        guard seconds >= minimumSpeechSeconds else { return nil }
        return Double(words) / seconds * 60
    }

    /// Words as spoken: runs of letters or digits, keeping contractions whole.
    public static func wordCount(_ text: String) -> Int {
        text.split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "’") }
            .filter { $0.contains { $0.isLetter || $0.isNumber } }.count
    }
}

/// One meeting's private coaching numbers. No words or names, only numbers.
public struct MeetingCoachSummary: Codable, Equatable, Sendable {
    public var durationSeconds: TimeInterval
    public var youSeconds: TimeInterval
    public var othersSeconds: TimeInterval
    public var overlapSeconds: TimeInterval
    public var longestMonologueSeconds: TimeInterval
    public var monologueCount: Int
    public var averageWordsPerMinute: Double?
    public var promptsShown: Int
    /// Experimental on-device AI suggestions shown, and how you rated them.
    public var aiSuggestionsShown: Int
    public var aiHelpfulCount: Int
    public var aiNotHelpfulCount: Int

    public init(
        durationSeconds: TimeInterval, youSeconds: TimeInterval, othersSeconds: TimeInterval, overlapSeconds: TimeInterval,
        longestMonologueSeconds: TimeInterval, monologueCount: Int, averageWordsPerMinute: Double?, promptsShown: Int,
        aiSuggestionsShown: Int = 0, aiHelpfulCount: Int = 0, aiNotHelpfulCount: Int = 0
    ) {
        self.durationSeconds = durationSeconds
        self.youSeconds = youSeconds
        self.othersSeconds = othersSeconds
        self.overlapSeconds = overlapSeconds
        self.longestMonologueSeconds = longestMonologueSeconds
        self.monologueCount = monologueCount
        self.averageWordsPerMinute = averageWordsPerMinute
        self.promptsShown = promptsShown
        self.aiSuggestionsShown = aiSuggestionsShown
        self.aiHelpfulCount = aiHelpfulCount
        self.aiNotHelpfulCount = aiNotHelpfulCount
    }

    public init(durationSeconds: TimeInterval, talkTime: MeetingTalkTime, monologues: MeetingMonologueTracker,
                pace: MeetingSpeakingPace, promptsShown: Int,
                aiSuggestionsShown: Int = 0, aiHelpfulCount: Int = 0, aiNotHelpfulCount: Int = 0) {
        self.init(
            durationSeconds: durationSeconds, youSeconds: talkTime.youSeconds, othersSeconds: talkTime.othersSeconds,
            overlapSeconds: talkTime.overlapSeconds, longestMonologueSeconds: monologues.longestRunSeconds,
            monologueCount: monologues.monologueCount, averageWordsPerMinute: pace.averageWordsPerMinute,
            promptsShown: promptsShown, aiSuggestionsShown: aiSuggestionsShown,
            aiHelpfulCount: aiHelpfulCount, aiNotHelpfulCount: aiNotHelpfulCount
        )
    }

    private enum CodingKeys: String, CodingKey {
        case durationSeconds, youSeconds, othersSeconds, overlapSeconds, longestMonologueSeconds, monologueCount
        case averageWordsPerMinute, promptsShown, aiSuggestionsShown, aiHelpfulCount, aiNotHelpfulCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        durationSeconds = try c.decode(TimeInterval.self, forKey: .durationSeconds)
        youSeconds = try c.decode(TimeInterval.self, forKey: .youSeconds)
        othersSeconds = try c.decode(TimeInterval.self, forKey: .othersSeconds)
        overlapSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .overlapSeconds) ?? 0
        longestMonologueSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .longestMonologueSeconds) ?? 0
        monologueCount = try c.decodeIfPresent(Int.self, forKey: .monologueCount) ?? 0
        averageWordsPerMinute = try c.decodeIfPresent(Double.self, forKey: .averageWordsPerMinute)
        promptsShown = try c.decodeIfPresent(Int.self, forKey: .promptsShown) ?? 0
        aiSuggestionsShown = try c.decodeIfPresent(Int.self, forKey: .aiSuggestionsShown) ?? 0
        aiHelpfulCount = try c.decodeIfPresent(Int.self, forKey: .aiHelpfulCount) ?? 0
        aiNotHelpfulCount = try c.decodeIfPresent(Int.self, forKey: .aiNotHelpfulCount) ?? 0
    }

    public var talkShare: Double? { MeetingTalkTime.share(you: youSeconds, others: othersSeconds) }
}

/// Coaching across recent meetings, newest first.
public struct MeetingCoachTrends: Equatable, Sendable {
    public enum Direction: String, Equatable, Sendable { case up, down, steady }

    public let meetingCount: Int
    public let averageTalkShare: Double?
    public let averageWordsPerMinute: Double?
    public let monologuesPerMeeting: Double
    public let longestMonologueSeconds: TimeInterval
    /// Your talk share in the latest three meetings against the three before.
    public let talkShareDirection: Direction?

    public static let maximumMeetings = 10

    public init(_ summaries: [MeetingCoachSummary]) {
        let recent = Array(summaries.prefix(Self.maximumMeetings))
        meetingCount = recent.count
        averageTalkShare = Self.mean(recent.compactMap(\.talkShare))
        averageWordsPerMinute = Self.mean(recent.compactMap(\.averageWordsPerMinute))
        monologuesPerMeeting = recent.isEmpty ? 0 : Double(recent.reduce(0) { $0 + $1.monologueCount }) / Double(recent.count)
        longestMonologueSeconds = recent.map(\.longestMonologueSeconds).max() ?? 0
        let latest = Self.mean(recent.prefix(3).compactMap(\.talkShare))
        let earlier = Self.mean(recent.dropFirst(3).prefix(3).compactMap(\.talkShare))
        if let latest, let earlier {
            let change = latest - earlier
            talkShareDirection = change > 0.05 ? .up : (change < -0.05 ? .down : .steady)
        } else {
            talkShareDirection = nil
        }
    }

    private static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}

/// When a window of your microphone is worth transcribing for pace and
/// suggestions: enough of your own speech, and not mostly the other side of
/// the call leaking through your speakers.
public enum MeetingLiveTranscriptionPolicy {
    public static let windowSeconds: TimeInterval = 20
    public static let minimumSpeechSeconds: TimeInterval = 5

    public static func shouldTranscribe(youSeconds: TimeInterval, bothSeconds: TimeInterval, othersSeconds: TimeInterval) -> Bool {
        let speech = youSeconds + bothSeconds
        guard speech >= minimumSpeechSeconds else { return false }
        return youSeconds >= 0.6 * (speech + othersSeconds)
    }
}

/// Rules for the experimental on-device AI suggestions. The model only sees
/// your recent words, the goal you typed and a few numbers, and its output
/// is shown only if it is one short, clean sentence.
public enum MeetingCoachSuggestionPolicy {
    public static let minimumNewWords = 60
    public static let minimumIntervalSeconds: TimeInterval = 180
    public static let earliestElapsedSeconds: TimeInterval = 120
    public static let maximumContextWords = 250
    public static let maximumSuggestionCharacters = 140

    public static func shouldRequest(elapsedSeconds: TimeInterval, lastRequestElapsedSeconds: TimeInterval?, newWords: Int) -> Bool {
        guard elapsedSeconds >= earliestElapsedSeconds, newWords >= minimumNewWords else { return false }
        guard let last = lastRequestElapsedSeconds else { return true }
        return elapsedSeconds - last >= minimumIntervalSeconds
    }

    /// The newest words, at most `maximumContextWords` of them.
    public static func context(from fragments: [String]) -> String {
        let words = fragments.joined(separator: " ").split(whereSeparator: \.isWhitespace)
        return words.suffix(maximumContextWords).joined(separator: " ")
    }

    /// A single short sentence, or `nil` for anything else (empty, "none",
    /// several lines, or too long).
    public static func sanitize(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        guard !text.contains("\n") else { return nil }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’*_`- ").union(.whitespaces))
        let lower = text.lowercased().trimmingCharacters(in: .punctuationCharacters)
        guard !lower.isEmpty, !["none", "no suggestion", "n/a", "nothing"].contains(lower) else { return nil }
        guard text.count <= maximumSuggestionCharacters else { return nil }
        if let last = text.last, !".!?".contains(last) { text += "." }
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

/// What the experimental on-device model may recommend. The model only picks
/// one of these; WhiskerFlow owns the wording, so a suggestion can never
/// quote the meeting, name anyone or add facts. Talk time, monologues and
/// pace are measured directly and are not the model's job.
public enum MeetingCoachAdvice: String, CaseIterable, Codable, Sendable {
    case none
    case reduceFillerWords
    case agreeOwnersAndDates
    case returnToGoal
    case acknowledgeConcerns
    case simplifyLanguage
    case askForInput
    case summariseSoFar

    public func message(goal: String) -> String? {
        switch self {
        case .none: return nil
        case .reduceFillerWords: return "Try a short pause instead of filler words."
        case .agreeOwnersAndDates: return "Pin down an owner and a date for each next step."
        case .returnToGoal:
            let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let short = trimmed.count > 60 ? String(trimmed.prefix(59)) + "…" : trimmed
            return "Steer back to your goal: \(short)"
        case .acknowledgeConcerns: return "Acknowledge their concern before explaining your side."
        case .simplifyLanguage: return "Try saying that in plainer words."
        case .askForInput: return "Ask a question to hear what the others think."
        case .summariseSoFar: return "Pause and summarise what’s been agreed so far."
        }
    }
}

/// Countable signals in your own recent words, computed without a model.
public enum MeetingCoachTextSignals {
    static let singleFillers: Set<String> = ["um", "umm", "uh", "uhh", "erm", "er", "ah", "hmm", "basically", "literally"]
    static let phraseFillers = ["you know", "sort of", "kind of", "i mean"]

    /// Filler words per 100 words.
    public static func fillerRate(_ text: String) -> Double {
        let words = normalizedWords(text)
        guard !words.isEmpty else { return 0 }
        var count = words.filter { singleFillers.contains($0) }.count
        let joined = " " + words.joined(separator: " ") + " "
        for phrase in phraseFillers {
            count += joined.components(separatedBy: " \(phrase) ").count - 1
        }
        // "like" is a filler only when set off as its own clause: ", like,".
        count += text.lowercased().components(separatedBy: ", like,").count - 1
        return Double(count) / Double(words.count) * 100
    }

    public static func questionCount(_ text: String) -> Int { text.filter { $0 == "?" }.count }

    static let vaguePhrases = [
        "someone should", "somebody should", "at some point", "circle back", "look into it", "look into that",
        "we should probably", "down the line", "revisit it", "revisit that", "sometime next", "when things calm down",
        "we'll figure it out", "we'll see", "one of us should", "at a later date",
    ]

    /// Phrases that leave a next step without an owner or a date.
    public static func vagueCommitmentCount(_ text: String) -> Int {
        let lower = " " + normalizedWords(text).joined(separator: " ").replacingOccurrences(of: "’", with: "'") + " "
        return vaguePhrases.reduce(0) { $0 + lower.components(separatedBy: " \($1) ").count - 1 }
    }

    static func normalizedWords(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0 == "'" || $0 == "’") }.map(String.init)
    }
}

/// The on-device model's yes/no judgements about your recent words.
public struct MeetingCoachJudgement: Equatable, Sendable {
    public var vagueNextSteps: Bool
    public var defensiveTone: Bool
    public var offGoal: Bool
    public var heavyJargon: Bool

    public init(vagueNextSteps: Bool = false, defensiveTone: Bool = false, offGoal: Bool = false, heavyJargon: Bool = false) {
        self.vagueNextSteps = vagueNextSteps
        self.defensiveTone = defensiveTone
        self.offGoal = offGoal
        self.heavyJargon = heavyJargon
    }

    /// Combines the judgements with the countable signals into one piece of
    /// advice, most important first.
    public static func advice(judgement: MeetingCoachJudgement?, recentWords: String, goal: String) -> MeetingCoachAdvice {
        let wordCount = MeetingCoachTextSignals.normalizedWords(recentWords).count
        let hasGoal = !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if judgement?.defensiveTone == true { return .acknowledgeConcerns }
        // Counted phrases are firmer evidence than the model's topic judgement.
        if judgement?.vagueNextSteps == true || MeetingCoachTextSignals.vagueCommitmentCount(recentWords) >= 2 {
            return .agreeOwnersAndDates
        }
        if hasGoal, judgement?.offGoal == true { return .returnToGoal }
        if wordCount >= 30, MeetingCoachTextSignals.fillerRate(recentWords) >= 8 { return .reduceFillerWords }
        if judgement?.heavyJargon == true { return .simplifyLanguage }
        if wordCount >= 120, MeetingCoachTextSignals.questionCount(recentWords) == 0 { return .askForInput }
        return .none
    }
}
