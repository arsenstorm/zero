import Testing
@testable import ZeroCore

/// How long ago a task last moved, as a list's corner has room for: Linear's "8h", "1d".
@Test func howLongAgoIsShortAndRoundsDown() {
    let now = 10_000_000_000
    #expect(Ago.short(now - 30_000, now: now) == "now")
    #expect(Ago.short(now - 5 * 60_000 - 59_000, now: now) == "5m")
    #expect(Ago.short(now - 8 * 3_600_000, now: now) == "8h")
    #expect(Ago.short(now - 26 * 3_600_000, now: now) == "1d")
    #expect(Ago.short(now - 15 * 86_400_000, now: now) == "2w")
    #expect(Ago.short(now + 60_000, now: now) == "now", "a clock a little ahead isn't the future")
}
