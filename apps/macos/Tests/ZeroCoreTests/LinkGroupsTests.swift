import Foundation
import Testing

@testable import ZeroCore

@Suite struct LinkGroupsTests {
    private func follow(_ topic: String, _ name: String = "", _ state: String = "", closed: Bool = false) -> ZerodLink.Followed {
        let json: [String: Any] = [
            "session": "s", "topic": topic, "mine": false, "about": [String](), "new": false, "detail": "", "at": 0,
            "summary": "\(name) https://x/\(topic)", "lastPoll": 0,
            "name": name, "state": state, "closed": closed,
        ]
        return try! JSONDecoder().decode(ZerodLink.Followed.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func links_go_under_the_issue_their_ticket_names_and_the_same_change_in_several_repos_is_one_line() {
        let follows = [
            follow("linear/ENG-1", "Vitals chart is blank", "In review"),
            follow("github/o/web/1", "ENG-1 Draw the vitals chart", "merged", closed: true),
            follow("github/o/api/2", "ENG-1 Draw the vitals chart", "merged", closed: true),
            follow("github/o/api/3", "ENG-1: Cache the vitals", "draft"),
            follow("github/o/web/4", "ENG-12 Something else", "open"),
            follow("slack/C1/1.2", "#web thread by sam"),
            follow("slack/C1", "#web"),
        ]
        let groups = LinkGroups.of(follows, issues: [("ENG-1", false)])
        #expect(groups.issues.map(\.ticket) == ["ENG-1"])
        let one = groups.issues[0]
        #expect(one.issue?.topic == "linear/ENG-1")
        #expect(one.changes.map { $0.follows.map(\.topic) } == [["github/o/web/1", "github/o/api/2"], ["github/o/api/3"]])
        #expect(one.changes.map(\.closed) == [true, false])
        #expect(one.changes.map(\.name) == ["Draw the vitals chart", "Cache the vitals"], "its ticket said once, by the issue")
        #expect(groups.other.map(\.topic) == ["github/o/web/4", "slack/C1/1.2"], "ENG-12 isn't ENG-1")
        #expect(groups.channels.map(\.topic) == ["slack/C1"])
    }

    @Test func an_issue_folds_once_it_is_done_and_one_without_links_has_no_group() {
        let follows = [
            follow("linear/ENG-1", "One", "Shipped", closed: true), follow("github/o/r/1", "ENG-2 Two", "open"),
            follow("github/o/r/9", "Elsewhere", "merged", closed: true),
        ]
        let groups = LinkGroups.of(follows, issues: [("ENG-2", false), ("ENG-1", true), ("ENG-3", false)])
        #expect(groups.issues.map(\.ticket) == ["ENG-2", "ENG-1"])
        #expect(groups.issues.map(\.folded) == [false, true])
        #expect(groups.other.map(\.topic) == ["github/o/r/9"])
    }

    @Test func without_a_board_an_issue_folds_once_everything_in_it_closed() {
        let open = LinkGroups.of(
            [follow("linear/ENG-1", "One", "Todo"), follow("github/o/r/1", "ENG-1 a", "merged", closed: true)], issues: [("ENG-1", nil)])
        #expect(open.issues[0].folded == false)
        let shut = LinkGroups.of([follow("github/o/r/1", "ENG-1 a", "merged", closed: true)], issues: [("ENG-1", nil)])
        #expect(shut.issues[0].folded == true)
    }
}
