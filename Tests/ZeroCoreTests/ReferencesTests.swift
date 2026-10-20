import Foundation
import Testing
@testable import ZeroCore

@Test func referencesLinkIssuesAndPullRequests() {
    let text = "Fixed OPS-3096 and eng-9559 in #12846 and api#6518, see arsenstorm/zero#3. UTF-8 and issue #7 stay."
    let found = References.find(in: text, repo: "acme/app", linearApp: true)
    let ns = text as NSString
    #expect(found.map { ns.substring(with: $0.range) } == ["OPS-3096", "eng-9559", "#12846", "api#6518", "arsenstorm/zero#3", "#7"])
    #expect(found.map(\.url.absoluteString) == [
        "linear://acme/issue/OPS-3096",
        "linear://acme/issue/ENG-9559",
        "https://github.com/acme/app/pull/12846",
        "https://github.com/acme/api/pull/6518",
        "https://github.com/arsenstorm/zero/pull/3",
        "https://github.com/acme/app/pull/7",
    ])
    #expect(References.find(in: "#12846 at 064c6bb7b5", repo: nil, linearApp: false).isEmpty)
    #expect(References.find(in: "push at 064c6bb7b5, not 1234567 or deadbeef", repo: "acme/app", linearApp: false)
        .map(\.url.absoluteString) == ["https://github.com/acme/app/commit/064c6bb7b5"])
}

@Test func remotesParseToOwnerAndName() {
    #expect(References.parse("git@github.com:arsenstorm/zero.git") == "arsenstorm/zero")
    #expect(References.parse("https://github.com/acme/app") == "acme/app")
    #expect(References.parse("git@gitlab.com:a/b.git") == nil)
}
