import Foundation

/// Formats a note's modified date the way Notes does (S-9): `Today 11:53` and
/// `Yesterday 09:10` with the time in the locale's own format, a short weekday name (`Mon`)
/// for the five days before that, `3 Sep` for anything else in the current year and
/// `3 Sep 2025` otherwise. Bands are calendar days in the calendar's time zone, so a note
/// saved at 23:59 is `Yesterday` one minute later.
///
/// `now` is a parameter of `string(for:now:)` rather than read inside, so the bands can be
/// tested and so the list can refresh every row against one instant on a day change (M6.5).
/// Formatters are built once; a `DateFormatter` costs more to make than to use, and the list
/// formats every visible row on each reload (PF-2).
@MainActor
public final class RelativeDateText {
    public let calendar: Calendar
    public let locale: Locale

    private let time: DateFormatter
    private let weekday: DateFormatter
    private let dayMonth: DateFormatter
    private let dayMonthYear: DateFormatter

    /// The locale decides the time format (`11:53` or `11:53 AM`), the month and weekday
    /// names and their order around the day; the calendar decides where days begin.
    public init(calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) {
        var calendar = calendar
        calendar.locale = locale
        self.calendar = calendar
        self.locale = locale
        time = Self.formatter(template: "jmm", calendar: calendar, locale: locale)
        weekday = Self.formatter(template: "EEE", calendar: calendar, locale: locale)
        dayMonth = Self.formatter(template: "dMMM", calendar: calendar, locale: locale)
        dayMonthYear = Self.formatter(template: "dMMMy", calendar: calendar, locale: locale)
    }

    /// The text for `date` as seen from `now`.
    public func string(for date: Date, now: Date = Date()) -> String {
        switch band(of: date, now: now) {
        case .today: return "Today " + time.string(from: date)
        case .yesterday: return "Yesterday " + time.string(from: date)
        case .weekday: return weekday.string(from: date)
        case .thisYear: return dayMonth.string(from: date)
        case .otherYear: return dayMonthYear.string(from: date)
        }
    }

    /// Which of S-9's forms a date takes, seen from `now`.
    public enum Band: Equatable, Sendable {
        case today, yesterday, weekday, thisYear, otherYear
    }

    public func band(of date: Date, now: Date) -> Band {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        // Whole days between the two midnights; a date later today is still today, and a
        // date in the future (a clock set back, a file stamped ahead) falls through to
        // the absolute forms rather than a weekday that reads as last week.
        let daysAgo = calendar.dateComponents([.day], from: day, to: today).day ?? .max
        switch daysAgo {
        case 0: return .today
        case 1: return .yesterday
        case 2...6: return .weekday
        default:
            return calendar.component(.year, from: date) == calendar.component(.year, from: now)
                ? .thisYear : .otherYear
        }
    }

    private static func formatter(template: String, calendar: Calendar, locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }
}
