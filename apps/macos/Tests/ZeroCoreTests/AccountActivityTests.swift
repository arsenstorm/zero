import Foundation
import Testing
@testable import ZeroCore

/// One Activity: every account's turns on a day together, each still named, a removed one's too.
@Test func accountsTurnsAreCombinedByDay() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    var gone = ZerodLink.SignIn(cli: .claude, kind: .token, label: "a@example.com")
    gone.id = "a"
    let hour = 1_800_000_000 / 3600
    let activity = AccountActivity(
        hours: ["a": [hour: 2], "claude": [hour + 1: 1, hour - 48: 4]], accounts: ["a": gone], calendar: calendar)
    let day = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(hour * 3600)))
    #expect(activity.totals[day] == 3)
    #expect(activity.days[day] == ["a": 2, "claude": 1])
    #expect(activity.names == ["a": "a@example.com", "claude": "Claude Code's own sign-in"])
}
