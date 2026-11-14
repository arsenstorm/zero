import Testing
@testable import ZeroCore

/// A worker's report shows its state, whatever its answer says after it: the earliest state in its first line is the one.
@Test func aWorkersReportShowsItsState() {
    let reply = "\n\nReply to it with `zero send …`."
    let cases: [(String, String)] = [
        ("finished: PR #318 is open", "px-robot-heart"),
        ("is waiting on the user's answer (ask 7f3a): merge now?", "px-circle-question"),
        ("is waiting: CI on #319", "px-robot-sleeping"),
        ("is waiting on a background run: it carries on when it finishes.", "px-bot-task"),
        ("failed: the provider returned 529", "px-bot-xmark"),
        ("looks stuck: no output for 12 minutes", "px-robot-angry"),
        ("hit a usage limit", "px-robot-minus"),
        ("is blocked: needs staging access", "px-robot-ban"),
        ("stopped: its process ended", "px-bot-minus"),
        ("stopped without an answer", "px-robot"),
    ]
    for (state, icon) in cases {
        #expect(AgentIcons.given(from: "s142", text: "Worker ENG-142 auth-fix \(state)" + reply) == icon)
    }
    // An answer with another state's words in it doesn't take that state.
    #expect(AgentIcons.given(from: "s9", text: "Worker ENG-9 finished: the old test failed: now it passes") == "px-robot-heart")
}

/// Another task's words, and an agent's own wake-up, are its; Zero's own words keep the UI's icon.
@Test func whoseWordsAMessageIsDecidesItsIcon() {
    #expect(AgentIcons.given(from: "s90", text: "My migration renames plan_id too") == "px-bots")
    #expect(AgentIcons.given(from: "zero", text: "Scheduled: check #318's CI") == "px-robot-time")
    #expect(AgentIcons.given(from: "zero", text: "The user answered your ask 7f3a (\"x\"): yes") == nil)
    #expect(AgentIcons.given(from: "zero", text: "Watch: `log/test.log` printed `FAILED`") == nil)
    #expect(AgentIcons.notice("Following acme/app#318") == "px-robot-search")
    #expect(AgentIcons.notice("Interrupted") == nil)
}

/// The agent's `zero` steps are named for what they did; asks, lookups and refusals stay commands.
@Test func anAgentsZeroStepsAreNamed() {
    let step = AgentIcons.step
    #expect(
        step("zero spawn \"Fix the token refresh\" --label \"ENG-142 auth-fix\"")
            == .init(icon: "px-robot-plus", words: "Started a worker", detail: "ENG-142 auth-fix"))
    #expect(step("zero spawn 'Stream the export'")?.detail == "Stream the export")
    #expect(step("zero send ENG-90 \"Hold yours?\"") == .init(icon: "px-envelope-arrow-right", words: "Wrote to", detail: "ENG-90"))
    #expect(step("zero note \"PR open\" --waiting") == .init(icon: "px-robot-pen", words: "Noted", detail: "PR open"))
    #expect(
        step("zero issue ENG-142 over \"ready for review\"")
            == .init(icon: "px-ticket", words: "ENG-142 → over", detail: "ready for review"))
    #expect(
        step("zero later save the flaky export spec --link x")
            == .init(icon: "px-bookmark-plus", words: "Saved for later", detail: "the flaky export spec"))
    #expect(step("zero follow https://github.com/acme/app/pull/318 --mine")?.detail == "acme/app#318")
    #expect(step("zero watch -- gh pr checks 42 --watch") == .init(icon: "px-eye", words: "Watching", detail: "gh pr checks 42 --watch"))
    #expect(step("zero watch --file log/test.log --alert FAILED")?.detail == "log/test.log")
    #expect(
        step("zero done \"merged and deployed\" --confirm k3x")
            == .init(icon: "px-circle-check", words: "Done", detail: "merged and deployed"))
    #expect(step("zero blocked \"staging access\" --confirm k3x")?.icon == "px-robot-ban")
    for plain in ["zero done \"x\" --ask", "zero later view k3", "zero watch stop k3", "zero status", "git status", "zero sendx a b"] {
        #expect(step(plain) == nil)
    }
}
