import Testing

@testable import HermesKit

/// `ClarifyChoice.split` mirrors upstream `strip_recommended`: the server suffixes the first
/// of two or more choices with `" (Recommended)"`; the app shows a badge and sends the bare
/// label.
@Suite struct ClarifyChoiceTests {
  @Test func suffixPresent() {
    let split = ClarifyChoice.split("Use SwiftUI (Recommended)")
    #expect(split.label == "Use SwiftUI")
    #expect(split.isRecommended)
  }

  @Test func suffixAbsent() {
    let split = ClarifyChoice.split("Use UIKit")
    #expect(split.label == "Use UIKit")
    #expect(!split.isRecommended)
  }

  @Test(arguments: ["Use SwiftUI (recommended)", "Use SwiftUI (RECOMMENDED)", "Use SwiftUI (ReCommended)"])
  func suffixMatchesCaseInsensitively(raw: String) {
    let split = ClarifyChoice.split(raw)
    #expect(split.label == "Use SwiftUI")
    #expect(split.isRecommended)
  }

  @Test func surroundingWhitespaceIsTrimmed() {
    #expect(ClarifyChoice.split("  Use SwiftUI   (Recommended)  ") == ("Use SwiftUI", true))
    #expect(ClarifyChoice.split("  Use UIKit \n") == ("Use UIKit", false))
  }

  @Test func onlyATrailingMarkerCounts() {
    #expect(ClarifyChoice.split("(Recommended) Use SwiftUI") == ("(Recommended) Use SwiftUI", false))
    #expect(ClarifyChoice.split("Use SwiftUI (Recommended) later") == ("Use SwiftUI (Recommended) later", false))
  }

  @Test func loneChoiceIsLeftUntouched() {
    // The server never marks a lone choice (nothing to prefer it over).
    #expect(ClarifyChoice.split("Proceed") == ("Proceed", false))
  }

  @Test func markerAloneIsNeverAnEmptyLabel() {
    #expect(ClarifyChoice.split("(Recommended)") == ("(Recommended)", false))
  }

  @Test func recommendedChoiceInADecodedRequestSplitsCleanly() throws {
    let request = ClarifyRequest(requestID: nil, question: "Framework?", choices: ["SwiftUI (Recommended)", "UIKit"])
    #expect(request.choices.map { ClarifyChoice.split($0).label } == ["SwiftUI", "UIKit"])
    #expect(request.choices.map { ClarifyChoice.split($0).isRecommended } == [true, false])
  }
}
