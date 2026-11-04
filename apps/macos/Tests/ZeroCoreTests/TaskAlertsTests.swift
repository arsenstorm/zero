import Foundation
import Testing
@testable import ZeroCore

/// A lead's row as zerod's board sends it: its team's state, its own, and a worker's when it has one.
private func row(_ id: String, state: String, own: String? = nil, worker: String? = nil, now: String? = nil, needs: String? = nil,
                 asks: [String] = [], quiet: Bool = false) -> BoardRow {
    let team = worker.map { #"[{"session":"w-\#(id)","state":"\#($0)","place":"w","asks":[]}]"# } ?? "[]"
    let json = """
    {"session":"\(id)","task":"Task \(id)","workspace":"zero","place":"p","online":true,"state":"\(state)","own":"\(own ?? state)",
     "now":\(now.map { "\"\($0)\"" } ?? "null"),"needs":\(needs.map { "\"\($0)\"" } ?? "null"),
     "asks":[\(asks.enumerated().map { #"{"id":"a\#($0.offset)","title":"\#($0.element)"}"# }.joined(separator: ","))],
     "workers":\(worker == nil ? 0 : 1),"team":\(team),"quiet":\(quiet)}
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
    #expect(changes.alerts == [TaskAlert(session: "1", kind: .finished, state: .handed, title: "Task 1", body: "Over to you: Merge the PR")])
    let done = TaskAlerts.changes(from: [row("1", state: "working")], to: [row("1", state: "done", now: "Fixed the build")])
    #expect(done.alerts.map(\.body) == ["Done: Fixed the build"])
}

@Test func aWorkerThatNeedsTheUserIsItsLeadsAlert() {
    // The lead works on; its worker asks: the lead's notification, saying it's a worker's.
    let changes = TaskAlerts.changes(from: [row("1", state: "working")], to: [row("1", state: "needsYou", own: "working", worker: "needsYou", asks: ["Which DB?"])])
    #expect(changes.alerts == [TaskAlert(session: "1", kind: .needsYou, state: .needsYou, title: "Task 1", body: "A worker needs you: Which DB?")])
}

@Test func aWorkerFinishingIsNoAlert() {
    let changes = TaskAlerts.changes(from: [row("1", state: "working", worker: "working")], to: [row("1", state: "working", worker: "done")])
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
    #expect(TaskAlerts.needingYou([row("1", state: "needsYou"), row("2", state: "needsYou", own: "working", worker: "needsYou"), row("3", state: "done")]) == 2)
}

@Test func theSameStandingIsntAnnouncedTwice() {
    let changes = TaskAlerts.changes(from: [row("1", state: "needsYou", asks: ["A?"])], to: [row("1", state: "needsYou", asks: ["A?", "B?"])])
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
    _ = TaskAlerts.changes(from: [row("2", state: "working")], to: [row("2", state: "needsYou", asks: ["Merge it?"])], announced: &announced)
    _ = TaskAlerts.changes(from: [row("2", state: "needsYou")], to: [row("2", state: "working")], announced: &announced)
    #expect(TaskAlerts.changes(from: [row("2", state: "working")], to: [row("2", state: "needsYou", asks: ["Deploy it?"])], announced: &announced).alerts.count == 1)
}

@Test func aReplyToATurnZeroStartedIsNoAlert() {
    // An event it follows passed on, a worker's report: the reply shows (unread), but there's nothing to tell.
    #expect(TaskAlerts.changes(from: [row("1", state: "working")], to: [row("1", state: "answered", quiet: true)]).alerts.isEmpty)
    #expect(TaskAlerts.changes(from: [row("1", state: "working")], to: [row("1", state: "answered")]).alerts.count == 1, "a reply to the user is")
    #expect(TaskAlerts.changes(from: [row("1", state: "working")], to: [row("1", state: "needsYou", asks: ["Merge it?"], quiet: true)]).alerts.count == 1,
            "what needs the user is news, whoever started the turn")
}

@Test func aTaskBackAtTheSameOpenQuestionAfterZerosTurnIsNoNewAlert() {
    // It asked, and was announced; an event and a worker's report each start a turn that ends on the same open ask.
    var announced: [String: String] = [:]
    #expect(TaskAlerts.changes(from: [row("1", state: "working")], to: [row("1", state: "needsYou", asks: ["Merge it?"])], announced: &announced).alerts.count == 1)
    for _ in 0..<2 {
        _ = TaskAlerts.changes(from: [row("1", state: "needsYou", asks: ["Merge it?"])], to: [row("1", state: "working", asks: ["Merge it?"])], announced: &announced)
        #expect(TaskAlerts.changes(from: [row("1", state: "working", asks: ["Merge it?"])], to: [row("1", state: "needsYou", asks: ["Merge it?"], quiet: true)],
                                   announced: &announced).alerts.isEmpty, "the same question, still open: nothing new")
    }
    // Another question is news.
    #expect(TaskAlerts.changes(from: [row("1", state: "working")], to: [row("1", state: "needsYou", asks: ["Merge it?", "Deploy it?"])], announced: &announced).alerts.count == 1)
}
