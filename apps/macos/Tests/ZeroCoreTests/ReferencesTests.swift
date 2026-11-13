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
