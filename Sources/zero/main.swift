import Foundation
import ZeroCore

func stderr(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }
func fail(_ message: String, _ code: Int32 = 1) -> Never { stderr(message); exit(code) }
func usage() -> Never {
    fail("""
    usage:
      zero ask     "question" [--option A --option B ...] [--title T] [--body B] [--code 'command or snippet']
                   an option ending with "…" asks Arsen for text; the answer is then "label: text"
      zero approve "what you want to do" [--body B] [--code 'command or snippet']   (Yes / No / Suggest something else…)
      zero run     'command' [--cwd DIR] [--title T]
      zero note    "where you are now" [--blocked | --done]   (no answer; sets your agent's dot: working, blocked, done)
      zero wait    <id>
      zero status  <id>
      zero list
    common: --async (print the id and return) --agent NAME ($ZERO_AGENT) --ticket ID --ttl MINUTES (default from Zero's settings)
    exit: 0 answered (answer on stdout; for run, the command's output and exit code), 2 declined, 3 expired
    """)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }
args.removeFirst()

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
                         soloProcessID: env["SOLO_PROCESS_ID"].flatMap(Int.init), ticket: flag("ticket"))
}

func follow(_ socket: UnixSocket) -> Never {
    while let response = socket.receive(Response.self) {
        switch response.op {
        case "output":
            if let chunk = response.chunk { FileHandle.standardOutput.write(Data(chunk.utf8)) }
        case "done":
            guard let ask = response.ask else { fail("zero: malformed reply") }
            switch ask.state {
            case .answered:
                if ask.kind == .run { exit(ask.exitCode ?? 0) }
                print(ask.answer ?? "")
                exit(0)
            case .declined:
                // A text option answers as "label: text"; the agent gets just the text.
                let labels = ask.options.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "…. ")) }
                var reason = ask.answer ?? ""
                if let label = labels.first(where: { reason.hasPrefix($0) }) {
                    reason = String(reason.dropFirst(label.count)).trimmingCharacters(in: CharacterSet(charactersIn: ": "))
                }
                fail("declined" + (reason.isEmpty ? "" : ": \(reason)"), 2)
            case .expired:
                fail("expired", 3)
            default:
                fail("zero: unexpected state \(ask.state.rawValue)")
            }
        case "error":
            fail("zero: \(response.message ?? "error")")
        default:
            break
        }
    }
    fail("zero: Zero.app closed the connection")
}

func create(_ ask: Ask) -> Never {
    let socket = connect()
    try? socket.send(Request(op: "create", ask: ask, wait: !async))
    guard let reply = socket.receive(Response.self), reply.op == "created", let id = reply.id else { fail("zero: no reply from Zero.app") }
    if async { print(id); exit(0) }
    stderr("zero: waiting on ask \(id)")
    follow(socket)
}

switch command {
case "ask":
    guard let question = positional.first else { usage() }
    let options = flags["option"] ?? []
    let title = flag("title") ?? question
    create(Ask(kind: options.isEmpty ? .question : .choice, title: title,
               body: flag("body") ?? (title == question ? "" : question), options: options,
               command: flag("code"), agent: agentIdentity(), ttl: ttl))
case "approve":
    guard let what = positional.first else { usage() }
    create(Ask(kind: .approve, title: what, body: flag("body") ?? "", options: ["Yes", "No", "Suggest something else…"],
               command: flag("code"), agent: agentIdentity(), ttl: ttl))
case "run":
    guard let shell = positional.first else { usage() }
    create(Ask(kind: .run, title: flag("title") ?? "Run a command", body: flag("body") ?? "",
               options: ["Run", "Reject", "Suggest something else…"],
               command: shell, cwd: flag("cwd") ?? FileManager.default.currentDirectoryPath, agent: agentIdentity(), ttl: ttl))
case "note":
    guard let text = positional.first else { usage() }
    let socket = connect()
    var note = Ask(kind: .note, title: "Update", body: text, agent: agentIdentity())
    note.status = flag("blocked") != nil ? "blocked" : (flag("done") != nil ? "done" : nil)
    try? socket.send(Request(op: "create", ask: note, wait: false))
    guard let reply = socket.receive(Response.self), reply.op == "created" else { fail("zero: no reply from Zero.app") }
case "wait":
    guard let id = positional.first else { usage() }
    let socket = connect()
    try? socket.send(Request(op: "wait", id: id))
    follow(socket)
case "status":
    guard let id = positional.first else { usage() }
    let socket = connect()
    try? socket.send(Request(op: "status", id: id))
    guard let reply = socket.receive(Response.self) else { fail("zero: no reply") }
    if reply.op == "error" { fail("zero: \(reply.message ?? "error")") }
    guard let ask = reply.ask else { fail("zero: malformed reply") }
    print(ask.state.rawValue + (ask.answer.map { " \($0)" } ?? ""))
case "list":
    let socket = connect()
    try? socket.send(Request(op: "list"))
    guard let reply = socket.receive(Response.self), let asks = reply.asks else { fail("zero: no reply") }
    for ask in asks { print("\(ask.id)  \(ask.state.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0))  \(ask.kind.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0))  \(ask.agent.name)  \(ask.title)") }
default:
    usage()
}
