import Foundation

/// Coarse calendar bucket for a session's last-active date — the session list's section
/// unit. A straight port of the desktop's `calendarBucket` (`apps/desktop/src/lib/time.ts`)
/// over `Calendar` date math instead of epoch-millisecond arithmetic, so day boundaries and
/// day differences stay DST-safe.
///
/// Granularity coarsens with age: today → yesterday → earlier this week → last week →
/// earlier this month → month (same year) → month + year. Ranges are non-overlapping
/// calendar ranges (never a rolling "previous 7 days"), and an empty range simply never
/// produces a bucket, so a sparse tail jumps straight to its month.
///
/// The human day ends when you sleep, not at midnight: the day boundary sits at
/// `dayRolloverHour` (4 AM local), so a 12:30 AM session groups with the previous
/// evening's 11:50 PM run instead of splitting off.
public struct SessionDateBucket: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case today, yesterday, thisWeek, lastWeek, thisMonth, month, monthYear
  }

  public let kind: Kind
  /// Stable section identity: `"today"` | `"yesterday"` | `"this-week"` | `"last-week"` |
  /// `"this-month"` | `"m-YYYY-M"` | `"my-YYYY-M"`. Month numbers are the calendar's
  /// 1-based months (the desktop's are JS 0-based; the key is a local identity only); a
  /// leap month appends `L`, and an era other than today's appends `-e<era>`.
  public let key: String
  /// Section header text. The relative buckets use fixed strings ("Today" is the top
  /// label — the desktop says "Earlier today" only because its unlabelled head run sits
  /// above it; mobile labels every section). Month buckets format the nominal day as a
  /// wide month (+ year for `monthYear`) on the bucketing calendar, its time zone, and its
  /// locale (`.current` when the calendar carries none).
  public let label: String

  /// Local hour at which one nominal day rolls into the next (desktop `DAY_ROLLOVER_HOUR`).
  public static let dayRolloverHour = 4

  public init(kind: Kind, key: String, label: String) {
    self.kind = kind
    self.key = key
    self.label = label
  }

  /// Start of the nominal day `date` belongs to, honouring the 4 AM rollover:
  /// Saturday 1 AM → start of Friday. Judged on the LOCAL hour, so a DST jump never moves
  /// the boundary off 4 AM wall-clock time.
  public static func nominalDayStart(_ date: Date, calendar: Calendar) -> Date {
    let start = calendar.startOfDay(for: date)
    guard calendar.component(.hour, from: date) < dayRolloverHour else { return start }
    return startOfDay(start, offsetBy: -1, calendar: calendar)
  }

  /// Port of desktop `calendarBucket`. `calendar` supplies the time zone, `firstWeekday`
  /// (the desktop's locale week start), and the month-label locale. A future date buckets
  /// as today.
  public static func bucket(for date: Date, now: Date, calendar: Calendar) -> SessionDateBucket {
    let nominal = nominalDayStart(date, calendar: calendar)
    let todayNominal = nominalDayStart(now, calendar: calendar)
    let dayDiff = calendar.dateComponents([.day], from: nominal, to: todayNominal).day ?? 0

    if dayDiff <= 0 {
      return SessionDateBucket(kind: .today, key: "today", label: "Today")
    }
    if dayDiff == 1 {
      return SessionDateBucket(kind: .yesterday, key: "yesterday", label: "Yesterday")
    }

    let weekStart = startOfWeek(containing: todayNominal, calendar: calendar)
    if nominal >= weekStart {
      return SessionDateBucket(kind: .thisWeek, key: "this-week", label: "Earlier this week")
    }
    if nominal >= startOfDay(weekStart, offsetBy: -7, calendar: calendar) {
      return SessionDateBucket(kind: .lastWeek, key: "last-week", label: "Last week")
    }

    // Interval comparisons, not raw year/month numbers: they respect eras (Japanese) and
    // leap months (Chinese), which bare components would merge.
    if calendar.isDate(nominal, equalTo: todayNominal, toGranularity: .month) {
      return SessionDateBucket(kind: .thisMonth, key: "this-month", label: "Earlier this month")
    }
    let sameYear = calendar.isDate(nominal, equalTo: todayNominal, toGranularity: .year)

    let day = calendar.dateComponents([.era, .year, .month, .isLeapMonth], from: nominal)
    let todayEra = calendar.component(.era, from: todayNominal)
    let leap = day.isLeapMonth == true ? "L" : ""
    let era = day.era == todayEra ? "" : "-e\(day.era ?? 0)"
    let yearMonth = "\(day.year ?? 0)-\(day.month ?? 0)\(leap)\(era)"
    let month = Date.FormatStyle(
      locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone
    ).month(.wide)
    return sameYear
      ? SessionDateBucket(kind: .month, key: "m-\(yearMonth)", label: nominal.formatted(month))
      : SessionDateBucket(
        kind: .monthYear, key: "my-\(yearMonth)", label: nominal.formatted(month.year())
      )
  }

  // MARK: - Private

  /// Start of the calendar week containing `day` (a nominal day start), per
  /// `calendar.firstWeekday` (1 = Sunday … 7 = Saturday).
  private static func startOfWeek(containing day: Date, calendar: Calendar) -> Date {
    let weekday = calendar.component(.weekday, from: day)
    return startOfDay(day, offsetBy: -((weekday - calendar.firstWeekday + 7) % 7), calendar: calendar)
  }

  /// Start of the day `days` calendar days from `day` — calendar arithmetic, never a fixed
  /// 86,400 s, so a 23- or 25-hour DST day still counts as one day.
  private static func startOfDay(_ day: Date, offsetBy days: Int, calendar: Calendar) -> Date {
    // A day offset is always representable on a Gregorian-style calendar.
    calendar.startOfDay(for: calendar.date(byAdding: .day, value: days, to: day)!)
  }
}
