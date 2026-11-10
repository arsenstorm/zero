import Foundation

// zerod, Zero's daemon (crates/zerod), runs the agent sessions; the app is its client. This is zerod's model as it
// comes over the wire (crates/zerod/src/model.rs), how a copy of it is kept (`ZerodMirror`), and the link to the daemon.
// ZerodWireTests decodes files zerod itself writes, so the two sides can't drift apart unnoticed.

public enum Provider: String, Codable, Sendable, CaseIterable {
    case codex, claude, opencode

    public var title: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .opencode: "OpenCode"
        }
    }
}

/// How freely an agent acts: auto lets the provider's own judgement decide what is safe (Claude's classifier, Codex's
/// sandbox) and brings the user the rest; unrestricted lets it do anything without asking.
public enum Permissions: String, Codable, Sendable, CaseIterable { case auto, unrestricted }

public enum SessionStatus: String, Decodable, Sendable { case starting, idle, working, waiting, offline }

public enum ItemStatus: String, Decodable, Sendable { case running, done, failed, declined }

public struct FileChange: Decodable, Equatable, Sendable {
    public var path: String
    /// "add", "delete" or "update".
    public var kind: String
    public var movePath: String?
    public var diff: String
    public init(path: String, kind: String, movePath: String?, diff: String) {
        self.path = path; self.kind = kind; self.movePath = movePath; self.diff = diff
    }
}

public struct ConversationItem: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var turn: String?
    public var kind: Kind
    public var status: ItemStatus
    /// When zerod first saw it, in milliseconds since 1970; nil from before zerod kept times.
    public var at: Int?

    public enum Kind: Equatable, Sendable {
        /// Your words, and the images sent with them (their files).
        case user(text: String, images: [String] = [])
        case agent(text: String, finalAnswer: Bool)
        case reasoning(text: String)
        case plan(text: String)
        case command(command: String, cwd: String, output: String, exitCode: Int?, durationMs: Int?)
        case fileChange([FileChange])
        case tool(name: String, detail: String)
        case notice(text: String, error: Bool)
        /// A table the agent handed to Zero to draw (`zero table`).
        case table(title: String, columns: [String], rows: [[String]])
    }

    public init(id: String, turn: String?, kind: Kind, status: ItemStatus, at: Int? = nil) {
        self.id = id; self.turn = turn; self.kind = kind; self.status = status; self.at = at
    }

    public var date: Date? { at.map { Date(timeIntervalSince1970: Double($0) / 1000) } }

    /// Words Zero gave the session rather than the user (a worker's report to its lead, a watched command's end): who
    /// they're from (a session id, or "zero") and the words without that line. As zerod marks them (model.rs FROM).
    public static func from(_ text: String) -> (from: String, text: String)? {
        guard text.hasPrefix("<!-- from: "), let end = text.range(of: " -->") else { return nil }
        let from = String(text[text.index(text.startIndex, offsetBy: 11)..<end.lowerBound])
        var rest = String(text[end.upperBound...])
        if rest.hasPrefix("\n") { rest.removeFirst() }
        return (from, rest)
    }

    /// The user's own message: not one Zero gave the session.
    public var isYours: Bool { if case let .user(text, _) = kind { Self.from(text) == nil } else { false } }
}

extension ConversationItem.Kind: Decodable {
    private enum Keys: String, CodingKey {
        case type, text, finalAnswer, command, cwd, output, exitCode, durationMs, changes, name, detail, error, images, title, columns, rows
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let text = { try c.decode(String.self, forKey: .text) }
        switch try c.decode(String.self, forKey: .type) {
        case "user": self = .user(text: try text(), images: try c.decodeIfPresent([String].self, forKey: .images) ?? [])
        case "agent": self = .agent(text: try text(), finalAnswer: try c.decode(Bool.self, forKey: .finalAnswer))
        case "reasoning": self = .reasoning(text: try text())
        case "plan": self = .plan(text: try text())
        case "command":
            self = .command(
                command: try c.decode(String.self, forKey: .command), cwd: try c.decode(String.self, forKey: .cwd),
                output: try c.decode(String.self, forKey: .output), exitCode: try c.decodeIfPresent(Int.self, forKey: .exitCode),
                durationMs: try c.decodeIfPresent(Int.self, forKey: .durationMs))
        case "fileChange": self = .fileChange(try c.decode([FileChange].self, forKey: .changes))
        case "tool": self = .tool(name: try c.decode(String.self, forKey: .name), detail: try c.decode(String.self, forKey: .detail))
        case "notice": self = .notice(text: try text(), error: try c.decode(Bool.self, forKey: .error))
        case "table":
            self = .table(
                title: try c.decode(String.self, forKey: .title), columns: try c.decode([String].self, forKey: .columns),
                rows: try c.decode([[String]].self, forKey: .rows))
        // A newer zerod's item still shows, as what it is, instead of failing the whole conversation.
        case let other: self = .notice(text: "An item Zero can't show yet (\(other))", error: false)
        }
    }
}

public enum ApprovalKind: String, Decodable, Sendable { case command, fileChange, tool }

/// What a choice does, the same for every provider.
public enum ChoiceKind: String, Decodable, Sendable { case allow, allowSession, allowAlways, deny, stop }

public struct Choice: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var kind: ChoiceKind
    public init(id: String, label: String, kind: ChoiceKind) { self.id = id; self.label = label; self.kind = kind }
}

public struct Approval: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var item: String?
    public var kind: ApprovalKind
    public var title: String
    public var command: String?
    public var cwd: String?
    public var reason: String?
    public var changes: [FileChange]
    /// The answers the provider takes, in its order.
    public var choices: [Choice]

    public init(
        id: String, item: String?, kind: ApprovalKind, title: String, command: String?, cwd: String?, reason: String?,
        changes: [FileChange], choices: [Choice]
    ) {
        self.id = id; self.item = item; self.kind = kind; self.title = title; self.command = command; self.cwd = cwd
        self.reason = reason; self.changes = changes; self.choices = choices
    }
}

/// The agent asking the user something: one or more fields answered together.
public struct Question: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var item: String?
    public var fields: [Field]
    public init(id: String, item: String?, fields: [Field]) { self.id = id; self.item = item; self.fields = fields }
}

public struct Field: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var header: String?
    public var question: String
    public var options: [QuestionOption]
    public var multiple: Bool
    /// The user's own words are taken too.
    public var other: Bool
    /// Shown as dots, and never kept in Zero's log.
    public var secret: Bool
    public init(id: String, header: String?, question: String, options: [QuestionOption], multiple: Bool, other: Bool, secret: Bool) {
        self.id = id; self.header = header; self.question = question; self.options = options; self.multiple = multiple; self.other = other;
        self.secret = secret
    }
}

public struct QuestionOption: Decodable, Equatable, Sendable {
    public var label: String
    public var description: String?
    public init(label: String, description: String?) { self.label = label; self.description = description }
}

/// Integrations as zerod keeps them (crates/zerod/src/integrations.rs): GitHub and Linear, each on or off with its views,
/// and the connected Linear workspace.
public struct IntegrationState: Decodable, Equatable, Sendable {
    public var settings: IntegrationSettings
    public var linear: String?
    /// Who the GitHub CLI is signed in as; nil when it isn't (or isn't installed).
    public var github: String?
    /// The Slack workspace connected and its channels' ids; nil when none is.
    /// Each Slack workspace connected.
    public var slack: [Slack.State]?
}

public struct IntegrationSettings: Decodable, Equatable, Sendable {
    public var github: IntegrationSource<GitHubView>
    public var linear: IntegrationSource<LinearView>
}

public struct IntegrationSource<View: Decodable & Equatable & Sendable>: Decodable, Equatable, Sendable {
    public var enabled: Bool
    public var views: [View]
}

/// A GitHub view: a search query.
public struct GitHubView: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var query: String
    public var start: TaskStart?
    public init(id: String = "", name: String, query: String, start: TaskStart? = nil) {
        self.id = id; self.name = name; self.query = query; self.start = start
    }
}

/// How a view's items start tasks (crates/zerod/src/integrations.rs): the folder, the agent, and a prompt that fills in
/// {key}, {title}, {url} and {state}.
public struct TaskStart: Codable, Equatable, Sendable {
    public var cwd: String
    public var prompt: String
    public var provider: String?
    public var model: String?
    public var effort: String?
    public var permissions: String?
    public init(
        cwd: String, prompt: String, provider: String? = nil, model: String? = nil, effort: String? = nil, permissions: String? = nil
    ) {
        self.cwd = cwd; self.prompt = prompt; self.provider = provider; self.model = model; self.effort = effort;
        self.permissions = permissions
    }
}

/// A task started from an item, or the one it already had, with the task's state pad.
public struct StartedTask: Decodable, Sendable {
    public var session: String
    public var existing: Bool
    public var pad: String?
}

/// A Linear view: whose issues ("me", "anyone", "nobody"), which teams and which state types (none means all).
public struct LinearView: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var assignee: String
    public var teams: [String]
    public var states: [String]
    /// The teams' own states by name; when any are picked they stand in for `states` (their types).
    public var stateNames: [String]
    public var start: TaskStart?
    public init(
        id: String = "", name: String, assignee: String = "me", teams: [String] = [],
        states: [String] = ["backlog", "unstarted", "started"],
        stateNames: [String] = [], start: TaskStart? = nil
    ) {
        self.id = id; self.name = name; self.assignee = assignee; self.teams = teams; self.states = states; self.stateNames = stateNames;
        self.start = start
    }
}

/// A Linear team and its own workflow states, in the order Linear lists them.
public struct LinearTeam: Decodable, Sendable, Identifiable {
    public struct State: Decodable, Sendable, Hashable {
        public var name: String
        public var type: String
        public var color: String
    }
    public var key: String
    public var name: String
    public var states: [State]
    public var id: String { key }
}

/// A scratchpad as zerod lists it (crates/zerod/src/pads.rs): a Markdown file under ~/.zero/scratchpads.
public struct PadSummary: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// "Work/2026"; empty at the top.
    public var folder: String
    public var link: String
    public var updated: Int
}

/// A heading in a pad, with its anchor (zero://pad/<id>#<slug>).
public struct PadSection: Decodable, Equatable, Sendable, Hashable {
    public var slug: String
    public var title: String
    public var level: Int
    /// Where its heading is, from 1.
    public var line: Int
}

/// A pad read whole: its text, the revision a write must name, and its sections.
public struct Pad: Decodable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var folder: String
    public var content: String
    public var revision: String
    public var sections: [PadSection]
    public var link: String
    public var updated: Int
}

public struct PadList: Decodable, Equatable, Sendable {
    public var pads: [PadSummary]
    public var folders: [String]
}

/// One row of a view: a pull request or an issue.
public struct IntegrationItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var key: String
    public var title: String
    public var url: String
    public var place: String
    public var state: String
    /// An issue's state's colour in Linear ("#f2c94c").
    public var color: String?
    public var checks: String?
    public var review: String?
    public var person: String?
    public var priority: Int?
    public var updated: String
    /// An issue's state's type (started, triage…), which its icon shows.
    public var kind: String?
    /// An issue's labels, then its project.
    public var tags: [IntegrationTag]?
    /// The assignee's picture.
    public var avatar: String?
    public var created: String?
    /// The task started from it, if one has been.
    public var task: String?
}

extension IntegrationItem {
    /// What its task is filed under, as zerod files it: an issue's key, a pull request's repository and number.
    public var ticketKey: String { key.hasPrefix("#") ? place + key : key }
}

/// A label, or a project with its icon (an emoji's shortcode, ":fire:", or one of Linear's own names).
public struct IntegrationTag: Codable, Equatable, Sendable, Hashable {
    public var name: String
    public var color: String?
    public var icon: String?
}

/// One row of the board (crates/zerod/src/board.rs): a lead session with its workers folded in.
public struct BoardRow: Decodable, Equatable, Sendable, Identifiable {
    /// As zerod's board has them (board.rs), most urgent first. Handed is "Over to you": a step only the user can take.
    /// Waiting is on someone or something that isn't the user.
    public enum State: String, Decodable, Sendable {
        /// `read`: Replied, and the user has seen the reply (it greys); the chat that's open shows it as Replied still.
        /// `done`: nothing left that the agent can do, last of all and archived after a while.
        case needsYou, trouble, blocked, working, handed, answered, waiting, paused, read, done, idle, offline
        /// Most urgent first, as the board sorts its rows.
        public var urgency: Int {
            switch self {
            case .needsYou: 0
            case .trouble: 1
            case .blocked: 1
            case .working: 2
            case .handed: 3
            case .answered: 4
            case .waiting: 5
            case .done: 9
            default: 8
            }
        }
        /// As the sidebar's state pill says it.
        public var title: String {
            switch self {
            case .needsYou: "Needs you"
            case .trouble: "In trouble"
            case .blocked: "Blocked"
            case .working: "Working"
            case .handed: "Over to you"
            case .answered, .read: "Replied"
            case .waiting: "Waiting"
            case .done: "Done"
            case .paused: "Paused"
            case .idle: "Idle"
            case .offline: "Offline"
            }
        }
    }
    public var session: String
    public var task: String
    /// The workspace it is in; "zero" when none was made.
    public var workspace: String = "zero"
    public var ticket: String?
    /// The agent the lead runs on, and when it last moved (ms since 1970); none from an older zerod.
    public var provider: Provider?
    public var at: Int?
    /// The shortest end of its folder that tells it from the other rows'.
    public var place: String
    /// Where that place is on disk, when the places command says (a bench's folder).
    public var path: String?
    /// Offline, `state` is the one it was last known in.
    public var online: Bool
    /// The team's: the lead's own, raised by a worker's that needs attention. What the row sorts by.
    public var state: State
    /// The lead's own, its workers left out (zerod's board.rs); nil from an older zerod.
    public var own: State?
    /// What the lead itself is doing: its icon in the sidebar, its status in the details pane.
    public var ownState: State { own ?? state }

    /// A task just started, before zerod's board has its row: Working, under its name, so it takes its place among the
    /// tasks at once (rather than showing elsewhere first and jumping when the board catches up).
    public static func starting(session: String, task: String, workspace: String) -> BoardRow? {
        let row: [String: Any] = [
            "session": session, "task": task, "workspace": workspace, "place": "", "online": true,
            "state": "working", "own": "working", "asks": [], "workers": 0,
        ]
        return (try? JSONSerialization.data(withJSONObject: row)).flatMap { try? JSONDecoder().decode(BoardRow.self, from: $0) }
    }
    public var now: String?
    public var needs: String?
    /// The open asks of the lead and its workers.
    public var asks: [Waiting]
    public var workers: Int
    /// Each of its workers as it is itself (zerod's board works it out by the same rules as a lead's).
    public var team: [Member]?
    /// Your messages waiting for after the current turn, in order; held, they wait for your say (you stopped the agent).
    public var queued: [Queued]?
    public var held: Bool?
    /// When it next wakes itself (`zero schedule`), in seconds since 1970.
    public var wakes: Int?
    /// A change picked while a turn ran, applied as it ends: the provider, model, effort or permissions.
    public var next: Next?
    public struct Next: Decodable, Equatable, Sendable {
        public var provider: Provider?
        public var model: String?
        public var effort: String?
        public var permissions: Permissions?
    }
    /// Its last turn was Zero's (an event it follows, a worker's report), not the user's: a reply to it isn't announced.
    public var quiet: Bool?
    /// The issues it drives, a row each, as its agent keeps them (`zero issue`): those on the user first.
    public var issues: [Issue]?
    public var id: String { session }

    /// One issue a lead drives (board.rs, model.rs Issue): who has it, in words what it needs or where it stands.
    public struct Issue: Decodable, Equatable, Sendable, Identifiable {
        public var ticket: String
        /// you, working, waiting, parked or done.
        public var state: String
        public var text: String
        /// When it came to its state, in milliseconds since 1970.
        public var since: Int
        public var id: String { ticket }

        /// In the sidebar's states: on the user is Needs you, parked is Paused.
        public var boardState: BoardRow.State {
            switch state {
            case "you": .needsYou
            case "working": .working
            case "waiting": .waiting
            case "parked": .paused
            default: .done
            }
        }

        /// How long it has been on the user ("12m", "3h", "2d"), while it is.
        public func waiting(at now: Date = Date()) -> String? {
            guard state == "you" else { return nil }
            let minutes = max(0, Int(now.timeIntervalSince1970 - Double(since) / 1000) / 60)
            return minutes < 60 ? "\(minutes)m" : minutes < 48 * 60 ? "\(minutes / 60)h" : "\(minutes / 1440)d"
        }
    }
    public struct Waiting: Decodable, Equatable, Sendable { public var id: String; public var title: String }

    public struct Member: Decodable, Equatable, Sendable {
        public var session: String
        public var state: State
        public var place: String
        public var path: String?
        public var now: String?
        public var needs: String?
        public var asks: [Waiting]
        public var queued: [Queued]?
        public var held: Bool?
    }

    /// One of its workers as a row of its own: its state, place and asks, for showing that worker.
    public func member(_ id: String) -> BoardRow? {
        guard let member = team?.first(where: { $0.session == id }) else { return nil }
        var row = self
        row.session = member.session; row.state = member.state; row.place = member.place; row.path = member.path
        row.now = member.now; row.needs = member.needs; row.asks = member.asks; row.workers = 0; row.team = nil
        row.own = nil // the lead's, not the worker's
        row.queued = member.queued; row.held = member.held
        return row
    }
}

/// A message of yours waiting for after the agent's current turn (crates/zerod/src/model.rs `Queued`).
public struct Queued: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var images: [String]?
    public init(id: String, text: String, images: [String]?) { self.id = id; self.text = text; self.images = images }
}

/// A task's provider terminal (crates/zerod/src/model.rs `Opened`): zero-host's id, and how much of the provider's own
/// history was in Zero's record when it opened.
public struct Opened: Decodable, Equatable, Sendable {
    public var id: String
    public var mark: Int
    public init(id: String, mark: Int) { self.id = id; self.mark = mark }
}

public struct UsageWindow: Decodable, Equatable, Sendable {
    public var name: String
    /// The share used, 0 to 1.
    public var used: Double
    public var resetsAt: Int?
}

public struct Usage: Decodable, Equatable, Sendable {
    public var limited: Bool
    /// Unix seconds.
    public var resetsAt: Int?
    public var windows: [UsageWindow]
}

public enum FailureKind: String, Decodable, Sendable { case limit, signIn, network, model, other }

public struct Failure: Decodable, Equatable, Sendable {
    public var kind: FailureKind
    public var message: String
}

/// What a session needs from the user, most urgent first: the bar's dot (zerod's `Conversation::attention`).
public enum Attention: String, Decodable, Sendable {
    case needsYou, limited, stuck, failed, blocked, working, done, answered, idle, offline, starting
}

public struct Conversation: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var provider: Provider
    public var cwd: String
    public var permissions: Permissions
    /// A name the user or its lead gave it, and what the work is for (an issue, a ticket).
    public var label: String?
    public var ticket: String?
    /// Where it runs, by name, when its folder doesn't say.
    public var place: String?
    /// The git branch its folder was on when it started.
    public var branch: String?
    /// The session that started it, for a worker.
    public var parent: String?
    /// The workspace it was put in; nil, and its folder decides (Workspace.workspace(of:)).
    public var workspace: String?
    /// The sign-in its CLI runs as (zerod's signins.rs); none, its CLI's own.
    public var signin: String?
    /// The provider's own id for the conversation, once it has one.
    public var thread: String?
    public var title: String?
    public var model: String?
    public var effort: String?
    public var status: SessionStatus
    public var turn: String?
    public var error: String?
    public var items: [ConversationItem]
    public var approvals: [Approval]
    public var questions: [Question]
    public var usage: Usage?
    public var failure: Failure?
    /// Why it looks stuck, while it does.
    public var stalled: String?
    /// The unified diff of everything the latest turn changed.
    public var diff: String?
    /// While the task is in its provider's own terminal: zero-host's id for it.
    public var terminal: Opened?
    /// What its agent says about it beyond its name and ticket, by name ("PR": a link): `zero attr`.
    public var attributes: [String: String]?
    /// How many changes have been applied; the next change zerod sends for this session is `seq + 1`.
    public var seq: UInt64

    public init(id: String, provider: Provider, cwd: String) {
        self.id = id; self.provider = provider; self.cwd = cwd; permissions = .auto; status = .starting; items = []; approvals = [];
        questions = []; seq = 0
    }

    public func item(_ id: String) -> ConversationItem? { items.first { $0.id == id } }

    /// What zerod's `Conversation::attention` says, step for step.
    public var attention: Attention {
        if !approvals.isEmpty || !questions.isEmpty { return .needsYou }
        if usage?.limited == true || failure?.kind == .limit { return .limited }
        if stalled != nil { return .stuck }
        if failure != nil { return .failed }
        switch status {
        case .working, .waiting: return .working
        case .starting: return .starting
        case .offline: return .offline
        case .idle:
            // As zerod decides (model.rs): a worker's answer is its report to its lead, done; a lead's answer says
            // whether the task is done or waits on the user (Zero's ending, or a question in prose), else it's a turn
            // finished, not a task.
            guard case let .agent(text, true)? = items.last?.kind else { return .idle }
            if parent != nil { return .done }
            switch ZeroEnding.split(text).1 {
            case .done?: return .done
            case .asked?: return .needsYou
            case .waiting?: return .blocked
            case .working?: return .idle
            case nil:
                return text.split(whereSeparator: \.isNewline).contains { $0.trimmingCharacters(in: .whitespaces).hasSuffix("?") }
                    ? .needsYou : .answered
            }
        }
    }

    /// What zerod's `Conversation::apply` does, step for step.
    public mutating func apply(_ change: Change) {
        seq += 1
        switch change {
        case let .thread(thread, model, effort):
            self.thread = thread
            if let model { self.model = model }
            if let effort { self.effort = effort }
        case let .title(title): self.title = title
        case let .named(label, ticket): self.label = label; self.ticket = ticket
        case let .placed(workspace): self.workspace = workspace
        case let .signedIn(signin): self.signin = signin
        case let .permitted(permissions):
            // As zerod records it (model.rs): the change, and a line in the conversation saying so.
            self.permissions = permissions
            let text =
                permissions == .auto ? "Auto from here: it asks before what isn't safe" : "Unrestricted from here: it acts without asking"
            items.append(
                ConversationItem(id: "permitted-\(items.count)", turn: nil, kind: .notice(text: text, error: false), status: .done))
        case let .status(status, turn, error):
            self.status = status; self.turn = turn; self.error = error
        case let .item(item):
            if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item } else { items.append(item) }
        case let .delta(id, text):
            guard let i = items.firstIndex(where: { $0.id == id }) else { return }
            switch items[i].kind {
            case let .user(body, images): items[i].kind = .user(text: body + text, images: images)
            case let .agent(body, final): items[i].kind = .agent(text: body + text, finalAnswer: final)
            case let .reasoning(body): items[i].kind = .reasoning(text: body + text)
            case let .plan(body): items[i].kind = .plan(text: body + text)
            case let .notice(body, error): items[i].kind = .notice(text: body + text, error: error)
            case let .command(command, cwd, output, exitCode, durationMs):
                items[i].kind = .command(command: command, cwd: cwd, output: output + text, exitCode: exitCode, durationMs: durationMs)
            case .fileChange, .tool, .table: break
            }
        case let .approval(approval):
            approvals.removeAll { $0.id == approval.id }
            approvals.append(approval)
        case let .resolved(id): approvals.removeAll { $0.id == id }
        case let .question(question):
            questions.removeAll { $0.id == question.id }
            questions.append(question)
        case let .answered(id): questions.removeAll { $0.id == id }
        case let .usage(usage): self.usage = usage
        case let .failed(failure): self.failure = failure
        case let .stalled(reason): stalled = reason
        case let .diff(diff): self.diff = diff
        case let .terminal(terminal): self.terminal = terminal
        case .archived: break
        case let .place(place): self.place = place
        case let .parent(parent): self.parent = parent
        case .snapshot: break
        case let .attribute(name, value):
            var all = attributes ?? [:]
            all[name] = value
            attributes = all.isEmpty ? nil : all
        case .other:
            break
        case let .rewound(before):
            // As zerod does (model.rs): the message and what followed go, and with them the provider's thread.
            if let at = items.firstIndex(where: { $0.id == before }) { items.removeSubrange(at...) }
            thread = nil; turn = nil; approvals = []; questions = []; diff = nil; error = nil; failure = nil; stalled = nil
        case let .switched(provider, model, effort):
            self.provider = provider; self.thread = nil; self.model = model; self.effort = effort
            // As zerod does: where each provider took over, in the conversation itself; stopped for the handover, one line.
            if let last = items.indices.last, case .notice("Interrupted", false) = items[last].kind {
                items[last].kind = .notice(text: "Interrupted and continued in \(provider.title)", error: false)
            } else {
                items.append(
                    ConversationItem(
                        id: "switched-\(seq)", turn: nil, kind: .notice(text: "Continued in \(provider.title)", error: false), status: .done
                    ))
            }
        }
    }
}

public enum Change: Decodable, Equatable, Sendable {
    case thread(String, model: String?, effort: String?)
    case title(String?)
    case named(label: String?, ticket: String?)
    case placed(String?)
    /// Runs as another sign-in from its next start (zerod's signins.rs).
    case signedIn(String?)
    /// What the agent may do without asking, from its next start.
    case permitted(Permissions)
    case status(SessionStatus, turn: String?, error: String?)
    case item(ConversationItem)
    case delta(item: String, text: String)
    case approval(Approval)
    case resolved(String)
    case question(Question)
    case answered(String)
    case usage(Usage)
    case failed(Failure?)
    case stalled(String?)
    case diff(String?)
    /// The task moved to another provider, which starts a thread of its own from Zero's record.
    case switched(Provider, model: String?, effort: String?)
    /// The task went to its provider's terminal, or came back.
    case terminal(Opened?)
    /// The task was put away: it leaves the list.
    case archived
    /// Where the task runs, by name.
    case place(String?)
    /// The task became a worker of another, or a lead again.
    case parent(String?)
    /// zerod kept the folder as it was when a message went (what a rewind can bring back).
    case snapshot
    /// Its agent said something about the task; nil takes it back.
    case attribute(String, String?)
    /// A change of a kind this app doesn't know (a newer zerod's): counted, so the changes after it still apply, and
    /// otherwise passed over. The board carries what the app shows of it (an issue's row, say).
    case other(String)
    /// Back to just before this message of yours: it and everything after it are gone.
    case rewound(String)

    private enum Keys: String, CodingKey {
        case type, thread, model, effort, title, status, turn, error, item, text, approval, diff, question, usage, failure, reason, label,
            ticket, provider, terminal, place, parent, before, name, value, workspace, permissions, signin
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "thread":
            self = .thread(
                try c.decode(String.self, forKey: .thread), model: try c.decodeIfPresent(String.self, forKey: .model),
                effort: try c.decodeIfPresent(String.self, forKey: .effort))
        case "title": self = .title(try c.decodeIfPresent(String.self, forKey: .title))
        case "named":
            self = .named(
                label: try c.decodeIfPresent(String.self, forKey: .label), ticket: try c.decodeIfPresent(String.self, forKey: .ticket))
        case "placed": self = .placed(try c.decodeIfPresent(String.self, forKey: .workspace))
        case "signedIn": self = .signedIn(try c.decodeIfPresent(String.self, forKey: .signin))
        case "permitted": self = .permitted(try c.decode(Permissions.self, forKey: .permissions))
        case "status":
            self = .status(
                try c.decode(SessionStatus.self, forKey: .status), turn: try c.decodeIfPresent(String.self, forKey: .turn),
                error: try c.decodeIfPresent(String.self, forKey: .error))
        case "item": self = .item(try c.decode(ConversationItem.self, forKey: .item))
        case "delta": self = .delta(item: try c.decode(String.self, forKey: .item), text: try c.decode(String.self, forKey: .text))
        case "approval": self = .approval(try c.decode(Approval.self, forKey: .approval))
        case "resolved": self = .resolved(try c.decode(String.self, forKey: .approval))
        case "question": self = .question(try c.decode(Question.self, forKey: .question))
        case "answered": self = .answered(try c.decode(String.self, forKey: .question))
        case "usage": self = .usage(try c.decode(Usage.self, forKey: .usage))
        case "failed": self = .failed(try c.decodeIfPresent(Failure.self, forKey: .failure))
        case "stalled": self = .stalled(try c.decodeIfPresent(String.self, forKey: .reason))
        case "diff": self = .diff(try c.decodeIfPresent(String.self, forKey: .diff))
        case "terminal": self = .terminal(try c.decodeIfPresent(Opened.self, forKey: .terminal))
        case "archived": self = .archived
        case "place": self = .place(try c.decodeIfPresent(String.self, forKey: .place))
        case "parent": self = .parent(try c.decodeIfPresent(String.self, forKey: .parent))
        case "snapshot": self = .snapshot
        case "attribute": self = .attribute(try c.decode(String.self, forKey: .name), try c.decodeIfPresent(String.self, forKey: .value))
        case "rewound": self = .rewound(try c.decode(String.self, forKey: .before))
        case "switched":
            self = .switched(
                try c.decode(Provider.self, forKey: .provider), model: try c.decodeIfPresent(String.self, forKey: .model),
                effort: try c.decodeIfPresent(String.self, forKey: .effort))
        case let other: self = .other(other)
        }
    }
}

/// A change as zerod sends it: which session, and its number in that session's sequence.
public struct ZerodEvent: Decodable, Sendable {
    public var session: String
    public var seq: UInt64
    public var change: Change
    public init(session: String, seq: UInt64, change: Change) { self.session = session; self.seq = seq; self.change = change }
}

/// A copy of zerod's sessions, kept the way zerod's subscription is meant to be followed: a snapshot of each session,
/// then only the change numbered next.
public struct ZerodMirror: Sendable {
    public enum Message: Sendable {
        case session(Conversation)
        case change(ZerodEvent)
        /// How many of a session's items came before those its snapshot carried: older pages, fetched as needed.
        case earlier(session: String, count: Int)
    }

    public private(set) var conversations: [String: Conversation] = [:]
    /// Each session's items not loaded, before the ones that are.
    public private(set) var earlier: [String: Int] = [:]
    /// And after them: a window jumped to (the rail's) stops short of the end; newer pages come as it's scrolled down.
    public private(set) var later: [String: Int] = [:]
    /// Session ids in the order they first arrived.
    public private(set) var order: [String] = []

    public init() {}

    /// False when the copy has fallen behind (a change skipped ahead, or came for a session without a snapshot):
    /// subscribe again for fresh snapshots.
    @discardableResult
    public mutating func receive(_ message: Message) -> Bool {
        switch message {
        case let .session(conversation):
            if conversations[conversation.id] == nil { order.append(conversation.id) }
            conversations[conversation.id] = conversation
            later[conversation.id] = 0
            return true
        case let .earlier(session, count):
            earlier[session] = count
            return true
        case let .change(event) where event.change == .archived:
            conversations[event.session] = nil
            earlier[event.session] = nil
            later[event.session] = nil
            order.removeAll { $0 == event.session }
            return true
        case let .change(event):
            guard let seq = conversations[event.session]?.seq else { return false }
            if event.seq <= seq { return true }
            guard event.seq == seq + 1 else { return false }
            // Changed where it is: copied out and back, every item of a long task was copied for each word streamed.
            let count = conversations[event.session]!.items.count
            conversations[event.session]!.apply(event.change)
            // Short of the end, what's new lies past the window: counted there, not put after its last item.
            let now = conversations[event.session]!.items.count
            if let cut = later[event.session], cut > 0, now > count {
                later[event.session] = cut + now - count
                conversations[event.session]!.items.removeLast(now - count)
            }
            return true
        }
    }

    /// Older items, put before those loaded; `remaining` are still before them.
    public mutating func prepend(_ session: String, items: [ConversationItem], remaining: Int) {
        guard var conversation = conversations[session] else { return }
        let loaded = Set(conversation.items.map(\.id))
        conversation.items = items.filter { !loaded.contains($0.id) } + conversation.items
        conversations[session] = conversation
        earlier[session] = remaining
    }

    /// A page of it anywhere, in place of what was loaded, with how many items lie either side.
    public mutating func window(_ session: String, items: [ConversationItem], earlier before: Int, later after: Int) {
        guard var conversation = conversations[session] else { return }
        conversation.items = items
        conversations[session] = conversation
        earlier[session] = before
        later[session] = after
    }

    /// Newer items, put after those loaded; `later` are still after them.
    public mutating func append(_ session: String, items: [ConversationItem], later after: Int) {
        guard var conversation = conversations[session] else { return }
        let loaded = Set(conversation.items.map(\.id))
        conversation.items += items.filter { !loaded.contains($0.id) }
        conversations[session] = conversation
        later[session] = after
    }

    /// Back to the latest `keep` items: the older ones are fetched again if they're wanted.
    public mutating func trim(_ session: String, keep: Int) {
        guard var conversation = conversations[session], conversation.items.count > keep else { return }
        let dropped = conversation.items.count - keep
        conversation.items.removeFirst(dropped)
        conversations[session] = conversation
        earlier[session, default: 0] += dropped
    }
}

/// A message of yours in a conversation's outline, with the start of its answer: the rail's marks.
public struct OutlineMark: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var answer: String?
}

public struct ZerodError: LocalizedError, Equatable {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// One connection to zerod: requests answered by id (so several can be in flight), and, after `subscribe`, the
/// sessions' snapshots and changes through `onMessage`. Blocking socket I/O on a thread of its own.
public final class ZerodLink: @unchecked Sendable {
    /// ~/.zero/zerod.sock, or the one ZERO_DAEMON names (a test daemon, say).
    public static let socket = ProcessInfo.processInfo.environment["ZERO_DAEMON"] ?? Paths.dir.appendingPathComponent("zerod.sock").path
    public static let home = Paths.dir.appendingPathComponent("zerod").path

    private let connection: any LineConnection
    private let lock = NSLock()
    private let writing = NSLock()
    private var next = 0
    private var waiting: [Int: CheckedContinuation<Any, Error>] = [:]
    private var closed = false
    private var messageHandler: (@Sendable (ZerodMirror.Message) -> Void)?
    private var inboxHandler: (@Sendable (InboxMessage) -> Void)?
    private var closeHandler: (@Sendable () -> Void)?
    private var feedHandler: (@Sendable (Feed) -> Void)?

    /// What zerod pushes besides sessions, after `subscribe`: the board whenever it changes, and that pads changed.
    public enum Feed: Sendable {
        case board([BoardRow])
        case pads
        case loops
        case later
        case following
        case workspaces
        case signins
        /// zerod is restarting as a new build: pausing turns between steps first.
        case restarting
        /// Notifications to take off a phone, by id: seen on the Mac (from the Mac's bridge, not zerod).
        case clear([String])
    }

    /// The board and notices, on the link's reading thread.
    public var onFeed: (@Sendable (Feed) -> Void)? {
        get { lock.withLock { feedHandler } }
        set { lock.withLock { feedHandler = newValue } }
    }

    /// What `followInbox` brings: every ask with which agents are offline and reachable, then each change.
    public enum InboxMessage: Sendable {
        case asks([Ask], offline: Set<String>, reachable: Set<String>)
        case ask(Ask)
        case output(id: String, chunk: String)
        case removed(String)
        case agents(offline: Set<String>, reachable: Set<String>)
    }

    /// The inbox's snapshot and changes, on the link's reading thread.
    public var onInbox: (@Sendable (InboxMessage) -> Void)? {
        get { lock.withLock { inboxHandler } }
        set { lock.withLock { inboxHandler = newValue } }
    }

    /// Snapshots and changes, on the link's reading thread.
    public var onMessage: (@Sendable (ZerodMirror.Message) -> Void)? {
        get { lock.withLock { messageHandler } }
        set { lock.withLock { messageHandler = newValue } }
    }

    /// The connection ended: zerod quit, or `close`.
    public var onClose: (@Sendable () -> Void)? {
        get { lock.withLock { closeHandler } }
        set { lock.withLock { closeHandler = newValue } }
    }

    public init(path: String = ZerodLink.socket) throws {
        connection = try UnixSocket.connect(path: path)
        Thread.detachNewThread { [self] in read() }
    }

    /// Over another connection: the phone's, through the tunnel.
    public init(connection: any LineConnection) {
        self.connection = connection
        Thread.detachNewThread { [self] in read() }
    }

    public func close() { connection.shutdown() }

    // The daemon's requests (crates/zerod/src/server.rs).

    public func hello() async throws -> Int {
        try ((await call("hello")) as? [String: Any])?["version"] as? Int ?? 0
    }

    /// Every session, without its items.
    public func list() async throws -> [Conversation] { try decode([Conversation].self, from: await call("list")) }

    public func get(_ session: String) async throws -> Conversation {
        try decode(Conversation.self, from: await call("get", ["session": session]))
    }

    /// Starts a session and returns its id at once, while the provider starts.
    public func start(
        provider: Provider, cwd: String, prompt: String, images: [String] = [], model: String? = nil, effort: String? = nil,
        permissions: Permissions = .auto, workspace: String? = nil
    ) async throws -> String {
        let result = try await call(
            "start",
            [
                "provider": provider.rawValue, "cwd": cwd, "prompt": prompt, "images": images, "model": model, "effort": effort,
                "permissions": permissions.rawValue, "workspace": workspace,
            ])
        guard let session = (result as? [String: Any])?["session"] as? String else { throw ZerodError(message: "zerod started no session") }
        return session
    }

    public func send(session: String, text: String, images: [String] = [], model: String? = nil, effort: String? = nil) async throws {
        _ = try await call("send", ["session": session, "text": text, "images": images, "model": model, "effort": effort])
    }

    /// For after the current turn, one turn each; between turns it goes at once.
    public func queue(session: String, text: String, images: [String] = []) async throws {
        _ = try await call("queue", ["session": session, "text": text, "images": images])
    }
    public func unqueue(session: String, item: String) async throws { _ = try await call("unqueue", ["session": session, "item": item]) }
    /// Lets a queue held since a stop go on.
    public func release(session: String) async throws { _ = try await call("release", ["session": session]) }
    /// The user asks two tasks to work together: each is told about the other and how to reach it.
    public func introduce(session: String, to other: String) async throws {
        _ = try await call("introduce", ["session": session, "args": ["other": other]])
    }

    public func interrupt(session: String) async throws { _ = try await call("interrupt", ["session": session]) }
    public func stop(session: String) async throws { _ = try await call("stop", ["session": session]) }
    /// Puts tasks and their workers on hold (every task, none named), and takes them off it; gives the sessions it did.
    public func pause(sessions: [String]) async throws -> [String] { try await call("pause", ["sessions": sessions]) as? [String] ?? [] }
    public func unpause(sessions: [String]) async throws -> [String] {
        try await call("unpause", ["sessions": sessions]) as? [String] ?? []
    }
    /// Puts the task away: out of the list, its files kept in zerod's archive/.
    public func archive(session: String) async throws { _ = try await call("archive", ["session": session]) }

    /// A task put away itself (not with its lead), as the archive lists it.
    public struct Archived: Decodable, Equatable, Sendable, Identifiable {
        public let id: String
        public let task: String
        public let at: Int
        public let workspace: String?
        /// The workers that went with it, and come back with it.
        public let workers: Int
        /// The lead of a worker archived on its own.
        public var parent: String?
        public var date: Date { Date(timeIntervalSince1970: TimeInterval(at) / 1000) }
    }

    public func archived() async throws -> [Archived] { try decode([Archived].self, from: await call("archived")) }

    /// Brings a task back, and the workers archived with it: the ids back.
    /// A task saved for later, whole: off the board, on hold, an item in Later. The item.
    public func saveForLater(session: String) async throws { _ = try await call("saveForLater", ["session": session]) }
    /// A task saved for later back on the board: its session.
    public func resumeLater(_ item: String) async throws -> String? {
        (try await call("resumeLater", ["args": ["item": item]]) as? [String: Any])?["session"] as? String
    }
    public func unarchive(session: String) async throws -> [String] { try await call("unarchive", ["session": session]) as? [String] ?? [] }

    /// What going back to a message of yours would do to the folder.
    public func rewindPreview(session: String, message: String) async throws -> RewindPreview {
        try decode(RewindPreview.self, from: await call("rewindPreview", ["session": session, "message": message]))
    }

    /// Back to just before a message of yours: the conversation, the folder's code, or both; the message comes back.
    public func rewind(session: String, message: String, conversation: Bool, code: Bool) async throws -> Rewound {
        try decode(
            Rewound.self, from: await call("rewind", ["session": session, "message": message, "conversation": conversation, "code": code]))
    }

    /// A new task from just before a message of yours; this one stays. Its id comes back with the message.
    public func branch(session: String, message: String) async throws -> Rewound {
        try decode(Rewound.self, from: await call("branch", ["session": session, "message": message]))
    }
    public func resume(session: String) async throws { _ = try await call("resume", ["session": session]) }
    /// Moves the task to another provider between turns; the next message starts it there.
    /// Hands the task to its provider's own terminal; zero-host's id for it.
    public func openTerminal(session: String) async throws -> String {
        guard let terminal = (try await call("openTerminal", ["session": session]) as? [String: Any])?["terminal"] as? String else {
            throw ZerodError(message: "zerod opened no terminal")
        }
        return terminal
    }
    /// Back from the provider's terminal to Zero's UI, with what happened there.
    public func closeTerminal(session: String) async throws { _ = try await call("closeTerminal", ["session": session]) }
    public func switchProvider(session: String, to provider: Provider, model: String?, effort: String?) async throws {
        _ = try await call("switch", ["session": session, "provider": provider.rawValue, "model": model, "effort": effort])
    }

    public func decide(session: String, approval: String, choice: String) async throws {
        _ = try await call("decide", ["session": session, "approval": approval, "choice": choice])
    }

    /// Answers an open question, every field at once: picked options, or the user's own words.
    public func answer(session: String, question: String, answers: [String: [String]]) async throws {
        _ = try await call("answer", ["session": session, "question": question, "answers": answers])
    }

    // Leads and workers.

    /// Starts a worker of `lead`, in its folder and with its permissions unless given others.
    public func spawn(
        lead: String, provider: Provider?, prompt: String, cwd: String? = nil, model: String? = nil, effort: String? = nil,
        permissions: Permissions? = nil, label: String? = nil, ticket: String? = nil, workspace: String? = nil
    ) async throws -> String {
        let result = try await call(
            "spawn",
            [
                "session": lead, "provider": provider?.rawValue, "prompt": prompt, "cwd": cwd, "model": model,
                "effort": effort, "permissions": permissions?.rawValue, "label": label, "ticket": ticket, "workspace": workspace,
            ])
        guard let session = (result as? [String: Any])?["session"] as? String else { throw ZerodError(message: "zerod started no session") }
        return session
    }

    /// A Claude Code, Codex or OpenCode session from outside Zero, by its id, taken in as a task where it ran, with its
    /// history: offline and not opened, until a message resumes it on its own thread.
    public func migrate(_ thread: String, label: String? = nil, workspace: String? = nil) async throws -> String {
        var params: [String: Any] = ["thread": thread]
        if let label { params["label"] = label }
        if let workspace { params["workspace"] = workspace }
        let result = try await call("migrate", params)
        guard let session = (result as? [String: Any])?["session"] as? String else { throw ZerodError(message: "zerod migrated nothing") }
        return session
    }

    /// A worker (by its task's id, or its session's) let go of its lead: a task of its own.
    public func detach(_ target: String) async throws { _ = try await call("detach", ["thread": target]) }

    /// A task (by its id, or its Claude Code session's) made a worker of `lead`, taken in first if Zero hasn't it.
    public func adopt(lead: String, target: String) async throws -> String {
        let result = try await call("adopt", ["session": lead, "thread": target])
        guard let session = (result as? [String: Any])?["session"] as? String else { throw ZerodError(message: "zerod adopted nothing") }
        return session
    }

    /// Something an agent says about its task (`zero attr`); nil takes it back.
    /// One of the issues a task drives, its row set: who has it (you, working, waiting, parked, done) and in words
    /// what it needs from the user, where it stands, or why it's parked.
    public func issue(session: String, ticket: String, state: String, text: String) async throws {
        _ = try await call("issue", ["session": session, "ticket": ticket, "state": state, "text": text])
    }

    public func attribute(session: String, name: String, value: String?) async throws {
        _ = try await call("attr", ["session": session, "name": name, "value": value])
    }

    /// A table the agent hands to Zero to draw, in its conversation.
    public func table(session: String, title: String, columns: [String], rows: [[String]]) async throws {
        _ = try await call("table", ["session": session, "title": title, "columns": columns, "rows": rows])
    }

    public func label(session: String, label: String?, ticket: String?) async throws {
        _ = try await call("label", ["session": session, "label": label, "ticket": ticket])
    }
    /// Where the session runs, by name (a bench, a machine); nil goes back to its folder.
    public func place(session: String, place: String?) async throws {
        _ = try await call("place", ["session": session, "place": place])
    }
    /// The command that says where tasks run by ticket (zerod reruns it every minute); empty for none.
    public func placesCommand() async throws -> String {
        ((try await call("settings")) as? [String: Any])?["places"] as? String ?? ""
    }
    public func setPlacesCommand(_ command: String) async throws { _ = try await call("configure", ["places": command]) }

    /// Settings › Git: the identity agents' Git commits and signs as, and the public half of their signing key.
    public func agentGit() async throws -> (AgentGit, String?) {
        let settings = try await call("settings") as? [String: Any] ?? [:]
        var git = AgentGit()
        if let raw = settings["git"], let data = try? JSONSerialization.data(withJSONObject: raw),
            let kept = try? JSONDecoder().decode(AgentGit.self, from: data)
        {
            git = kept
        }
        return (git, settings["gitPublicKey"] as? String)
    }

    public func setAgentGit(_ git: AgentGit) async throws {
        _ = try await call("configure", ["git": try JSONSerialization.jsonObject(with: JSONEncoder().encode(git))])
    }

    /// The committer for GitHub account `login`: its name and noreply email, as GitHub has them.
    public func gitAccount(_ login: String) async throws -> (login: String, name: String, email: String) {
        let found = try await call("gitAccount", ["args": ["login": login]]) as? [String: Any] ?? [:]
        return (found["login"] as? String ?? login, found["name"] as? String ?? "", found["email"] as? String ?? "")
    }

    /// The agents' signing key's title among `login`'s signing keys on GitHub; nil when it isn't one of them.
    public func gitCheck(_ login: String) async throws -> String? {
        (try await call("gitCheck", ["args": ["login": login]]) as? [String: Any])?["title"] as? String
    }

    /// The private key at `path` as the agents' signing key: zerod keeps its own copy. Gives its public half.
    public func takeGitKey(path: String) async throws -> String {
        ((try await call("gitKey", ["args": ["path": path]])) as? [String: Any])?["publicKey"] as? String ?? ""
    }
    /// Seconds a done task stays before zerod archives it; 0 never, -1 once read. Unset, a day.
    public func archiveCompleted() async throws -> Int {
        ((try await call("settings")) as? [String: Any])?["archiveCompleted"] as? Int ?? 24 * 3600
    }
    public func setArchiveCompleted(_ seconds: Int) async throws { _ = try await call("configure", ["archiveCompleted": seconds]) }
    /// Whether agents may use their CLI's own subagents (Claude's Agent tool, Codex's multi-agent tools); unset, off.
    public func subagents() async throws -> Bool {
        ((try await call("settings")) as? [String: Any])?["subagents"] as? Bool ?? false
    }
    public func setSubagents(_ on: Bool) async throws { _ = try await call("configure", ["subagents": on]) }
    #if os(macOS)
        /// The models the user added to Zero, for each CLI.
        public func customModels() async throws -> [CustomModels.Model] {
            let kept = ((try await call("settings")) as? [String: Any])?["models"] ?? []
            return try JSONDecoder().decode([CustomModels.Model].self, from: JSONSerialization.data(withJSONObject: kept))
        }
        public func setCustomModels(_ models: [CustomModels.Model]) async throws {
            let list = try JSONSerialization.jsonObject(with: JSONEncoder().encode(models))
            _ = try await call("configure", ["models": list])
        }
    #endif

    /// The sessions `session` started, without their items, each with how it's doing (which zerod tells, since the
    /// items it would be worked out from are left out).
    public func workers(of session: String) async throws -> [(Conversation, Attention)] {
        struct Summary: Decodable {
            let attention: Attention
            let conversation: Conversation
            init(from decoder: Decoder) throws {
                conversation = try Conversation(from: decoder)
                attention = try decoder.container(keyedBy: Key.self).decode(Attention.self, forKey: .attention)
            }
            enum Key: String, CodingKey { case attention }
        }
        return try decode([Summary].self, from: await call("workers", ["session": session])).map { ($0.conversation, $0.attention) }
    }

    /// What the session last gave as its answer.
    // Loops: named instructions an agent follows (zerod's loops.rs), named as @name in a message or a brief.

    public struct Loop: Decodable, Equatable, Sendable, Identifiable {
        public var id: String { name }
        public let name: String
        public let description: String
        public let body: String
        public let children: [String]
        public let uses: [Use]
        public struct Use: Decodable, Equatable, Sendable { public let session: String; public let role: String; public let at: Int }
    }

    private func loops(from result: Any) throws -> [Loop] {
        try JSONDecoder().decode([Loop].self, from: JSONSerialization.data(withJSONObject: result))
    }

    public func loops() async throws -> [Loop] { try loops(from: try await call("loops")) }

    /// Something saved for later (zerod's later.rs): a note in plain words and, when viewed, the artifact behind it.
    public struct LaterItem: Decodable, Equatable, Sendable, Identifiable {
        public let id: String
        public let note: String
        public let artifact: String?
        public let from: String?
        public let task: String?
        public let workspace: String?
        public let links: [String]
        public let files: [String]
        public let created: Int
        public let updated: Int
        public let done: Bool
        /// Saved by an agent without the user asking: shown apart until kept, gone after a week if not.
        public let suggested: Bool?
        public let version: Int
        public let versions: [Version]
        public let link: String
        /// A task saved whole, by its session: off the board until it's resumed from Later.
        public let resume: String?
        public struct Version: Decodable, Equatable, Sendable {
            public let version: Int; public let note: String; public let at: Int; public let by: String?
        }
        public var createdAt: Date { Date(timeIntervalSince1970: TimeInterval(created)) }
    }

    /// One of Later's tools (list, view, save, edit, delete); from a task, `session` says which.
    public func later(_ tool: String, _ args: [String: Any] = [:], session: String? = nil) async throws -> Any {
        try await call("later", ["tool": tool, "args": args, "session": session])
    }

    public func laterItems(_ query: String = "") async throws -> [LaterItem] {
        try JSONDecoder().decode([LaterItem].self, from: JSONSerialization.data(withJSONObject: try await later("list", ["query": query])))
    }

    public func laterItem(_ id: String, version: Int? = nil) async throws -> LaterItem {
        var args: [String: Any] = ["item": id]
        if let version { args["version"] = version }
        return try JSONDecoder().decode(LaterItem.self, from: JSONSerialization.data(withJSONObject: try await later("view", args)))
    }

    public func editLater(_ id: String, _ fields: [String: Any]) async throws {
        _ = try await later("edit", fields.merging(["item": id]) { $1 })
    }

    public func loop(_ name: String) async throws -> Loop {
        try loops(from: [try await call("loop", ["name": name])]).first!
    }

    public func saveLoop(_ name: String, description: String, body: String) async throws -> Loop {
        try loops(from: [try await call("saveLoop", ["name": name, "description": description, "body": body])]).first!
    }

    public func deleteLoop(_ name: String) async throws { _ = try await call("deleteLoop", ["name": name]) }

    public func result(of session: String) async throws -> String? {
        ((try await call("result", ["session": session])) as? [String: Any])?["answer"] as? String
    }

    /// Waits until the sessions (or, with `any`, one of them) stop working; each as id, label, ticket, attention, answer,
    /// error and stalled.
    public func wait(on sessions: [String], any: Bool = false, timeout: Int? = nil) async throws -> [[String: Any]] {
        try await call("wait", ["sessions": sessions, "any": any, "timeout": timeout]) as? [[String: Any]] ?? []
    }

    // Word from outside.

    /// Words for a session, given when it is between turns.
    /// The user saw a task's reply (its answer's item): zerod settles Replied for everyone.
    public func seen(session: String, answer: String? = nil) async throws {
        _ = try await call("seen", ["session": session, "answer": answer])
    }

    /// Words for a session between its turns, marked as Zero's, or as `from`'s (another task's).
    public func notify(session: String, text: String, from: String? = nil) async throws {
        _ = try await call("notify", ["session": session, "text": text, "from": from])
    }

    /// What a task's agent may do without asking, changed between turns: its next message starts it with them.
    public func setPermissions(session: String, _ permissions: Permissions) async throws {
        _ = try await call("setPermissions", ["session": session, "permissions": permissions.rawValue])
    }

    // Zero for Chrome (zerod's browser.rs).

    /// One browser tool for a session (nil: Zero's own tabs): its MCP content, text and images.
    public func browserCall(session: String?, tool: String, args: [String: Any]) async throws -> [[String: Any]] {
        let result = try await call("browserCall", ["session": session, "tool": tool, "args": args])
        return (result as? [String: Any])?["content"] as? [[String: Any]] ?? []
    }

    /// Puts the native host's manifest where Chrome reads it; the extension's folder, to load in Chrome.
    public func browserSetup() async throws -> (manifest: String, extension: String) {
        let result = try await call("browserSetup") as? [String: Any]
        return (result?["manifest"] as? String ?? "", result?["extension"] as? String ?? "")
    }

    /// The Chromes connected: id, name.
    public func browsers() async throws -> [(id: String, name: String)] {
        ((try await call("browsers")) as? [[String: Any]] ?? []).map { ($0["id"] as? String ?? "", $0["name"] as? String ?? "") }
    }

    /// While zerod restarts: what it's waiting for, each turn's task and the command it's letting finish.
    public struct RestartStatus: Decodable, Sendable, Equatable {
        public struct Waiting: Decodable, Sendable, Equatable, Identifiable {
            public let session: String; public let task: String; public let command: String; public var id: String { session }
        }
        public let restarting: Bool
        public let waiting: [Waiting]
        /// The longest a command is waited for, in seconds.
        public let most: Int
    }

    public func restartStatus() async throws -> RestartStatus {
        let result = try await call("restartStatus")
        return try JSONDecoder().decode(RestartStatus.self, from: JSONSerialization.data(withJSONObject: result ?? [:]))
    }

    /// Safari's automation session started, as browser_compare starts it: whether Safari takes remote control.
    public func checkSafari() async throws { _ = try await call("checkSafari") }

    /// Firefox Developer Edition opened under Zero's remote control, its extension installed.
    public func openFirefox() async throws { _ = try await call("openFirefox") }

    public func browserSettings() async throws -> [String] {
        ((try await call("browserSettings")) as? [String: Any])?["blocked"] as? [String] ?? []
    }
    public func saveBrowserSettings(blocked: [String]) async throws {
        _ = try await call("saveBrowserSettings", ["browser": ["blocked": blocked]])
    }

    // Workspaces: the user's work split by who it's for (zerod's workspaces.rs). "zero" is always there.

    public struct Workspace: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        /// A Nucleo icon's name, or an emoji.
        public var glyph: String
        public init(id: String = "", name: String, glyph: String = "") { self.id = id; self.name = name; self.glyph = glyph }
    }

    public func workspaces() async throws -> [Workspace] { try decode([Workspace].self, from: await call("workspaces")) }

    /// One of the CLIs' sign-ins Zero keeps (zerod's signins.rs): what it is, never its value (that's in the
    /// Keychain, under `signInKeychain` by its id, or in a Codex account's own home).
    public struct SignIn: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var cli: Provider
        public var kind: Kind
        /// The account's email, or the name given to a key.
        public var label: String
        public var plan: String?
        /// An OpenCode provider's key: the variable OpenCode reads it from.
        public var variable: String?
        /// Still being signed in (a Codex account waiting on the browser).
        public var pending: Bool?
        public enum Kind: String, Codable, Sendable { case token, apiKey, codexHome, claudeHome }
        public init(cli: Provider, kind: Kind, label: String, variable: String? = nil) {
            id = ""; self.cli = cli; self.kind = kind; self.label = label; self.variable = variable
        }
    }
    public static let signInKeychain = "Zero sign-ins"

    public func signIns() async throws -> (list: [SignIn], defaults: [String: String], usage: [String: Usage], refused: [String: [String]])
    {
        struct Listed: Decodable {
            let signins: [SignIn]; let defaults: [String: String]; let usage: [String: Usage]?; let refused: [String: [String]]?
        }
        let listed = try decode(Listed.self, from: await call("signIns"))
        return (listed.signins, listed.defaults, listed.usage ?? [:], listed.refused ?? [:])
    }
    public func saveSignIn(_ signin: SignIn) async throws -> SignIn {
        let data = try JSONEncoder().encode(signin)
        return try decode(SignIn.self, from: await call("saveSignIn", ["signin": try JSONSerialization.jsonObject(with: data)]))
    }
    public func deleteSignIn(_ id: String) async throws { _ = try await call("deleteSignIn", ["signin": id]) }
    /// Each account's finished turns by the hour they ended in (Unix hours), by its id.
    public func accountActivity() async throws -> [String: [Int: Int]] {
        let raw = try decode([String: [String: Int]].self, from: await call("accountActivity"))
        return raw.mapValues { hours in Dictionary(uniqueKeysWithValues: hours.compactMap { key, count in Int(key).map { ($0, count) } }) }
    }
    /// Each account's usage asked of its CLI now; the sign-ins notice says when it's in.
    public func readUsage() async throws { _ = try await call("readUsage") }
    /// Codex signs an account in itself, in a home of its own: its ChatGPT page to open (none for an API key).
    public func codexSignIn(label: String?, apiKey: String?) async throws -> (id: String, page: URL?) {
        let result = try await call("codexSignIn", ["signin": ["label": label as Any, "apiKey": apiKey as Any]]) as? [String: Any]
        return (result?["id"] as? String ?? "", (result?["page"] as? String).flatMap(URL.init(string:)))
    }

    /// An MCP server set up in Zero (zerod's mcp_servers.rs): every task's CLI in its workspaces is given it as it starts.
    public struct McpServer: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var command: String?
        public var args: [String]
        public var url: String?
        public var env: [Value]
        public var headers: [Value]
        /// The workspaces it's for; none, every workspace.
        public var workspaces: [String]
        public var enabled: Bool

        public struct Value: Codable, Equatable, Sendable {
            public var name: String
            /// Kept in Zero's file only when that's where it comes from.
            public var value: String?
            public var from: Source
            public init(name: String = "", value: String? = nil, from: Source = .keychain) {
                self.name = name; self.value = value; self.from = from
            }
        }

        public enum Source: String, Codable, Sendable, CaseIterable { case keychain, command, file }

        public init(
            id: String = "", name: String = "", command: String? = nil, args: [String] = [], url: String? = nil, env: [Value] = [],
            headers: [Value] = [],
            workspaces: [String] = [], enabled: Bool = true
        ) {
            self.id = id; self.name = name; self.command = command; self.args = args; self.url = url; self.env = env; self.headers = headers
            self.workspaces = workspaces; self.enabled = enabled
        }

        /// The Keychain's service for its values; each value's account is "<id>.<name>" (as zerod reads them).
        public static let keychain = "Zero MCP"
    }

    public func mcpServers() async throws -> [McpServer] { try decode([McpServer].self, from: await call("mcpServers")) }
    public func saveMcpServer(_ server: McpServer) async throws -> McpServer {
        let data = try JSONEncoder().encode(server)
        return try decode(McpServer.self, from: await call("saveMcpServer", ["server": try JSONSerialization.jsonObject(with: data)]))
    }
    public func deleteMcpServer(_ id: String) async throws { _ = try await call("deleteMcpServer", ["server": id]) }

    public func saveWorkspace(_ workspace: Workspace) async throws -> Workspace {
        let fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace))
        return try decode(Workspace.self, from: await call("saveWorkspace", ["workspace": fields]))
    }

    public func deleteWorkspace(_ id: String) async throws { _ = try await call("deleteWorkspace", ["workspace": id]) }

    /// Puts a session in a workspace; nil puts it back in its folder's.
    public func placeInWorkspace(session: String, workspace: String?) async throws {
        _ = try await call("placeInWorkspace", ["session": session, "workspace": workspace])
    }

    // Following: what sessions hear of between their turns.

    public struct Followed: Decodable, Equatable, Sendable, Identifiable {
        public var id: String { session + " " + topic }
        public let session: String
        public let topic: String
        public var mine: Bool = false
        public var about: [String] = []
        /// When the follow was made, seconds since 1970.
        public let at: Int
        /// The followed thing in a line: a pull request's title and state, an issue's identifier and status.
        public let summary: String
        /// Why polling it fails, while it does.
        public var error: String?
        public let lastPoll: Int
        public var new: Bool = false
        public var detail: String = ""
        /// The integration it is read through: "github", "linear" or "slack".
        public var source: String { String(topic.prefix { $0 != "/" }) }
    }

    public func follow(session: String, topic: String, mine: Bool, about: [String]) async throws -> Followed {
        try decode(Followed.self, from: await call("follow", ["session": session, "topic": topic, "mine": mine, "about": about]))
    }

    /// How many follows went: those named, or with nil all of the session's.
    public func unfollow(session: String, topics: [String]?) async throws -> Int {
        let reply = try await call("unfollow", topics.map { ["session": session, "topics": $0] } ?? ["session": session, "all": true])
        return (reply as? [String: Any])?["removed"] as? Int ?? 0
    }

    public func following(session: String? = nil) async throws -> [Followed] {
        try decode([Followed].self, from: await call("following", session.map { ["session": $0] } ?? [:]))
    }

    /// Runs `command` in the session's folder and tells the session how it ended.
    public func watch(session: String, command: String) async throws {
        _ = try await call("watch", ["session": session, "command": command])
    }

    /// A file watched for the session (zerod's watches.rs): its id.
    public func watchFile(session: String, file: String, alerts: [String], done: String?, quiet: Int?) async throws -> String {
        let result =
            try await call(
                "watchFile", ["session": session, "watch": ["file": file, "alerts": alerts, "done": done as Any, "quiet": quiet as Any]])
            as? [String: Any]
        return result?["watch"] as? String ?? ""
    }
    public func watches(session: String?) async throws -> [[String: Any]] {
        try await call("watches", ["session": session]) as? [[String: Any]] ?? []
    }
    public func unwatch(_ id: String) async throws { _ = try await call("unwatch", ["watch": id]) }

    /// Wakes `session` at `at` with `text` (zerod's schedules.rs): the schedule, as zerod keeps it.
    public func schedule(session: String, at: Date, text: String) async throws -> [String: Any] {
        try await call("schedule", ["session": session, "at": Int(at.timeIntervalSince1970), "text": text]) as? [String: Any] ?? [:]
    }
    public func schedules(session: String?) async throws -> [[String: Any]] {
        try await call("schedules", ["session": session]) as? [[String: Any]] ?? []
    }
    public func unschedule(_ id: String) async throws { _ = try await call("unschedule", ["item": id]) }

    public func remind(session: String, minutes: Int, text: String) async throws {
        _ = try await call("remind", ["session": session, "minutes": minutes, "text": text])
    }

    /// Each provider's limits as its CLI last reported them.
    public func usage() async throws -> [(Provider, Usage)] {
        struct Row: Decodable { let provider: Provider; let usage: Usage }
        return try decode([Row].self, from: await call("usage")).map { ($0.provider, $0.usage) }
    }

    public func board() async throws -> [BoardRow] { try decode([BoardRow].self, from: await call("board")) }

    /// Older items of a session: the page before `before`, or all of them from `from` up to it.
    public func items(session: String, before: String?, from: String? = nil, limit: Int = 60) async throws -> [ConversationItem] {
        try decode(
            [ConversationItem].self, from: await call("items", ["session": session, "before": before, "from": from, "limit": limit]))
    }
    /// A page anywhere in a session: from a message, after one, or the latest; with how many items lie either side.
    public func window(session: String, from: String? = nil, after: String? = nil, limit: Int = 60) async throws -> (
        items: [ConversationItem], earlier: Int, later: Int
    ) {
        struct Window: Decodable { let items: [ConversationItem]; let earlier: Int; let later: Int }
        let page = try decode(Window.self, from: await call("window", ["session": session, "from": from, "after": after, "limit": limit]))
        return (page.items, page.earlier, page.later)
    }
    public func outline(session: String) async throws -> [OutlineMark] {
        try decode([OutlineMark].self, from: await call("outline", ["session": session]))
    }

    // Scratchpads: one op, `pad`, taking the same tools and arguments as the MCP server.
    public func pad<T: Decodable>(_ tool: String, _ args: [String: Any], as type: T.Type) async throws -> T {
        try decode(T.self, from: await call("pad", ["tool": tool, "args": args]))
    }

    // Integrations.
    public func integrations() async throws -> IntegrationState { try decode(IntegrationState.self, from: await call("integrations")) }
    public func setIntegration(_ integration: String, enabled: Bool) async throws -> IntegrationState {
        try decode(IntegrationState.self, from: await call("setIntegration", ["integration": integration, "enabled": enabled]))
    }
    public func saveView(_ integration: String, view: some Encodable) async throws -> IntegrationState {
        let fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(view))
        return try decode(IntegrationState.self, from: await call("saveView", ["integration": integration, "view": fields]))
    }
    public func orderViews(_ integration: String, ids: [String]) async throws -> IntegrationState {
        try decode(IntegrationState.self, from: await call("orderViews", ["integration": integration, "ids": ids]))
    }
    public func deleteView(_ integration: String, view: String) async throws -> IntegrationState {
        try decode(IntegrationState.self, from: await call("deleteView", ["integration": integration, "view": view]))
    }
    public func viewItems(_ integration: String, view: String) async throws -> [IntegrationItem] {
        try decode([IntegrationItem].self, from: await call("viewItems", ["integration": integration, "view": view]))
    }
    /// What the view last showed, however long ago; nil before it has been fetched.
    public func cachedItems(_ integration: String, view: String) async throws -> [IntegrationItem]? {
        try decode([IntegrationItem]?.self, from: await call("viewItems", ["integration": integration, "view": view, "cached": true]))
    }
    public func linearTeams(cached: Bool = false) async throws -> [LinearTeam]? {
        try decode([LinearTeam]?.self, from: await call("linearTeams", ["cached": cached]))
    }
    /// The item's task: the one it has, or a new one from its view's template.
    public func startTask(_ integration: String, view: String, item: IntegrationItem) async throws -> StartedTask {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item))
        return try decode(StartedTask.self, from: await call("startTask", ["integration": integration, "view": view, "item": object]))
    }
    /// The page to open in the browser; zerod waits for Linear to come back.
    public func connectLinear() async throws -> URL {
        guard let url = ((try await call("connectLinear")) as? [String: Any])?["url"] as? String, let link = URL(string: url) else {
            throw ZerodError(message: "zerod gave no Linear page")
        }
        return link
    }
    public func disconnectLinear() async throws -> IntegrationState {
        try decode(IntegrationState.self, from: await call("disconnectLinear"))
    }
    public func connectSlack(token: String) async throws -> IntegrationState {
        try decode(IntegrationState.self, from: await call("connectSlack", ["token": token]))
    }
    public func disconnectSlack(team: String) async throws -> IntegrationState {
        try decode(IntegrationState.self, from: await call("disconnectSlack", ["team": team]))
    }
    /// Slack's channels again: new ones get ids too.
    public func refreshSlack() async throws -> IntegrationState { try decode(IntegrationState.self, from: await call("refreshSlack")) }

    /// From now on `onMessage` gets every session's snapshot, then each change.
    public func subscribe() async throws { _ = try await call("subscribe") }

    /// Changes as they come, but no snapshots up front (a phone, on a slow link): a session's comes once it changes,
    /// or with `recent` when it's opened.
    public func subscribeLazily() async throws { _ = try await call("subscribe", ["lazy": true]) }

    /// A session's latest items, and how many came before them.
    public func recent(session: String) async throws -> (Conversation, Int) {
        let result = try await call("recent", ["session": session]) as? [String: Any] ?? [:]
        let conversation = try decode(Conversation.self, from: result["conversation"] ?? [:])
        return (conversation, result["earlier"] as? Int ?? 0)
    }

    // The inbox.

    /// From now on `onInbox` gets every ask, then each change.
    public func followInbox() async throws { _ = try await call("inbox") }

    /// `keep` keeps the ask's own id unless it is taken.
    public func create(_ ask: Ask, keep: Bool = false) async throws -> Ask {
        let object = try JSONSerialization.jsonObject(with: jsonEncoder.encode(ask))
        let made = try await call("create", ["ask": object, "keep": keep])
        return try jsonDecoder.decode(Ask.self, from: JSONSerialization.data(withJSONObject: made))
    }

    public func choose(_ ask: String, option: Int) async throws { _ = try await call("choose", ["ask": ask, "option": option]) }
    /// A text option with its text.
    public func answer(_ ask: String, option: Int, text: String) async throws {
        _ = try await call("answerAsk", ["ask": ask, "option": option, "text": text])
    }
    public func reply(_ ask: String, text: String) async throws { _ = try await call("reply", ["ask": ask, "text": text]) }
    public func takeBack(_ ask: String) async throws -> Bool { try await call("takeBack", ["ask": ask]) as? Bool ?? false }
    public func withdraw(_ ask: String, reason: String?) async throws { _ = try await call("withdraw", ["ask": ask, "text": reason]) }
    public func dismiss(_ ask: String) async throws { _ = try await call("dismiss", ["ask": ask]) }
    public func cancelRun(_ ask: String) async throws { _ = try await call("cancelRun", ["ask": ask]) }
    /// Delivers an answer again, to an agent that asked with --async.
    public func deliver(_ ask: String) async throws { _ = try await call("deliver", ["ask": ask]) }
    public func message(_ text: String, to agent: String) async throws { _ = try await call("message", ["agent": agent, "text": text]) }
    public func close(agent: String, stop: Bool) async throws { _ = try await call("close", ["agent": agent, "stop": stop]) }
    public func screen(of agent: String) async throws -> String? { try await call("screen", ["agent": agent]) as? String }
    /// Keys into the agent's terminal; the screen just after.
    public func press(_ keys: [UInt8], on agent: String) async throws -> String? {
        try await call("press", ["agent": agent, "keys": keys.map(Int.init)]) as? String
    }
    public func switchModel(of agent: String, model: String?, effort: String?) async throws {
        _ = try await call("switchModel", ["agent": agent, "model": model, "effort": effort])
    }
    /// The inbox's settings: the take-back window and default expiry in seconds, and the drop folders' patterns.
    public func configure(takeBack: Double, ttl: Int, patterns: [String]) async throws {
        _ = try await call("configure", ["takeBack": takeBack, "ttl": ttl, "patterns": patterns])
    }

    /// One request; nil fields are left out.
    public func call(_ op: String, _ fields: [String: Any?] = [:]) async throws -> Any {
        try await withCheckedThrowingContinuation { (answer: CheckedContinuation<Any, Error>) in
            let id: Int? = lock.withLock {
                guard !closed else { return nil }
                next += 1
                waiting[next] = answer
                return next
            }
            guard let id else { return answer.resume(throwing: ZerodError(message: "Not connected to zerod")) }
            var body = fields.compactMapValues { $0 }
            body["op"] = op
            body["id"] = id
            do {
                let line = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
                try writing.withLock { try connection.write(line: line) }
            } catch {
                lock.withLock { waiting.removeValue(forKey: id) }?.resume(
                    throwing: ZerodError(message: "Couldn't write to zerod: \(error)"))
            }
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from result: Any) throws -> T {
        try JSONDecoder().decode(T.self, from: try JSONSerialization.data(withJSONObject: result, options: .fragmentsAllowed))
    }

    private struct Snapshot: Decodable { let conversation: Conversation; let earlier: Int? }
    private struct BoardFeed: Decodable { let rows: [BoardRow] }
    private struct Asks: Decodable { let asks: [Ask]; let offline: Set<String>; let reachable: Set<String> }
    private struct OneAsk: Decodable { let ask: Ask }
    private struct Output: Decodable { let ask: String; let chunk: String }
    private struct Removed: Decodable { let ask: String }
    private struct Agents: Decodable { let offline: Set<String>; let reachable: Set<String> }

    private static func inbox(_ event: String, _ data: Data) -> InboxMessage? {
        switch event {
        case "asks": (try? jsonDecoder.decode(Asks.self, from: data)).map { .asks($0.asks, offline: $0.offline, reachable: $0.reachable) }
        case "ask": (try? jsonDecoder.decode(OneAsk.self, from: data)).map { .ask($0.ask) }
        case "output": (try? jsonDecoder.decode(Output.self, from: data)).map { .output(id: $0.ask, chunk: $0.chunk) }
        case "removed": (try? jsonDecoder.decode(Removed.self, from: data)).map { .removed($0.ask) }
        case "agents": (try? jsonDecoder.decode(Agents.self, from: data)).map { .agents(offline: $0.offline, reachable: $0.reachable) }
        default: nil
        }
    }

    private struct EventName: Decodable { let event: String? }
    private struct Cleared: Decodable { let ids: [String]? }

    private func read() {
        while let line = connection.readLine() {
            let data = Data(line.utf8)
            // An event's name read with the decoder, not the whole line made into Foundation objects first and then
            // decoded again (a snapshot of every session: 29 ms of the one, then 91 ms of the other).
            if let event = (try? JSONDecoder().decode(EventName.self, from: data))?.event {
                if event == "board" {
                    if let rows = try? JSONDecoder().decode(BoardFeed.self, from: data).rows { onFeed?(.board(rows)) }
                    continue
                }
                if event == "pads" { onFeed?(.pads); continue }
                if event == "loops" { onFeed?(.loops); continue }
                if event == "later" { onFeed?(.later); continue }
                if event == "following" { onFeed?(.following); continue }
                if event == "workspaces" { onFeed?(.workspaces); continue }
                if event == "signins" { onFeed?(.signins); continue }
                if event == "restarting" { onFeed?(.restarting); continue }
                if event == "clear" { onFeed?(.clear((try? JSONDecoder().decode(Cleared.self, from: data))?.ids ?? [])); continue }
                let decoded: ZerodMirror.Message? =
                    switch event {
                    case "session":
                        (try? JSONDecoder().decode(Snapshot.self, from: data)).map { snapshot in
                            onMessage?(.earlier(session: snapshot.conversation.id, count: snapshot.earlier ?? 0))
                            return .session(snapshot.conversation)
                        }
                    case "change": (try? JSONDecoder().decode(ZerodEvent.self, from: data)).map { .change($0) }
                    default: nil
                    }
                if let decoded { onMessage?(decoded) } else if let inbox = Self.inbox(event, data) { onInbox?(inbox) }
                continue
            }
            guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let id = message["id"] as? Int, let answer = lock.withLock({ waiting.removeValue(forKey: id) })
            else { continue }
            if message["ok"] as? Bool == true {
                answer.resume(returning: message["result"] ?? NSNull())
            } else {
                answer.resume(throwing: ZerodError(message: message["error"] as? String ?? "zerod refused the request"))
            }
        }
        let pending = lock.withLock {
            closed = true
            defer { waiting.removeAll() }
            return Array(waiting.values)
        }
        for answer in pending { answer.resume(throwing: ZerodError(message: "zerod closed the connection")) }
        connection.close()
        onClose?()
    }

    // Starting the daemon.

    /// zerod next to this program (Zero.app's MacOS folder, or the build folder), else the installed app's.
    public static var executable: String {
        let sibling = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
            .appendingPathComponent("zerod").path
        return FileManager.default.isExecutableFile(atPath: sibling) ? sibling : "/Applications/Zero.app/Contents/MacOS/zerod"
    }

    /// The installed daemon, started if it isn't running.
    public static func ensureRunning() async -> Bool { await launch(binary: executable, home: home, socket: socket) }

    /// Starts `binary` on `socket` unless a daemon already answers there, and waits up to three seconds for it.
    /// zerod leaves the app's session at start (setsid), so it keeps running when the app quits.
    public static func launch(binary: String, home: String, socket: String) async -> Bool {
        if answers(socket) { return true }
        #if os(macOS)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["--home", home, "--socket", socket]
            let log = URL(fileURLWithPath: socket).deletingLastPathComponent().appendingPathComponent("zerod.log")
            try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
            let output = try? FileHandle(forWritingTo: log)
            _ = try? output?.seekToEnd()
            process.standardOutput = output
            process.standardError = output
            guard (try? process.run()) != nil else { return false }
            for _ in 0..<30 {
                try? await Task.sleep(for: .milliseconds(100))
                if answers(socket) { return true }
            }
        #endif
        return false
    }

    private static func answers(_ socket: String) -> Bool {
        guard let connection = try? UnixSocket.connect(path: socket) else { return false }
        connection.close()
        return true
    }
}

/// How the folder differs from when a message went: what restoring its code would undo. No snapshot outside git, or
/// for messages sent before Zero kept them.
public struct RewindPreview: Decodable, Equatable, Sendable {
    public let snapshot: Bool
    public let files: Int?
    public let insertions: Int?
    public let deletions: Int?
}

/// A message gone back to: its words and images, to send again or change; and, branched, the new task's id.
public struct Rewound: Decodable, Sendable {
    public let text: String
    public let images: [String]
    public let session: String?
}

/// The identity agents' Git commits and signs as (zerod git.rs): the user stays the author; this commits and signs.
public struct AgentGit: Codable, Equatable, Sendable {
    public var enabled = false
    /// The GitHub account that commits and signs; its name and noreply email are GitHub's.
    public var login = ""
    public var name = ""
    public var email = ""
    /// GitHub over HTTPS with the GitHub CLI's sign-in, not SSH.
    public var https = true
    /// Only agents in these folders; none, every folder.
    public var folders: [String] = []
    public init() {}
}
