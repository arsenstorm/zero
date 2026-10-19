import Testing
@testable import ZeroCore

@Test func soloReplyTakesLastSpokenBlockAfterPrompt() {
    let screen = """
    ⏺ Earlier answer, before the message.

    ✻ Worked for 3s · done 11:20 PM

    〉 hi

    ● Hi Arsen. What are we working on?

    ✳ Worked for 1s · done 11:22 PM

    ❯ next thing typed but not sent
    """
    #expect(SoloAdapter.lastReply(in: screen, after: "hi") == "Hi Arsen. What are we working on?")
}

@Test func soloReplySkipsToolCallsAndKeepsParagraphs() {
    let screen = """
    ❯ fix the spinner

    ⏺ Bash(make run)
      ⎿  built

    ⏺ Installed and pushed.

      The spinner is now a Core Animation arc.

    ✻ Churned for 1m · done 11:23 PM
    """
    #expect(SoloAdapter.lastReply(in: screen, after: "fix the spinner") == "Installed and pushed.\n\nThe spinner is now a Core Animation arc.")
}
