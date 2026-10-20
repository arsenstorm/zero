import Testing
@testable import ZeroCore

@MainActor @Test func accountsSwitchAtTheThresholdInEitherWindow() {
    #expect(!ClaudeAccounts.exhausted(.init(fiveHour: 97, sevenDay: 60)))
    #expect(ClaudeAccounts.exhausted(.init(fiveHour: 98, sevenDay: 10)))
    #expect(ClaudeAccounts.exhausted(.init(fiveHour: nil, sevenDay: 99.5)))
    #expect(ClaudeAccounts.accessToken(#"{"claudeAiOauth":{"accessToken":"t"}}"#) == "t")
}
