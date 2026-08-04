import SnapshotTesting
import SwiftUI
import XCTest

@testable import HermesMobile

/// Snapshots for chat Markdown tables (#59). Reducer tests can't see layout, so these are
/// the regression net for the two symptoms the issue reported: a wide table clipped at the
/// trailing edge with truncated cells, and a phantom vertical gap around the table.
///
/// Every case renders the full `MarkdownText` path (parse → `MarkdownTableView`) pinned to
/// the device width, so the snapshot shows exactly what the transcript's hosting cell would
/// measure: a table wider than the viewport pans (only its first screenful is captured, with
/// no ellipsis and no squeezed columns), a table that fits renders inline at natural column
/// widths, and the image's height hugs the content.
final class MarkdownTableSnapshotTests: SnapshotTestCase {
  /// Pinned to the device width so a wide table is genuinely over-wide (as on a phone),
  /// rather than being handed an unbounded proposal by `.sizeThatFits`.
  private var width: CGFloat { device.size?.width ?? 390 }

  private func table(_ markdown: String) -> some View {
    MarkdownText(text: markdown)
      .padding()
      .frame(width: width)
      .background(Color(uiColor: .systemBackground))
  }

  /// The issue's repro shape: four columns, one of them multi-sentence prose. The long
  /// cells must WRAP at `MarkdownTableView.columnMaxWidth` (no "…" truncation, no cell
  /// squeezed to a sliver), and the columns overflow the viewport so the grid pans
  /// horizontally instead of clipping its content away.
  func testMarkdownTable_wideLongContent() {
    let markdown = """
      Here's the comparison:

      | Field | Type | Required | Notes |
      | --- | --- | --- | --- |
      | `session_id` | string | yes | Identifies the live runtime session. It rides on the event frame, never inside the message body. |
      | `reasoning` | string | no | Present only when the selected model advertises reasoning support in `model.options`. |
      | `usage` | object | no | Token counts for the turn. |

      That's the whole envelope.
      """
    assertSnapshot(of: table(markdown), as: componentImage())
  }

  /// The same wide table rendered at its natural content width (no viewport pin), which is
  /// what the horizontal `ScrollView` pans over. Nothing is lost off the trailing edge and
  /// no cell is ellipsised — the long column simply wraps at `columnMaxWidth` while the
  /// short columns stay narrow. The device-width shot above can only ever capture the first
  /// screenful, so this is the case that actually locks in "no truncation".
  func testMarkdownTable_wideContentUnclipped() {
    let view = MarkdownTableView(
      headers: ["Field", "Type", "Required", "Notes"],
      rows: [
        ["`session_id`", "string", "yes",
         "Identifies the live runtime session. It rides on the event frame, never inside the message body."],
        ["`reasoning`", "string", "no",
         "Present only when the selected model advertises reasoning support in `model.options`."],
        ["`usage`", "object", "no", "Token counts for the turn."],
      ]
    )
    .padding()
    // A generous viewport, not `.sizeThatFits`' own proposal: the horizontal `ScrollView`
    // is flexible along its scroll axis, so the compressed-fit render would collapse it to
    // zero width. 700pt is wider than the grid's content, so the whole table is visible.
    .frame(width: 700, alignment: .leading)
    .background(Color(uiColor: .systemBackground))
    assertSnapshot(of: view, as: componentImage())
  }

  /// A small 2×2 table renders inline: columns take their natural (narrow) width, nothing
  /// stretches to fill the row, and there is nothing to pan.
  func testMarkdownTable_small() {
    let markdown = """
      | Key | Value |
      | --- | --- |
      | on | true |
      | off | false |
      """
    assertSnapshot(of: table(markdown), as: componentImage())
  }

  /// Ragged rows: a row with fewer cells than there are headers pads with empty cells
  /// (and a row with an extra cell widens the grid) rather than dropping or misaligning
  /// columns.
  func testMarkdownTable_ragged() {
    let markdown = """
      | A | B | C |
      | --- | --- | --- |
      | 1 | 2 |
      | 1 | 2 | 3 |
      """
    assertSnapshot(of: table(markdown), as: componentImage())
  }

  /// The degenerate single-column case. One column can never overflow the viewport (the
  /// cap is narrower than the screen), so the long cell must WRAP at `columnMaxWidth` and
  /// the grid must not stretch to fill the row — it stays left-aligned at its own width.
  func testMarkdownTable_singleColumn() {
    let markdown = """
      | Note |
      | --- |
      | Identifies the live runtime session. It rides on the event frame, never inside the message body. |
      | Short. |
      """
    assertSnapshot(of: table(markdown), as: componentImage())
  }

  /// A table surrounded by every other block segment (heading, prose, list, blockquote,
  /// fenced code). The table must sit in the `VStack`'s normal 8pt rhythm — no phantom gap
  /// above or below it (the second symptom in #59) — and the neighbouring segments must
  /// keep their own full-width layout rather than being pulled to the table's width.
  func testMarkdownTable_midProse() {
    let markdown = """
      ## Event envelope

      Every frame carries the same envelope:

      - the id lives on the frame
      - the body is opaque

      | Field | Required |
      | --- | --- |
      | `session_id` | yes |
      | `usage` | no |

      > Unknown fields decode leniently.

      ```json
      {"type": "message.delta"}
      ```

      That's the whole envelope.
      """
    assertSnapshot(of: table(markdown), as: componentImage())
  }
}
