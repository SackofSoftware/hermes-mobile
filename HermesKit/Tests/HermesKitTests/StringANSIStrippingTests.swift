import Foundation
import Testing

@testable import HermesKit

/// `String.strippingANSI` (#36 follow-up): the agent formats slash-command output for a
/// terminal (SGR colors, cursor moves, box-drawing color runs); on mobile the introducing
/// ESC byte (0x1B) is invisible, so the sequences render as literal garbage (`[1;31m`,
/// `[0m`, `[38;2;255;215;0m`). Only ESC-introduced sequences are removed — normal text,
/// box-drawing, the mascot, and a literal `[abc]` with no ESC are preserved byte-for-byte.
struct StringANSIStrippingTests {
  /// ESC (0x1B) is invisible in source; spell it out for readable fixtures.
  private let esc = "\u{1B}"

  @Test func removesSGRColorCodes() {
    #expect("\(esc)[1;31mUnknown command: /foo\(esc)[0m".strippingANSI == "Unknown command: /foo")
    #expect("\(esc)[2;3mitalic dim\(esc)[0m".strippingANSI == "italic dim")
  }

  @Test func removes24BitTrueColorCodes() {
    // 24-bit foreground: ESC[38;2;R;G;Bm (gold), then reset.
    #expect("\(esc)[1;38;2;255;215;0mgold\(esc)[0m".strippingANSI == "gold")
  }

  @Test func removesLoneResetCode() {
    #expect("done\(esc)[0m".strippingANSI == "done")
  }

  @Test func plainTextIsUnchanged() {
    #expect("just plain text".strippingANSI == "just plain text")
    #expect("".strippingANSI == "")
    // No ESC anywhere → returned verbatim via the fast path.
    #expect("no escapes here 123 !@#".strippingANSI == "no escapes here 123 !@#")
  }

  @Test func boxDrawingAndMascotArePreserved() {
    // The mascot and box-drawing chrome must survive — they are not ESC-introduced.
    #expect("(^_^)?".strippingANSI == "(^_^)?")
    #expect("+---+\n| x |\n+---+".strippingANSI == "+---+\n| x |\n+---+")
    // Multibyte characters are untouched.
    #expect("↶ Undid 1 turn — café ☕".strippingANSI == "↶ Undid 1 turn — café ☕")
  }

  @Test func literalBracketTextWithoutESCIsPreserved() {
    // A literal `[abc]` / `[1;31m`-looking run with NO ESC prefix is ordinary text.
    #expect("[abc]".strippingANSI == "[abc]")
    #expect("array[1;31m] index".strippingANSI == "array[1;31m] index")
  }

  @Test func escPrefixedSequenceLookingLikeLiteralIsStripped() {
    // The visible `[1;31m` tail preceded by a REAL (invisible) ESC IS an escape sequence.
    #expect("\(esc)[1;31m".strippingANSI == "")
    #expect("a\(esc)[1;31mb".strippingANSI == "ab")
  }

  @Test func stripsMixedColorRunsKeepingContent() {
    let input = "\(esc)[1;31mUnknown command: /foo\(esc)[0m\n\(esc)[38;2;255;215;0m(^_^)?\(esc)[0m +---+"
    #expect(input.strippingANSI == "Unknown command: /foo\n(^_^)? +---+")
  }

  @Test func stripsCursorMovementAndOtherCSIFinals() {
    // CSI sequences with non-`m` finals (cursor moves, clear) are removed too.
    #expect("\(esc)[2J\(esc)[Hcleared".strippingANSI == "cleared")
    #expect("x\(esc)[3Dy".strippingANSI == "xy")
  }

  @Test func stripsOSCSequences() {
    // OSC (set window title): ESC ] ... BEL. And ST-terminated (ESC \) form.
    #expect("\(esc)]0;window title\u{07}body".strippingANSI == "body")
    #expect("\(esc)]8;;https://example.com\(esc)\\link".strippingANSI == "link")
  }

  @Test func stripsOtherTwoByteAndLoneTrailingESC() {
    // A two-byte Fe escape (ESC + a byte) is dropped; a lone trailing ESC is dropped.
    #expect("a\(esc)Mb".strippingANSI == "ab")
    #expect("tail\(esc)".strippingANSI == "tail")
  }
}
