import Darwin
import MachO

// `zero` as agents and hooks call it most (note, done, withdraw, status, prompt, issue, send): Darwin alone, as
// starting a program that loads Foundation and ZeroCore's frameworks costs more than the call. Everything else, and
// every usage or error path these would take before reaching Zero, is zero-full's (the CLI in Sources/zero), run in
// this process's place, so what each command prints and how it exits stays that program's.

/// zero-full, beside this program, given these arguments (and what was read of stdin, when it was).
func delegate(stdin data: [UInt8]? = nil) -> Never {
    var size = UInt32(PATH_MAX)
    var path = [CChar](repeating: 0, count: Int(size) + 1)
    _ = _NSGetExecutablePath(&path, &size)
    var real = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    let me = realpath(path, &real) != nil ? String(cString: real) : String(cString: path)
    let full = String(me[..<(me.lastIndex(of: "/") ?? me.startIndex)]) + "/zero-full"
    if let data, let file = tmpfile() {
        _ = fwrite(data, 1, data.count, file)
        rewind(file)
        dup2(fileno(file), STDIN_FILENO)
    }
    execv(full, CommandLine.unsafeArgv)
    fail("zero: no zero-full at \(full)")
}

func fail(_ message: String, _ code: Int32 = 1) -> Never { fputs(message + "\n", stderr); exit(code) }

func env(_ name: String) -> String? { getenv(name).map { String(cString: $0) } }

// The arguments, read as zero-full reads them.
var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { delegate() }
args.removeFirst()
if ["help", "--help", "-h"].contains(command) || args.contains("--help") || args.contains("-h") { delegate() }
var flags: [String: [String]] = [:]
var positional: [String] = []
var i = 0
while i < args.count {
    let arg = args[i]
    if arg == "--" { positional.append(contentsOf: args[(i + 1)...]); break }
    if arg.hasPrefix("--") {
        let key = String(arg.dropFirst(2))
        if ["async", "blocked", "done", "merged", "completed", "waiting", "any", "mine", "all", "asked", "watch", "block", "ask"].contains(key) {
            flags[key, default: []].append("1")
        } else {
            i += 1
            guard i < args.count else { delegate() }
            flags[key, default: []].append(args[i])
        }
    } else {
        positional.append(arg)
    }
    i += 1
}
func flag(_ key: String) -> String? { flags[key]?.last }

// JSON, as much of it as these commands write and read.

func quote(_ text: String) -> String {
    var out = "\""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case _ where scalar.value < 0x20:
            let hex = String(scalar.value, radix: 16)
            out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
        default: out.unicodeScalars.append(scalar)
        }
    }
    return out + "\""
}

/// An object of already-encoded values, in this order; nil values left out.
func object(_ pairs: [(String, String?)]) -> String {
    "{" + pairs.compactMap { key, value in value.map { quote(key) + ":" + $0 } }.joined(separator: ",") + "}"
}

indirect enum JSON {
    case null, bool(Bool), number(String), string(String), array([JSON]), object([String: JSON])
    subscript(key: String) -> JSON? { if case .object(let fields) = self { fields[key] } else { nil } }
    var string: String? { if case .string(let text) = self { text } else { nil } }
}

/// Strict JSON: nil for anything JSONSerialization might read differently (invalid UTF-8, a lone surrogate, raw
/// control characters), so the caller can leave it to zero-full.
struct Parser {
    let bytes: [UInt8]
    var at = 0

    static func parse(_ bytes: [UInt8]) -> JSON? {
        var parser = Parser(bytes: bytes)
        guard let value = parser.value() else { return nil }
        parser.space()
        return parser.at == bytes.count ? value : nil
    }

    mutating func space() { while at < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[at]) { at += 1 } }

    mutating func literal(_ word: String, _ value: JSON) -> JSON? {
        let utf8 = Array(word.utf8)
        guard bytes.count - at >= utf8.count, Array(bytes[at..<at + utf8.count]) == utf8 else { return nil }
        at += utf8.count
        return value
    }

    mutating func value() -> JSON? {
        space()
        guard at < bytes.count else { return nil }
        switch bytes[at] {
        case UInt8(ascii: "{"):
            at += 1
            var fields: [String: JSON] = [:]
            space()
            if at < bytes.count, bytes[at] == UInt8(ascii: "}") { at += 1; return .object(fields) }
            while true {
                space()
                guard let key = string() else { return nil }
                space()
                guard at < bytes.count, bytes[at] == UInt8(ascii: ":") else { return nil }
                at += 1
                guard let value = value() else { return nil }
                fields[key] = value
                space()
                guard at < bytes.count else { return nil }
                if bytes[at] == UInt8(ascii: ",") { at += 1; continue }
                guard bytes[at] == UInt8(ascii: "}") else { return nil }
                at += 1
                return .object(fields)
            }
        case UInt8(ascii: "["):
            at += 1
            var items: [JSON] = []
            space()
            if at < bytes.count, bytes[at] == UInt8(ascii: "]") { at += 1; return .array(items) }
            while true {
                guard let item = value() else { return nil }
                items.append(item)
                space()
                guard at < bytes.count else { return nil }
                if bytes[at] == UInt8(ascii: ",") { at += 1; continue }
                guard bytes[at] == UInt8(ascii: "]") else { return nil }
                at += 1
                return .array(items)
            }
        case UInt8(ascii: "\""): return string().map(JSON.string)
        case UInt8(ascii: "t"): return literal("true", .bool(true))
        case UInt8(ascii: "f"): return literal("false", .bool(false))
        case UInt8(ascii: "n"): return literal("null", .null)
        default:
            let start = at
            while at < bytes.count, "+-.0123456789eE".utf8.contains(bytes[at]) { at += 1 }
            guard at > start, let text = String(validating: bytes[start..<at], as: UTF8.self), Double(text) != nil else { return nil }
            return .number(text)
        }
    }

    mutating func hex4() -> UInt32? {
        guard bytes.count - at >= 4, let text = String(validating: bytes[at..<at + 4], as: UTF8.self), let value = UInt32(text, radix: 16) else { return nil }
        at += 4
        return value
    }

    mutating func string() -> String? {
        guard at < bytes.count, bytes[at] == UInt8(ascii: "\"") else { return nil }
        at += 1
        var out: [UInt8] = []
        while at < bytes.count {
            let byte = bytes[at]
            at += 1
            switch byte {
            case UInt8(ascii: "\""): return String(validating: out, as: UTF8.self)
            case UInt8(ascii: "\\"):
                guard at < bytes.count else { return nil }
                let escape = bytes[at]
                at += 1
                let simple: [UInt8: UInt8] = [0x22: 0x22, 0x5C: 0x5C, 0x2F: 0x2F, 0x62: 0x08, 0x66: 0x0C, 0x6E: 0x0A, 0x72: 0x0D, 0x74: 0x09]
                if let plain = simple[escape] { out.append(plain); continue }
                guard escape == UInt8(ascii: "u"), var code = hex4() else { return nil }
                if (0xD800..<0xDC00).contains(code) {
                    guard bytes.count - at >= 2, bytes[at] == UInt8(ascii: "\\"), bytes[at + 1] == UInt8(ascii: "u") else { return nil }
                    at += 2
                    guard let low = hex4(), (0xDC00..<0xE000).contains(low) else { return nil }
                    code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                }
                guard let scalar = Unicode.Scalar(code) else { return nil }
                out.append(contentsOf: Array(String(Character(scalar)).utf8))
            case 0..<0x20: return nil
            default: out.append(byte)
            }
        }
        return nil
    }
}

// The sockets: zero.sock for asks and notes, zerod.sock for zerod's requests.

/// $HOME, as zerod finds ~/.zero: asking for the account's home instead took a millisecond of each call.
let home: String = env("HOME") ?? getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? "/"
let askSocket = env("ZERO_SOCKET") ?? home + "/.zero/zero.sock"
let daemonSocket = env("ZERO_DAEMON") ?? home + "/.zero/zerod.sock"

final class Connection {
    let fd: Int32
    var buffer: [UInt8] = []

    init?(_ path: String) {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { $0.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strlcpy($0, path, capacity) } }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { close(fd); return nil }
    }

    /// False when it couldn't all be written.
    @discardableResult func write(line: String) -> Bool {
        let bytes = Array((line + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
            guard n > 0 else { return false }
            offset += n
        }
        return true
    }

    /// The next line; what's left at the end of the stream; nil after that.
    func readLine() -> [UInt8]? {
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                defer { buffer.removeFirst(newline + 1) }
                return Array(buffer[..<newline])
            }
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 {
                guard !buffer.isEmpty else { return nil }
                defer { buffer.removeAll() }
                return buffer
            }
            buffer.append(contentsOf: chunk[..<n])
        }
    }

    /// zero.sock's reply as zero-full's Response decodes: an object with a string op; nil otherwise.
    func reply() -> JSON? {
        guard let line = readLine(), let reply = Parser.parse(line), reply["op"]?.string != nil else { return nil }
        for key in ["id", "message", "chunk"] {
            if let value = reply[key], value.string == nil { if case .null = value {} else { return nil } }
        }
        return reply
    }
}

/// One of zerod's requests, as ZerodLink makes it; fails with zerod's words when it refuses.
func zerod(_ op: String, _ fields: [(String, String?)]) {
    guard let link = Connection(daemonSocket) else { delegate() }
    guard link.write(line: object(fields + [("op", quote(op)), ("id", "1")])) else {
        fail("zero: Couldn't write to zerod: write: \(String(cString: strerror(errno)))")
    }
    while let line = link.readLine() {
        guard let message = Parser.parse(line), case .object = message, message["event"]?.string == nil,
              case .number(let id)? = message["id"], Int(id) == 1 else { continue }
        if case .bool(true)? = message["ok"] { return }
        fail("zero: \(message["error"]?.string ?? "zerod refused the request")")
    }
    fail("zero: zerod closed the connection")
}

// The ask a note, a done or a prompt is sent as, encoded as zero-full's Ask is.

func twoDigits(_ n: Int32) -> String { n < 10 ? "0\(n)" : "\(n)" }

func iso(_ seconds: time_t) -> String {
    var t = seconds
    var parts = tm()
    gmtime_r(&t, &parts)
    return "\(parts.tm_year + 1900)-\(twoDigits(parts.tm_mon + 1))-\(twoDigits(parts.tm_mday))T\(twoDigits(parts.tm_hour)):\(twoDigits(parts.tm_min)):\(twoDigits(parts.tm_sec))Z"
}

func newID() -> String {
    let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
    return String((0..<6).map { _ in alphabet.randomElement()! })
}

func agentIdentity(session: String? = nil) -> String {
    let own = env("ZERO_HOST_TERMINAL").map { "claude-" + String($0.suffix(6)) }
    let name = flag("agent") ?? env("ZERO_AGENT") ?? own ?? "shell-\(getppid())"
    var host = [CChar](repeating: 0, count: 256)
    var cwd = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    var runtime: String?, ref: String?
    if let terminal = env("ZERO_HOST_TERMINAL") { runtime = "zero"; ref = terminal }
    if let session = env("ZERO_SESSION") { runtime = "zerod"; ref = session }
    return object([
        ("name", quote(name)),
        ("host", quote(gethostname(&host, host.count) == 0 ? String(cString: host) : "mac")),
        ("cwd", quote(getcwd(&cwd, cwd.count) != nil ? String(cString: cwd) : "")),
        ("ticket", flag("ticket").map(quote)),
        ("session", session.map(quote)),
        ("runtime", runtime.map(quote)), ("ref", ref.map(quote)),
    ])
}

func ask(kind: String, title: String, body: String, agent: String, status: String? = nil, needs: String? = nil) -> String {
    let now = time(nil)
    return object([
        ("id", quote(newID())), ("kind", quote(kind)), ("title", quote(title)), ("body", quote(body)), ("options", "[]"),
        ("agent", agent), ("createdAt", quote(iso(now))), ("expiresAt", quote(iso(now + 3600))), ("state", quote("waiting")),
        ("output", quote("")), ("status", status.map(quote)), ("needs", needs.map(quote)),
    ])
}

func connectAsks() -> Connection {
    guard let socket = Connection(askSocket) else { delegate() }
    return socket
}

// The commands.

func note() -> Never {
    guard let text = positional.first, (flag("needs")?.count ?? 0) <= 280 else { delegate() }
    let socket = connectAsks()
    let status = ["blocked", "done", "completed", "merged", "waiting"].first { flag($0) != nil }.map { $0 == "merged" ? "completed" : $0 }
    let note = ask(kind: "note", title: flag("ticket") ?? "Update", body: text, agent: agentIdentity(), status: status, needs: flag("needs"))
    if status == "done" || status == "completed" {
        fputs("zero: a note's --done doesn't mark the task done; zero done does (it asks you to confirm)\n", stderr)
    }
    socket.write(line: object([("op", quote("create")), ("ask", note), ("wait", "false")]))
    guard socket.reply()?["op"]?.string == "created" else { fail("zero: no reply from Zero.app") }
    exit(0)
}

func done() -> Never {
    guard let text = positional.first else { delegate() }
    let socket = connectAsks()
    let said = ask(kind: "note", title: "Update", body: text, agent: agentIdentity())
    socket.write(line: object([("op", quote("done")), ("ask", said), ("id", flag("confirm").map(quote)), ("text", flag("ask") != nil ? quote("ask") : nil)]))
    guard let reply = socket.reply() else { fail("zero: no reply from Zero.app") }
    switch reply["op"]?.string {
    case "marked": print("Marked done. End your turn with [zero: done].")
    case "created": print("Asked as \(reply["id"]?.string ?? ""). End your turn with [zero: asked \(reply["id"]?.string ?? "")].")
    case "notDone": print(reply["message"]?.string ?? "Not marked done yet."); exit(1)
    default: fail("zero: \(reply["message"]?.string ?? "no reply")")
    }
    exit(0)
}

func withdraw() -> Never {
    guard let id = positional.first else { delegate() }
    let socket = connectAsks()
    socket.write(line: object([("op", quote("withdraw")), ("id", quote(id)), ("text", flag("reason").map(quote))]))
    guard socket.reply()?["op"]?.string == "withdrawn" else { fail("zero: no reply from Zero.app") }
    exit(0)
}

func status() -> Never {
    guard let id = positional.first else { delegate() }
    let socket = connectAsks()
    socket.write(line: object([("op", quote("status")), ("id", quote(id))]))
    guard let reply = socket.reply() else { fail("zero: no reply") }
    if reply["op"]?.string == "error" { fail("zero: \(reply["message"]?.string ?? "error")") }
    guard let asked = reply["ask"], case .object = asked else { fail("zero: malformed reply") }
    let states = ["waiting", "pending", "running", "answered", "declined", "expired"]
    guard let state = asked["state"]?.string, states.contains(state) else { fail("zero: no reply") }
    print(state + (asked["answer"]?.string.map { " \($0)" } ?? ""))
    exit(0)
}

func issue() -> Never {
    guard positional.count >= 2, let session = flag("session") ?? env("ZERO_SESSION") else { delegate() }
    zerod("issue", [("session", quote(session)), ("ticket", quote(positional[0])), ("state", quote(positional[1])),
                    ("text", quote(positional.dropFirst(2).joined(separator: " ")))])
    exit(0)
}

func send() -> Never {
    guard positional.count >= 2 else { delegate() }
    let text = positional[1...].joined(separator: " ")
    if let me = env("ZERO_SESSION"), me != positional[0] {
        zerod("notify", [("session", quote(positional[0])), ("text", quote(text)), ("from", quote(me))])
    } else {
        zerod("send", [("session", quote(positional[0])), ("text", quote(text)), ("images", "[]")])
    }
    exit(0)
}

/// The plugin's UserPromptSubmit hook (zero-full's promptCommand, which says why each step is as it is).
func prompt() -> Never {
    var input: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 1 << 16)
    while true {
        let n = read(STDIN_FILENO, &chunk, chunk.count)
        guard n > 0 else { break }
        input.append(contentsOf: chunk[..<n])
    }
    guard let hook = Parser.parse(input), case .object = hook else { delegate(stdin: input) }
    let prompt = trimmed(hook["prompt"]?.string ?? "")
    let session = String(String.UnicodeScalarView((hook["session_id"]?.string ?? "").unicodeScalars.filter { $0 != "/" }))
    let briefWords = ["BRIEF", "FIX", "REVIEW", "TEST"]
    // NSRegularExpression's \w and \b read beyond ASCII in ways not worth copying: such prompts are zero-full's.
    if !prompt.unicodeScalars.allSatisfy(\.isASCII), briefWords.contains(where: { prompt.contains($0) }) { delegate(stdin: input) }
    let folder = home + "/.zero/presence"
    let file = folder + "/" + (session.isEmpty ? "unknown" : session)
    let saved = contents(of: file)?.split(separator: " ")
    let previous = saved?.first.map(String.init)
    var now = timespec()
    clock_gettime(CLOCK_REALTIME, &now)
    let typedRecently = previous == "human" && (saved?.dropFirst().first.flatMap { Double($0) }).map { Double(now.tv_sec) + Double(now.tv_nsec) / 1e9 - $0 < 600 } == true
    let machinery = ["<task-notification>", "<system-reminder>", "Caveat:"].contains { prompt.hasPrefix($0) }
    let zeroSaid = ["The user answered your ask", "The user declined your ask", "The user ran your command", "The user rejected your command", "Your ask "]
        .contains { prompt.hasPrefix($0) }
    var source: String
    if previous == "worker" || namesBrief(Array(prompt.utf8)) { source = "worker" }
    else if machinery || zeroSaid { source = typedRecently ? "human" : "zero" }
    else { source = sourceZeroKnows(prompt, session: session) }
    mkdir(home + "/.zero", 0o755)
    mkdir(folder, 0o755)
    let stamp = source == "human" && typedRecently && (machinery || zeroSaid) ? (saved?.dropFirst().first.map(String.init) ?? "") : String(now.tv_sec)
    write("\(source) \(stamp)", to: file)
    let context: String? = switch source {
    case "human": "The user typed this in the terminal and is at the keyboard: answer them here in the chat. This turn needs no Zero note and no [zero: …] ending, and anything you'd ask them, ask here."
    case "worker": "You were started from a brief by a lead agent: report to that lead as the brief says, not to the user. Don't post Zero notes or asks and don't end turns with [zero: …]. Only use zero run, with --why, for a command only the user can run on their Mac."
    default: nil
    }
    guard let context else { exit(0) }
    print(object([("hookSpecificOutput", object([("hookEventName", quote("UserPromptSubmit")), ("additionalContext", quote(context))]))]))
    exit(0)
}

/// Without the whitespace and newlines at either end, as Foundation's trimming does (by scalar, White_Space).
func trimmed(_ text: String) -> String {
    let scalars = Array(text.unicodeScalars)
    guard let first = scalars.firstIndex(where: { !$0.properties.isWhitespace }),
          let last = scalars.lastIndex(where: { !$0.properties.isWhitespace }) else { return "" }
    return String(String.UnicodeScalarView(scalars[first...last]))
}

/// `\b(BRIEF|FIX|REVIEW|TEST)[\w.-]*\.md\b`, for ASCII text.
func namesBrief(_ text: [UInt8]) -> Bool {
    func word(_ byte: UInt8) -> Bool { byte == UInt8(ascii: "_") || (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) }
    for start in text.indices where start == 0 || !word(text[start - 1]) {
        for keyword in ["BRIEF", "FIX", "REVIEW", "TEST"].map({ Array($0.utf8) }) where text[start...].starts(with: keyword) {
            var end = start + keyword.count
            while end < text.count, word(text[end]) || text[end] == UInt8(ascii: ".") || text[end] == UInt8(ascii: "-") { end += 1 }
            // Any end of that run that is ".md" before a non-word character or the end.
            for stop in stride(from: end, through: start + keyword.count + 3, by: -1)
            where Array(text[(stop - 3)..<stop]) == Array(".md".utf8) && (stop == text.count || !word(text[stop])) { return true }
        }
    }
    return false
}

func contents(of path: String) -> String? {
    let fd = open(path, O_RDONLY)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var bytes: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &chunk, chunk.count)
        if n < 0 { return nil }
        if n == 0 { break }
        bytes.append(contentsOf: chunk[..<n])
    }
    return String(validating: bytes, as: UTF8.self)
}

/// Written whole or not at all: to a file beside it, then moved over it.
func write(_ text: String, to path: String) {
    let temporary = path + ".\(getpid()).tmp"
    let fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard fd >= 0 else { return }
    let bytes = Array(text.utf8)
    let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    close(fd)
    if written == bytes.count { rename(temporary, path) } else { unlink(temporary) }
}

/// Zero's own inbox messages look typed; Zero knows what it sent. Unknown without Zero: typed.
func sourceZeroKnows(_ prompt: String, session: String) -> String {
    guard let socket = Connection(askSocket) else { return "human" }
    let message = ask(kind: "message", title: "Prompt", body: prompt, agent: agentIdentity(session: session.isEmpty ? nil : session))
    socket.write(line: object([("op", quote("prompt")), ("ask", message)]))
    return socket.reply()?["message"]?.string ?? "human"
}

switch command {
case "note": note()
case "done": done()
case "withdraw": withdraw()
case "status": status()
case "prompt": prompt()
case "issue": issue()
case "send": send()
default: delegate()
}
