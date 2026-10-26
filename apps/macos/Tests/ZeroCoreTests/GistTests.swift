import Testing
@testable import ZeroCore

@Test func gistTakesFiveWordsOfTheFirstLine() {
    #expect(Store.gist(of: "fix the flaky checkout spec, then open a PR\nmore detail") == "Fix the flaky checkout spec…")
    #expect(Store.gist(of: "Reply with the single word ready, then stop.") == "Reply with the single word…")
    #expect(Store.gist(of: "add dark mode") == "Add dark mode")
    #expect(Store.gist(of: "hi") == nil)
}
