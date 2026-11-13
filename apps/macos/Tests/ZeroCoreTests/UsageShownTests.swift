import Foundation
import Testing
@testable import ZeroCore

private let now = 1_800_000_000

private func account(_ id: String, _ cli: Provider = .claude) -> ZerodLink.SignIn {
    var signin = ZerodLink.SignIn(cli: cli, kind: .claudeHome, label: "\(id)@example.com")
    signin.id = id
    return signin
}

private func usage(week: Double, five: Double? = nil, weekResets: Int = now + 86_400) throws -> Usage {
    var windows = [#"{"name":"7 days","used":\#(week),"resetsAt":\#(weekResets)}"#]
    if let five { windows.insert(#"{"name":"5 hours","used":\#(five),"resetsAt":\#(now + 3_600)}"#, at: 0) }
    let json = #"{"limited":false,"windows":[\#(windows.joined(separator: ","))]}"#
    return try JSONDecoder().decode(Usage.self, from: Data(json.utf8))
}

/// Every account with usage known, the most used first (by its fullest window that hasn't reset): the rail's mark is
/// the first, its card all of them.
@Test func everyAccountShowsMostUsedFirst() throws {
    let signins = [account("a"), account("b", .codex), account("c"), account("k")]
    let known = [
        "a": try usage(week: 0.2, five: 0.4), "b": try usage(week: 0.7), "c": try usage(week: 0.95, weekResets: now - 60),
        "k": try usage(week: 0.5),
    ]
    #expect(UsageShown.accounts(signins: signins, usage: known, now: now).map(\.0.id) == ["b", "k", "a", "c"], "c's week has reset")
    #expect(UsageShown.accounts(signins: signins, usage: [:], now: now).isEmpty, "nothing known: nothing to show")
}

/// What a window shows: its share while it hasn't reset, none once it has.
@Test func aWindowThatHasResetIsUnused() throws {
    let known = try usage(week: 0.6, weekResets: now - 1)
    #expect(UsageShown.used(known.windows[0], now: now) == 0)
    #expect(UsageShown.used(try usage(week: 1.4).windows[0], now: now) == 1)
}

/// An account's one ring is its fullest window, the one that stops it first; level, the week (the longer wait).
@Test func theFullestWindowIsTheOneShown() throws {
    #expect(UsageShown.fullest(try usage(week: 0.73), now: now)?.name == "7 days")
    #expect(UsageShown.fullest(try usage(week: 0.2, five: 0.4), now: now)?.name == "5 hours")
    #expect(UsageShown.fullest(try usage(week: 0, five: 0), now: now)?.name == "7 days")
    #expect(UsageShown.fullest(try usage(week: 0.6, five: 0.3, weekResets: now - 1), now: now)?.name == "5 hours", "the week has reset")
}

private func decode(_ json: String) throws -> Usage { try JSONDecoder().decode(Usage.self, from: Data(json.utf8)) }

/// At its limit until a reset, an account shows as full whatever its figures (its CLI said so in an error, without
/// them); once that reset has passed, its figures again.
@Test func anAccountAtItsLimitIsFullUntilItResets() throws {
    let stopped = try decode(
        #"{"limited":true,"resetsAt":\#(now + 600),"windows":[{"name":"7 days","used":0.4,"resetsAt":\#(now + 86_400)}]}"#)
    #expect(UsageShown.limited(stopped, now: now))
    #expect(UsageShown.used(stopped, now: now) == 1)
    #expect(!UsageShown.limited(stopped, now: now + 601))
    #expect(UsageShown.used(stopped, now: now + 601) == 0.4)
    let saidOnly = try decode(#"{"limited":true,"resetsAt":\#(now + 600),"windows":[]}"#)
    let signins = [account("s"), account("n"), account("u")]
    let known = [
        "s": saidOnly, "n": try decode(#"{"limited":false,"windows":[],"noLimits":true}"#),
        "u": try decode(#"{"limited":false,"windows":[]}"#),
    ]
    #expect(
        Set(UsageShown.accounts(signins: signins, usage: known, now: now).map(\.0.id)) == ["s", "n"],
        "at a limit, or no plan limits: shown; nothing known: not")
}

/// How old an account's figures are: its oldest window's read, for the tooltip once it's over half an hour.
@Test func theFiguresAgeIsTheirOldestRead() throws {
    let usage = try decode(
        #"{"limited":false,"windows":[{"name":"5 hours","used":0.1,"readAt":\#(now - 120)},{"name":"7 days","used":0.4,"readAt":\#(now - 2_700)}]}"#
    )
    #expect(UsageShown.stale(usage, now: now) == "Read 45 min ago")
    let fresh = try decode(#"{"limited":false,"windows":[{"name":"7 days","used":0.4,"readAt":\#(now - 600)}]}"#)
    #expect(UsageShown.stale(fresh, now: now) == nil)
    #expect(
        UsageShown.stale(try decode(#"{"limited":false,"windows":[{"name":"7 days","used":0.4,"readAt":\#(now - 3 * 3_600)}]}"#), now: now)
            == "Read 3 h ago")
}

/// The most recently used account first (the rail's mark), whatever its figures; accounts not used lately after them,
/// the most used first; one spent (days ago, here) after all that can run.
@Test func theMostRecentlyUsedAccountComesFirst() throws {
    let signins = [account("spent"), account("recent", .codex), account("other"), account("idle")]
    let known = [
        "spent": try usage(week: 1), "recent": try usage(week: 0.2), "other": try usage(week: 0.5), "idle": try usage(week: 0.7),
    ]
    let last = ["spent": now - 3 * 86_400, "recent": now - 60, "other": now - 3_600]
    #expect(
        UsageShown.accounts(signins: signins, usage: known, lastUsed: last, now: now).map(\.0.id) == ["recent", "other", "idle", "spent"])
}

/// An account at its limit can't be the one in use: it comes after every account that can run, however recent its
/// last turn; when all are at theirs, the most recent first.
@Test func anAccountAtItsLimitIsNeverTheMostRecent() throws {
    let signins = [account("full"), account("free"), account("idle")]
    let known = ["full": try usage(week: 1), "free": try usage(week: 0.3), "idle": try usage(week: 0.1)]
    let last = ["full": now - 60, "free": now - 3_600]
    #expect(UsageShown.accounts(signins: signins, usage: known, lastUsed: last, now: now).map(\.0.id) == ["free", "idle", "full"])
    let allFull = ["full": try usage(week: 1), "free": try usage(week: 1), "idle": try usage(week: 1)]
    #expect(UsageShown.accounts(signins: signins, usage: allFull, lastUsed: last, now: now).map(\.0.id) == ["full", "free", "idle"])
}

/// The card's groups: one per CLI, in the order their first account comes, each keeping its accounts' order.
@Test func accountsGroupByCLIInOrderOfTheirFirst() throws {
    let shown = try [account("c1", .codex), account("a1"), account("c2", .codex), account("a2")].map { ($0, try usage(week: 0.1)) }
    #expect(UsageShown.byCLI(shown).map { $0.map(\.0.id) } == [["c1", "c2"], ["a1", "a2"]])
}
