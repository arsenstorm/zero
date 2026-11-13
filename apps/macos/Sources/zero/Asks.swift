import Foundation
import ZeroCore

/// A question or a request is the headline of its card; the reasoning behind it belongs in --body.
func shortHeadline(_ text: String) {
    guard text.count > 140 else { return }
    fail(
        "zero: keep the question to one short line (about 12 words, ending in ?) and put the details in --body; this one is \(text.count) characters"
    )
}

/// The text under a question is two or three plain sentences; anything longer goes in a file the agent links.
func shortDetail(_ text: String?, flag name: String) {
    guard let text, text.count > 280 else { return }
    fail(
        "zero: keep --\(name) to two or three plain sentences (280 characters; this is \(text.count)): the problem, what you recommend and why. Put anything longer in a file and give its path"
    )
}

@MainActor func agentIdentity() -> AgentIdentity {
    let env = ProcessInfo.processInfo.environment
    let name: String = flag("agent") ?? env["ZERO_AGENT"] ?? "shell-\(getppid())"
    var identity = AgentIdentity(
        name: name, host: AgentIdentity.thisHost,
        cwd: FileManager.default.currentDirectoryPath,
        ticket: flag("ticket"))
    // A session zerod runs: its notes, asks and runs join that session's approvals in the inbox.
    if let session = env["ZERO_SESSION"] { identity.runtime = "zerod"; identity.ref = session }
    return identity
}

/// Prints the ask's progress and exits with its outcome. If Zero.app goes away mid-wait (it was restarted, say),
/// reconnects for up to ten minutes and waits on the same ask, since Zero keeps open asks across a relaunch.
func follow(_ first: UnixSocket, id: String, finish: (Ask) -> Never = outcome) -> Never {
    var socket = first
    var lost: Date?
    while true {
        guard let response = socket.receive(Response.self) else {
            let since = lost ?? Date()
            lost = since
            guard Date().timeIntervalSince(since) < 600 else { fail("zero: Zero.app closed the connection") }
            Thread.sleep(forTimeInterval: 2)
            guard let again = try? UnixSocket.connect(path: Paths.socket) else { continue }
            socket = again
            try? socket.send(Request(op: "wait", id: id))
            continue
        }
        lost = nil
        switch response.op {
        case "output":
            if let chunk = response.chunk { FileHandle.standardOutput.write(Data(chunk.utf8)) }
        case "done":
            guard let ask = response.ask else { fail("zero: malformed reply") }
            finish(ask)
        case "error":
            fail("zero: \(response.message ?? "error")")
        default:
            break
        }
    }
}

/// The CLI's answer for a finished ask: stdout and the exit code agents read.
func outcome(_ ask: Ask) -> Never {
    switch ask.state {
    case .answered:
        if ask.kind == .run { exit(ask.exitCode ?? 0) }
        print(ask.answer ?? "")
        exit(0)
    case .declined:
        fail("declined" + (reason(ask).map { ": \($0)" } ?? ""), 2)
    case .expired:
        fail(ask.status == "withdrawn" ? "withdrawn" : "expired", 3)
    default:
        fail("zero: unexpected state \(ask.state.rawValue)")
    }
}

/// A text option answers as "label: text"; the agent gets just the text.
func reason(_ ask: Ask) -> String? {
    let labels = ask.options.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "…. ")) }
    var reason = ask.answer ?? ""
    if let label = labels.first(where: { reason.hasPrefix($0) }) {
        reason = String(reason.dropFirst(label.count)).trimmingCharacters(in: CharacterSet(charactersIn: ": "))
    }
    return reason.isEmpty ? nil : reason
}

@MainActor func create(_ ask: Ask, finish: (Ask) -> Never = outcome) -> Never {
    let socket = connect()
    try? socket.send(Request(op: "create", ask: ask, wait: !async))
    guard let reply = socket.receive(Response.self), reply.op == "created", let id = reply.id else { fail("zero: no reply from Zero.app") }
    if async { print(id); exit(0) }
    stderr("zero: waiting on ask \(id)")
    follow(socket, id: id, finish: finish)
}

@MainActor func askCommand() {
    guard let question = positional.first else { usage() }
    let options = flags["option"] ?? []
    // Choices written into the question can only be answered by typing; as options they take one key.
    if options.isEmpty, question.range(of: #"\((a|1)\).*\((b|2)\)"#, options: .regularExpression) != nil {
        fail("zero: put the choices in --option, one each (the first is the one you recommend), not as (a)/(b) in the question")
    }
    shortHeadline(question)
    shortDetail(flag("body"), flag: "body")
    let title = flag("title") ?? flag("ticket") ?? question
    var ask = Ask(
        kind: options.isEmpty ? .question : .choice, title: title, body: title == question ? "" : question, options: options,
        command: flag("code"), agent: agentIdentity(), ttl: ttl)
    ask.detail = flag("body")
    ask.about = about()
    // --block: it can't go on without the answer; Zero holds its other events until it's answered.
    ask.blocks = flag("block") != nil ? true : nil
    create(ask)
}

@MainActor func approveCommand() {
    guard let what = positional.first else { usage() }
    shortHeadline(what)
    shortDetail(flag("body"), flag: "body")
    var approval = Ask(
        kind: .approve, title: what, body: flag("body") ?? "", options: ["Yes", "No", "Suggest something else…"],
        command: flag("code"), agent: agentIdentity(), ttl: ttl)
    approval.about = about()
    create(approval)
}

/// --about "#bench-plan": the heading of the agent's it's about, which zerod finds; left out, its words just before.
func about() -> Ask.About? { flag("about").map { Ask.About(anchor: $0) } }

@MainActor func withdrawCommand() {
    guard let id = positional.first else { usage() }
    let socket = connect()
    try? socket.send(Request(op: "withdraw", id: id, text: flag("reason")))
    guard let reply = socket.receive(Response.self), reply.op == "withdrawn" else { fail("zero: no reply from Zero.app") }
}

@MainActor func runCommand() {
    guard let shell = positional.first else { usage() }
    guard flag("why") != nil || flag("body") != nil else {
        fail("zero run needs --why: say what you need the output for, so the user knows what they are running")
    }
    shortDetail(flag("why") ?? flag("body"), flag: "why")
    let folder = flag("cwd") ?? FileManager.default.currentDirectoryPath
    var run = Ask(
        kind: .run, title: flag("title") ?? flag("ticket") ?? "Run a command", body: flag("why") ?? flag("body") ?? "",
        options: ["Run", "Reject", "Suggest something else…"], command: shell, cwd: folder, agent: agentIdentity(), ttl: ttl)
    run.script = Ask.script(of: shell, cwd: folder)
    run.about = about()
    if let prefix = flag("allow") {
        let rest = shell.hasPrefix(prefix) ? shell.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces) : ""
        guard !rest.isEmpty, rest.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._/~-+@:,=".contains($0)) }) else {
            fail("zero: --allow needs the command to be that prefix and one plain file path after it")
        }
        run.allow = prefix
    }
    create(run)
}

@MainActor func noteCommand() {
    guard let text = positional.first else { usage() }
    let socket = connect()
    var note = Ask(kind: .note, title: flag("ticket") ?? "Update", body: text, agent: agentIdentity())
    // --merged, as agents said it before: completed.
    note.status = ["blocked", "done", "completed", "merged", "waiting"].first { flag($0) != nil }.map { $0 == "merged" ? "completed" : $0 }
    note.needs = flag("needs")
    shortDetail(note.needs, flag: "needs")
    // With --needs it's over to the user, as documented: the warning is for a note that says done alone.
    if note.needs == nil && (note.status == "done" || note.status == "completed") {
        FileHandle.standardError.write(
            Data("zero: a note's --done doesn't mark the task done; zero done does (it asks you to confirm)\n".utf8))
    }
    try? socket.send(Request(op: "create", ask: note, wait: false))
    guard let reply = socket.receive(Response.self), reply.op == "created" else { fail("zero: no reply from Zero.app") }
}

/// `zero done`: refused at first with what done means and a token, printed for the agent; with --confirm TOKEN, done;
/// with --ask, the user asked (its id printed, to end the turn on).
@MainActor func doneCommand() {
    guard let text = positional.first else { usage() }
    if flag("needs") != nil {
        fail("zero: a step left to the user isn't done: zero note \"what's done\" --needs \"their step\" shows Over to you")
    }
    let socket = connect()
    let said = Ask(kind: .note, title: "Update", body: text, agent: agentIdentity())
    try? socket.send(Request(op: "done", ask: said, id: flag("confirm"), text: flag("ask") != nil ? "ask" : nil))
    guard let reply = socket.receive(Response.self) else { fail("zero: no reply from Zero.app") }
    switch reply.op {
    case "marked": print("Marked done. End your turn with [zero: done].")
    case "created": print("Asked as \(reply.id ?? ""). End your turn with [zero: asked \(reply.id ?? "")].")
    case "notDone": print(reply.message ?? "Not marked done yet."); exit(1)
    default: fail("zero: \(reply.message ?? "no reply")")
    }
}

/// `zero blocked`: as done, refused at first with what blocked means and a token; with --confirm TOKEN, blocked.
@MainActor func blockedCommand() {
    guard let text = positional.first else { usage() }
    let socket = connect()
    try? socket.send(
        Request(op: "blocked", ask: Ask(kind: .note, title: "Update", body: text, agent: agentIdentity()), id: flag("confirm")))
    guard let reply = socket.receive(Response.self) else { fail("zero: no reply from Zero.app") }
    switch reply.op {
    case "marked": print("Marked blocked. End your turn with [zero: blocked].")
    case "notBlocked": print(reply.message ?? "Not marked blocked yet."); exit(1)
    default: fail("zero: \(reply.message ?? "no reply")")
    }
}

@MainActor func waitCommand() {
    guard let id = positional.first else { usage() }
    let socket = connect()
    try? socket.send(Request(op: "wait", id: id))
    follow(socket, id: id)
}

@MainActor func statusCommand() {
    guard let id = positional.first else { usage() }
    let socket = connect()
    try? socket.send(Request(op: "status", id: id))
    guard let reply = socket.receive(Response.self) else { fail("zero: no reply") }
    if reply.op == "error" { fail("zero: \(reply.message ?? "error")") }
    guard let ask = reply.ask else { fail("zero: malformed reply") }
    print(ask.state.rawValue + (ask.answer.map { " \($0)" } ?? ""))
}

@MainActor func sayCommand() {
    guard positional.count >= 2 else { usage() }
    let socket = connect()
    try? socket.send(Request(op: "message", agent: positional[0], text: positional[1...].joined(separator: " ")))
    guard let reply = socket.receive(Response.self), reply.op == "created" else {
        fail("zero: \(socket.receive(Response.self)?.message ?? "no reply from Zero.app")")
    }
}

@MainActor func listCommand() {
    let socket = connect()
    // Open ones unless --all: every ask ever made is hundreds of kilobytes to decode.
    var request = Request(op: "list")
    request.open = flag("all") == nil ? true : nil
    try? socket.send(request)
    guard let reply = socket.receive(Response.self), let asks = reply.asks else { fail("zero: no reply") }
    for ask in asks {
        print(
            "\(ask.id)  \(ask.state.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0))  \(ask.kind.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0))  \(ask.agent.name)  \(ask.title)"
        )
    }
}
