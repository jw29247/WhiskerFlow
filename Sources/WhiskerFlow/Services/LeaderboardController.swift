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
    @ObservationIgnored private var showsPreview = false

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

    func startPeriodicReporting() {
        guard periodic == nil else { return }
        periodic = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.report()
                try? await Task.sleep(nanoseconds: Self.reportIntervalNanoseconds)
            }
        }
    }

    /// Sends the days Atlas doesn't have yet. Returns whether it succeeded;
    /// a failure is retried on the next report.
    @discardableResult
    func report() async -> Bool {
        if let reporting { return await reporting.value }
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self, let client = self.client() else { return false }
            let today = self.today
            let days = LeaderboardReport.daysToSend(self.usageDays(self.meetingTally), reportedThrough: self.reportedThrough, today: today)
            do {
                for start in stride(from: 0, to: days.count, by: LeaderboardReport.maximumDaysPerRequest) {
                    let end = min(start + LeaderboardReport.maximumDaysPerRequest, days.count)
                    _ = try await client.report(Array(days[start..<end]))
                }
                self.reportedThrough = today
                return true
            } catch {
                return false
            }
        }
        reporting = task
        let succeeded = await task.value
        reporting = nil
        return succeeded
    }

    /// Reports, then reads the board for the current window.
    func refresh() async {
        guard !showsPreview else { return }
        guard let client = client() else {
            errorMessage = LeaderboardClientError.signedOut.errorDescription
            return
        }
        isLoading = true
        defer { isLoading = false }
        await report()
        let today = self.today
        do {
            board = try await client.board(today: today, since: window.since(today: today, firstWeekday: calendar().firstWeekday))
            updatedAt = now()
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Atlas couldn't load the leaderboard."
        }
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
        static let meetingTally = "leaderboardMeetingTally"
        static let meetingsSeeded = "leaderboardMeetingsSeeded"
    }
}
