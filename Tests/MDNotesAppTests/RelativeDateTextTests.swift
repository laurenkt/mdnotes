import Foundation
import MDNotesApp
import XCTest

/// `RelativeDateText` (S-9): one test per band, the band edges, and the year boundary.
/// The calendar is pinned to Gregorian in UTC and the locale to en_GB so the strings are
/// the same on every machine; a second locale checks the time and month forms follow it.
@MainActor
final class RelativeDateTextTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()
    private lazy var text = RelativeDateText(calendar: calendar, locale: Locale(identifier: "en_GB"))

    /// Wednesday 3 September 2025, 11:53 UTC.
    private lazy var now = date(2025, 9, 3, 11, 53)

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        guard let date = calendar.date(from: components) else {
            XCTFail("no date for \(components)")
            return .distantPast
        }
        return date
    }

    // MARK: Today and Yesterday carry the time

    func testS9_todayIsTheWordAndTheTime() {
        XCTAssertEqual(text.string(for: now, now: now), "Today 11:53")
        XCTAssertEqual(text.string(for: date(2025, 9, 3, 0, 0), now: now), "Today 00:00", "midnight starts today")
        XCTAssertEqual(
            text.string(for: date(2025, 9, 3, 23, 59), now: now), "Today 23:59", "later today is still today")
    }

    func testS9_yesterdayIsTheWordAndTheTime() {
        XCTAssertEqual(text.string(for: date(2025, 9, 2, 9, 10), now: now), "Yesterday 09:10")
        XCTAssertEqual(
            text.string(for: date(2025, 9, 2, 23, 59), now: date(2025, 9, 3, 0, 0)), "Yesterday 23:59",
            "a minute across midnight is yesterday: bands are calendar days, not 24-hour spans")
    }

    // MARK: Weekday names for the five days before yesterday

    func testS9_weekdayWithinTheLastSixDays() {
        XCTAssertEqual(text.string(for: date(2025, 9, 1, 8, 0), now: now), "Mon", "two days ago")
        XCTAssertEqual(text.string(for: date(2025, 8, 31), now: now), "Sun")
        XCTAssertEqual(text.string(for: date(2025, 8, 30), now: now), "Sat")
        XCTAssertEqual(text.string(for: date(2025, 8, 29), now: now), "Fri")
        XCTAssertEqual(text.string(for: date(2025, 8, 28, 23, 59), now: now), "Thu", "six days ago, last of the band")
    }

    func testS9_sevenDaysAgoIsADateNotAWeekday() {
        XCTAssertEqual(
            text.string(for: date(2025, 8, 27, 23, 59), now: now), "27 Aug",
            "a week ago would read as the same weekday as today")
    }

    // MARK: Dates this year and other years

    func testS9_dayAndMonthWithinTheCurrentYear() {
        XCTAssertEqual(text.string(for: date(2025, 3, 3, 15, 0), now: now), "3 Mar")
        XCTAssertEqual(text.string(for: date(2025, 1, 1), now: now), "1 Jan", "the first day of the year is this year")
        XCTAssertEqual(
            text.string(for: date(2025, 12, 25), now: now), "25 Dec", "a future date this year gets no weekday")
    }

    func testS9_dayMonthAndYearOtherwise() {
        XCTAssertEqual(text.string(for: date(2024, 3, 3, 15, 0), now: now), "3 Mar 2024")
        XCTAssertEqual(text.string(for: date(2024, 12, 31, 23, 59), now: now), "31 Dec 2024", "last day of last year")
        XCTAssertEqual(text.string(for: date(2026, 1, 1), now: now), "1 Jan 2026", "next year is another year")
    }

    // MARK: The year boundary

    func testS9_yearBoundary_relativeBandsCrossItAndAbsoluteOnesDoNot() {
        let january = date(2026, 1, 2, 10, 0)  // Friday 2 January 2026
        XCTAssertEqual(text.string(for: date(2026, 1, 2, 9, 0), now: january), "Today 09:00")
        XCTAssertEqual(text.string(for: date(2026, 1, 1, 9, 0), now: january), "Yesterday 09:00")
        XCTAssertEqual(text.string(for: date(2025, 12, 31, 9, 0), now: january), "Wed", "last year, but two days ago")
        XCTAssertEqual(text.string(for: date(2025, 12, 27, 9, 0), now: january), "Sat", "six days ago, across the year")
        XCTAssertEqual(text.string(for: date(2025, 12, 26, 9, 0), now: january), "26 Dec 2025", "a week ago: last year")
        XCTAssertEqual(text.string(for: date(2026, 1, 1, 0, 0), now: date(2026, 1, 20)), "1 Jan", "this year, no year")
    }

    func testS9_bandsAreCalendarDaysInTheCalendarsTimeZone() throws {
        var sydney = Calendar(identifier: .gregorian)
        sydney.timeZone = try XCTUnwrap(TimeZone(identifier: "Australia/Sydney"))
        let local = RelativeDateText(calendar: sydney, locale: Locale(identifier: "en_GB"))
        // 23:30 UTC on 2 Sep is 09:30 on 3 Sep in Sydney: today there, yesterday in UTC.
        let stamp = date(2025, 9, 2, 23, 30)
        XCTAssertEqual(local.string(for: stamp, now: now), "Today 09:30")
        XCTAssertEqual(text.string(for: stamp, now: now), "Yesterday 23:30")
    }

    // MARK: Locale

    func testS9_timeAndDateFormsFollowTheLocale() {
        let us = RelativeDateText(calendar: calendar, locale: Locale(identifier: "en_US"))
        let today = us.string(for: now, now: now)
        XCTAssertTrue(today.hasPrefix("Today 11:53"), today)
        XCTAssertTrue(today.hasSuffix("AM"), "en_US uses a 12-hour clock: \(today)")
        XCTAssertEqual(us.string(for: date(2025, 3, 3), now: now), "Mar 3", "month before day")
        XCTAssertEqual(us.string(for: date(2024, 3, 3), now: now), "Mar 3, 2024")
        XCTAssertEqual(us.string(for: date(2025, 9, 1), now: now), "Mon")

        let german = RelativeDateText(calendar: calendar, locale: Locale(identifier: "de_DE"))
        XCTAssertTrue(
            german.string(for: date(2025, 9, 1), now: now).hasPrefix("Mo"), "weekday names are localised")
        XCTAssertEqual(german.string(for: date(2024, 3, 3), now: now), "3. März 2024")
    }

    func testS9_bandIsExposedForTheListsRefresh() {
        XCTAssertEqual(text.band(of: now, now: now), .today)
        XCTAssertEqual(text.band(of: date(2025, 9, 2), now: now), .yesterday)
        XCTAssertEqual(text.band(of: date(2025, 8, 28), now: now), .weekday)
        XCTAssertEqual(text.band(of: date(2025, 8, 27), now: now), .thisYear)
        XCTAssertEqual(text.band(of: date(2024, 8, 27), now: now), .otherYear)
    }
}
