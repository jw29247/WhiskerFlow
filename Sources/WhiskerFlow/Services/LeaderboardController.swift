import Foundation
import Observation
import WhiskerFlowCore

/// Reports this Mac's daily counts to Atlas and reads the company board.
@MainActor
@Observable
final class LeaderboardController {
    static let reportIntervalNanoseconds: UInt64 = 15 * 60 * 1_000_000_000

    var window: LeaderboardWindow = .week { didSet { if window != oldValue { Task { await refresh() } } } }
    var metric: LeaderboardMetric = .words
    private(set) var board: LeaderboardBoard?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var updatedAt: Date?

    var rows: [LeaderboardRanking.Row] { LeaderboardRanking.ranked(board?.entries ?? [], by: metric) }

    @ObservationIgnored private let client: () -> LeaderboardAtlasClient?
    @ObservationIgnored private let usageDays: (MeetingTally) -> [LeaderboardDay]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let calendar: () -> Calendar
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var reporting: Task<Bool, Never>?
    @ObservationIgnored private var periodic: Task<Void, Never>?
    /// What Atlas has accepted for each day in this launch, so the periodic
    /// report can skip a resend.
    @ObservationIgnored private var acceptedDays: [String: LeaderboardDay] = [:]
    @ObservationIgnored private var showsPreview = false
    /// Bumped by `signOut()`, so a board or report still in flight is dropped.
    @ObservationIgnored private var accountGeneration = 0

    init(
        client: @escaping () -> LeaderboardAtlasClient?,
        usageDays: @escaping (MeetingTally) -> [LeaderboardDay],
        defaults: UserDefaults = .standard,
        calendar: @escaping () -> Calendar = { .autoupdatingCurrent },
        now: @escaping () -> Date = Date.init
    ) {
        self.client = client
        self.usageDays = usageDays
        self.defaults = defaults
        self.calendar = calendar
        self.now = now
    }

    private var today: LocalDay { LocalDay(now(), calendar: calendar()) }

    /// The last day Atlas has a report for.
    private var reportedThrough: LocalDay? {
        get { defaults.string(forKey: Keys.reportedThrough).flatMap(LocalDay.init(key:)) }
        set { defaults.set(newValue?.key, forKey: Keys.reportedThrough) }
    }

    /// The first day any report may include, set by `signOut()`. Unlike
    /// `reportedThrough`, which every report advances, it never moves on, so
    /// days from before a sign-out are never sent to a later sign-in.
    private var reportsFrom: LocalDay? {
        get { defaults.string(forKey: Keys.reportsFrom).flatMap(LocalDay.init(key:)) }
        set { defaults.set(newValue?.key, forKey: Keys.reportsFrom) }
    }

    // MARK: - Meetings

    /// Counts a finished meeting recording towards its day.
    func recordMeeting(startedAt: Date, durationMs: Int64) {
        var tally = meetingTally
        tally.record(day: LocalDay(startedAt, calendar: calendar()), durationSeconds: Int(durationMs / 1_000))
        meetingTally = tally
    }

    /// Seeds the tally once from the meetings this Mac still keeps.
    func seedMeetingsIfNeeded(_ meetings: [(startedAt: Date, durationMs: Int64)]) {
        guard !defaults.bool(forKey: Keys.meetingsSeeded) else { return }
        defaults.set(true, forKey: Keys.meetingsSeeded)
        for meeting in meetings { recordMeeting(startedAt: meeting.startedAt, durationMs: meeting.durationMs) }
    }

    var meetingTally: MeetingTally {
        get { defaults.data(forKey: Keys.meetingTally).flatMap { try? JSONDecoder().decode(MeetingTally.self, from: $0) } ?? MeetingTally() }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Keys.meetingTally) }
    }

    // MARK: - Reporting

    var isReportingPeriodically: Bool { periodic != nil }

    func startPeriodicReporting() {
        guard periodic == nil else { return }
        periodic = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.report(onlyIfChanged: true)
                try? await Task.sleep(for: .nanoseconds(Self.reportIntervalNanoseconds), tolerance: .seconds(60))
            }
        }
    }

    /// Sends the days Atlas doesn't have yet. Returns whether it succeeded;
    /// a failure is retried on the next report. `onlyIfChanged` (the periodic
    /// report) sends nothing when the days are the ones Atlas last accepted.
    @discardableResult
    func report(onlyIfChanged: Bool = false) async -> Bool {
        if let reporting { return await reporting.value }
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self, let client = self.client() else { return false }
            let generation = self.accountGeneration
            let today = self.today
            let boundary = self.reportsFrom
            let days = LeaderboardReport.daysToSend(self.usageDays(self.meetingTally), reportedThrough: self.reportedThrough, today: today)
                .filter { day in boundary.map { day.day >= $0 } ?? true }
            if onlyIfChanged, !days.isEmpty, days.allSatisfy({ self.acceptedDays[$0.day.key] == $0 }) { return true }
            do {
                for start in stride(from: 0, to: days.count, by: LeaderboardReport.maximumDaysPerRequest) {
                    let end = min(start + LeaderboardReport.maximumDaysPerRequest, days.count)
                    _ = try await client.report(Array(days[start..<end]))
                }
                guard generation == self.accountGeneration else { return false }
                self.reportedThrough = today
                for day in days { self.acceptedDays[day.day.key] = day }
                return true
            } catch {
                return false
            }
        }
        reporting = task
        let succeeded = await task.value
        if reporting == task { reporting = nil }
        return succeeded
    }

    /// Reports, then reads the board for the current window.
    func refresh() async {
        guard !showsPreview else { return }
        guard let client = client() else {
            errorMessage = LeaderboardClientError.signedOut.errorDescription
            return
        }
        let generation = accountGeneration
        isLoading = true
        defer { if generation == accountGeneration { isLoading = false } }
        await report()
        let today = self.today
        do {
            let board = try await client.board(today: today, since: window.since(today: today, firstWeekday: calendar().firstWeekday))
            guard generation == accountGeneration else { return }
            self.board = board
            updatedAt = now()
            errorMessage = nil
        } catch {
            guard generation == accountGeneration else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Atlas couldn't load the leaderboard."
        }
    }

    /// Sign-out: stops reporting and forgets the board. From now on no report
    /// includes a day before today, so earlier days not yet reported stay
    /// unreported and are never sent to a later sign-in. Today's total is
    /// whole-day usage and can include use from before the sign-out; that is
    /// accepted. The meeting tally is this Mac's own count and stays.
    func signOut() {
        accountGeneration &+= 1
        acceptedDays = [:]
        periodic?.cancel()
        periodic = nil
        reporting?.cancel()
        reporting = nil
        board = nil
        errorMessage = nil
        updatedAt = nil
        isLoading = false
        reportsFrom = today
    }

    #if DEBUG
    func insertForPreview(_ board: LeaderboardBoard) {
        showsPreview = true
        self.board = board
        updatedAt = now()
    }
    #endif

    private enum Keys {
        static let reportedThrough = "leaderboardReportedThrough"
        static let reportsFrom = "leaderboardReportsFrom"
        static let meetingTally = "leaderboardMeetingTally"
        static let meetingsSeeded = "leaderboardMeetingsSeeded"
    }
}
