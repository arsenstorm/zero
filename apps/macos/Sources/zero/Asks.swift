import Foundation
import ZeroCore

/// A question or a request is the headline of its card; the reasoning behind it belongs in --body.
func shortHeadline(_ text: String) {
    guard text.count > 140 else { return }
    fail("zero: keep the question to one short line (about 12 words, ending in ?) and put the details in --body; this one is \(text.count) characters")
}

/// The text under a question is two or three plain sentences; anything longer goes in a file the agent links.
func shortDetail(_ text: String?, flag name: String) {
    guard let text, text.count > 280 else { return }
    fail("zero: keep --\(name) to two or three plain sentences (280 characters; this is \(text.count)): the problem, what you recommend and why. Put anything longer in a file and give its path")
}

@MainActor func agentIdentity() -> AgentIdentity {
    let env = ProcessInfo.processInfo.environment
    let solo: String? = env["SOLO_PROCESS_ID"].map { "solo-" + $0 }
    let rex: String? = env["REX_BLOCK"].map { "rex-" + String($0.suffix(6)) }
    let own: String? = env["ZERO_HOST_TERMINAL"].map { "claude-" + String($0.suffix(6)) }
    let hyperfocus: String? = env["HF_SESSION_ID"].map { "hf-" + $0 }
    let name: String = flag("agent") ?? env["ZERO_AGENT"] ?? solo ?? own ?? rex ?? hyperfocus ?? "shell-\(getppid())"
    var identity = AgentIdentity(name: name, host: ProcessInfo.processInfo.hostName,
                         cwd: FileManager.default.currentDirectoryPath,
                         soloProcessID: env["SOLO_PROCESS_ID"].flatMap(Int.init), soloProjectID: env["SOLO_PROJECT_ID"].flatMap(Int.init),
                         ticket: flag("ticket"))
    // Inside a Rex terminal: Zero reaches the agent through Rex.
    if let block = env["REX_BLOCK"] { identity.runtime = "rex"; identity.ref = block; identity.refGroup = env["REX_SESSION"] }
    // Inside one of Zero's own terminals: Zero reaches the agent through zero-host.
    if let terminal = env["ZERO_HOST_TERMINAL"] { identity.runtime = "zero"; identity.ref = terminal }
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
    var ask = Ask(kind: options.isEmpty ? .question : .choice, title: title, body: title == question ? "" : question, options: options,
                  command: flag("code"), agent: agentIdentity(), ttl: ttl)
    ask.detail = flag("body")
    // --block: it can't go on without the answer; Zero holds its other events until it's answered.
    ask.blocks = flag("block") != nil ? true : nil
    create(ask)
}

@MainActor func approveCommand() {
    guard let what = positional.first else { usage() }
    shortHeadline(what)
    shortDetail(flag("body"), flag: "body")
    create(Ask(kind: .approve, title: what, body: flag("body") ?? "", options: ["Yes", "No", "Suggest something else…"],
               command: flag("code"), agent: agentIdentity(), ttl: ttl))
}

@MainActor func withdrawCommand() {
    guard let id = positional.first else { usage() }
    let socket = connect()
    try? socket.send(Request(op: "withdraw", id: id, text: flag("reason")))
    guard let reply = socket.receive(Response.self), reply.op == "withdrawn" else { fail("zero: no reply from Zero.app") }
}

@MainActor func runCommand() {
    guard let shell = positional.first else { usage() }
    guard flag("why") != nil || flag("body") != nil else { fail("zero run needs --why: say what you need the output for, so the user knows what they are running") }
    shortDetail(flag("why") ?? flag("body"), flag: "why")
    let folder = flag("cwd") ?? FileManager.default.currentDirectoryPath
    var run = Ask(kind: .run, title: flag("title") ?? flag("ticket") ?? "Run a command", body: flag("why") ?? flag("body") ?? "",
                  options: ["Run", "Reject", "Suggest something else…"], command: shell, cwd: folder, agent: agentIdentity(), ttl: ttl)
    run.script = Ask.script(of: shell, cwd: folder)
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
    try? socket.send(Request(op: "create", ask: note, wait: false))
    guard let reply = socket.receive(Response.self), reply.op == "created" else { fail("zero: no reply from Zero.app") }
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
    guard let reply = socket.receive(Response.self), reply.op == "created" else { fail("zero: \(socket.receive(Response.self)?.message ?? "no reply from Zero.app")") }
}

@MainActor func listCommand() {
    let socket = connect()
    try? socket.send(Request(op: "list"))
    guard let reply = socket.receive(Response.self), let asks = reply.asks else { fail("zero: no reply") }
    for ask in asks { print("\(ask.id)  \(ask.state.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0))  \(ask.kind.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0))  \(ask.agent.name)  \(ask.title)") }
}
