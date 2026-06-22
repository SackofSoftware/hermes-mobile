import Foundation
import Testing

@testable import HermesKit

/// Raw-JSON decoding of the re-hydration payloads (`ActivateResponse` / `SessionMessage`).
/// Upholds "decode leniently, never crash": reasoning arrives under any of
/// `reasoning` / `reasoning_content` / `reasoning_details`, and `reasoning_details` may be a
/// provider-shaped non-string array — which must be tolerated (decoded via `try?`) without
/// throwing, with `reasoningText` resolving to the string variants.
struct SessionDecodingTests {
  private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
  }

  @Test func activateResponseDecodesReasoningStringVariants() throws {
    // `reasoning` is the preferred field; assert it resolves through `reasoningText`.
    let json = """
    {
      "session_id": "live1",
      "stored_session_id": "stored1",
      "running": true,
      "messages": [
        { "id": 1, "role": "assistant", "content": "answer", "reasoning": "step one" }
      ]
    }
    """
    let response = try decode(ActivateResponse.self, json)
    #expect(response.sessionID == "live1")
    #expect(response.storedSessionID == "stored1")
    #expect(response.running == true)
    #expect(response.messages.first?.reasoningText == "step one")
  }

  @Test func reasoningFallsBackToContentVariant() throws {
    // No `reasoning`, but `reasoning_content` present → that wins.
    let json = """
    { "id": 2, "role": "assistant", "content": "x", "reasoning_content": "from content" }
    """
    let message = try decode(SessionMessage.self, json)
    #expect(message.reasoningText == "from content")
  }

  @Test func nonStringReasoningDetailsArrayIsIgnoredAndDoesNotThrow() throws {
    // `reasoning_details` arrives as a provider-shaped ARRAY (not a string). The decoder must
    // NOT throw on it (decoded via `try?`); it's simply ignored, and `reasoningText` resolves
    // from the string variants instead.
    let json = """
    {
      "session_id": "live2",
      "messages": [
        {
          "id": 3,
          "role": "assistant",
          "content": "y",
          "reasoning": "wins",
          "reasoning_details": [
            { "type": "reasoning.text", "text": "block" }
          ]
        }
      ]
    }
    """
    // The whole payload must decode without throwing despite the non-string array.
    let response = try decode(ActivateResponse.self, json)
    let message = try #require(response.messages.first)
    #expect(message.reasoningDetails == nil)  // array form ignored, never crashes
    #expect(message.reasoningText == "wins")  // string variant resolves
  }

  @Test func reasoningDetailsStringFormIsSurfaced() throws {
    // When `reasoning_details` *is* a plain string (and the others absent), surface it.
    let json = """
    { "id": 4, "role": "assistant", "content": "z", "reasoning_details": "plain string detail" }
    """
    let message = try decode(SessionMessage.self, json)
    #expect(message.reasoningText == "plain string detail")
  }

  @Test func toolCallsAndCallIDDecode() throws {
    // The assistant `tool_calls` entry (raw `arguments` string) and the linked `tool`
    // result's `tool_call_id` — both feed `reconstructTranscript` on resume hydration.
    let assistant = """
    {
      "id": 1, "role": "assistant", "content": "",
      "tool_calls": [
        { "id": "call_1", "type": "function",
          "function": { "name": "terminal", "arguments": "{\\"command\\":\\"git status\\"}" } }
      ]
    }
    """
    let assistantMessage = try decode(SessionMessage.self, assistant)
    let call = try #require(assistantMessage.toolCalls?.first)
    #expect(call.id == "call_1")
    #expect(call.name == "terminal")
    #expect(call.arguments == #"{"command":"git status"}"#)

    let result = """
    { "id": 2, "role": "tool", "content": "clean", "tool_name": "terminal", "tool_call_id": "call_1" }
    """
    let resultMessage = try decode(SessionMessage.self, result)
    #expect(resultMessage.toolCallID == "call_1")
  }
}
