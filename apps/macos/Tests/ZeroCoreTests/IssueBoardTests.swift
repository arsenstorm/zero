import Foundation
import Testing

@testable import ZeroCore

@Suite struct IssueBoardTests {
    private func issue(_ ticket: String, _ state: String, _ text: String = "", since: Int = 0) -> BoardRow.Issue {
        BoardRow.Issue(ticket: ticket, state: state, text: text, since: since)
    }

    @Test func opened_it_puts_those_on_the_user_first_then_by_how_long() {
        let issues = [
            issue("A", "done", since: 1), issue("B", "working", since: 5), issue("C", "you", since: 9), issue("D", "working", since: 2),
        ]
        #expect(IssueBoard.sorted(issues).map(\.ticket) == ["C", "D", "B", "A"])
    }

    @Test func shown_its_rows_keep_their_places_as_states_change() {
        // Open, a row whose state changes stays where it is (its cell lit); a new one comes in at the end; one gone goes.
        let shown = ["C", "D", "B", "A"]
        let now = [issue("A", "done"), issue("B", "you"), issue("D", "working"), issue("E", "working")]
        #expect(IssueBoard.kept(now, order: shown).map(\.ticket) == ["D", "B", "A", "E"])
    }

    @Test func a_change_lights_the_cells_it_changed() {
        let before = [issue("A", "working", "tests"), issue("B", "waiting", "CI")]
        let after = [issue("A", "you", "tests"), issue("B", "waiting", "CI green"), issue("C", "working")]
        let lit = IssueBoard.changed(from: before, to: after)
        #expect(lit["A"] == [.state])
        #expect(lit["B"] == [.text])
        #expect(lit["C"] == nil, "a new row isn't a change of a cell")
    }

    @Test func the_strip_counts_each_state_in_the_boards_order() {
        let issues = [issue("A", "done"), issue("B", "working"), issue("C", "working"), issue("D", "you")]
        let counts = IssueBoard.counts(issues)
        #expect(counts.map(\.state) == [.needsYou, .working, .done])
        #expect(counts.map(\.count) == [1, 2, 1])
    }

    @Test func an_issues_age_is_its_time_in_its_state() {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(IssueBoard.age(since: 10_000_000 - 14 * 60_000, now: now) == "14m")
        #expect(IssueBoard.age(since: 10_000_000 - 3 * 3_600_000, now: now) == "3h")
        #expect(IssueBoard.age(since: 10_000_000 - 3 * 86_400_000, now: now) == "3d")
    }

    @Test func its_steps_come_with_the_conversation_and_with_each_change() throws {
        let json = #"""
            {"type": "issue", "issue": {"ticket": "A", "state": "waiting", "text": "CI", "since": 2000,
             "history": [{"state": "working", "text": "tests", "at": 1000}, {"state": "waiting", "text": "CI", "at": 2000}]}}
            """#
        var conversation = Conversation(id: "lead", provider: .claude, cwd: "/")
        conversation.apply(try JSONDecoder().decode(Change.self, from: Data(json.utf8)))
        #expect(conversation.issues?.first?.history?.map(\.state) == ["working", "waiting"])
        let again = #"{"type": "issue", "issue": {"ticket": "A", "state": "done", "text": "merged", "since": 3000}}"#
        conversation.apply(try JSONDecoder().decode(Change.self, from: Data(again.utf8)))
        #expect(conversation.issues?.map(\.state) == ["done"], "replaced, not added")
    }
}
