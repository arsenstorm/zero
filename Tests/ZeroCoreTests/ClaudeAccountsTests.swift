import Testing
@testable import ZeroCore

@MainActor @Test func accountsSwitchAtTheThresholdOfTheWatchedLimit() {
    let busy = ClaudeAccounts.Usage(fiveHour: 98, sevenDay: 60)
    #expect(ClaudeAccounts.exhausted(busy, at: 98, watching: .either))
    #expect(ClaudeAccounts.exhausted(busy, at: 98, watching: .fiveHour))
    #expect(!ClaudeAccounts.exhausted(busy, at: 98, watching: .weekly))
    #expect(!ClaudeAccounts.exhausted(busy, at: 99, watching: .either))
    #expect(ClaudeAccounts.exhausted(.init(fiveHour: nil, sevenDay: 95), at: 95, watching: .weekly))
    #expect(ClaudeAccounts.accessToken(#"{"claudeAiOauth":{"accessToken":"t"}}"#) == "t")
}
