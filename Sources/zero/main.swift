import Foundation
import ZeroCore

func stderr(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }
func fail(_ message: String, _ code: Int32 = 1) -> Never { stderr(message); exit(code) }
func usage(help: Bool = false) -> Never {
    let text = """
    usage:
      zero ask     "short question?" [--option A --option B ...] [--body "details"] [--title T] [--code 'command or snippet']
                   the question is one line (about 12 words); the details Arsen may need go in --body
                   an option ending with "…" asks Arsen for text; the answer is then "label: text"
      zero approve "what you want to do" [--body "details"] [--code 'command or snippet']   (Yes / No / Suggest something else…)
      zero run     'command' --why "what you need the output for" [--cwd DIR] [--title T]
                   runs on Arsen's Mac after he presses Run; a script file's contents are shown to him
      zero note    "where you are now" [--blocked | --done]   (no answer; sets your agent's dot: working, blocked, done)
      zero withdraw <id> [--reason "why"]   (take back an open ask that no longer needs Arsen)
      zero wait    <id>
      zero status  <id>
      zero list
      zero say     <agent> "text"   (sends Arsen's words to the agent through Zero, as the inbox's message box does)
    common: --async (print the id and return) --agent NAME ($ZERO_AGENT) --ticket ID (the ticket the ask is about,
            shown as its context) --ttl MINUTES (default from Zero's settings) --help
    exit: 0 answered (answer on stdout; for run, the command's output and exit code), 2 declined, 3 expired
    """
    if help { print(text); exit(0) }
    fail(text)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }
args.removeFirst()
if ["help", "--help", "-h"].contains(command) || args.contains("--help") || args.contains("-h") { usage(help: true) }

var flags: [String: [String]] = [:]
var positional: [String] = []
var i = 0
while i < args.count {
    let arg = args[i]
    if arg.hasPrefix("--") {
        let key = String(arg.dropFirst(2))
        if ["async", "blocked", "done"].contains(key) {
            flags[key, default: []].append("1")
        } else {
            i += 1
            guard i < args.count else { fail("zero: missing value for --\(key)") }
            flags[key, default: []].append(args[i])
        }
    } else {
        positional.append(arg)
    }
    i += 1
}
func flag(_ key: String) -> String? { flags[key]?.last }
let async = flag("async") != nil
let ttl = (flag("ttl").flatMap(Double.init) ?? 0) * 60 // 0: let the app apply its default expiry

/// A question or a request is the headline of its card; the reasoning behind it belongs in --body.
func shortHeadline(_ text: String) {
    guard text.count > 140 else { return }
    fail("zero: keep the question to one short line (about 12 words, ending in ?) and put the details in --body; this one is \(text.count) characters")
}

func connect() -> UnixSocket {
    do { return try UnixSocket.connect(path: Paths.socket) } catch { fail("zero: Zero.app is not running (\(error))") }
}

func agentIdentity() -> AgentIdentity {
    let env = ProcessInfo.processInfo.environment
    let name = flag("agent") ?? env["ZERO_AGENT"]
        ?? env["SOLO_PROCESS_ID"].map { "solo-\($0)" }
        ?? env["HF_SESSION_ID"].map { "hf-\($0)" }
        ?? "shell-\(getppid())"
    return AgentIdentity(name: name, host: ProcessInfo.processInfo.hostName,
                         cwd: FileManager.default.currentDirectoryPath,
                         soloProcessID: env["SOLO_PROCESS_ID"].flatMap(Int.init), soloProjectID: env["SOLO_PROJECT_ID"].flatMap(Int.init),
                         ticket: flag("ticket"))
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

func create(_ ask: Ask, finish: (Ask) -> Never = outcome) -> Never {
    let socket = connect()
    try? socket.send(Request(op: "create", ask: ask, wait: !async))
    guard let reply = socket.receive(Response.self), reply.op == "created", let id = reply.id else { fail("zero: no reply from Zero.app") }
    if async { print(id); exit(0) }
    stderr("zero: waiting on ask \(id)")
    follow(socket, id: id, finish: finish)
}

/// Prints a hook's JSON answer to Claude Code and exits 0.
func hookReply(_ object: [String: Any]) -> Never {
    if let data = try? JSONSerialization.data(withJSONObject: object) { FileHandle.standardOutput.write(data + Data("\n".utf8)) }
    exit(0)
}

switch command {
case "ask":
    guard let question = positional.first else { usage() }
    let options = flags["option"] ?? []
    // Choices written into the question can only be answered by typing; as options they take one key.
    if options.isEmpty, question.range(of: #"\((a|1)\).*\((b|2)\)"#, options: .regularExpression) != nil {
        fail("zero: put the choices in --option, one each (the first is the one you recommend), not as (a)/(b) in the question")
    }
    shortHeadline(question)
    let title = flag("title") ?? flag("ticket") ?? question
    var ask = Ask(kind: options.isEmpty ? .question : .choice, title: title, body: title == question ? "" : question, options: options,
                  command: flag("code"), agent: agentIdentity(), ttl: ttl)
    ask.detail = flag("body")
    create(ask)
case "approve":
    guard let what = positional.first else { usage() }
    shortHeadline(what)
    create(Ask(kind: .approve, title: what, body: flag("body") ?? "", options: ["Yes", "No", "Suggest something else…"],
               command: flag("code"), agent: agentIdentity(), ttl: ttl))
case "permission":
    // Claude Code's PermissionRequest hook input on stdin; Arsen's answer goes back as the hook's decision. If Zero
    // can't be reached or the ask expires, nothing is printed and Claude Code's own permission flow carries on.
    let hook = FileHandle.standardInput.readDataToEndOfFile()
    guard let ask = Ask.permission(hook: hook, agent: agentIdentity(), ttl: ttl) else { fail("zero: no permission request on stdin") }
    let suggestions = ((try? JSONSerialization.jsonObject(with: hook)) as? [String: Any])?["permission_suggestions"] as? [Any] ?? []
    create(ask) { done in
        switch done.state {
        case .answered:
            var decision: [String: Any] = ["behavior": "allow"]
            if done.answer == "Always allow", !suggestions.isEmpty { decision["updatedPermissions"] = suggestions }
            hookReply(["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]])
        case .declined:
            hookReply(["hookSpecificOutput": ["hookEventName": "PermissionRequest",
                                              "decision": ["behavior": "deny", "message": "Arsen said no in Zero" + (reason(done).map { ": \($0)" } ?? "")]]])
        default:
            exit(0)
        }
    }
case "withdraw":
    guard let id = positional.first else { usage() }
    let socket = connect()
    try? socket.send(Request(op: "withdraw", id: id, text: flag("reason")))
    guard let reply = socket.receive(Response.self), reply.op == "withdrawn" else { fail("zero: no reply from Zero.app") }
case "prompt":
    // The plugin's UserPromptSubmit hook. Works out who sent the prompt: a Solo timer or a background result
    // (machinery), Zero (an answer or a message from the inbox), the lead (a worker's brief), or Arsen typing in
    // the terminal. Records it for the stop hook and tells the agent how to treat the turn.
    let input = (try? JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile())) as? [String: Any] ?? [:]
    let prompt = (input["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let session = (input["session_id"] as? String ?? "").replacingOccurrences(of: "/", with: "")
    let folder = Paths.dir.appendingPathComponent("presence")
    let file = folder.appendingPathComponent(session.isEmpty ? "unknown" : session)
    let previous = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    let machinery = ["[Solo timer", "<task-notification>", "<system-reminder>", "Caveat:"].contains { prompt.hasPrefix($0) }
    let zeroSaid = ["Arsen answered your ask", "Arsen declined your ask", "Arsen ran your command", "Arsen rejected your command", "Your ask "]
        .contains { prompt.hasPrefix($0) }
    let brief = prompt.range(of: #"\b(BRIEF|FIX|REVIEW|TEST)[\w.-]*\.md\b"#, options: .regularExpression) != nil
    var source: String
    if previous == "worker" || brief { source = "worker" }
    else if machinery { source = "zero" } // a timer or a background result: Zero's rules apply again
    else if zeroSaid { source = "zero" }
    else {
        // Zero's own inbox messages look typed; Zero knows what it sent. Unknown without Zero: treat as typed.
        let socket = try? UnixSocket.connect(path: Paths.socket)
        var identity = agentIdentity()
        identity.session = session.isEmpty ? nil : session // so Zero can name the agent by its session's title
        try? socket?.send(Request(op: "prompt", ask: Ask(kind: .message, title: "Prompt", body: prompt, agent: identity)))
        source = socket?.receive(Response.self)?.message ?? "human"
    }
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try? source.write(to: file, atomically: true, encoding: .utf8)
    let context: String? = switch source {
    case "human": "Arsen typed this in the terminal and is at the keyboard: answer him here in the chat. This turn needs no Zero note and no [zero: …] ending, and anything you'd ask him, ask here."
    case "worker": "You were started from a brief by a lead agent: report to that lead as the brief says, not to Arsen. Don't post Zero notes or asks and don't end turns with [zero: …]. Only use zero run, with --why, for a command only Arsen can run on his Mac."
    default: nil
    }
    guard let context else { exit(0) }
    hookReply(["hookSpecificOutput": ["hookEventName": "UserPromptSubmit", "additionalContext": context]])
case "run":
    guard let shell = positional.first else { usage() }
    guard flag("why") != nil || flag("body") != nil else { fail("zero run needs --why: say what you need the output for, so Arsen knows what he is running") }
    let folder = flag("cwd") ?? FileManager.default.currentDirectoryPath
    var run = Ask(kind: .run, title: flag("title") ?? flag("ticket") ?? "Run a command", body: flag("why") ?? flag("body") ?? "",
                  options: ["Run", "Reject", "Suggest something else…"], command: shell, cwd: folder, agent: agentIdentity(), ttl: ttl)
    run.script = Ask.script(of: shell, cwd: folder)
    create(run)
case "note":
    guard let text = positional.first else { usage() }
    let socket = connect()
    var note = Ask(kind: .note, title: flag("ticket") ?? "Update", body: text, agent: agentIdentity())
    note.status = flag("blocked") != nil ? "blocked" : (flag("done") != nil ? "done" : nil)
    try? socket.send(Request(op: "create", ask: note, wait: false))
    guard let reply = socket.receive(Response.self), reply.op == "created" else { fail("zero: no reply from Zero.app") }
case "wait":
    guard let id = positional.first else { usage() }
    let socket = connect()
    try? socket.send(Request(op: "wait", id: id))
    follow(socket, id: id)
case "status":
    guard let id = positional.first else { usage() }
    let socket = connect()
    try? socket.send(Request(op: "status", id: id))
    guard let reply = socket.receive(Response.self) else { fail("zero: no reply") }
    if reply.op == "error" { fail("zero: \(reply.message ?? "error")") }
    guard let ask = reply.ask else { fail("zero: malformed reply") }
    print(ask.state.rawValue + (ask.answer.map { " \($0)" } ?? ""))
case "say":
    guard positional.count >= 2 else { usage() }
    let socket = connect()
    try? socket.send(Request(op: "message", agent: positional[0], text: positional[1...].joined(separator: " ")))
    guard let reply = socket.receive(Response.self), reply.op == "created" else { fail("zero: \(socket.receive(Response.self)?.message ?? "no reply from Zero.app")") }
case "list":
    let socket = connect()
    try? socket.send(Request(op: "list"))
    guard let reply = socket.receive(Response.self), let asks = reply.asks else { fail("zero: no reply") }
    for ask in asks { print("\(ask.id)  \(ask.state.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0))  \(ask.kind.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0))  \(ask.agent.name)  \(ask.title)") }
default:
    usage()
}
