import AppKit
import SwiftUI
import ZeroCore

/// The side panel's first tab, the task's details: what needs you first (its status in words, its workers' asks
/// answerable here; its own ask docks in the conversation beside it), then its issues and workers, what it points at,
/// what it left running, the agent on it, and where it works. Nothing hides behind a hover.
struct TaskDetails: View {
    let workspace: Workspace
    /// For answering its workers' asks.
    let inbox: InboxController
    let navigation: Navigation
    let row: BoardRow?
    let conversation: Conversation
    /// Opens a link: in its app when Zero opens it in one, else in a tab of the panel (SidePanel.open).
    let open: (String) -> Void
    /// Every worker listed, not only the ones that need attention.
    @State private var allWorkers = false
    @FocusState private var focus: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                status; issues; workers; links; leftRunning; agent; folder
            }
            .font(.system(size: 12.5))
            .frame(maxWidth: 460, alignment: .leading)
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .thinScrollbar()
        .task(id: workspace.followingVersion) { await workspace.loadFollowing() }
    }

    // MARK: Status

    /// The pill, the words of its status, when it wakes, a change waiting for its next turn, and its workers' asks.
    @ViewBuilder private var status: some View {
        if let row {
            let asks = row.asks.compactMap { waiting in inbox.store.asks.first { $0.id == waiting.id && $0.session != conversation.id } }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    StateLabel(state: row.ownState)
                    if let wakes = row.wakes {
                        Text("Wakes at \(Date(timeIntervalSince1970: TimeInterval(wakes)).formatted(date: .omitted, time: .shortened))")
                            .foregroundStyle(.secondary)
                    }
                }
                if let words = row.trouble ?? row.needs ?? row.now, !words.isEmpty {
                    Text(Self.inline(words)).foregroundStyle(.secondary).tint(Theme.link).fixedSize(horizontal: false, vertical: true)
                }
                if let next = nextTurn(row.next) { Text(next).foregroundStyle(.tertiary) }
                ForEach(asks) { ask in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 6) {
                            PixelIcon("px-circle-question", height: 12).foregroundStyle(.secondary)
                            Text(ask.session.flatMap { workspace.names[$0] } ?? "A worker").fontWeight(.medium).lineLimit(1)
                            Text("asks").foregroundStyle(.secondary)
                        }
                        .padding(.top, 10)
                        // The inbox's card without its frame (a card in a card), lined up with the tab's text.
                        CardView(ask: ask, controller: inbox, focus: $focus, flat: true, showsByline: false).padding(.horizontal, -16)
                    }
                }
            }
            .padding(.bottom, 4)
        }
    }

    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    /// A change picked during a turn, applied as it ends.
    private func nextTurn(_ next: BoardRow.Next?) -> String? {
        guard let next else { return nil }
        let parts = [
            next.model.map { model in
                ComposerRows.catalogue(next.provider ?? conversation.provider).first { $0.id == model }?.name ?? ModelNames.readable(model)
            },
            next.effort.map { effortLabel($0, short: true) },
            next.permissions.map { $0 == .unrestricted ? "unrestricted" : "auto" },
        ].compactMap { $0 }
        return parts.isEmpty ? nil : "Next turn: " + parts.joined(separator: " · ")
    }

    // MARK: Issues and workers

    /// Its issues are the board at the top of its conversation (IssueStrip): here, how many, and a way to it.
    @ViewBuilder private var issues: some View {
        let issues = row?.issues ?? []
        if !issues.isEmpty {
            let you = issues.filter { $0.state == "you" }.count
            section("Issues") {
                Button {
                    NotificationCenter.default.post(name: IssueStrip.show, object: conversation.id)
                } label: {
                    Self.linked(
                        "\(issues.count) \(issues.count == 1 ? "issue" : "issues")"
                            + (you == 0 ? "" : " · \(you) \(you == 1 ? "needs" : "need") you"))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The few that matter (needing you, in trouble, at work) first, the rest behind their count; a click shows one.
    @ViewBuilder private var workers: some View {
        let members = (row?.team ?? []).filter { $0.session != conversation.id }.sorted { $0.state.urgency < $1.state.urgency }
        if !members.isEmpty {
            let urgent = members.filter { $0.state.urgency <= 2 }
            let shown = allWorkers ? members : Array((urgent.isEmpty ? members : urgent).prefix(8))
            section("Workers", trailing: members.count > shown.count || allWorkers ? (allWorkers ? "Fewer" : "All \(members.count)") : nil)
            {
                allWorkers.toggle()
            } content: {
                ForEach(shown, id: \.session) { member in
                    Button {
                        navigation.worker = member.session
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            TaskStateIcon(state: member.state).frame(width: 14, height: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(workspace.conversation(member.session).map(Workspace.label(of:)) ?? member.place).fontWeight(.medium)
                                    .lineLimit(1)
                                if let now = member.needs ?? member.now, !now.isEmpty { Text(now).foregroundStyle(.secondary).lineLimit(2) }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity([.done, .idle, .offline].contains(member.state) ? 0.6 : 1)
                }
            }
        }
    }

    // MARK: Links

    /// Its pull request, ticket, other attributes and follows, once each; each opens in a tab of the panel.
    @ViewBuilder private var links: some View {
        let links = TaskLinksList.of(conversation, row: row, in: workspace)
        if !links.isEmpty {
            section("Links") {
                ForEach(links) { link in
                    LinkLine(link: link, open: open) { follow in
                        Task { await workspace.unfollow(session: follow.session, topic: follow.topic) }
                    }
                }
            }
        }
    }

    @ViewBuilder private var leftRunning: some View {
        if let left = workspace.left[conversation.id] {
            section("Left running", trailing: left.things.count > 1 ? "Stop all" : nil) {
                Task { await workspace.stopLeft(conversation.id) }
            } content: {
                LeftRunningRows(workspace: workspace, session: conversation.id, things: left.things)
            }
        }
    }

    // MARK: Agent and folder

    private var agent: some View {
        section("Agent") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 9) {
                property("Model") {
                    HStack(spacing: 5) {
                        if let mark = conversation.provider.mark {
                            mark.resizable().aspectRatio(contentMode: .fit).frame(width: 13, height: 13).clipShape(
                                RoundedRectangle(cornerRadius: 3))
                        }
                        Text(
                            ModelNames.agent(
                                modelName ?? conversation.provider.title, effort: conversation.effort.map { effortLabel($0, short: true) },
                                advisor: advisor)
                        )
                        .lineLimit(1).tip([conversation.provider.title, conversation.model].compactMap { $0 }.joined(separator: " · "))
                    }
                }
                property("Acts") {
                    if conversation.permissions == .unrestricted {
                        HStack(spacing: 5) {
                            NucleoIcon("bolt-lightning", fill: "glyph", size: 12).foregroundStyle(.orange)
                            Text("Without asking")
                        }
                    } else {
                        Text("Asks before what isn't safe")
                    }
                }
                if let signin = workspace.signins.first(where: { $0.id == conversation.signin }) {
                    property("Account") { account(signin) }
                }
                property("Uses") { uses }
            }
        }
    }

    /// The sign-in it runs as, and how much of its five hours is used.
    private func account(_ signin: ZerodLink.SignIn) -> some View {
        HStack(spacing: 6) {
            Text([signin.label, signin.plan].compactMap { $0 }.joined(separator: " · ")).lineLimit(1)
            if let usage = workspace.signinUsage[signin.id], let window = usage.windows.first(where: { $0.name != "7 days" }) {
                let used = UsageShown.used(window, now: Int(Date().timeIntervalSince1970))
                Capsule().fill(Theme.chip).frame(width: 44, height: 4)
                    .overlay(alignment: .leading) { Capsule().fill(Color.secondary).frame(width: 44 * min(1, used)) }
                Text("\(Int((used * 100).rounded()))% of 5 hours").monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    /// What its processes use now, the split on hover; a dash while nothing runs (parked), keeping the row's place.
    @ViewBuilder private var uses: some View {
        if let uses = workspace.uses[conversation.id] {
            let parts = [
                (conversation.provider.title, uses.cli), ("MCP servers", uses.mcp), ("commands", uses.commands),
            ].filter { $0.1.memory > 0 }.map { "\($0.0) \(Self.bytes($0.1.memory))" }
            Text("\(Self.bytes(uses.memory)) · \(Int(uses.cpu.rounded()))% CPU").monospacedDigit().lineLimit(1)
                .tip(parts.joined(separator: " · "))
        } else {
            Text("–").foregroundStyle(.secondary).tip("Nothing running: its agent is parked until there's work")
        }
    }

    private var folder: some View {
        section("Folder") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 9) {
                property("Where") {
                    // The place's own folder when the places command says (a bench's), else the task's.
                    let folder = row?.path ?? conversation.cwd
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: folder))
                    } label: {
                        Self.linked(row?.place ?? Projects.name(of: conversation.cwd)).truncationMode(.middle)
                    }
                    .buttonStyle(.plain).tip("Show \((folder as NSString).abbreviatingWithTildeInPath) in Finder")
                }
                if let branch = conversation.branch {
                    property("Branch") { Text(branch).lineLimit(1).truncationMode(.middle).tip(branch) }
                }
                // Finder, an editor, the terminal app in its folder: the last one used, or the list.
                property("Open in") { OpenInButton(workspace: workspace, conversation: conversation) }
                // The task in the user's own terminal app, on its CLI's own resume; back once that CLI exits.
                property("Continue") {
                    let open = conversation.terminal != nil
                    Button {
                        Task { open ? await workspace.closeTerminal(conversation.id) : await workspace.openTerminal(conversation.id) }
                    } label: {
                        Self.linked(open ? "Back to Zero" : "In \(TerminalApp.shared.name)")
                    }
                    .buttonStyle(.plain).disabled(!open && conversation.thread == nil)
                    .tip(!open && conversation.thread == nil ? "Its CLI hasn't started a session to resume yet" : "")
                }
            }
        }
    }

    // MARK: Parts

    /// A section: its heading (and an action at its right, as All 3 or Stop all), then its rows.
    private func section(
        _ title: String, trailing: String? = nil, action: @escaping () -> Void = {}, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                if let trailing { Button(trailing, action: action).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            .padding(.top, 20)
            content()
        }
    }

    private func property(_ name: String, @ViewBuilder value: () -> some View) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary).frame(width: 58, alignment: .leading)
            value().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The ticket's page: Linear's link for its team's workspace.
    static func ticketURL(_ ticket: String) -> URL? {
        guard let team = ticket.split(separator: "-").first, let space = LinearTeams.known[String(team)] else { return nil }
        // The web link: the panel's opener turns it into the app's when the user has Linear links open there.
        return URL(string: "https://linear.app/\(space)/issue/\(ticket)")
    }

    /// Its value as a link (opened in the panel) when it is one, plain words otherwise.
    @ViewBuilder private func link(_ text: String, to url: URL?) -> some View {
        if let url {
            Button {
                open(url.absoluteString)
            } label: {
                Self.linked(text)
            }
            .buttonStyle(.plain).tip(url.absoluteString)
        } else {
            Text(text).lineLimit(2)
        }
    }

    private var advisor: String? {
        guard conversation.provider == .claude, let advisor = conversation.advisor else { return nil }
        return ClaudeModels.advisors(for: conversation.model ?? "").contains { $0.id == advisor } ? advisor : nil
    }

    private var modelName: String? {
        guard let model = conversation.model else { return nil }
        return ComposerRows.catalogue(conversation.provider).first { $0.id == model }?.name ?? ModelNames.readable(model)
    }

    // MARK: Shared with other views

    static func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .memory)
    }

    /// Something that opens: a little heavier, on a dashed underline; no icon, no blue.
    static func linked(_ text: String) -> some View {
        Text(text).fontWeight(.medium).lineLimit(1)
            // Drawn, not the system's underline, which sits too far below the words: just under the baseline.
            .overlay(alignment: .bottom) {
                Rule().stroke(.secondary.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [2, 2])).frame(height: 1).offset(y: -1.5)
            }
            .pointerStyle(.link)
    }

    /// A line across, for the dashed underline.
    private struct Rule: Shape {
        func path(in rect: CGRect) -> Path {
            Path {
                $0.move(to: CGPoint(x: rect.minX, y: rect.midY)); $0.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            }
        }
    }

    /// A GitHub pull request as "repo#123"; any other link without its scheme; words as they are.
    static func shown(_ value: String) -> String {
        if let pr = value.firstMatch(of: #/github\.com/[\w.-]+/([\w.-]+)/pull/(\d+)/#) { return "\(pr.1)#\(pr.2)" }
        if value.hasPrefix("https://") || value.hasPrefix("http://") {
            return String(value.split(separator: "/", maxSplits: 1).last ?? Substring(value)).trimmingCharacters(
                in: CharacterSet(charactersIn: "/"))
        }
        return value
    }

    static func url(_ value: String) -> URL? {
        guard value.hasPrefix("https://") || value.hasPrefix("http://") else { return nil }
        return URL(string: value)
    }
}

/// Everything a task points at, once each: its pull request (set with `zero attr`, else the latest its words
/// mention), its ticket, its other attributes, and what it follows. A followed one carries its latest line, or that
/// polling it fails.
struct TaskLinksList: Identifiable, Equatable {
    var id: String { url.isEmpty ? title : url }
    var icon: String
    var title: String
    var url: String
    /// Its latest line from following it ("Retry failed payments · open"), or nil.
    var detail: String?
    var followed: ZerodLink.Followed?

    @MainActor static func of(_ conversation: Conversation, row: BoardRow?, in workspace: Workspace) -> [TaskLinksList] {
        let follows = workspace.followed.filter { $0.session == conversation.id }
        var links: [TaskLinksList] = []
        var attributes = (conversation.attributes ?? [:]).sorted { $0.key < $1.key }.map { (name: $0.key, value: $0.value) }
        if !attributes.contains(where: { $0.name.uppercased() == "PR" }), let found = mentionedPR(conversation, row: row, in: workspace) {
            attributes.insert((name: "PR", value: found), at: 0)
        }
        for (name, value) in attributes {
            let follow = follows.first { $0.url?.absoluteString == value }
            let icon = value.contains("github.com") ? "github:glyph" : TaskDetails.url(value) == nil ? "text" : "link"
            let title = TaskDetails.url(value) == nil ? "\(name): \(value)" : TaskDetails.shown(value)
            links.append(
                TaskLinksList(
                    icon: icon, title: title, url: TaskDetails.url(value) == nil ? "" : value, detail: follow?.title, followed: follow))
        }
        if let ticket = conversation.ticket {
            let team = String(ticket.split(separator: "-").first ?? "")
            let url = LinearTeams.known[team].map { "https://linear.app/\($0)/issue/\(ticket)" } ?? ""
            let follow = follows.first { $0.topic.hasSuffix(ticket) }
            links.append(TaskLinksList(icon: "ticket", title: ticket, url: url, detail: follow?.title, followed: follow))
        }
        for follow in follows where !links.contains(where: { $0.followed == follow }) {
            let icon = ["github": "github:glyph", "linear": "ticket", "slack": "slack:glyph"][follow.source] ?? "link"
            links.append(TaskLinksList(icon: icon, title: follow.title, url: follow.url?.absoluteString ?? "", followed: follow))
        }
        return links
    }

    /// The latest pull request the task's words mention, as a GitHub link.
    @MainActor private static func mentionedPR(_ conversation: Conversation, row: BoardRow?, in workspace: Workspace) -> String? {
        let texts =
            [row?.asks.first?.title, row?.needs, row?.now].compactMap { $0 }
            + (workspace.live(conversation.id)?.conversation.items ?? []).reversed().compactMap { item -> String? in
                switch item.kind {
                case let .agent(text, _), let .user(text, _): text
                default: nil
                }
            }
        return texts.lazy.compactMap { $0.firstMatch(of: #/https://github\.com/[\w.-]+/[\w.-]+/pull/\d+/#).map { String($0.0) } }.first
    }
}

/// A link of the task's: its kind's icon, its name, and what's latest from following it, or that it can't be read.
/// A followed one has an eye, an × to unfollow under the pointer.
private struct LinkLine: View {
    let link: TaskLinksList
    let open: (String) -> Void
    let unfollow: (ZerodLink.Followed) -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            NucleoIcon(link.icon, size: 13).foregroundStyle(.secondary).frame(width: 14)
            if link.url.isEmpty {
                Text(link.title).lineLimit(1).truncationMode(.middle).layoutPriority(1)
            } else {
                Button {
                    open(link.url)
                } label: {
                    TaskDetails.linked(link.title).truncationMode(.middle)
                }
                .buttonStyle(.plain).tip(link.url).layoutPriority(1)
            }
            if let error = link.followed?.error {
                Text("Can't reach \(Self.service(link.followed?.source ?? "")) · retrying").foregroundStyle(.tertiary).lineLimit(1).tip(
                    error)
            } else if let detail = link.detail, !detail.isEmpty, detail != link.title {
                Text(detail).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let follow = link.followed {
                Button {
                    unfollow(follow)
                } label: {
                    NucleoIcon(hovered ? "xmark" : "eye", size: hovered ? 11 : 12).foregroundStyle(hovered ? .secondary : .tertiary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(Hovering(radius: 5)).tip(hovered ? "Unfollow" : "Following")
            }
        }
        .frame(minHeight: 20)
        .contentShape(Rectangle()).onHover { hovered = $0 }
    }

    static func service(_ source: String) -> String {
        ["github": "GitHub", "linear": "Linear", "slack": "Slack"][source] ?? source
    }
}
