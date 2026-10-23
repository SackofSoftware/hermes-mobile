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

  @Test func rolloverStaysAtFourAMWallClockAcrossSpringForward() {
    // US DST began Sun 8 Mar 2026 at 2 AM (clocks jump to 3 AM EDT).
    let calendar = Self.calendar()
    #expect(
      SessionDateBucket.nominalDayStart(Self.date(2026, 3, 8, 4, 30), calendar: calendar)
        == Self.date(2026, 3, 8, 0)
    )
    #expect(
      SessionDateBucket.nominalDayStart(Self.date(2026, 3, 8, 3, 30), calendar: calendar)
        == Self.date(2026, 3, 7, 0)
    )
  }

  @Test func rolloverStaysAtFourAMWallClockAcrossFallBack() {
    // US DST ended Sun 1 Nov 2026 at 2 AM (clocks fall back to 1 AM EST).
    let calendar = Self.calendar()
    #expect(
      SessionDateBucket.nominalDayStart(Self.date(2026, 11, 1, 3, 30), calendar: calendar)
        == Self.date(2026, 10, 31, 0)
    )
    #expect(
      SessionDateBucket.nominalDayStart(Self.date(2026, 11, 1, 4, 0), calendar: calendar)
        == Self.date(2026, 11, 1, 0)
    )
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

  @Test func lastWeekReachesBackAcrossAMonthBoundary() {
    // Wed 3 Jun 2026: last week (Mon 25 – Sun 31 May) wins over the May month bucket.
    let wednesday = Self.date(2026, 6, 3, 12)
    #expect(kind(2026, 5, 27, now: wednesday) == .lastWeek)
    #expect(kind(2026, 5, 25, now: wednesday) == .lastWeek)
    #expect(kind(2026, 5, 24, now: wednesday) == .month)
  }

  @Test func weekRangesReachBackAcrossAYearBoundary() {
    // Fri 2 Jan 2026: this week starts Mon 29 Dec 2025, last week Mon 22 Dec 2025.
    let friday = Self.date(2026, 1, 2, 12)
    #expect(kind(2025, 12, 29, now: friday) == .thisWeek)
    #expect(kind(2025, 12, 22, now: friday) == .lastWeek)
    #expect(kind(2025, 12, 21, now: friday) == .monthYear)
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

  @Test func leapMonthsAreDistinctFromTheirNamesake() {
    // Chinese 2025 has a leap 6th month (25 Jul – 22 Aug); 10 Jul is the regular 6th.
    var chinese = Calendar(identifier: .chinese)
    chinese.timeZone = TimeZone(identifier: "America/New_York")!
    chinese.locale = Locale(identifier: "en_US")
    chinese.firstWeekday = 2
    let inLeapMonth = Self.date(2025, 8, 15, 12)  // Friday
    let regular = SessionDateBucket.bucket(
      for: Self.date(2025, 7, 10), now: inLeapMonth, calendar: chinese
    )
    let leap = SessionDateBucket.bucket(
      for: Self.date(2025, 8, 1), now: inLeapMonth, calendar: chinese
    )
    #expect(regular.kind == .month)
    #expect(leap.kind == .thisMonth)

    let later = Self.date(2025, 9, 30, 12)
    let regularLater = SessionDateBucket.bucket(
      for: Self.date(2025, 7, 10), now: later, calendar: chinese
    )
    let leapLater = SessionDateBucket.bucket(
      for: Self.date(2025, 8, 1), now: later, calendar: chinese
    )
    #expect(regularLater.kind == .month)
    #expect(leapLater.kind == .month)
    #expect(regularLater.key != leapLater.key)
  }

  @Test func erasAreDistinctEvenWithMatchingYearNumbers() {
    // Japanese: June 1989 is Heisei 1, June 2019 is Reiwa 1 — same year and month numbers.
    var japanese = Calendar(identifier: .japanese)
    japanese.timeZone = TimeZone(identifier: "America/New_York")!
    japanese.locale = Locale(identifier: "en_US")
    let now = Self.date(2019, 6, 28, 12)
    let heisei = SessionDateBucket.bucket(
      for: Self.date(1989, 6, 1), now: now, calendar: japanese
    )
    let reiwa = SessionDateBucket.bucket(
      for: Self.date(2019, 6, 1), now: now, calendar: japanese
    )
    #expect(heisei.kind == .monthYear)
    #expect(reiwa.kind == .thisMonth)
  }

  @Test func otherErasTagTheirKey() {
    // Now Reiwa 2 (2020): Heisei 2 (1990) and Showa 2 (1927) June must not share a key.
    var japanese = Calendar(identifier: .japanese)
    japanese.timeZone = TimeZone(identifier: "America/New_York")!
    japanese.locale = Locale(identifier: "en_US")
    let now = Self.date(2020, 6, 28, 12)
    let heisei = SessionDateBucket.bucket(for: Self.date(1990, 6, 1), now: now, calendar: japanese)
    let showa = SessionDateBucket.bucket(for: Self.date(1927, 6, 1), now: now, calendar: japanese)
    #expect(heisei.kind == .monthYear)
    #expect(showa.kind == .monthYear)
    #expect(heisei.key != showa.key)
  }

  // MARK: - Labels

  @Test func relativeBucketsUseFixedLabels() {
    #expect(bucket(2026, 6, 18).label == "Today")
    #expect(bucket(2026, 6, 17).label == "Yesterday")
    #expect(bucket(2026, 6, 16).label == "Earlier this week")
    #expect(bucket(2026, 6, 10).label == "Last week")
    #expect(bucket(2026, 6, 2).label == "Earlier this month")
  }

  @Test func monthBucketsFormatMonthAndMonthYear() {
    let month = bucket(2026, 3, 3)
    #expect(month.kind == .month)
    #expect(month.label == "March")

    let monthYear = bucket(2025, 12, 3)
    #expect(monthYear.kind == .monthYear)
    #expect(monthYear.label == "December 2025")
  }

  @Test func monthLabelsFollowTheCalendarLocale() {
    var calendar = Self.calendar()
    calendar.locale = Locale(identifier: "de_DE")
    let bucket = SessionDateBucket.bucket(
      for: Self.date(2026, 3, 3), now: Self.thuNoon, calendar: calendar
    )
    #expect(bucket.label == "März")
  }

  @Test func monthLabelsFormatTheNominalDayInTheCalendarTimeZone() {
    // 1 Mar 2026 06:00 UTC is 01:00 in New York — before the 4 AM rollover, so its nominal
    // day is 28 Feb and the label names February.
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let instant = utc.date(from: DateComponents(year: 2026, month: 3, day: 1, hour: 6))!
    let bucket = SessionDateBucket.bucket(for: instant, now: Self.thuNoon, calendar: Self.calendar())
    #expect(bucket.label == "February")
  }
}
