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
/// sandbox) and brings Arsen the rest; unrestricted lets it do anything without asking.
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

    public enum Kind: Equatable, Sendable {
        case user(text: String)
        case agent(text: String, finalAnswer: Bool)
        case reasoning(text: String)
        case plan(text: String)
        case command(command: String, cwd: String, output: String, exitCode: Int?, durationMs: Int?)
        case fileChange([FileChange])
        case tool(name: String, detail: String)
        case notice(text: String, error: Bool)
    }

    public init(id: String, turn: String?, kind: Kind, status: ItemStatus) {
        self.id = id; self.turn = turn; self.kind = kind; self.status = status
    }
}

extension ConversationItem.Kind: Decodable {
    private enum Keys: String, CodingKey { case type, text, finalAnswer, command, cwd, output, exitCode, durationMs, changes, name, detail, error }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let text = { try c.decode(String.self, forKey: .text) }
        switch try c.decode(String.self, forKey: .type) {
        case "user": self = .user(text: try text())
        case "agent": self = .agent(text: try text(), finalAnswer: try c.decode(Bool.self, forKey: .finalAnswer))
        case "reasoning": self = .reasoning(text: try text())
        case "plan": self = .plan(text: try text())
        case "command":
            self = .command(command: try c.decode(String.self, forKey: .command), cwd: try c.decode(String.self, forKey: .cwd),
                            output: try c.decode(String.self, forKey: .output), exitCode: try c.decodeIfPresent(Int.self, forKey: .exitCode),
                            durationMs: try c.decodeIfPresent(Int.self, forKey: .durationMs))
        case "fileChange": self = .fileChange(try c.decode([FileChange].self, forKey: .changes))
        case "tool": self = .tool(name: try c.decode(String.self, forKey: .name), detail: try c.decode(String.self, forKey: .detail))
        case "notice": self = .notice(text: try text(), error: try c.decode(Bool.self, forKey: .error))
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

    public init(id: String, item: String?, kind: ApprovalKind, title: String, command: String?, cwd: String?, reason: String?,
                changes: [FileChange], choices: [Choice]) {
        self.id = id; self.item = item; self.kind = kind; self.title = title; self.command = command; self.cwd = cwd
        self.reason = reason; self.changes = changes; self.choices = choices
    }
}

/// The agent asking Arsen something: one or more fields answered together.
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
    /// Arsen's own words are taken too.
    public var other: Bool
    /// Shown as dots, and never kept in Zero's log.
    public var secret: Bool
    public init(id: String, header: String?, question: String, options: [QuestionOption], multiple: Bool, other: Bool, secret: Bool) {
        self.id = id; self.header = header; self.question = question; self.options = options; self.multiple = multiple; self.other = other; self.secret = secret
    }
}

public struct QuestionOption: Decodable, Equatable, Sendable {
    public var label: String
    public var description: String?
    public init(label: String, description: String?) { self.label = label; self.description = description }
}

/// One row of the board (crates/zerod/src/board.rs): a lead session with its workers folded in.
public struct BoardRow: Decodable, Equatable, Sendable, Identifiable {
    public enum State: String, Decodable, Sendable { case needsYou, trouble, working, waiting, ready, done, idle, offline }
    public var session: String
    public var task: String
    public var ticket: String?
    /// The shortest end of its folder that tells it from the other rows'.
    public var place: String
    public var state: State
    public var now: String?
    public var needs: String?
    /// The open asks of the lead and its workers.
    public var asks: [Waiting]
    public var workers: Int
    public var id: String { session }
    public struct Waiting: Decodable, Equatable, Sendable { public var id: String; public var title: String }
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

/// What a session needs from Arsen, most urgent first: the bar's dot (zerod's `Conversation::attention`).
public enum Attention: String, Decodable, Sendable { case needsYou, limited, stuck, failed, working, done, idle, offline, starting }

public struct Conversation: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var provider: Provider
    public var cwd: String
    public var permissions: Permissions
    /// A name the user or its lead gave it, and what the work is for (an issue, a ticket).
    public var label: String?
    public var ticket: String?
    /// The git branch its folder was on when it started.
    public var branch: String?
    /// The session that started it, for a worker.
    public var parent: String?
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
    /// How many changes have been applied; the next change zerod sends for this session is `seq + 1`.
    public var seq: UInt64

    public init(id: String, provider: Provider, cwd: String) {
        self.id = id; self.provider = provider; self.cwd = cwd; permissions = .auto; status = .starting; items = []; approvals = []; questions = []; seq = 0
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
            if case .agent(_, true)? = items.last?.kind { return .done }
            return .idle
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
        case let .status(status, turn, error):
            self.status = status; self.turn = turn; self.error = error
        case let .item(item):
            if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item } else { items.append(item) }
        case let .delta(id, text):
            guard let i = items.firstIndex(where: { $0.id == id }) else { return }
            switch items[i].kind {
            case let .user(body): items[i].kind = .user(text: body + text)
            case let .agent(body, final): items[i].kind = .agent(text: body + text, finalAnswer: final)
            case let .reasoning(body): items[i].kind = .reasoning(text: body + text)
            case let .plan(body): items[i].kind = .plan(text: body + text)
            case let .notice(body, error): items[i].kind = .notice(text: body + text, error: error)
            case let .command(command, cwd, output, exitCode, durationMs):
                items[i].kind = .command(command: command, cwd: cwd, output: output + text, exitCode: exitCode, durationMs: durationMs)
            case .fileChange, .tool: break
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
        }
    }
}

public enum Change: Decodable, Equatable, Sendable {
    case thread(String, model: String?, effort: String?)
    case title(String?)
    case named(label: String?, ticket: String?)
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

    private enum Keys: String, CodingKey { case type, thread, model, effort, title, status, turn, error, item, text, approval, diff, question, usage, failure, reason, label, ticket }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "thread": self = .thread(try c.decode(String.self, forKey: .thread), model: try c.decodeIfPresent(String.self, forKey: .model),
                                      effort: try c.decodeIfPresent(String.self, forKey: .effort))
        case "title": self = .title(try c.decodeIfPresent(String.self, forKey: .title))
        case "named": self = .named(label: try c.decodeIfPresent(String.self, forKey: .label), ticket: try c.decodeIfPresent(String.self, forKey: .ticket))
        case "status": self = .status(try c.decode(SessionStatus.self, forKey: .status), turn: try c.decodeIfPresent(String.self, forKey: .turn),
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
        case let other: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown change \(other)")
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
    }

    public private(set) var conversations: [String: Conversation] = [:]
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
            return true
        case let .change(event):
            guard var conversation = conversations[event.session] else { return false }
            if event.seq <= conversation.seq { return true }
            guard event.seq == conversation.seq + 1 else { return false }
            conversation.apply(event.change)
            conversations[event.session] = conversation
            return true
        }
    }
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

    private let connection: UnixSocket
    private let lock = NSLock()
    private let writing = NSLock()
    private var next = 0
    private var waiting: [Int: CheckedContinuation<Any, Error>] = [:]
    private var closed = false
    private var messageHandler: (@Sendable (ZerodMirror.Message) -> Void)?
    private var inboxHandler: (@Sendable (InboxMessage) -> Void)?
    private var closeHandler: (@Sendable () -> Void)?

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

    public func close() { connection.shutdown() }

    // The daemon's requests (crates/zerod/src/server.rs).

    public func hello() async throws -> Int {
        try ((await call("hello")) as? [String: Any])?["version"] as? Int ?? 0
    }

    /// Every session, without its items.
    public func list() async throws -> [Conversation] { try decode([Conversation].self, from: await call("list")) }

    public func get(_ session: String) async throws -> Conversation { try decode(Conversation.self, from: await call("get", ["session": session])) }

    /// Starts a session and returns its id at once, while the provider starts.
    public func start(provider: Provider, cwd: String, prompt: String, model: String? = nil, effort: String? = nil,
                      permissions: Permissions = .auto) async throws -> String {
        let result = try await call("start", ["provider": provider.rawValue, "cwd": cwd, "prompt": prompt, "model": model, "effort": effort,
                                              "permissions": permissions.rawValue])
        guard let session = (result as? [String: Any])?["session"] as? String else { throw ZerodError(message: "zerod started no session") }
        return session
    }

    public func send(session: String, text: String, model: String? = nil, effort: String? = nil) async throws {
        _ = try await call("send", ["session": session, "text": text, "model": model, "effort": effort])
    }

    public func interrupt(session: String) async throws { _ = try await call("interrupt", ["session": session]) }
    public func stop(session: String) async throws { _ = try await call("stop", ["session": session]) }
    public func resume(session: String) async throws { _ = try await call("resume", ["session": session]) }

    public func decide(session: String, approval: String, choice: String) async throws {
        _ = try await call("decide", ["session": session, "approval": approval, "choice": choice])
    }

    /// Answers an open question, every field at once: picked options, or Arsen's own words.
    public func answer(session: String, question: String, answers: [String: [String]]) async throws {
        _ = try await call("answer", ["session": session, "question": question, "answers": answers])
    }

    // Leads and workers.

    /// Starts a worker of `lead`, in its folder and with its permissions unless given others.
    public func spawn(lead: String, provider: Provider?, prompt: String, cwd: String? = nil, model: String? = nil, effort: String? = nil,
                      permissions: Permissions? = nil, label: String? = nil, ticket: String? = nil) async throws -> String {
        let result = try await call("spawn", ["session": lead, "provider": provider?.rawValue, "prompt": prompt, "cwd": cwd, "model": model,
                                              "effort": effort, "permissions": permissions?.rawValue, "label": label, "ticket": ticket])
        guard let session = (result as? [String: Any])?["session"] as? String else { throw ZerodError(message: "zerod started no session") }
        return session
    }

    public func label(session: String, label: String?, ticket: String?) async throws {
        _ = try await call("label", ["session": session, "label": label, "ticket": ticket])
    }

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
    public func notify(session: String, text: String) async throws { _ = try await call("notify", ["session": session, "text": text]) }

    /// Runs `command` in the session's folder and tells the session how it ended.
    public func watch(session: String, command: String) async throws { _ = try await call("watch", ["session": session, "command": command]) }

    public func remind(session: String, minutes: Int, text: String) async throws {
        _ = try await call("remind", ["session": session, "minutes": minutes, "text": text])
    }

    /// Each provider's limits as its CLI last reported them.
    public func usage() async throws -> [(Provider, Usage)] {
        struct Row: Decodable { let provider: Provider; let usage: Usage }
        return try decode([Row].self, from: await call("usage")).map { ($0.provider, $0.usage) }
    }

    public func board() async throws -> [BoardRow] { try decode([BoardRow].self, from: await call("board")) }

    /// From now on `onMessage` gets every session's snapshot, then each change.
    public func subscribe() async throws { _ = try await call("subscribe") }

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
    public func answer(_ ask: String, option: Int, text: String) async throws { _ = try await call("answerAsk", ["ask": ask, "option": option, "text": text]) }
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
    public func press(_ keys: [UInt8], on agent: String) async throws -> String? { try await call("press", ["agent": agent, "keys": keys.map(Int.init)]) as? String }
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
                lock.withLock { waiting.removeValue(forKey: id) }?.resume(throwing: ZerodError(message: "Couldn't write to zerod: \(error)"))
            }
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from result: Any) throws -> T {
        try JSONDecoder().decode(T.self, from: try JSONSerialization.data(withJSONObject: result, options: .fragmentsAllowed))
    }

    private struct Snapshot: Decodable { let conversation: Conversation }
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

    private func read() {
        while let line = connection.readLine() {
            let data = Data(line.utf8)
            guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let event = message["event"] as? String {
                let decoded: ZerodMirror.Message? = switch event {
                case "session": (try? JSONDecoder().decode(Snapshot.self, from: data)).map { .session($0.conversation) }
                case "change": (try? JSONDecoder().decode(ZerodEvent.self, from: data)).map { .change($0) }
                default: nil
                }
                if let decoded { onMessage?(decoded) } else if let inbox = Self.inbox(event, data) { onInbox?(inbox) }
                continue
            }
            guard let id = message["id"] as? Int, let answer = lock.withLock({ waiting.removeValue(forKey: id) }) else { continue }
            if message["ok"] as? Bool == true { answer.resume(returning: message["result"] ?? NSNull()) }
            else { answer.resume(throwing: ZerodError(message: message["error"] as? String ?? "zerod refused the request")) }
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
        let sibling = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("zerod").path
        return FileManager.default.isExecutableFile(atPath: sibling) ? sibling : "/Applications/Zero.app/Contents/MacOS/zerod"
    }

    /// The installed daemon, started if it isn't running.
    public static func ensureRunning() async -> Bool { await launch(binary: executable, home: home, socket: socket) }

    /// Starts `binary` on `socket` unless a daemon already answers there, and waits up to three seconds for it.
    /// zerod leaves the app's session at start (setsid), so it keeps running when the app quits.
    public static func launch(binary: String, home: String, socket: String) async -> Bool {
        if answers(socket) { return true }
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
        return false
    }

    private static func answers(_ socket: String) -> Bool {
        guard let connection = try? UnixSocket.connect(path: socket) else { return false }
        connection.close()
        return true
    }
}
