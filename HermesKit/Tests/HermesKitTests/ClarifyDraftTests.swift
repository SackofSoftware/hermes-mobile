import Foundation
import Testing

@testable import HermesKit

/// The clarify card's form rules (`ClarifyDraft`), the locked-answer display, and which cards
/// `ChatView` gives layout priority (`isCompressibleCardPending`) — the logic behind the
/// rebuilt `ClarifyCardView`, kept in HermesKit so the view stays declarative.
@Suite struct ClarifyDraftTests {
  private let pickOne = ClarifyQuestion(
    qid: "q0", question: "Framework?", choices: ["SwiftUI (Recommended)", "UIKit"])
  private let pickMany = ClarifyQuestion(
    qid: "q1", question: "Targets?", choices: ["iOS", "macOS", "visionOS"], multiSelect: true)
  private let freeText = ClarifyQuestion(qid: "q2", question: "Name?")

  private var batch: ClarifyRequest {
    ClarifyRequest(requestID: nil, questions: [pickOne, pickMany, freeText], answerShape: .answers)
  }

  // MARK: - Picking

  @Test func nothingIsPreselected() {
    let draft = ClarifyDraft()
    #expect(!draft.isPicked("SwiftUI (Recommended)", in: pickOne))
    #expect(draft.answer(for: pickOne) == nil)
    #expect(draft.answers(for: batch).isEmpty)
    #expect(!draft.isComplete(for: batch))
  }

  @Test func singleSelectHoldsOnePickRadioStyle() {
    var draft = ClarifyDraft()
    draft.toggle("UIKit", in: pickOne)
    draft.toggle("SwiftUI (Recommended)", in: pickOne)
    #expect(draft.answer(for: pickOne) == .choices(["SwiftUI (Recommended)"]))
    draft.toggle("SwiftUI (Recommended)", in: pickOne)
    #expect(draft.answer(for: pickOne) == .choices(["SwiftUI (Recommended)"]), "tapping the pick again keeps it")
  }

  @Test func multiSelectTogglesInTheServersOrder() {
    var draft = ClarifyDraft()
    draft.toggle("visionOS", in: pickMany)
    draft.toggle("iOS", in: pickMany)
    #expect(draft.answer(for: pickMany) == .choices(["iOS", "visionOS"]))
    draft.toggle("visionOS", in: pickMany)
    #expect(draft.answer(for: pickMany) == .choices(["iOS"]))
    draft.toggle("iOS", in: pickMany)
    #expect(draft.answer(for: pickMany) == nil, "un-picking everything leaves no answer")
  }

  @Test func aChoiceTheQuestionDoesNotOfferIsIgnored() {
    var draft = ClarifyDraft()
    draft.toggle("Android", in: pickMany)
    #expect(draft.answer(for: pickMany) == nil)
  }

  // MARK: - Other / free text

  @Test func typingOtherReplacesThePicksAndPickingClearsTheText() {
    var draft = ClarifyDraft()
    draft.toggle("iOS", in: pickMany)
    draft.setText("  watchOS  ", for: pickMany)
    #expect(draft.answer(for: pickMany) == .other("watchOS"), "typed text goes out trimmed")
    #expect(!draft.isPicked("iOS", in: pickMany))

    draft.toggle("macOS", in: pickMany)
    #expect(draft.text(for: pickMany).isEmpty)
    #expect(draft.answer(for: pickMany) == .choices(["macOS"]))
  }

  @Test func blankTextIsNoAnswerAndKeepsThePicks() {
    var draft = ClarifyDraft()
    draft.toggle("UIKit", in: pickOne)
    draft.setText("   ", for: pickOne)
    #expect(draft.answer(for: pickOne) == .choices(["UIKit"]))
    draft.setText(" \n", for: freeText)
    #expect(draft.answer(for: freeText) == nil)
  }

  @Test func freeTextAnswersAsOther() {
    var draft = ClarifyDraft()
    draft.setText("feature/clarify", for: freeText)
    #expect(draft.answer(for: freeText) == .other("feature/clarify"))
  }

  // MARK: - Skip

  @Test func skipIsTheAnswerWhileItStandsAndAnyEditUnskips() {
    var draft = ClarifyDraft()
    draft.setText("draft", for: freeText)
    draft.toggleSkip(freeText)
    #expect(draft.isSkipped(freeText))
    #expect(draft.answer(for: freeText) == .skipped)
    draft.toggleSkip(freeText)
    #expect(draft.answer(for: freeText) == .other("draft"), "un-skipping brings the edit back")

    draft.toggleSkip(pickOne)
    draft.toggle("UIKit", in: pickOne)
    #expect(!draft.isSkipped(pickOne))
    #expect(draft.answer(for: pickOne) == .choices(["UIKit"]))
  }

  // MARK: - The form as a whole

  @Test func completeOnlyWhenEveryQuestionIsAnsweredOrSkipped() {
    var draft = ClarifyDraft()
    draft.toggle("UIKit", in: pickOne)
    draft.toggle("iOS", in: pickMany)
    #expect(!draft.isComplete(for: batch))
    draft.toggleSkip(freeText)
    #expect(draft.isComplete(for: batch))
    #expect(draft.answers(for: batch) == [
      "q0": .choices(["UIKit"]), "q1": .choices(["iOS"]), "q2": .skipped,
    ])
  }

  @Test func lockedQuestionsCountAsAnsweredAndAreNotResubmittedByTheDraft() {
    var request = batch
    request.lockedAnswers = ["q0": "SwiftUI", "q1": String?.none]
    var draft = ClarifyDraft()
    // An edit to a question that is now locked (a replay landed mid-edit) is not submitted:
    // the reducer re-sends the lock instead.
    draft.toggle("UIKit", in: pickOne)
    #expect(!draft.isComplete(for: request))
    draft.setText("app", for: freeText)
    #expect(draft.isComplete(for: request))
    #expect(draft.answers(for: request) == ["q2": .other("app")])
  }

  @Test func singleFormsKeyTheirAnswerOnTheEmptyKey() {
    let single = ClarifyRequest(requestID: nil, question: "Proceed?", choices: ["Yes", "No"])
    let question = single.questions[0]
    #expect(question.answerKey == "")
    var draft = ClarifyDraft()
    draft.toggle("Yes", in: question)
    #expect(draft.answers(for: single) == ["": .choices(["Yes"])])
  }

  // MARK: - Locked display

  @Test func lockedDisplayText() {
    var request = batch
    request.lockedAnswers = ["q0": "SwiftUI", "q1": #"["iOS","macOS"]"#, "q2": String?.none]
    #expect(request.isLocked(pickOne))
    #expect(request.lockedDisplayText(for: pickOne) == "SwiftUI")
    #expect(request.lockedDisplayText(for: pickMany) == "iOS, macOS")
    #expect(request.lockedDisplayText(for: freeText) == "Skipped")

    let open = batch
    #expect(!open.isLocked(pickOne))
    #expect(open.lockedDisplayText(for: pickOne) == nil)
    // The nil-qid single form can never be locked.
    let single = ClarifyRequest(requestID: nil, question: "Proceed?")
    #expect(!single.isLocked(single.questions[0]))
  }

  @Test func aLockedMultiSelectThatIsNotAnArrayShowsAsSent() {
    var request = batch
    request.lockedAnswers = ["q1": "typed other"]
    #expect(request.lockedDisplayText(for: pickMany) == "typed other")
  }

  // MARK: - Layout priority

  @Test @MainActor func onlyApprovalsAndMultiQuestionClarifyAreCompressible() {
    var state = ChatFeature.State(
      connection: ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t"))
    #expect(!state.isCompressibleCardPending, "no card")

    state.present(.approval(ApprovalRequest(command: "rm -rf build", detail: nil)))
    #expect(state.isCompressibleCardPending)

    state.present(.clarify(batch))
    #expect(state.isCompressibleCardPending, "a multi-question clarify absorbs the squeeze")

    state.present(.clarify(ClarifyRequest(requestID: nil, question: "Proceed?", choices: ["Yes", "No"])))
    #expect(!state.isCompressibleCardPending, "a single question hugs its form")

    state.present(.secret(.sudo, SecretPrompt(command: "apt install ripgrep")))
    #expect(!state.isCompressibleCardPending)
  }
}
