# Inbox-style session list with date sections

## Overview

Replace the session list's one-line rows and the workspace / chronological grouping pref with
the desktop's **Inbox style**: every interactive session renders as a three-line card
(workspace · age / title + preview / model · message count), and the list is sectioned by
**update-date buckets** (Today, Yesterday, Earlier this week, Last week, Earlier this month,
then month, then month + year). On desktop this is an opt-in render variant that composes with
whichever grouping is active; on mobile it is **always on and the only list UI** — the
grouping pref and its picker go away, since the card already names the workspace on every row.

Alongside: the Cron Jobs section gains a persisted collapse chevron on its header (replacing the
organize-menu "Cron Jobs section" toggle, and fixing the gap where hiding the section also hid
its unread badge), and the organize menu — left with a single item — becomes a direct
"Archived sessions" toolbar button.

Design history: brainstorm on 2026-10-23 (this plan). Desktop reference lives in the sibling
clone `/Users/eugene/Documents/Development/Personal/hermes-agent`, read via
`git show upstream/main:<path>` (the working tree goes stale).

## Context (from discovery)

**Desktop reference (upstream/main):**
- `apps/desktop/src/app/chat/sidebar/session-row.tsx` — the card branch (~line 600): header
  row = status dot + workspace label (project name → cwd leaf → "Home") + age; body = title
  (medium) + `session.preview`; footer = model + "N messages" + todo progress.
- `apps/desktop/src/store/layout.ts` — `$sidebarCardRows` (off by default, "a RENDER variant,
  deliberately not a grouping"). Pinned rows render as cards too, so one column never mixes
  card and inline geometry; dense tree surfaces (projects, messaging, cron) keep the one-liner.
- `apps/desktop/src/lib/time.ts` — `calendarBucket(seconds, nowMs, weekStartsOn)`:
  `DAY_ROLLOVER_HOUR = 4` nominal-day rollover, locale first weekday, kinds
  `today | yesterday | thisWeek | lastWeek | thisMonth | month | monthYear`, keys
  `today`/`yesterday`/`this-week`/`last-week`/`this-month`/`m-YYYY-M`/`my-YYYY-M`. Tests in
  `apps/desktop/src/lib/time.test.ts`. Desktop's unlabelled "recent head run" heuristic
  (`session-date-groups.ts`) is **deliberately not ported** — buckets only.
- `apps/desktop/src/types/hermes.ts` — `SessionInfo.model: null | string` is on the list row.

**Mobile (this repo):**
- `HermesKit/Sources/HermesKit/Features/SessionListFeature.swift` — `State.groupingMode`,
  `groups`, `expandedGroups`, `visibleEntries(in:)`, `chronologicalSessions`/`chronologicalEntries`,
  `pinnedEntries`, `showCronSection`, `cronJobGroups`, `unmatchedCronSessions`,
  `cronUnreadCount`, `now` (poll-refreshed); actions `setGroupingMode`, `toggleGroupExpansion`,
  `setShowCronSection`; prefs loaded in the `task` bootstrap (~line 1477).
- `HermesKit/Sources/HermesKit/Models/SessionGroupingMode.swift`, `Models/SessionGroup.swift`
  (+ `Tests/HermesKitTests/SessionGroupTests.swift`) — to be removed.
- `Models/SessionBranchTree.swift` — `SessionBranchEntry { session, branchStem }`,
  `flattenSessionsWithBranches` (branch children carry a non-nil stem).
- `Models/Session.swift` — has `preview`, `cwd`, `updatedAt`, `messageCount`, `displayName`
  (title → preview → id), `resolvedTitle`/`resolvedPreview`; **no `model`**.
- `Clients/HermesRESTClient.swift` ~line 842 — `SessionListDTO` + `asSession`; `model` key
  not decoded. `SearchResultDTO` carries the match snippet as the row's preview.
- `Clients/PreferencesClient.swift` — `loadGroupingMode`/`saveGroupingMode`
  (`hermes.session-grouping-mode`), `loadShowCronSection`/`saveShowCronSection`
  (`hermes.show-cron-section`); `.inMemory()` + live.
- Logout recipes resetting both prefs: `AppFeature.swift` ~394 and ~761,
  `SettingsFeature.swift` ~354.
- `HermesMobile/Sources/Features/SessionListView.swift` — `sessionListContent` (~134),
  `cronSectionHeader` (~223), `organizeMenu` (~428), `groupSection` (~464), `row(_:)` builder
  (~491: the single funnel for swipe / context menu / highlight / tap).
- `HermesMobile/Sources/Features/SessionRowView.swift` — current one-line row with the
  private `ActiveGlow` modifier; stays as-is for cron run peeks + archived sheet.
- `HermesMobile/Sources/Features/Chat/ComposerView.swift` ~210 — the chat chip shows the raw
  model string (no shortening rule exists); the card footer does the same.
- `HermesMobile/Sources/DemoMode.swift` — `loadGroupingMode` override (~74) and
  `groupingMode:` state init (~204).
- Tests: `HermesKit/Tests/HermesKitTests/SessionListFeatureTests.swift` (19 grouping/cron-section
  references), `SessionGroupTests.swift`, `SessionDecodingTests.swift`,
  `HermesMobileTests/SessionSnapshotTests.swift` (`testSessionList_chronological`,
  `testSessionList_cronSection_chronological`, `testSessionList_noCronSection`, …).
- Docs: `docs/features/session-list.md` ("Grouping & archived" paragraph), `CLAUDE.md`
  "Session list" bullets, `docs/development.md` snapshot breakdown.

**Patterns:** logic in HermesKit (pure, `swift test` on macOS), views thin; prefs via
`PreferencesClient` and cleared in all three logout recipes; snapshots of a `List` use
`deviceImage()`, components use `componentImage()`; new snapshots record on the first
`make snapshot` run and assert on the second.

## Development Approach

- **testing approach**: Regular (code first, then tests, per task) — consistent with every
  prior plan.
- complete each task fully before moving to the next; commit at each task boundary
  (capitalized verb, no prefixes).
- make small, focused changes.
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task —
  tests are a required deliverable, listed as separate checklist items.
- **CRITICAL: all tests must pass before starting the next task** — no exceptions.
- **CRITICAL: update this plan file when scope changes during implementation.**
- `script -q /dev/null swift test --package-path HermesKit` for live package output;
  `make snapshot` for the iOS snapshot suite (`tuist generate` first after adding a source file).
- `HermesKit/Package.resolved` goes dirty from local resolves — `git checkout --` it, never
  commit it.
- The pre-existing broad snapshot drift (identical render size, small pixel residual) is NOT a
  regression; judge by render-size mismatch. The global re-record stays its own commit.

## Testing Strategy

- **unit tests** (HermesKit): required for every task — the bucket port, the section builder,
  the DTO decode, the collapse pref round-trip, and the removal of the grouping surface.
- **snapshot tests** (`HermesMobileTests`): card component variants + list device snapshots;
  no e2e suite exists in this project.
- **measured layout tests**: none needed — the card has no scroll region or width cap of its
  own; natural-height rows are a snapshot concern.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope

## Solution Overview

1. **Date bucketing is a pure HermesKit model** (`SessionDateBucket` + `SessionDateSection`),
   a straight port of desktop's `calendarBucket` (4 AM rollover, calendar first weekday) with
   fixed labels resolved in HermesKit so they are unit-tested. The section builder walks
   `chronologicalEntries` (already recency-sorted and branch-flattened) and opens a new section
   only on a top-level entry whose bucket key changes; branch children (non-nil `branchStem`)
   stay in their parent's section so a parent + branches cluster never splits across a header.
   Empty buckets never appear; a nil `updatedAt` row goes to a trailing "Older" section.
2. **`State.dateSections`** is computed from `state.now` (already poll-refreshed for the cron
   countdown), so headers re-bucket on the same cadence as the age labels — no new ticker.
3. **The grouping surface is deleted**, not deprecated: enum, model, pref, actions, computed
   state, menu picker, snapshot tests. `chronologicalEntries` remains the one lane.
4. **Cron collapse replaces cron hide**: `cronSectionCollapsed` (default `false`, new pref key)
   toggled from the header chevron; the header (with badge) is always visible.
5. **`SessionCardView` is a new view** (Option B from the brainstorm): separate from
   `SessionRowView` so each style owns its own glow/pulse state and the compact row stays
   untouched for cron peeks and the archived sheet. The card is a flat row with hairline
   separators and natural height — **no min-height floor** (#79 rule stands).
6. **`row(_:)` stays the single affordance funnel** in `SessionListView`; only its body changes.

## Technical Details

### `SessionDateBucket` (HermesKit `Models/SessionDateBucket.swift`)

```swift
public struct SessionDateBucket: Equatable, Sendable {
  public enum Kind: Equatable, Sendable { case today, yesterday, thisWeek, lastWeek, thisMonth, month, monthYear }
  public let kind: Kind
  public let key: String      // "today" | "yesterday" | "this-week" | "last-week" | "this-month" | "m-YYYY-M" | "my-YYYY-M"
  public let anchor: Date     // nominal day start — month formatting only

  public static let dayRolloverHour = 4

  /// Port of desktop `calendarBucket`. `calendar` supplies time zone + `firstWeekday`.
  public static func bucket(for date: Date, now: Date, calendar: Calendar = .autoupdatingCurrent) -> SessionDateBucket
  /// "Today" | "Yesterday" | "Earlier this week" | "Last week" | "Earlier this month" |
  /// "September" (same year) | "December 2025" (prior year). Month names via `DateFormatter`
  /// templates ("MMMM" / "MMMM yyyy") on the injected calendar/locale.
  public func label(calendar: Calendar = .autoupdatingCurrent) -> String
}
```

Algorithm (mirrors desktop exactly, dates instead of ms):
- `nominalDayStart(d)` = `calendar.startOfDay(for: d - 4h)`.
- `dayDiff` = whole days between `nominalDayStart(now)` and `nominalDayStart(date)`;
  `<= 0` → today, `== 1` → yesterday.
- `weekStart` = start of the calendar week containing today's nominal day
  (`calendar.firstWeekday`); `nominal >= weekStart` → thisWeek; `>= weekStart - 7d` → lastWeek.
- same year + month → thisMonth; same year → month (`m-`); else monthYear (`my-`).

Note: "Today" is the top-bucket label (desktop says "Earlier today" only because its
unlabelled head run sits above it; mobile labels every section).

### `SessionDateSection` (same file or `Models/SessionDateSection.swift`)

```swift
public struct SessionDateSection: Equatable, Sendable, Identifiable {
  public let id: String                 // bucket key, or "older" for nil updatedAt
  public let label: String
  public var entries: [SessionBranchEntry]
}

/// Pure. Preserves input order; opens a section on each TOP-LEVEL entry (branchStem == nil)
/// whose bucket key differs from the current section; branch children append to the current
/// section unconditionally. Entries with nil `updatedAt` open/append to the trailing "Older"
/// section (they already sort last). Never reorders.
public func groupEntriesByDate(_ entries: [SessionBranchEntry], now: Date, calendar: Calendar) -> [SessionDateSection]
```

Edge: a branch child with no preceding top-level section (cannot happen after
`flattenSessionsWithBranches`, but stay total) opens a section from its own bucket.

### `SessionListFeature.State`

- Remove: `groupingMode`, `expandedGroups`, `groups`, `visibleEntries(in:)`, `showCronSection`.
- Add: `cronSectionCollapsed: Bool = false`,
  `dateSections: [SessionDateSection] { groupEntriesByDate(chronologicalEntries, now: now, calendar: calendar) }`
  where `calendar` is a `@Dependency(\.calendar)`-sourced value captured into state at `task`
  (or the computed property takes a `Calendar` parameter and the view passes
  `.autoupdatingCurrent`; pick the former so snapshots are deterministic through the
  dependency override).
- Actions: remove `setGroupingMode`, `toggleGroupExpansion`, `setShowCronSection`; add
  `toggleCronSectionCollapsed` (flips state, persists via `preferences.saveCronSectionCollapsed`).
- `task` bootstrap loads `cronSectionCollapsed` instead of `showCronSection`/`groupingMode`.

### `PreferencesClient`

- Remove `loadGroupingMode`/`saveGroupingMode` + key `hermes.session-grouping-mode` (the live
  implementation also `removeObject`s the stale key once on first load — one line, so a
  TestFlight upgrade leaves no orphaned default).
- Replace `loadShowCronSection`/`saveShowCronSection` with
  `loadCronSectionCollapsed: () -> Bool = { false }` / `saveCronSectionCollapsed(Bool)`, key
  `hermes.cron-section-collapsed`; remove the old `hermes.show-cron-section` key on first load
  the same way. `.inMemory()` mirrors.
- All three logout recipes call `saveCronSectionCollapsed(false)` instead of the two old resets.

### `Session.model`

- `Session.model: String?` (doc: raw server model id as the chat chip shows it; nil on older
  agents). `SessionListDTO.model: String?` with `case model` in `CodingKeys`, mapped via
  `model?.nonEmpty`. Snapshot store untouched (its `model` column is the chat's live model).

### `SessionCardView` (`HermesMobile/Sources/Features/SessionCardView.swift`)

Inputs: `session: Session`, `now: Date`, `branchStem: String?`, `isUnread`, `isPinned`,
`isActive`. Layout (`VStack(alignment: .leading, spacing: 4)`):

1. Header `HStack(spacing: 6)`: unread dot (8pt accent circle, "Unread" a11y), optional
   `Text(branchStem)` monospaced caption, workspace label (`session.cwd` last path component,
   else "No workspace") `.font(.caption).foregroundStyle(.secondary)` single line truncating,
   pin glyph when pinned, `Spacer()`, relative age (`RelativeDateTimeFormatter`, `.named`)
   `.font(.caption).foregroundStyle(.secondary)`.
2. Title: `session.displayName` (`resolvedTitle ?? resolvedPreview ?? id`) `.font(.headline)`,
   weight `.semibold` normally and `.bold` when unread (the row's own convention, one step
   heavier), `lineLimit(2)` + `fixedSize(horizontal: false, vertical: true)` (load-bearing —
   see the comment in `SessionRowView`).
3. Preview: only when `resolvedTitle != nil && resolvedPreview != nil` (untitled sessions
   promote the preview into the title slot and drop this line) —
   `.font(.subheadline).foregroundStyle(.secondary).lineLimit(1)`.
4. Footer: `HStack(spacing: 8)` of `model` (raw string, `lineLimit(1)`) and
   `"\(count) messages"` (`count > 0`, pluralised via `^[\(count) message](inflect: true)`),
   `.font(.caption).foregroundStyle(.tertiary)`; the whole line is omitted when both are nil.
5. `.padding(.vertical, 4)`, then the card's own `CardActiveGlow` modifier (copy of
   `ActiveGlow` with its own `@State pulsing`, `onAppear`/`onChange(isActive)`/
   `onChange(reduceMotion)` wiring identical) — Option B: separate so the two styles can
   diverge.
6. `.accessibilityElement(children: .combine)` with an explicit
   `.accessibilityLabel` built in order: workspace, title, preview, model, message count, age,
   then "Unread"/"Pinned"/"Working" flags present.

Search results reuse the same card; the search DTO already fills `preview` with the match
snippet, so the keyword line comes for free. No `showsPreview` input.

### `SessionListView`

- `sessionListContent`: `sessionsSectionHeader` → `Section("Pinned")` of cards →
  `ForEach(store.dateSections) { Section(section.label) { ForEach(section.entries) { row($0) } } }`
  → cron section. Section headers use the default `List` plain-style header (secondary,
  uppercase per platform) — no custom header view.
- Search branch: `ForEach(store.sessions) { row($0) }` (card, no `showsPreview`).
- `row(_:)`: body becomes `SessionCardView(...)`; swipe actions, context menu,
  `listRowBackground` highlight, `accessibilityAddTraits(.isSelected)` unchanged.
- `cronSectionHeader`: wrap in a `Button` (plain style) sending
  `.toggleCronSectionCollapsed` with `animation: reduceMotion ? nil : .snappy`; trailing
  `Image(systemName: "chevron.down")` rotated `-90°` when collapsed; badge stays;
  `.accessibilityAddTraits(.isHeader)` + `.accessibilityValue(collapsed ? "Collapsed" : "Expanded")`
  + `.accessibilityHint("Double-tap to show or hide cron jobs")`. The job rows, peeks, and
  `unmatchedCronSessions` render only when `!store.cronSectionCollapsed`.
- Toolbar: replace `organizeMenu` with
  `Button { store.send(.archivedButtonTapped) } label: { Label("Archived sessions", systemImage: "archivebox") }`.
- Cron run rows inside a peek keep `SessionRowView` via a separate `cronRunRow(_:)` (today's
  `row(_:)` is shared — split so cron runs don't become cards). Archived sheet untouched.
- `DemoMode.swift`: drop `loadGroupingMode` override and the `groupingMode:` init arg; seed
  fixture `updatedAt`s so the demo list spans at least Today / Yesterday / Last week.

### Row-identity & affordance invariants that must not change

- Pinned lane keeps pin order; nesting via `flattenSessionsWithBranches` unchanged.
- Trailing swipe is destructive-first; context menu offers Archive + Delete (gated); Copy ID
  context-menu-only; no min-height floor; reduce-motion respected.

## Implementation Steps

### Task 1: Port the calendar bucket and section builder into HermesKit

**Files:**
- Create: `HermesKit/Sources/HermesKit/Models/SessionDateBucket.swift`
- Create: `HermesKit/Sources/HermesKit/Models/SessionDateSection.swift`
- Create: `HermesKit/Tests/HermesKitTests/SessionDateBucketTests.swift`
- Create: `HermesKit/Tests/HermesKitTests/SessionDateSectionTests.swift`

- [x] add `SessionDateBucket` (`Kind`, `key`, `anchor`, `dayRolloverHour = 4`,
      `bucket(for:now:calendar:)`) as a port of desktop `calendarBucket` using `Calendar`
      date math (start-of-day, `firstWeekday`, `dateComponents(.day)` diffs)
- [x] add `label(calendar:)` with the five fixed strings and `DateFormatter` month /
      month + year templates on the injected calendar + locale
- [x] add `SessionDateSection` + `groupEntriesByDate(_:now:calendar:)` (top-level entries open
      sections on key change, branch children append, nil `updatedAt` → trailing "Older")
      — a top-level entry buckets on its cluster's freshest `updatedAt` (matching the
      flatten's cluster sort) and an already-emitted key never opens a duplicate section
- [x] write `SessionDateBucketTests`: port `time.test.ts` cases with a fixed `now`
      (Thu 2026-06-18 noon) and a Gregorian calendar pinned to a fixed time zone — today /
      yesterday / this week / last week / this month / month / month-year, Monday AND Sunday
      `firstWeekday`, the 4 AM rollover (1 AM → previous day), stable keys across a month
      (`m-2026-2` twice, `my-2025-2`), and the label strings
- [x] write `SessionDateSectionTests`: empty input, single bucket, bucket boundary inside a
      parent + branch cluster (children stay with the parent), nil `updatedAt` trailing section,
      order preserved and never re-sorted, no empty sections, a leading branch child still
      yields a section
- [x] run `swift test` — must pass before task 2

### Task 2: Decode `model` onto `Session`

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Models/Session.swift`
- Modify: `HermesKit/Sources/HermesKit/Clients/HermesRESTClient.swift`
- Modify: `HermesKit/Tests/HermesKitTests/SessionDecodingTests.swift`

- [x] add `Session.model: String?` (+ init param, doc comment: raw server id, nil on older agents)
- [x] add `model` to `SessionListDTO` + `CodingKeys` and map `model?.nonEmpty` in `asSession`
- [x] write decode tests: present, absent (nil), empty string (nil), `null` (nil)
- [x] run `swift test` — must pass before task 3

### Task 3: Replace the cron-section hide pref with a collapse pref

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Clients/PreferencesClient.swift`
- Modify: `HermesKit/Sources/HermesKit/Features/SessionListFeature.swift`
- Modify: `HermesKit/Sources/HermesKit/AppFeature.swift`
- Modify: `HermesKit/Sources/HermesKit/Features/SettingsFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/SessionListFeatureTests.swift`
- Modify: `HermesKit/Tests/HermesKitTests/SessionListCronTests.swift`
- Modify: `HermesKit/Tests/HermesKitTests/AppFeatureTests.swift` (or wherever the logout
  recipes are asserted — locate with `grep -rn saveShowCronSection HermesKit/Tests`)
- Modify: `HermesMobile/Sources/Features/SessionListView.swift` (minimal: keep compiling —
  bind the existing toggle to the new flag; the real header UI lands in task 6)

- [x] replace `loadShowCronSection`/`saveShowCronSection` with
      `loadCronSectionCollapsed`/`saveCronSectionCollapsed` (`hermes.cron-section-collapsed`,
      default `false`) in the interface, live, and `.inMemory()`; live load removes the stale
      `hermes.show-cron-section` key once
- [x] rename `State.showCronSection` → `cronSectionCollapsed`, replace `setShowCronSection`
      with `toggleCronSectionCollapsed` (flip + persist), load it in the `task` bootstrap
- [x] update all three logout recipes to `saveCronSectionCollapsed(false)`
- [x] update tests: toggle flips + persists, bootstrap loads `true`, each logout recipe resets
      to `false`; adjust existing cron-section tests to the new flag name
- [x] run `swift test` — must pass before task 4

### Task 4: Remove the grouping mode and expose `dateSections`

**Files:**
- Delete: `HermesKit/Sources/HermesKit/Models/SessionGroupingMode.swift`
- Delete: `HermesKit/Sources/HermesKit/Models/SessionGroup.swift`
- Delete: `HermesKit/Tests/HermesKitTests/SessionGroupTests.swift`
- Modify: `HermesKit/Sources/HermesKit/Clients/PreferencesClient.swift`
- Modify: `HermesKit/Sources/HermesKit/Features/SessionListFeature.swift`
- Modify: `HermesKit/Sources/HermesKit/AppFeature.swift`
- Modify: `HermesKit/Sources/HermesKit/Features/SettingsFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/SessionListFeatureTests.swift`
- Modify: `HermesMobile/Sources/Features/SessionListView.swift` (minimal compile fix: render
  `dateSections` in place of the `switch groupingMode`; drop the picker from the menu)
- Modify: `HermesMobile/Sources/DemoMode.swift`

- [x] delete `SessionGroupingMode`, `SessionGroup`, and the `loadGroupingMode`/
      `saveGroupingMode` client members + key (live load removes the stale key once)
- [x] remove `State.groupingMode`, `expandedGroups`, `groups`, `visibleEntries(in:)` and
      actions `setGroupingMode`, `toggleGroupExpansion`; drop the three logout-recipe resets
- [x] add `State.dateSections` computed from `chronologicalEntries` + `now` (+ calendar
      dependency captured at `task` so TestStore/snapshots pin it) — a dedicated
      `\.sessionListCalendar` key (the library `\.calendar` has no test value)
- [x] update `SessionListFeatureTests`: delete grouping tests; add `dateSections` cases —
      sections follow `now` (a `pollTick` that moves `now` across midnight re-buckets), cron and
      pinned rows never appear in `dateSections`, branch clusters intact
- [x] update `DemoMode` (drop the grouping override + init arg; spread fixture `updatedAt`s
      across Today / Yesterday / Last week)
- [x] run `swift test` — must pass before task 5

### Task 5: Add `SessionCardView`

**Files:**
- Create: `HermesMobile/Sources/Features/SessionCardView.swift`
- Modify: `HermesMobileTests/SessionSnapshotTests.swift`

- [x] implement the card per Technical Details (header / title / preview / footer, own
      `CardActiveGlow` + pulse state, combined accessibility label, no min-height floor)
- [x] workspace label helper: `cwd` last path component else "No workspace" (small private
      `Session` extension in the view file; keep `SessionGroup.noWorkspaceLabel`'s string)
- [x] `tuist generate` so the new file is picked up
- [x] add component snapshots (`componentImage()`, pinned width, dark + light where the
      existing row tests do): titled, untitled-promoted (no preview line), unread, pinned,
      working glow, no footer (nil model + 0 messages), branch stem, long title wraps to two
      lines
- [x] run `make snapshot` twice (record, then assert) — must pass before task 6

### Task 6: Wire the list: date sections, cron collapse header, Archived button

**Files:**
- Modify: `HermesMobile/Sources/Features/SessionListView.swift`
- Modify: `HermesMobileTests/SessionSnapshotTests.swift`

- [x] `sessionListContent` renders Pinned cards, then `ForEach(dateSections)` as `Section`s
      with their labels, then the cron section
- [x] `row(_:)` body → `SessionCardView`; split a `cronRunRow(_:)` that keeps
      `SessionRowView` for peeks and `unmatchedCronSessions`; search branch uses `row(_:)`
      without `showsPreview` — both go through one shared `sessionRow(_:content:)`
      affordance funnel; the flat cron fallback uses `cronRunRow(_:)` too
- [x] cron header becomes the collapse control (chevron, snappy animation gated on
      reduce-motion, badge always visible, header trait + collapsed/expanded value + hint);
      job rows / peeks / unmatched runs hidden while collapsed
- [x] replace `organizeMenu` with the `archivebox` "Archived sessions" toolbar button
- [x] delete `testSessionList_chronological`, `testSessionList_cronSection_chronological`,
      `testSessionList_noCronSection` and their recorded snapshots; retarget the remaining list
      snapshots (fixtures get `updatedAt`s that span several buckets; `now` pinned)
- [x] add device snapshots: `testSessionList_dateSections` (Today / Yesterday / Last week /
      month-year headers, pinned on top, a nested branch inside a section),
      `testSessionList_cronSectionCollapsed`, `testSessionList_searchResultsCards`
      — `testSessionList_dateSections` renders at a 1250pt-tall device size
      (`deviceImage(height:)`) so every header is in frame
- [x] run `make snapshot` twice for the new tests, then once more as the assert pass — must pass
      (modulo the documented pre-existing drift) before task 7

### Task 7: Verify acceptance criteria

- [ ] every interactive session renders as a card in Pinned, date sections, and search; cron
      run peeks and the archived sheet still render the compact row
- [ ] no grouping picker anywhere; `grep -rn "SessionGroupingMode\|groupingMode\|showCronSection"`
      over `HermesKit/Sources`, `HermesMobile/Sources`, tests, and docs returns nothing
- [ ] cron header toggles and persists across relaunch; badge visible while collapsed; logout
      resets it
- [ ] untitled sessions never show the preview twice; nil model / zero messages hide the footer
- [ ] swipe (destructive-first), context menu, Copy ID, highlight, and open-tap behave as
      before on cards (manual pass on simulator)
- [ ] run full package suite: `script -q /dev/null swift test --package-path HermesKit`
- [ ] run `make snapshot`; confirm every failure is the documented equal-size drift
- [ ] `git checkout -- HermesKit/Package.resolved` if dirty

### Task 8: [Final] Update documentation

- [ ] `docs/features/session-list.md`: replace "Grouping & archived" with "Date sections and
      inbox cards" (bucket table with keys + labels, 4 AM rollover, branch-cluster rule, the
      "Older" section, card anatomy and the untitled-promotion rule, cron collapse pref, the
      Archived toolbar button, which surfaces keep the compact row)
- [ ] `CLAUDE.md` "Session list": rewrite the grouping bullet in place at the same length
      (date sections + cards always on; `SessionDateBucket` pure; cron collapse pref; compact
      row only for cron peeks + archived) and drop stale `SessionGroupingMode` mentions
- [ ] `docs/development.md`: adjust the snapshot per-suite breakdown for the renamed /
      removed list snapshots
- [ ] `README.md`: update the feature-overview line about grouping, if it mentions the picker
      (screenshots are out of scope)
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification:**
- Simulator pass on iPhone (compact) and iPad (regular, sidebar width): section headers,
  card truncation at sidebar width, pinned cards, cron collapse animation and reduce-motion,
  VoiceOver reading order on a card, swipe and context affordances.
- Against a real agent: a session with a nil `model` (older agent) and one with zero messages
  hide the footer; search shows the keyword snippet in the preview line.
- TestFlight upgrade from a build that persisted `hermes.session-grouping-mode` /
  `hermes.show-cron-section`: no crash, stale keys cleared, cron section expanded by default.

**External:**
- App Store screenshots will show the old list; re-capture per the screenshot recipe when the
  next store build ships (separate task).
- The global snapshot re-record remains its own pending commit.
