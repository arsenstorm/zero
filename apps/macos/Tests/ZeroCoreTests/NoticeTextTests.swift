import Foundation
import Testing
@testable import ZeroCore

@Test func aNoticesSignInLinkOpensAndOtherWordsStayAsWritten() {
    let signIn = NoticeText.attributed(
        "CVE lookup needs you to sign in on your Mac: [open its sign-in page](https://cve.example/authorize?x=1)")
    #expect(String(signIn.characters) == "CVE lookup needs you to sign in on your Mac: open its sign-in page")
    #expect(signIn.runs.compactMap(\.link) == [URL(string: "https://cve.example/authorize?x=1")!])
    #expect(String(NoticeText.attributed("Allowed without asking: rm *.tmp *.log").characters) == "Allowed without asking: rm *.tmp *.log")
}

/// Zero's word to an agent about its ask, folded in the chat: said for the user, what came of it, not "The user…".
@Test func anAsksOutcomeReadsAsWhatCameOfIt() {
    #expect(
        NoticeText.headline("The user answered your ask k3x9qa (\"Ship it?\"): Something else: not yet\nmore")
            == "Ask answered with “Something else: not yet”")
    #expect(NoticeText.headline("The user declined your ask k3x9qa (\"Ship it?\"): later") == "Ask declined")
    #expect(
        NoticeText.headline("Your ask k3x9qa (\"Ship it?\") expired without an answer from the user. Decide without it or ask again.")
            == "Ask expired")
    #expect(NoticeText.headline("The user ran your command k3x9qa (`ls`). It succeeded (exit 0).") == "Command ran")
    #expect(NoticeText.headline("The user rejected your command k3x9qa (`rm -rf x`): no") == "Command rejected")
    #expect(NoticeText.headline("1 new event on what you follow:") == nil)
}
