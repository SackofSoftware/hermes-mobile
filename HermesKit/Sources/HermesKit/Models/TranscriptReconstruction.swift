import Foundation

/// Pure, server-authoritative re-hydration of a chat transcript from stored history
/// messages (`session.activate` / `session.resume` `messages`, also REST
/// `GET /api/sessions/{id}/messages`). Mirrors the desktop `toChatMessages()`
/// (`apps/desktop/src/lib/chat-messages.ts`):
///
/// For each message, in order:
///   1. a **reasoning** row (assistant only) from `reasoning ?? reasoning_content ??
///      reasoning_details`, emitted collapsed/complete as a `.thinking` row;
///   2. an **assistant/user text** row — kept even when empty / tool-only so a
///      tool-only assistant turn isn't dropped;
///   3. **tool-call** rows from the assistant's `tool_calls`, keyed by `tool_call_id`
///      (fallback the tool name), status `.complete`.
///
/// A `role: "tool"` message walks **backward** to the nearest matching assistant
/// tool-call — by `tool_call_id` first, then by name — and attaches its result.
///
/// **Keying parity:** tool rows are keyed by `tool_call_id` exactly as the live fold
/// keys `ChatFeature.State.toolRowIDs` by the gateway `tool_id`. The resulting
/// `.tool(...)` row `kind` is byte-identical to the live fold's merged
/// `tool.start` + `tool.complete` row (verified by the keying-parity test).
///
/// The `id` factory is injected so callers can supply the reducer's `@Dependency(\.uuid)`
/// (the live fold generates row ids the same way); identity is never load-bearing for
/// reconstruction — rows are matched/merged by their key, not their `ChatRow.ID`.
public func reconstructTranscript(
  _ messages: [SessionMessage],
  makeID: () -> UUID = { UUID() }
) -> [ChatRow] {
  var rows: [ChatRow] = []
  // tool_call_id (or name fallback) → index into `rows` of that tool row, so a later
  // `role:"tool"` result can find and fill it. Mirrors the live fold's `toolRowIDs`.
  var toolRowIndexByKey: [String: Int] = [:]

  /// Key a tool by its stable id, falling back to its name — identical to how the live
  /// fold stores `toolRowIDs[toolID]` (id when present) and how a `tool` result message
  /// matches backward (id first, then name).
  func toolKey(id: String?, name: String?) -> String {
    if let id = id?.nonEmpty { return id }
    return "name:\(name?.nonEmpty ?? "tool")"
  }

  for message in messages {
    switch message.role {
    case "tool":
      attachToolResult(message, into: &rows, indexByKey: toolRowIndexByKey)

    case "assistant":
      // 1. Reasoning row (collapsed + complete).
      if let reasoning = message.reasoningText {
        rows.append(ChatRow(id: makeID(), kind: .thinking(
          reasoning: reasoning, status: nil, elapsedSeconds: 0, isComplete: true
        )))
      }

      // 2. Assistant text row — kept even when empty so tool-only turns survive (the
      //    live fold likewise creates the assistant row lazily but never drops the turn).
      if let text = message.content?.nonEmpty {
        rows.append(ChatRow(id: makeID(), kind: .message(role: .assistant, text: text, isComplete: true)))
      }

      // 3. Tool-call rows, keyed identically to the live fold.
      for call in message.toolCalls ?? [] {
        let name = call.name?.nonEmpty ?? "tool"
        let args = call.arguments.flatMap(parseToolArgs)
        let detail = ToolDetail(
          argsText: args == nil ? call.arguments?.nonEmpty : nil,
          args: args
        )
        let row = ChatRow(id: makeID(), kind: .tool(
          name: name, title: name, state: .complete,
          detail: detail.isEmpty ? nil : detail, durationS: nil
        ))
        rows.append(row)
        toolRowIndexByKey[toolKey(id: call.id, name: name)] = rows.count - 1
      }

    case "user":
      if let text = message.content?.nonEmpty {
        rows.append(ChatRow(id: makeID(), kind: .message(role: .user, text: text, isComplete: true)))
      }

    default:
      // Unknown role — skip, never crash (lenient).
      continue
    }
  }

  return rows
}

/// Walk `rows` backward for the nearest unfilled assistant tool row matching this `tool`
/// message — by `tool_call_id`, then by tool name — and attach its `result`.
private func attachToolResult(
  _ message: SessionMessage,
  into rows: inout [ChatRow],
  indexByKey: [String: Int]
) {
  let resultText = message.content?.nonEmpty

  // 1. Exact id match (fast path via the index, mirrors the live fold's keyed lookup).
  if let id = message.toolCallID?.nonEmpty, let idx = indexByKey[id] {
    fillToolResult(at: idx, resultText: resultText, in: &rows)
    return
  }

  // 2. Backward scan by name to the nearest tool row that has no result yet.
  let name = message.toolName?.nonEmpty
  for idx in stride(from: rows.count - 1, through: 0, by: -1) {
    guard case let .tool(rowName, _, _, detail, _) = rows[idx].kind else { continue }
    let hasResult = detail?.resultText?.nonEmpty != nil
    if hasResult { continue }
    if let name, rowName != name { continue }
    fillToolResult(at: idx, resultText: resultText, in: &rows)
    return
  }
}

/// Merge a tool result into the row at `idx`, preserving the existing args/title/name.
private func fillToolResult(at idx: Int, resultText: String?, in rows: inout [ChatRow]) {
  guard rows.indices.contains(idx),
        case let .tool(name, title, _, detail, durationS) = rows[idx].kind
  else { return }
  let merged = ToolDetail(
    argsText: detail?.argsText,
    args: detail?.args,
    resultText: resultText,
    inlineDiff: detail?.inlineDiff
  )
  rows[idx].kind = .tool(
    name: name, title: title, state: .complete,
    detail: merged.isEmpty ? nil : merged, durationS: durationS
  )
}

/// Parse a tool-call `arguments` JSON string into a structured value — only when it's an
/// object (a bare scalar stays raw text). Shared by `reconstructTranscript` (re-hydration)
/// and the live `tool.complete` fold in `ChatFeature`, so the args rendering is identical
/// on both the streamed and re-hydrated paths.
func parseToolArgs(_ string: String) -> JSONValue? {
  guard let data = string.data(using: .utf8),
        let value = try? JSONDecoder().decode(JSONValue.self, from: data),
        case .object = value
  else { return nil }
  return value
}
