import Foundation

/// Coarse calendar bucket for a session's last-active date — the session list's section
/// unit. A straight port of the desktop's `calendarBucket` (`apps/desktop/src/lib/time.ts`)
/// over `Calendar` date math instead of epoch-millisecond arithmetic, so it stays DST-safe.
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
  /// 1-based months (the desktop's are JS 0-based; the key is a local identity only).
  public let key: String
  /// The nominal day start the date belongs to — used only for month formatting.
  public let anchor: Date

  /// Local hour at which one nominal day rolls into the next (desktop `DAY_ROLLOVER_HOUR`).
  public static let dayRolloverHour = 4

  public init(kind: Kind, key: String, anchor: Date) {
    self.kind = kind
    self.key = key
    self.anchor = anchor
  }

  /// Start of the nominal day `date` belongs to, honouring the 4 AM rollover:
  /// Saturday 1 AM → start of Friday.
  public static func nominalDayStart(_ date: Date, calendar: Calendar) -> Date {
    calendar.startOfDay(for: date.addingTimeInterval(-Double(dayRolloverHour) * 3600))
  }

  /// Port of desktop `calendarBucket`. `calendar` supplies the time zone and
  /// `firstWeekday` (the desktop's locale week start). A future date buckets as today.
  public static func bucket(
    for date: Date,
    now: Date,
    calendar: Calendar = .autoupdatingCurrent
  ) -> SessionDateBucket {
    let nominal = nominalDayStart(date, calendar: calendar)
    let todayNominal = nominalDayStart(now, calendar: calendar)
    let dayDiff = calendar.dateComponents([.day], from: nominal, to: todayNominal).day ?? 0

    if dayDiff <= 0 {
      return SessionDateBucket(kind: .today, key: "today", anchor: nominal)
    }
    if dayDiff == 1 {
      return SessionDateBucket(kind: .yesterday, key: "yesterday", anchor: nominal)
    }

    let weekStart = startOfWeek(containing: todayNominal, calendar: calendar)
    if nominal >= weekStart {
      return SessionDateBucket(kind: .thisWeek, key: "this-week", anchor: nominal)
    }
    let lastWeekStart = calendar.date(byAdding: .day, value: -7, to: weekStart)
      .map { calendar.startOfDay(for: $0) } ?? weekStart.addingTimeInterval(-7 * 86_400)
    if nominal >= lastWeekStart {
      return SessionDateBucket(kind: .lastWeek, key: "last-week", anchor: nominal)
    }

    let day = calendar.dateComponents([.year, .month], from: nominal)
    let today = calendar.dateComponents([.year, .month], from: todayNominal)
    let sameYear = day.year == today.year
    if sameYear, day.month == today.month {
      return SessionDateBucket(kind: .thisMonth, key: "this-month", anchor: nominal)
    }

    let yearMonth = "\(day.year ?? 0)-\(day.month ?? 0)"
    return sameYear
      ? SessionDateBucket(kind: .month, key: "m-\(yearMonth)", anchor: nominal)
      : SessionDateBucket(kind: .monthYear, key: "my-\(yearMonth)", anchor: nominal)
  }

  /// Section header text. The relative buckets use fixed strings ("Today" is the top
  /// label — the desktop says "Earlier today" only because its unlabelled head run sits
  /// above it; mobile labels every section). Month buckets format the anchor with the
  /// `"MMMM"` / `"MMMM yyyy"` templates on the injected calendar, its time zone, and its
  /// locale (`.current` when the calendar carries none).
  public func label(calendar: Calendar = .autoupdatingCurrent) -> String {
    switch kind {
    case .today: return "Today"
    case .yesterday: return "Yesterday"
    case .thisWeek: return "Earlier this week"
    case .lastWeek: return "Last week"
    case .thisMonth: return "Earlier this month"
    case .month: return Self.format(anchor, template: "MMMM", calendar: calendar)
    case .monthYear: return Self.format(anchor, template: "MMMM yyyy", calendar: calendar)
    }
  }

  // MARK: - Private

  /// Start of the calendar week containing `day` (a nominal day start), per
  /// `calendar.firstWeekday` (1 = Sunday … 7 = Saturday).
  private static func startOfWeek(containing day: Date, calendar: Calendar) -> Date {
    let weekday = calendar.component(.weekday, from: day)
    let back = (weekday - calendar.firstWeekday + 7) % 7
    guard let start = calendar.date(byAdding: .day, value: -back, to: day) else { return day }
    return calendar.startOfDay(for: start)
  }

  private static func format(_ date: Date, template: String, calendar: Calendar) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = calendar.locale ?? .current
    formatter.setLocalizedDateFormatFromTemplate(template)
    return formatter.string(from: date)
  }
}
