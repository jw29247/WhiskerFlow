import Foundation

/// A calendar date as the user saw it when they dictated: the Gregorian
/// year-month-day in the time zone of that moment. Insights store days, not
/// instants, so a streak is about the user's own days — a 23-hour DST day or a
/// flight across time zones never splits or merges them. Arithmetic runs on a
/// fixed UTC calendar, where every day is exactly one day long.
public struct LocalDay: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The day `date` falls on in `calendar`'s time zone.
    public init(_ date: Date, calendar: Calendar) {
        let components = Self.gregorian(in: calendar.timeZone).dateComponents([.year, .month, .day], from: date)
        self.init(year: components.year ?? 1970, month: components.month ?? 1, day: components.day ?? 1)
    }

    /// Parses the `yyyy-MM-dd` storage key.
    public init?(key: String) {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        self.init(year: parts[0], month: parts[1], day: parts[2])
    }

    public var key: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public var description: String { key }

    /// Noon UTC on this date: a stable instant for arithmetic and weekday lookup.
    private var referenceDate: Date {
        Self.utc.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? Date(timeIntervalSince1970: 0)
    }

    public func adding(days: Int) -> LocalDay {
        let date = Self.utc.date(byAdding: .day, value: days, to: referenceDate) ?? referenceDate
        let components = Self.utc.dateComponents([.year, .month, .day], from: date)
        return LocalDay(year: components.year ?? year, month: components.month ?? month, day: components.day ?? day)
    }

    /// Whole days from `other` to `self` (positive when `self` is later).
    public func days(since other: LocalDay) -> Int {
        Self.utc.dateComponents([.day], from: other.referenceDate, to: referenceDate).day ?? 0
    }

    /// 1 = Sunday … 7 = Saturday, matching `Calendar.firstWeekday`.
    public var weekday: Int {
        Self.utc.component(.weekday, from: referenceDate)
    }

    /// The first day of the week containing `self`, per `calendar.firstWeekday`.
    public func startOfWeek(firstWeekday: Int) -> LocalDay {
        adding(days: -((weekday - firstWeekday + 7) % 7))
    }

    public var startOfMonth: LocalDay { LocalDay(year: year, month: month, day: 1) }

    public static func < (lhs: LocalDay, rhs: LocalDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    /// The local hour (0–23) of `date` in `calendar`'s time zone.
    public static func hour(of date: Date, calendar: Calendar) -> Int {
        gregorian(in: calendar.timeZone).component(.hour, from: date)
    }

    private static let utc: Calendar = gregorian(in: TimeZone(identifier: "UTC")!)

    private static func gregorian(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}
