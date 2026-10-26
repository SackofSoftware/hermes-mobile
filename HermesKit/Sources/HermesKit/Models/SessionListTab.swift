import Foundation

/// The session list's bottom-bar tabs: the interactive sessions, and the cron jobs with their
/// runs. The Cron Jobs tab exists only while there is cron content
/// (`SessionListFeature.State.hasCronContent`).
public enum SessionListTab: Equatable, Sendable, CaseIterable {
  case sessions
  case cron
}
