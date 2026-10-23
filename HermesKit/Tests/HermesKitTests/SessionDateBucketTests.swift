import Foundation
import Testing

@testable import HermesKit

/// Port of the desktop's `apps/desktop/src/lib/time.test.ts` `calendarBucket` /
/// `sessionBucketLabel` / `nominalDayStart` cases, on a Gregorian calendar pinned to a
/// fixed time zone + locale so the results never depend on the host. Months here are
/// 1-based (the desktop's JS dates are 0-based).
struct SessionDateBucketTests {
  /// Gregorian, New York (a DST zone), en_US, with an explicit first weekday
  /// (1 = Sunday, 2 = Monday).
  static func calendar(firstWeekday: Int = 2) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    calendar.locale = Locale(identifier: "en_US")
    calendar.firstWeekday = firstWeekday
    return calendar
  }

  static func date(
    _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 10, _ minute: Int = 0,
    calendar: Calendar = calendar()
  ) -> Date {
    calendar.date(from: DateComponents(
      year: year, month: month, day: day, hour: hour, minute: minute
    ))!
  }

  /// Thursday 18 Jun 2026, local noon (15 Jun 2026 is a Monday).
  static let thuNoon = date(2026, 6, 18, 12)

  private func kind(
    _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 10,
    now: Date = thuNoon, firstWeekday: Int = 2
  ) -> SessionDateBucket.Kind {
    SessionDateBucket.bucket(
      for: Self.date(year, month, day, hour), now: now,
      calendar: Self.calendar(firstWeekday: firstWeekday)
    ).kind
  }

  private func bucket(_ year: Int, _ month: Int, _ day: Int) -> SessionDateBucket {
    SessionDateBucket.bucket(
      for: Self.date(year, month, day), now: Self.thuNoon, calendar: Self.calendar()
    )
  }

  // MARK: - nominalDayStart

  @Test func dayBoundaryRollsAtFourAMNotMidnight() {
    let calendar = Self.calendar()
    // 1 AM Saturday still belongs to Friday's run.
    #expect(
      SessionDateBucket.nominalDayStart(Self.date(2026, 6, 20, 1, 30), calendar: calendar)
        == Self.date(2026, 6, 19, 0)
    )
    #expect(
      SessionDateBucket.nominalDayStart(Self.date(2026, 6, 20, 4, 30), calendar: calendar)
        == Self.date(2026, 6, 20, 0)
    )
    #expect(SessionDateBucket.dayRolloverHour == 4)
  }

  @Test func anchorIsTheNominalDayStart() {
    #expect(bucket(2026, 5, 28).anchor == Self.date(2026, 5, 28, 0))
  }

  // MARK: - Kinds

  @Test func currentDayAndFutureBucketAsToday() {
    #expect(kind(2026, 6, 18, 5) == .today)
    #expect(kind(2026, 6, 18, 23) == .today)
    #expect(kind(2026, 6, 19) == .today) // future, defensively
  }

  @Test func smallHoursBelongToThePreviousEvening() {
    // 1 AM today (before the 4 AM rollover) is part of yesterday's run.
    #expect(kind(2026, 6, 18, 1) == .yesterday)

    // Viewed at 00:58, last evening's sessions are still the current day.
    let smallHours = Self.date(2026, 6, 19, 0, 58)
    #expect(kind(2026, 6, 18, 23, now: smallHours) == .today)
    #expect(kind(2026, 6, 18, 10, now: smallHours) == .today)
    #expect(kind(2026, 6, 17, 15, now: smallHours) == .yesterday)
  }

  @Test func rangesCoarsenWithAgeOnAMondayWeek() {
    #expect(kind(2026, 6, 17) == .yesterday)
    #expect(kind(2026, 6, 16) == .thisWeek) // Tue this week
    #expect(kind(2026, 6, 15) == .thisWeek) // Mon this week
    #expect(kind(2026, 6, 14) == .lastWeek) // Sun last week
    #expect(kind(2026, 6, 8) == .lastWeek) // Mon last week
    #expect(kind(2026, 6, 7) == .thisMonth) // earlier in June
    #expect(kind(2026, 6, 1) == .thisMonth)
    #expect(kind(2026, 5, 28) == .month) // May, same year
    #expect(kind(2025, 12, 3) == .monthYear) // December, prior year
  }

  @Test func respectsASundayWeekStart() {
    // With the week starting Sun 14 Jun, that Sunday is this week, not last.
    #expect(kind(2026, 6, 14, firstWeekday: 1) == .thisWeek)
    #expect(kind(2026, 6, 13, firstWeekday: 1) == .lastWeek)
    #expect(kind(2026, 6, 7, firstWeekday: 1) == .lastWeek) // Sun of last week
    #expect(kind(2026, 6, 6, firstWeekday: 1) == .thisMonth)
  }

  @Test func dayDiffIsCalendarAwareAcrossDST() {
    // US DST began Sun 8 Mar 2026 (a 23-hour day) — still exactly one day back.
    let monday = Self.date(2026, 3, 9, 12)
    #expect(kind(2026, 3, 8, 10, now: monday) == .yesterday)
    #expect(kind(2026, 3, 7, 10, now: monday) == .lastWeek)
  }

  // MARK: - Keys

  @Test func relativeBucketsHaveFixedKeys() {
    #expect(bucket(2026, 6, 18).key == "today")
    #expect(bucket(2026, 6, 17).key == "yesterday")
    #expect(bucket(2026, 6, 16).key == "this-week")
    #expect(bucket(2026, 6, 10).key == "last-week")
    #expect(bucket(2026, 6, 2).key == "this-month")
  }

  @Test func sameMonthSessionsShareAKeyAndYearsDisambiguate() {
    #expect(bucket(2026, 2, 3).key == "m-2026-2")
    #expect(bucket(2026, 2, 20).key == "m-2026-2")
    #expect(bucket(2025, 2, 3).key == "my-2025-2")
  }

  // MARK: - Labels

  @Test func relativeBucketsUseFixedLabels() {
    let calendar = Self.calendar()
    #expect(bucket(2026, 6, 18).label(calendar: calendar) == "Today")
    #expect(bucket(2026, 6, 17).label(calendar: calendar) == "Yesterday")
    #expect(bucket(2026, 6, 16).label(calendar: calendar) == "Earlier this week")
    #expect(bucket(2026, 6, 10).label(calendar: calendar) == "Last week")
    #expect(bucket(2026, 6, 2).label(calendar: calendar) == "Earlier this month")
  }

  @Test func monthBucketsFormatMonthAndMonthYear() {
    let calendar = Self.calendar()
    let month = bucket(2026, 3, 3)
    #expect(month.kind == .month)
    #expect(month.label(calendar: calendar) == "March")

    let monthYear = bucket(2025, 12, 3)
    #expect(monthYear.kind == .monthYear)
    #expect(monthYear.label(calendar: calendar) == "December 2025")
  }

  @Test func monthLabelsFollowTheCalendarLocale() {
    var calendar = Self.calendar()
    calendar.locale = Locale(identifier: "de_DE")
    #expect(bucket(2026, 3, 3).label(calendar: calendar) == "März")
  }
}
