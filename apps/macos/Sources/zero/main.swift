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
      zero note    "where you are now" [--blocked | --done | --merged | --waiting] [--needs "what Arsen should do, when he can"]
                   (no answer; sets your agent's dot and its row on Zero's board: working, blocked, done, or
                   waiting on something other than Arsen)
      zero withdraw <id> [--reason "why"]   (take back an open ask that no longer needs Arsen)
      zero wait    <id>
      zero status  <id>
      zero list
      zero attach  [agent]   (shows one of Zero's own agents' terminal here to watch or type in; ⌃] lets go. No agent: lists them)
      zero say     <agent> "text"   (sends Arsen's words to the agent through Zero, as the inbox's message box does)
    sessions Zero runs (from inside one, the session you are in is the lead):
      zero spawn   "task" [--brief FILE] [--provider codex|claude|opencode] [--model M] [--effort E] [--cwd DIR]
                   [--label NAME] [--ticket REF] [--permissions auto|unrestricted]
                   starts a worker of this session (its folder and permissions unless given others) and prints its id;
                   when it finishes, fails or gets stuck, this session is told. Outside a session: a new session here.
      zero send    <session> "text"   (a message to a session, resumed first if it is offline)
      zero wait    <session>... [--any] [--timeout MINUTES]   (until they stop working: finished, failed, stuck, or waiting on the user)
      zero workers   (the sessions this one started)
      zero result  <session>   (its last answer)
      zero label   "name" [--ticket REF] [--where PLACE] [--session ID]   (names this session, or another; --where says where it runs,
                   a bench or a machine, for the board's Where; --where "" goes back to its folder)
      zero notify  <session> "text"   (words for a session, given between its turns: for event sources and scripts)
      zero watch   [--session ID] -- command...   (runs it in the background; this session is told how it ended, so end
                   your turn instead of polling: zero watch -- gh pr checks 42 --watch)
      zero remind  <minutes> "text" [--session ID]   (this session is told it then)
      zero usage   (each provider's limits as its CLI last reported them)
      zero mcp     (Zero's MCP server on stdio, giving an agent the user's scratchpads: add it as an MCP server's command)
    common: --async (print the id and return) --agent NAME ($ZERO_AGENT) --ticket ID (the ticket the ask is about,
            shown as its context) --ttl MINUTES (default from Zero's settings) --help
    exit: 0 answered (answer on stdout; for run, the command's output and exit code), 2 declined, 3 expired
    """
    if help { print(text); exit(0) }
    fail(text)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }
// The MCP server is zerod's own, beside this in Zero.app; it speaks on stdio, so this program becomes it.
if command == "mcp" {
    let here = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    let zerod = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("zerod").path
        ?? here.appendingPathComponent("zerod").path
    let argv = [zerod, "mcp"] + args.dropFirst()
    var cArgs = argv.map { strdup($0) } + [nil]
    execv(zerod, &cArgs)
    fail("zero: no zerod at \(zerod)")
}
args.removeFirst()
if ["help", "--help", "-h"].contains(command) || args.contains("--help") || args.contains("-h") { usage(help: true) }

var flags: [String: [String]] = [:]
var positional: [String] = []
var i = 0
while i < args.count {
    let arg = args[i]
    // After "--" everything is the command (zero watch -- gh pr checks 42 --watch).
    if arg == "--" { positional.append(contentsOf: args[(i + 1)...]); break }
    if arg.hasPrefix("--") {
        let key = String(arg.dropFirst(2))
        if ["async", "blocked", "done", "waiting", "any"].contains(key) {
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

/// The text under a question is two or three plain sentences; anything longer goes in a file the agent links.
func shortDetail(_ text: String?, flag name: String) {
    guard let text, text.count > 280 else { return }
    fail("zero: keep --\(name) to two or three plain sentences (280 characters; this is \(text.count)): the problem, what you recommend and why. Put anything longer in a file and give its path")
}

func connect() -> UnixSocket {
    do { return try UnixSocket.connect(path: Paths.socket) } catch { fail("zero: Zero.app is not running (\(error))") }
}

func agentIdentity() -> AgentIdentity {
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

func create(_ ask: Ask, finish: (Ask) -> Never = outcome) -> Never {
    let socket = connect()
    try? socket.send(Request(op: "create", ask: ask, wait: !async))
    guard let reply = socket.receive(Response.self), reply.op == "created", let id = reply.id else { fail("zero: no reply from Zero.app") }
    if async { print(id); exit(0) }
    stderr("zero: waiting on ask \(id)")
    follow(socket, id: id, finish: finish)
}

/// Asks one thing and waits for its outcome, without exiting: for hooks that ask several things in a row.
/// nil when Zero can't be reached.
func askAndWait(_ ask: Ask) -> Ask? {
    guard let socket = try? UnixSocket.connect(path: Paths.socket) else { return nil }
    try? socket.send(Request(op: "create", ask: ask, wait: true))
    guard let reply = socket.receive(Response.self), reply.op == "created" else { return nil }
    while let response = socket.receive(Response.self) {
        if response.op == "done" { return response.ask }
    }
    return nil
}

/// `zero attach`: one of zero-host's terminals in this one, raw, until ⌃] (or the terminal closes). The agent is
/// named as Zero names it (claude-<the terminal id's last six>), by its terminal id, or by the start of its label.
func attach(_ which: String?) -> Never {
    guard let list = HostLink.call(HostLink.Request(op: "list")), let terminals = list.terminals else { fail("zero: none of Zero's own agents are running") }
    guard let which else {
        for terminal in terminals {
            print("claude-\(terminal.id.suffix(6))  \(terminal.running ? "running" : "exited ")  \(terminal.label)")
        }
        exit(0)
    }
    let lowered = which.lowercased()
    guard let terminal = terminals.first(where: { which.hasSuffix(String($0.id.suffix(6))) || $0.id == which })
            ?? terminals.first(where: { $0.label.lowercased().hasPrefix(lowered) }) else { fail("zero: no agent \(which) in Zero's terminals") }
    var size = winsize()
    _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &size)
    guard let socket = try? UnixSocket.connect(path: HostLink.socket) else { fail("zero: Zero's terminal host isn't running") }
    try? socket.send(HostLink.Request(op: "attach", id: terminal.id, columns: size.ws_col > 0 ? Int(size.ws_col) : nil, rows: size.ws_row > 0 ? Int(size.ws_row) : nil))
    guard let reply = socket.receive(HostLink.Response.self), reply.ok else { fail("zero: couldn't attach to \(which)") }
    var saved = termios()
    tcgetattr(STDIN_FILENO, &saved)
    var raw = saved
    cfmakeraw(&raw)
    tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    // Its own screen, so letting go puts back what this terminal showed before.
    FileHandle.standardOutput.write(Data("\u{1B}[?1049h".utf8))
    func finish(_ note: String) -> Never {
        tcsetattr(STDIN_FILENO, TCSANOW, &saved)
        FileHandle.standardOutput.write(Data("\u{1B}[?1049l\u{1B}[0m".utf8))
        print(note)
        exit(0)
    }
    let early = socket.takeBuffered()
    if !early.isEmpty { FileHandle.standardOutput.write(early) }
    Thread.detachNewThread {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(STDIN_FILENO, &buffer, buffer.count)
            guard count > 0 else { break }
            if let detach = buffer[0..<count].firstIndex(of: 0x1D) {
                if detach > 0 { _ = Darwin.write(socket.fd, buffer, detach) }
                finish("zero: let go of \(terminal.label)")
            }
            _ = Darwin.write(socket.fd, buffer, count)
        }
    }
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let count = read(socket.fd, &buffer, buffer.count)
        guard count > 0 else { finish("zero: \(terminal.label)'s terminal closed") }
        _ = Darwin.write(STDOUT_FILENO, buffer, count)
    }
}

/// A session of zerod's: its ids are 16 hex digits, where an ask's are 6 letters and digits.
func isSession(_ id: String) -> Bool { id.count == 16 && id.allSatisfy(\.isHexDigit) }

/// One request to zerod, failing the command with zerod's own words.
func zerod<T>(_ body: (ZerodLink) async throws -> T) async -> T {
    guard let link = try? ZerodLink() else { fail("zero: Zero's daemon isn't running (open Zero)") }
    defer { link.close() }
    do { return try await body(link) } catch { fail("zero: \(error.localizedDescription)") }
}

/// A settled session as `zero wait` prints it: how it ended, then its answer or what's wrong.
func describe(_ session: [String: Any]) -> String {
    let id = session["id"] as? String ?? "?"
    let name = (session["label"] as? String).map { "\($0) " } ?? ""
    let attention = session["attention"] as? String ?? "?"
    let detail = session["answer"] as? String ?? session["error"] as? String ?? session["stalled"] as? String ?? ""
    return "\(name)\(id) \(attention)" + (detail.isEmpty ? "" : ":\n\(detail)")
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
    shortDetail(flag("body"), flag: "body")
    let title = flag("title") ?? flag("ticket") ?? question
    var ask = Ask(kind: options.isEmpty ? .question : .choice, title: title, body: title == question ? "" : question, options: options,
                  command: flag("code"), agent: agentIdentity(), ttl: ttl)
    ask.detail = flag("body")
    create(ask)
case "approve":
    guard let what = positional.first else { usage() }
    shortHeadline(what)
    shortDetail(flag("body"), flag: "body")
    create(Ask(kind: .approve, title: what, body: flag("body") ?? "", options: ["Yes", "No", "Suggest something else…"],
               command: flag("code"), agent: agentIdentity(), ttl: ttl))
case "permission":
    // Claude Code's PermissionRequest hook input on stdin; Arsen's answer goes back as the hook's decision. If Zero
    // can't be reached or the ask expires, nothing is printed and Claude Code's own permission flow carries on.
    let hook = FileHandle.standardInput.readDataToEndOfFile()
    // Claude Code's own questions are answered by the question hook, as questions, not as a permission.
    if (((try? JSONSerialization.jsonObject(with: hook)) as? [String: Any])?["tool_name"] as? String) == "AskUserQuestion" { exit(0) }
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
case "question":
    // Claude Code's PreToolUse hook input for its AskUserQuestion tool: each question becomes a Zero question,
    // and the answers go back as the tool's input, so its terminal picker never shows. Anything short of answers
    // for all of them prints nothing, and the picker shows in the terminal as usual.
    let hook = (try? JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile())) as? [String: Any] ?? [:]
    guard let input = hook["tool_input"] as? [String: Any], let questions = input["questions"] as? [[String: Any]], !questions.isEmpty else { exit(0) }
    var answers: [String: String] = [:]
    for item in questions {
        guard let question = item["question"] as? String else { exit(0) }
        let options = (item["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
        let descriptions = (item["options"] as? [[String: Any]] ?? []).compactMap { option -> String? in
            guard let label = option["label"] as? String, let text = option["description"] as? String, !text.isEmpty else { return nil }
            return "\(label): \(text)"
        }
        let several = item["multiSelect"] as? Bool == true
        var ask = Ask(kind: .choice, title: item["header"] as? String ?? question, body: question,
                      options: options + [several ? "Several, or something else…" : "Something else…"],
                      cwd: hook["cwd"] as? String, agent: agentIdentity(), ttl: ttl)
        ask.detail = descriptions.isEmpty ? nil : descriptions.joined(separator: "\n")
        guard let done = askAndWait(ask), done.state == .answered, let answer = done.answer else { exit(0) }
        answers[question] = options.contains(answer) ? answer : (reason(done) ?? answer)
    }
    var updated = input
    updated["answers"] = answers
    hookReply(["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "allow", "updatedInput": updated]])
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
    // "<source> <unix time>": the stop hook reads the first word.
    let saved = (try? String(contentsOf: file, encoding: .utf8))?.split(separator: " ")
    let previous = saved?.first.map(String.init)
    let typedRecently = previous == "human" && (saved?.dropFirst().first.flatMap { Double($0) }).map { Date().timeIntervalSince1970 - $0 < 600 } == true
    let machinery = ["[Solo timer", "<task-notification>", "<system-reminder>", "Caveat:"].contains { prompt.hasPrefix($0) }
    let zeroSaid = ["Arsen answered your ask", "Arsen declined your ask", "Arsen ran your command", "Arsen rejected your command", "Your ask "]
        .contains { prompt.hasPrefix($0) }
    let brief = prompt.range(of: #"\b(BRIEF|FIX|REVIEW|TEST)[\w.-]*\.md\b"#, options: .regularExpression) != nil
    var source: String
    if previous == "worker" || brief { source = "worker" }
    // A timer, a background result or Zero's answer arriving while Arsen is in the chat (often mid-turn) doesn't
    // mean he left: within ten minutes of his last typed prompt the turn stays his. After that, Zero's rules again.
    else if machinery || zeroSaid { source = typedRecently ? "human" : "zero" }
    else {
        // Zero's own inbox messages look typed; Zero knows what it sent. Unknown without Zero: treat as typed.
        let socket = try? UnixSocket.connect(path: Paths.socket)
        var identity = agentIdentity()
        identity.session = session.isEmpty ? nil : session // so Zero can name the agent by its session's title
        try? socket?.send(Request(op: "prompt", ask: Ask(kind: .message, title: "Prompt", body: prompt, agent: identity)))
        source = socket?.receive(Response.self)?.message ?? "human"
    }
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let stamp = source == "human" && typedRecently && (machinery || zeroSaid) ? (saved?.dropFirst().first.map(String.init) ?? "") : String(Int(Date().timeIntervalSince1970))
    try? "\(source) \(stamp)".write(to: file, atomically: true, encoding: .utf8)
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
    shortDetail(flag("why") ?? flag("body"), flag: "why")
    let folder = flag("cwd") ?? FileManager.default.currentDirectoryPath
    var run = Ask(kind: .run, title: flag("title") ?? flag("ticket") ?? "Run a command", body: flag("why") ?? flag("body") ?? "",
                  options: ["Run", "Reject", "Suggest something else…"], command: shell, cwd: folder, agent: agentIdentity(), ttl: ttl)
    run.script = Ask.script(of: shell, cwd: folder)
    create(run)
case "note":
    guard let text = positional.first else { usage() }
    let socket = connect()
    var note = Ask(kind: .note, title: flag("ticket") ?? "Update", body: text, agent: agentIdentity())
    note.status = ["blocked", "done", "merged", "waiting"].first { flag($0) != nil }
    note.needs = flag("needs")
    shortDetail(note.needs, flag: "needs")
    try? socket.send(Request(op: "create", ask: note, wait: false))
    guard let reply = socket.receive(Response.self), reply.op == "created" else { fail("zero: no reply from Zero.app") }
case "wait" where positional.first.map(isSession) == true:
    let settled = await zerod { try await $0.wait(on: positional, any: flag("any") != nil, timeout: flag("timeout").flatMap(Int.init).map { $0 * 60 }) }
    for session in settled { print(describe(session)) }
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
case "spawn":
    var prompt = positional.joined(separator: " ")
    if let brief = flag("brief") {
        let path = URL(fileURLWithPath: (brief as NSString).expandingTildeInPath, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardized.path
        guard FileManager.default.fileExists(atPath: path) else { fail("zero: no brief at \(path)") }
        prompt = "Read \(path) and do what it says." + (prompt.isEmpty ? "" : " " + prompt)
    }
    guard !prompt.isEmpty else { usage() }
    let provider: Provider? = flag("provider").map { name in
        guard let provider = Provider(rawValue: name) else { fail("zero: --provider is codex, claude or opencode") }
        return provider
    }
    let permissions: Permissions? = flag("permissions").map { name in
        guard let permissions = Permissions(rawValue: name) else { fail("zero: --permissions is auto or unrestricted") }
        return permissions
    }
    let session = await zerod { link -> String in
        if let lead = ProcessInfo.processInfo.environment["ZERO_SESSION"] {
            return try await link.spawn(lead: lead, provider: provider, prompt: prompt, cwd: flag("cwd"), model: flag("model"), effort: flag("effort"),
                                        permissions: permissions, label: flag("label"), ticket: flag("ticket"))
        }
        let id = try await link.start(provider: provider ?? .claude, cwd: flag("cwd") ?? FileManager.default.currentDirectoryPath, prompt: prompt,
                                      model: flag("model"), effort: flag("effort"), permissions: permissions ?? .auto)
        if flag("label") != nil || flag("ticket") != nil { try await link.label(session: id, label: flag("label"), ticket: flag("ticket")) }
        return id
    }
    print(session)
case "send":
    guard positional.count >= 2 else { usage() }
    await zerod { try await $0.send(session: positional[0], text: positional[1...].joined(separator: " ")) }
case "workers":
    guard let lead = flag("session") ?? ProcessInfo.processInfo.environment["ZERO_SESSION"] else { fail("zero: workers of which session? (--session ID)") }
    let workers = await zerod { try await $0.workers(of: lead) }
    for (worker, attention) in workers {
        print("\(worker.id)  \(attention.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0))  \(Workspace.label(of: worker))\(worker.ticket.map { "  (\($0))" } ?? "")")
    }
case "result":
    guard let session = positional.first else { usage() }
    guard let answer = await zerod({ try await $0.result(of: session) }) else { fail("zero: \(session) has no answer yet", 3) }
    print(answer)
case "label":
    guard let session = flag("session") ?? ProcessInfo.processInfo.environment["ZERO_SESSION"] else { fail("zero: label which session? (--session ID)") }
    // --where alone names where it runs and leaves its name and ticket be.
    if let place = flag("where") { await zerod { try await $0.place(session: session, place: place) } }
    if flag("where") == nil || !positional.isEmpty || flag("ticket") != nil {
        await zerod { try await $0.label(session: session, label: positional.isEmpty ? nil : positional.joined(separator: " "), ticket: flag("ticket")) }
    }
case "notify":
    guard positional.count >= 2 else { usage() }
    await zerod { try await $0.notify(session: positional[0], text: positional[1...].joined(separator: " ")) }
case "watch" where flag("session") != nil || ProcessInfo.processInfo.environment["ZERO_SESSION"] != nil:
    guard !positional.isEmpty, let session = flag("session") ?? ProcessInfo.processInfo.environment["ZERO_SESSION"] else { usage() }
    await zerod { try await $0.watch(session: session, command: positional.joined(separator: " ")) }
    print("zero: watching; this session will be told how it ends")
case "remind":
    guard positional.count >= 2, let minutes = Int(positional[0]),
          let session = flag("session") ?? ProcessInfo.processInfo.environment["ZERO_SESSION"] else { usage() }
    await zerod { try await $0.remind(session: session, minutes: minutes, text: positional[1...].joined(separator: " ")) }
case "usage":
    for (provider, usage) in await zerod({ try await $0.usage() }) {
        let reset = usage.resetsAt.map { " until " + Date(timeIntervalSince1970: TimeInterval($0)).formatted(date: .omitted, time: .shortened) } ?? ""
        let windows = usage.windows.map { "\($0.name) \(Int(($0.used * 100).rounded()))%" }.joined(separator: " · ")
        print("\(provider.title)  \(usage.limited ? "limited\(reset)" : "ok")  \(windows)")
    }
case "attach":
    attach(positional.first)
case "list":
    let socket = connect()
    try? socket.send(Request(op: "list"))
    guard let reply = socket.receive(Response.self), let asks = reply.asks else { fail("zero: no reply") }
    for ask in asks { print("\(ask.id)  \(ask.state.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0))  \(ask.kind.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0))  \(ask.agent.name)  \(ask.title)") }
default:
    usage()
}
