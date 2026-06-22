import Foundation

/// Pure, server-authoritative re-hydration of a chat transcript from the `session.resume`
/// `messages` array. The gateway returns the server's **cooked** history shape (built by
/// `_history_to_messages`), NOT the raw DB rows — each entry is one of:
///   - a text row: `{role: "user" | "assistant" | "system", text, ...}` (an assistant row
///     may also carry `reasoning` / `reasoning_content` / `reasoning_details`);
///   - a tool row: `{role: "tool", name, context}` — the server has already matched the
///     tool call to its result and flattened it into a single row with a display `name` and
///     a short args/preview `context`. There are **no** `tool_calls` arrays or
///     `tool_call_id` back-matching in this payload.
///
/// Mirrors the desktop TUI's `toTranscriptMessages` (`ui-tui/src/domain/messages.ts`).
/// For each message, in order:
///   1. an assistant **reasoning** row (from `reasoningText`), emitted collapsed/complete
///      as a `.thinking` row with unknown elapsed (`0` → the view shows a bare "Thought");
///   2. an assistant / user **text** row from `displayText` (skipped when empty);
///   3. a completed **tool** row for each `role: "tool"` entry (title = `name`, the
///      `context` preview surfaced in the detail sheet).
///
/// The `id` factory is injected so callers can supply the reducer's `@Dependency(\.uuid)`;
/// identity is never load-bearing here (resumed rows are static/complete).
public func reconstructTranscript(
  _ messages: [SessionMessage],
  makeID: () -> UUID = { UUID() }
) -> [ChatRow] {
  var rows: [ChatRow] = []

  for message in messages {
    switch message.role {
    case "tool":
      // The server already resolved the call → result into one cooked row.
      let toolName = message.toolDisplayName ?? "tool"
      let preview = message.context?.nonEmpty
      let detail = preview.map { ToolDetail(argsText: $0) }
      rows.append(ChatRow(id: makeID(), kind: .tool(
        name: toolName, title: toolName, state: .complete,
        detail: detail, durationS: nil
      )))

    case "assistant":
      // 1. Reasoning row (collapsed + complete). Elapsed is unknown on re-hydration — `0`
      //    renders as a bare "Thought" disclosure (no misleading "· 0s").
      if let reasoning = message.reasoningText {
        rows.append(ChatRow(id: makeID(), kind: .thinking(
          reasoning: reasoning, status: nil, elapsedSeconds: 0, isComplete: true
        )))
      }
      // 2. Assistant text row (the server omits empty/tool-only assistant turns, so a
      //    missing body here just means there's nothing to render for it).
      if let text = message.displayText {
        rows.append(ChatRow(id: makeID(), kind: .message(role: .assistant, text: text, isComplete: true)))
      }

    case "user":
      if let text = message.displayText {
        rows.append(ChatRow(id: makeID(), kind: .message(role: .user, text: text, isComplete: true)))
      }

    default:
      // Unknown / `system` role — mobile has no bubble for it; skip, never crash.
      continue
    }
  }

  return rows
}
