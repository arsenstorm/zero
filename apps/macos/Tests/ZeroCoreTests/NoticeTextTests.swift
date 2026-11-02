import Foundation
import Testing
@testable import ZeroCore

@Test func aNoticesSignInLinkOpensAndOtherWordsStayAsWritten() {
    let signIn = NoticeText.attributed("CVE lookup needs you to sign in on your Mac: [open its sign-in page](https://cve.example/authorize?x=1)")
    #expect(String(signIn.characters) == "CVE lookup needs you to sign in on your Mac: open its sign-in page")
    #expect(signIn.runs.compactMap(\.link) == [URL(string: "https://cve.example/authorize?x=1")!])
    #expect(String(NoticeText.attributed("Allowed without asking: rm *.tmp *.log").characters) == "Allowed without asking: rm *.tmp *.log")
}
