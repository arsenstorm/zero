import Foundation
import Testing
@testable import ZeroCore

/// A lead's row as zerod's board sends it: its team's state, its own, and a worker's when it has one.
private func row(
    _ id: String, state: String, own: String? = nil, worker: String? = nil, now: String? = nil, needs: String? = nil,
    asks: [String] = [], quiet: Bool = false, onYou: [(String, String)] = []
) -> BoardRow {
    let team = worker.map { #"[{"session":"w-\#(id)","state":"\#($0)","place":"w","asks":[]}]"# } ?? "[]"
    let json = """
        {"session":"\(id)","task":"Task \(id)","workspace":"zero","place":"p","online":true,"state":"\(state)","own":"\(own ?? state)",
         "now":\(now.map { "\"\($0)\"" } ?? "null"),"needs":\(needs.map { "\"\($0)\"" } ?? "null"),
         "asks":[\(asks.enumerated().map { #"{"id":"a\#($0.offset)","title":"\#($0.element)"}"# }.joined(separator: ","))],
         "workers":\(worker == nil ? 0 : 1),"team":\(team),"quiet":\(quiet),
         "issues":[\(onYou.map { #"{"ticket":"\#($0.0)","state":"you","text":"\#($0.1)","since":0}"# }.joined(separator: ","))]}
        """
    return try! JSONDecoder().decode(BoardRow.self, from: Data(json.utf8))
}

@Test func aTaskThatComesToNeedTheUserIsAnAlert() {
    let changes = TaskAlerts.changes(from: [row("1", state: "working")], to: [row("1", state: "needsYou", asks: ["Merge it?"])])
    #expect(changes.alerts == [TaskAlert(session: "1", kind: .needsYou, state: .needsYou, title: "Task 1", body: "Merge it?")])
    #expect(changes.cleared.isEmpty)
}

@Test func workingAndIdleAreNoAlert() {
    let changes = TaskAlerts.changes(from: [row("1", state: "idle")], to: [row("1", state: "working")])
    #expect(changes.alerts.isEmpty && changes.cleared.isEmpty)
}

@Test func aFinishedTaskSaysHowItEnded() {
    let changes = TaskAlerts.changes(from: [row("1", state: "working")], to: [row("1", state: "handed", needs: "Merge the PR")])
    #expect(
        changes.alerts == [TaskAlert(session: "1", kind: .finished, state: .handed, title: "Task 1", body: "Over to you: Merge the PR")])
    let done = TaskAlerts.changes(from: [row("1", state: "working")], to: [row("1", state: "done", now: "Fixed the build")])
    #expect(done.alerts.map(\.body) == ["Done: Fixed the build"])
}

@Test func aWorkerThatNeedsTheUserIsItsLeadsAlert() {
    // The lead works on; its worker asks: the lead's notification, saying it's a worker's.
    let changes = TaskAlerts.changes(
        from: [row("1", state: "working")], to: [row("1", state: "needsYou", own: "working", worker: "needsYou", asks: ["Which DB?"])])
    #expect(
        changes.alerts == [
            TaskAlert(session: "1", kind: .needsYou, state: .needsYou, title: "Task 1", body: "A worker needs you: Which DB?")
        ])
}

@Test func aWorkerFinishingIsNoAlert() {
    let changes = TaskAlerts.changes(
        from: [row("1", state: "working", worker: "working")], to: [row("1", state: "working", worker: "done")])
    #expect(changes.alerts.isEmpty)
}

@Test func anAlertMovedOnFromIsCleared() {
    // Answered from the inbox bar: back to work, so its notification goes.
    let answered = TaskAlerts.changes(from: [row("1", state: "needsYou")], to: [row("1", state: "working")])
    #expect(answered.alerts.isEmpty && answered.cleared == ["1"])
    // Archived: gone from the board.
    #expect(TaskAlerts.changes(from: [row("1", state: "done")], to: []).cleared == ["1"])
    // Read, a reply settles to Idle.
    #expect(TaskAlerts.changes(from: [row("1", state: "answered")], to: [row("1", state: "idle")]).cleared == ["1"])
}

@Test func theBadgeCountsTasksWaitingOnTheUser() {
    #expect(
        TaskAlerts.needingYou([
            row("1", state: "needsYou"), row("2", state: "needsYou", own: "working", worker: "needsYou"), row("3", state: "done"),
        ]) == 2)
}

@Test func theSameStandingIsntAnnouncedTwice() {
    let changes = TaskAlerts.changes(
        from: [row("1", state: "needsYou", asks: ["A?"])], to: [row("1", state: "needsYou", asks: ["A?", "B?"])])
    #expect(changes.alerts.isEmpty && changes.cleared.isEmpty)
}

@Test func notificationsArePlainText() {
    #expect(TaskAlerts.plain("**PR #12** is `open`, see [the diff](https://x.dev).") == "PR #12 is open, see the diff.")
    #expect(TaskAlerts.plain("## Done\n\n- [x] Tests pass\n- Ship _it_\n> quoted") == "Done · Tests pass · Ship it · quoted")
    #expect(TaskAlerts.plain("```swift\nlet a = 1\n```\nAfter") == "let a = 1 · After")
    #expect(TaskAlerts.plain(String(repeating: "word ", count: 100)).count <= 200)
    let alert = TaskAlerts.changes(from: [row("a", state: "working")], to: [row("a", state: "answered", now: "**Merged** `#42`")]).alerts[0]
    #expect(alert.body == "Replied: Merged #42")
}

@Test func aSettledTaskBackToTheSameEndAfterZerosTurnIsNoNewAlert() {
    // Merged, announced; Zero passes on an event, the task works a moment, and it's merged still: nothing new.
    var announced: [String: String] = [:]
    let merged = TaskAlerts.changes(from: [row("1", state: "working")], to: [row("1", state: "done")], announced: &announced)
    #expect(merged.alerts.count == 1)
    _ = TaskAlerts.changes(from: [row("1", state: "done")], to: [row("1", state: "working")], announced: &announced)
    #expect(TaskAlerts.changes(from: [row("1", state: "working")], to: [row("1", state: "done")], announced: &announced).alerts.isEmpty)
    // A task asking again is always news: its new question.
    _ = TaskAlerts.changes(
        from: [row("2", state: "working")], to: [row("2", state: "needsYou", asks: ["Merge it?"])], announced: &announced)
    _ = TaskAlerts.changes(from: [row("2", state: "needsYou")], to: [row("2", state: "working")], announced: &announced)
    #expect(
        TaskAlerts.changes(
            from: [row("2", state: "working")], to: [row("2", state: "needsYou", asks: ["Deploy it?"])], announced: &announced
        ).alerts.count == 1)
}

@Test func aReplyToATurnZeroStartedIsNoAlert() {
    // An event it follows passed on, a worker's report: the reply shows (unread), but there's nothing to tell.
    #expect(TaskAlerts.changes(from: [row("1", state: "working")], to: [row("1", state: "answered", quiet: true)]).alerts.isEmpty)
    #expect(
        TaskAlerts.changes(from: [row("1", state: "working")], to: [row("1", state: "answered")]).alerts.count == 1,
        "a reply to the user is")
    #expect(
        TaskAlerts.changes(from: [row("1", state: "working")], to: [row("1", state: "needsYou", asks: ["Merge it?"], quiet: true)]).alerts
            .count == 1,
        "what needs the user is news, whoever started the turn")
}

@Test func aTaskBackAtTheSameOpenQuestionAfterZerosTurnIsNoNewAlert() {
    // It asked, and was announced; an event and a worker's report each start a turn that ends on the same open ask.
    var announced: [String: String] = [:]
    #expect(
        TaskAlerts.changes(
            from: [row("1", state: "working")], to: [row("1", state: "needsYou", asks: ["Merge it?"])], announced: &announced
        ).alerts.count == 1)
    for _ in 0..<2 {
        _ = TaskAlerts.changes(
            from: [row("1", state: "needsYou", asks: ["Merge it?"])], to: [row("1", state: "working", asks: ["Merge it?"])],
            announced: &announced)
        #expect(
            TaskAlerts.changes(
                from: [row("1", state: "working", asks: ["Merge it?"])],
                to: [row("1", state: "needsYou", asks: ["Merge it?"], quiet: true)],
                announced: &announced
            ).alerts.isEmpty, "the same question, still open: nothing new")
    }
    // Another question is news.
    #expect(
        TaskAlerts.changes(
            from: [row("1", state: "working")], to: [row("1", state: "needsYou", asks: ["Merge it?", "Deploy it?"])], announced: &announced
        ).alerts.count == 1)
}

@Test func anAlertSoundedAtTheMacGoesToThePhoneIfItStillStandsMinutesLater() {
    let start = Date(timeIntervalSince1970: 1_000)
    let replied = TaskAlert(session: "1", kind: .finished, state: .answered, title: "Task 1", body: "Replied: done")
    let held = ["1": (alert: replied, at: start)]
    let still = [row("1", state: "answered")]
    #expect(TaskAlerts.due(held, rows: still, now: start + 299, lastInput: start).isEmpty, "not yet")
    #expect(
        TaskAlerts.due(held, rows: still, now: start + 300, lastInput: start) == [replied], "unseen five minutes on: the phone")
    #expect(TaskAlerts.due(held, rows: [row("1", state: "read")], now: start + 300, lastInput: start).isEmpty, "seen meanwhile")
    #expect(TaskAlerts.due(held, rows: [row("1", state: "working")], now: start + 300, lastInput: start).isEmpty, "moved on")
    #expect(
        TaskAlerts.due(held, rows: still, now: start + 300, lastInput: start + 60).isEmpty,
        "open in front, and the user was there after it came")
    #expect(
        TaskAlerts.due(held, rows: still, now: start + 300, lastInput: start - 1) == [replied],
        "open in front, but nobody there since")
    #expect(
        TaskAlerts.due(held, rows: still, now: start + 300, lastInput: start + 60).isEmpty,
        "at the Mac since it sounded, on another task: they were there to hear it, nothing goes on five minutes late")
}

@Test func anIssueThatTurnsToTheUserSaysWhichAndWhatItNeeds() {
    // A lead driving several issues: the one now on the user is the news, by its ticket, however the lead's row reads.
    var announced: [String: String] = [:]
    let first = TaskAlerts.changes(
        from: [row("1", state: "working")],
        to: [row("1", state: "needsYou", now: "Two PRs are green.", onYou: [("ENG-1", "merge decision")])], announced: &announced)
    #expect(first.alerts.first?.body == "ENG-1: merge decision")
    // Another issue on the user, the lead still Needs you: news too.
    let second = TaskAlerts.changes(
        from: [row("1", state: "needsYou", onYou: [("ENG-1", "merge decision")])],
        to: [row("1", state: "needsYou", onYou: [("ENG-1", "merge decision"), ("ENG-2", "the OCI Apply")])], announced: &announced)
    #expect(second.alerts.first?.body == "ENG-2: the OCI Apply")
}

@Test func anIssueStillOnTheUserIsNotNewsAgainAfterEachTurn() {
    // The lead works on other things and ends each turn with new words; the issue on the user hasn't changed, so the
    // notification it already gave isn't given again (it came three times, each about the same issue).
    var announced: [String: String] = [:]
    let issue = [("ENG-1", "Live in production; move it to PM review")]
    let first = TaskAlerts.changes(
        from: [row("1", state: "working")], to: [row("1", state: "needsYou", now: "Merged #1.", onYou: issue)], announced: &announced)
    #expect(first.alerts.count == 1)
    _ = TaskAlerts.changes(
        from: [row("1", state: "needsYou", now: "Merged #1.", onYou: issue)], to: [row("1", state: "working", onYou: issue)],
        announced: &announced)
    let again = TaskAlerts.changes(
        from: [row("1", state: "working", onYou: issue)], to: [row("1", state: "needsYou", now: "Opened #2.", onYou: issue)],
        announced: &announced)
    #expect(again.alerts.isEmpty, "the same issue, still on the user")
    // Asked something new meanwhile: news.
    let asked = TaskAlerts.changes(
        from: [row("1", state: "working", onYou: issue)],
        to: [row("1", state: "needsYou", now: "Opened #3.", asks: ["Merge #3?"], onYou: issue)], announced: &announced)
    #expect(asked.alerts.count == 1)
}

@Test func whatStandsAtLaunchIsNotNewsOnceTheTaskMovesAndComesBack() {
    // Zero reopened (an update): the issue already on the user isn't announced again the first time the lead works on
    // something else and comes back to it.
    let issue = [("ENG-1", "Live in production; move it to PM review")]
    let atLaunch = [row("1", state: "needsYou", now: "Merged #1.", onYou: issue)]
    var announced = TaskAlerts.announced(atLaunch)
    _ = TaskAlerts.changes(from: atLaunch, to: [row("1", state: "working", onYou: issue)], announced: &announced)
    let back = TaskAlerts.changes(
        from: [row("1", state: "working", onYou: issue)], to: [row("1", state: "needsYou", now: "Opened #2.", onYou: issue)],
        announced: &announced)
    #expect(back.alerts.isEmpty)
}

@Test func anIssueOverToTheUserIsDrawnOverToYouAndAnUnknownStateStillDecodes() {
    let issue = { (state: String) in
        try! JSONDecoder().decode(BoardRow.Issue.self, from: Data(#"{"ticket":"T-1","state":"\#(state)","text":"","since":0}"#.utf8))
    }
    #expect(issue("over").boardState == .handed)
    #expect(issue("you").boardState == .needsYou)
    #expect(issue("someday").boardState == .done)
}
