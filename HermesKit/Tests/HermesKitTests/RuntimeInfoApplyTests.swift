import Foundation
import Testing

@testable import HermesKit

/// Pure `applyRuntimeInfo` — present fields overwrite, absent fields preserve.
struct RuntimeInfoApplyTests {
  @Test func fullInfoOverwritesEveryField() {
    var target = RuntimeInfoTarget(model: "old", reasoningEffort: "low", usage: nil)
    let info = SessionInfo(
      model: "gpt-5", reasoningEffort: "high",
      usage: Usage(contextUsed: 100, contextMax: 200, contextPercent: 50)
    )

    applyRuntimeInfo(info, into: &target)

    #expect(target.model == "gpt-5")
    #expect(target.reasoningEffort == "high")
    #expect(target.usage == Usage(contextUsed: 100, contextMax: 200, contextPercent: 50))
  }

  @Test func partialInfoPreservesExistingModelAndUsage() {
    let existingUsage = Usage(contextUsed: 80, contextMax: 200, contextPercent: 40)
    var target = RuntimeInfoTarget(model: "gpt-5", reasoningEffort: "high", usage: existingUsage)
    // Usage-only push (e.g. a mid-turn `session.info` carrying just usage).
    let info = SessionInfo(usage: Usage(contextUsed: 120, contextMax: 200, contextPercent: 60))

    applyRuntimeInfo(info, into: &target)

    #expect(target.model == "gpt-5")  // preserved — never blanked
    #expect(target.reasoningEffort == "high")  // preserved
    #expect(target.usage == Usage(contextUsed: 120, contextMax: 200, contextPercent: 60))  // overwritten
  }

  @Test func emptyInfoPreservesEverything() {
    let usage = Usage(contextUsed: 10, contextMax: 100, contextPercent: 10)
    var target = RuntimeInfoTarget(model: "claude", reasoningEffort: "medium", usage: usage)

    applyRuntimeInfo(SessionInfo(), into: &target)

    #expect(target.model == "claude")
    #expect(target.reasoningEffort == "medium")
    #expect(target.usage == usage)
  }

  @Test func emptyStringModelAndReasoningPreserveExisting() {
    // A server push carrying empty-string `model`/`reasoningEffort` must NOT blank the
    // existing values (matches the live `.sessionInfo` fold's `.nonEmpty` guard) — guards
    // against re-introducing the blank-model regression.
    let usage = Usage(contextUsed: 10, contextMax: 100, contextPercent: 10)
    var target = RuntimeInfoTarget(model: "claude", reasoningEffort: "high", usage: nil)

    applyRuntimeInfo(SessionInfo(model: "", reasoningEffort: "", usage: usage), into: &target)

    #expect(target.model == "claude")  // empty string preserved, not blanked
    #expect(target.reasoningEffort == "high")  // empty string preserved
    #expect(target.usage == usage)  // usage still applied
  }

  @Test func modelOnlyInfoLeavesUsageUntouched() {
    let usage = Usage(contextUsed: 10, contextMax: 100, contextPercent: 10)
    var target = RuntimeInfoTarget(model: "old", reasoningEffort: nil, usage: usage)

    applyRuntimeInfo(SessionInfo(model: "new"), into: &target)

    #expect(target.model == "new")
    #expect(target.reasoningEffort == nil)
    #expect(target.usage == usage)  // not zeroed by a model-only push
  }

  @Test func zeroUsageFromColdResumePreservesCachedUsage() {
    // A freshly-resumed agent reports an all-zero usage until its first turn re-counts the
    // loaded history. That placeholder must NOT clobber the real (cached) context gauge.
    let cached = Usage(contextUsed: 42_000, contextMax: 200_000, contextPercent: 21)
    var target = RuntimeInfoTarget(model: "claude", reasoningEffort: nil, usage: cached)

    // `_get_usage` for a not-yet-run resumed agent: context_max known, everything else 0.
    let coldUsage = Usage(input: 0, output: 0, total: 0, contextUsed: 0, contextMax: 200_000, contextPercent: 0)
    applyRuntimeInfo(SessionInfo(model: "claude", usage: coldUsage), into: &target)

    #expect(target.usage == cached)  // preserved — the zero placeholder didn't win
  }

  @Test func zeroUsageStillAppliesWhenNothingCached() {
    // A genuinely fresh session (no cached usage) takes the zero — there's nothing better to
    // show, and a later turn updates it.
    var target = RuntimeInfoTarget(model: "claude", reasoningEffort: nil, usage: nil)
    let coldUsage = Usage(total: 0, contextUsed: 0, contextMax: 200_000, contextPercent: 0)

    applyRuntimeInfo(SessionInfo(usage: coldUsage), into: &target)

    #expect(target.usage == coldUsage)
  }

  @Test func realUsageOverwritesCached() {
    // A usage with an actual consumption signal still overwrites (the normal live path).
    let cached = Usage(contextUsed: 10, contextMax: 200_000, contextPercent: 0)
    var target = RuntimeInfoTarget(model: "claude", reasoningEffort: nil, usage: cached)
    let fresh = Usage(total: 5_000, contextUsed: 90_000, contextMax: 200_000, contextPercent: 45)

    applyRuntimeInfo(SessionInfo(usage: fresh), into: &target)

    #expect(target.usage == fresh)
  }
}
