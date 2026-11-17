import Foundation
import Testing
@testable import ZeroCore

@Test func referencesLinkIssuesAndPullRequests() {
    let text = "Fixed OPS-3096 and eng-9559 in #12846 and api#6518, see arsenstorm/zero#3. UTF-8 and issue #7 stay."
    let found = References.find(in: text, repo: "acme/app", linear: ["OPS": "acme", "ENG": "acme"], linearApp: true)
    let ns = text as NSString
    #expect(found.map { ns.substring(with: $0.range) } == ["OPS-3096", "eng-9559", "#12846", "api#6518", "arsenstorm/zero#3", "#7"])
    #expect(
        found.map(\.url.absoluteString) == [
            "linear://acme/issue/OPS-3096",
            "linear://acme/issue/ENG-9559",
            "https://github.com/acme/app/pull/12846",
            "https://github.com/acme/api/pull/6518",
            "https://github.com/arsenstorm/zero/pull/3",
            "https://github.com/acme/app/pull/7",
        ])
    #expect(References.find(in: "#12846 at 064c6bb7b5", repo: nil, linear: [:], linearApp: false).isEmpty)
    #expect(
        References.find(in: "push at 064c6bb7b5, not 1234567 or deadbeef", repo: "acme/app", linear: [:], linearApp: false)
            .map(\.url.absoluteString) == ["https://github.com/acme/app/commit/064c6bb7b5"])
}

@Test func issuesNeedAConnectedTeam() {
    #expect(
        References.find(in: "ENG-9559 and ABC-12", repo: nil, linear: ["ABC": "personal"], linearApp: false)
            .map(\.url.absoluteString) == ["https://linear.app/personal/issue/ABC-12"])
}

@Test func remotesParseToOwnerAndName() {
    #expect(References.parse("git@github.com:arsenstorm/zero.git") == "arsenstorm/zero")
    #expect(References.parse("https://github.com/acme/app") == "acme/app")
    #expect(References.parse("git@gitlab.com:a/b.git") == nil)
}

@Test func aFolderOfRepositoriesLendsItsOwnerToNamedPullRequests() {
    let found = References.find(in: "update api#6533, not #12", repo: nil, linear: [:], linearApp: false, owner: "acme")
    #expect(found.map(\.url.absoluteString) == ["https://github.com/acme/api/pull/6533"])
}

private let acme = Slack.State(team: .init(id: "T0AB", name: "Acme", domain: "acme"), channels: [:])

@Test func channelsOpenInSlackOnceTheWorkspaceIsKnown() {
    let text = "post in #docs or #eng-2, not #12 or a#b or https://x.com/#frag"
    #expect(References.find(in: text, repo: nil, linear: [:], linearApp: false).isEmpty)
    let found = References.find(in: text, repo: nil, linear: [:], linearApp: false, slack: [acme])
    let ns = text as NSString
    #expect(found.map { ns.substring(with: $0.range) } == ["#docs", "#eng-2"])
    #expect(found.first?.url.absoluteString == "https://slack.com/app_redirect?team=T0AB&channel=docs")
    let message = URL(string: "https://acme.slack.com/archives/C0123/p1700000000123456?thread_ts=1699999999.000100&cid=C0123")!
    #expect(
        SlackLinks.url(message, in: [acme])?.absoluteString
            == "slack://channel?team=T0AB&id=C0123&message=1700000000.123456&thread_ts=1699999999.000100")
    #expect(
        SlackLinks.url(URL(string: "https://acme.slack.com/archives/C0123")!, in: [acme])?.absoluteString
            == "slack://channel?team=T0AB&id=C0123")
    #expect(SlackLinks.url(message, in: []) == nil)
    #expect(SlackLinks.url(URL(string: "https://github.com/archives/x")!, in: [acme]) == nil)
}

@Test func eachSlackWorkspacesLinksOpenInIt() {
    // A message link in the workspace its domain names; "#channel" in the one that has a channel of that name.
    let beta = Slack.State(team: .init(id: "T0BE", name: "Beta", domain: "beta"), channels: ["general": "C9Z"])
    #expect(
        SlackLinks.url(URL(string: "https://beta.slack.com/archives/C9Z")!, in: [acme, beta])?.absoluteString
            == "slack://channel?team=T0BE&id=C9Z")
    #expect(
        SlackLinks.url(URL(string: "https://gamma.slack.com/archives/C1")!, in: [acme, beta]) == nil, "a workspace that isn't connected")
    let found = References.find(in: "#general and #docs", repo: nil, linear: [:], linearApp: false, slack: [acme, beta])
    #expect(
        found.map(\.url.absoluteString) == ["slack://channel?team=T0BE&id=C9Z", "https://slack.com/app_redirect?team=T0AB&channel=docs"])
}

@Test func githubsLinksCanBeTurnedOff() {
    #expect(References.find(in: "see #12 at 064c6bb7b5", repo: "o/r", linear: [:], linearApp: false, github: false).isEmpty)
    #expect(References.find(in: "see #12", repo: "o/r", linear: [:], linearApp: false).count == 1)
}

@Test func aKnownChannelOpensInSlackItself() {
    let found = References.find(
        in: "see #docs and #new", repo: nil, linear: [:], linearApp: false, slack: [Slack.State(team: acme.team, channels: ["docs": "C0D"])]
    )
    #expect(
        found.map(\.url.absoluteString) == ["slack://channel?team=T0AB&id=C0D", "https://slack.com/app_redirect?team=T0AB&channel=new"])
    // Slack's answers are read by zerod (integrations.rs); the app keeps the manifest that makes its Slack app.
    let manifest = Slack.createAppURL(posts: false).absoluteString
    #expect(manifest.hasPrefix("https://api.slack.com/apps?new_app=1&manifest_json=%7B"))
    #expect(manifest.removingPercentEncoding?.contains("\"channels:history\"") == true, "following a thread needs its history")
    // A token that can't post can't be made to, whoever ends up with it: chat:write only once the user lets agents post.
    #expect(manifest.removingPercentEncoding?.contains("chat:write") == false)
    #expect(Slack.createAppURL(posts: true).absoluteString.removingPercentEncoding?.contains("\"chat:write\"") == true)
}

/// Messages rendered before a team was known render again once it is (their cache keys hold the version), and a
/// refresh that brings the same teams leaves them be.
@MainActor @Test func newLinearTeamsBumpTheLinkVersionOnlyWhenTheyChange() {
    let before = LinkInputs.shared.version
    LinearTeams.known = ["SH": "acme", "U": "acme"]
    let after = LinkInputs.shared.version
    #expect(after > before)
    LinearTeams.known = ["SH": "acme", "U": "acme"]
    #expect(LinkInputs.shared.version == after)
    #expect(
        References.find(in: "U-9918", repo: nil, linear: LinearTeams.known, linearApp: false).first?.url.absoluteString
            == "https://linear.app/acme/issue/U-9918")
}

@Test func anAddressIsOneLinkNotTheReferencesInIt() {
    let text = "look at zero://task/01a1e4b4537c009e and https://github.com/acme/app/pull/7#ENG-12, then 064c6bb7b5"
    let found = References.find(in: text, repo: "acme/app", linear: ["ENG": "acme"], linearApp: false)
    let ns = text as NSString
    #expect(found.map { ns.substring(with: $0.range) } == ["zero://task/01a1e4b4537c009e", "064c6bb7b5"])
    #expect(found.first?.url.absoluteString == "zero://task/01a1e4b4537c009e")
}

/// A lead in a folder of worktrees (no repository of its own) writes a table of its pull requests and their heads.
private let followedPulls: [String: Set<String>] = ["13963": ["acme/app"], "13964": ["acme/app"], "500": ["acme/app", "acme/site"]]

@Test func aBarePullRequestIsTheOneTheTaskFollows() {
    let text = "#13963 is up, #500 is in two repos, #77 in none"
    let urls = { (repo: String?) in
        References.find(in: text, repo: repo, linear: [:], linearApp: false, pulls: followedPulls).map(\.url.absoluteString)
    }
    #expect(urls(nil) == ["https://github.com/acme/app/pull/13963"], "two repos or none, and no folder repo: no link")
    // A folder repo: one of the two repos is the folder's own; a number followed nowhere is the folder's.
    #expect(
        urls("acme/site") == [
            "https://github.com/acme/app/pull/13963", "https://github.com/acme/site/pull/500", "https://github.com/acme/site/pull/77",
        ])
    #expect(urls("acme/other").count == 2, "followed in two repos, neither the folder's: no guess")
}

@Test func aCommitIsInTheRepoOfThePullRequestBesideIt() {
    let find = { (text: String, repo: String?, row: String?) in
        References.find(in: text, repo: repo, linear: [:], linearApp: false, pulls: followedPulls, row: row).map(\.url.absoluteString)
    }
    // A table cell: the pull request is in another cell of its row.
    #expect(
        find("87c01f9a1e", nil, "#13963 | U-9810: titles | 87c01f9a1e | 17/17 pass") == ["https://github.com/acme/app/commit/87c01f9a1e"])
    #expect(find("87c01f9a1e", nil, "#77 | 87c01f9a1e").isEmpty, "a pull request of no known repo, no folder repo: no link")
    #expect(find("87c01f9a1e", nil, "#77 | 87c01f9a1e | after #13963").isEmpty, "its own PR unknown, another's known: no guess")
    // Prose: the pull request in the same sentence, not the one before.
    #expect(
        find("#13964 is merged. Then 79cf980666 went out.", nil, nil) == ["https://github.com/acme/app/pull/13964"])
    #expect(
        find("Pushed 79cf980666 to #13964.", nil, nil) == [
            "https://github.com/acme/app/commit/79cf980666", "https://github.com/acme/app/pull/13964",
        ])
    #expect(find("Pushed 79cf980666 to site#9.", nil, nil).isEmpty, "a named repo needs an owner")
    #expect(
        find("Pushed 79cf980666 to acme/site#9.", "acme/app", nil).first == "https://github.com/acme/site/commit/79cf980666")
    // Pull requests beside it that disagree, or one of no known repo: no link, not the folder's.
    #expect(find("Pushed 79cf980666 for acme/site#9 and acme/api#3.", "acme/app", nil).count == 2)
    #expect(find("79cf980666", "acme/other", "#500 | 79cf980666").isEmpty)
    // No pull request beside it: the folder's repo, else nothing.
    #expect(find("Pushed 79cf980666.", "acme/app", nil) == ["https://github.com/acme/app/commit/79cf980666"])
    #expect(find("Pushed 79cf980666.", nil, nil).isEmpty)
    // Not inside a word or an address.
    #expect(find("c4f54766-1dec-4258-9559-8f6f3bc9270b and 87c01f9a1e.png", "acme/app", nil).isEmpty)
    #expect(find("x79cf980666 and https://github.com/acme/app/commit/79cf980666", "acme/app", nil).isEmpty)
    #expect(find("zero://task/01a1e4b4537c009e", "acme/app", "#13963 | zero://task/01a1e4b4537c009e") == ["zero://task/01a1e4b4537c009e"])
}

@Test func aWorkersFollowsCountForItsLead() {
    let follow = { (session: String, topic: String) -> ZerodLink.Followed in
        let json =
            #"{"session":"\#(session)","topic":"\#(topic)","at":0,"summary":"","lastPoll":0,"mine":false,"about":[],"new":false,"detail":""}"#
        return try! JSONDecoder().decode(ZerodLink.Followed.self, from: Data(json.utf8))
    }
    let pulls = References.pulls(
        [
            follow("lead", "github/acme/app/13963"), follow("worker", "github/acme/site/pull/9"), follow("lead", "linear/U-1"),
            follow("other", "github/acme/app/9"), follow("lead", "github/*/*/4"),
        ], leads: ["worker": "lead"])
    #expect(pulls["lead"] == ["13963": ["acme/app"], "9": ["acme/site"]])
    #expect(pulls["worker"] == ["9": ["acme/site"]])
    #expect(pulls["other"] == ["9": ["acme/app"]])
}
