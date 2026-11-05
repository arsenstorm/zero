import Darwin
import Foundation
import ZeroCore

/// zero-host: keeps the terminals of the agents Zero starts itself. Each is a pseudo-terminal running the agent
/// through the user's login shell, its output kept by Ghostty's engine (Screen), so Zero can read the screen, type
/// into it, and tell whether its program still runs. Zero talks to it over HostLink.socket. It runs on its own, in a
/// session of its own, so its agents keep running when Zero quits or is rebuilt.

if CommandLine.arguments.dropFirst().first == "--selftest" {
    let screen = Screen(columns: 40, rows: 10)
    var replies = Data()
    screen.reply = { replies.append($0) }
    screen.feed(Data("hello\r\n\u{1B}[2J\u{1B}[Hcleared and redrawn\r\n\u{1B}[6n".utf8))
    print(screen.text())
    print("reply to cursor query:", replies.map { String(format: "%02x", $0) }.joined(separator: " "))
    exit(0)
}

/// One agent's terminal.
final class Terminal {
    let id: String
    let label: String
    let cwd: String
    let argv: [String]
    let screen: Screen
    private(set) var master: Int32 = -1
    private(set) var pid: pid_t = 0
    private(set) var exitCode: Int32?
    private var reader: DispatchSourceRead?
    /// Terminals attached with `zero attach`: each gets the program's output as it comes.
    var viewers: [Int32: UnixSocket] = [:]
    private let columns: Int, rows: Int
    private var exitWatch: DispatchSourceProcess?
    /// A run's output as it comes, and where its exit code goes when it ends: a zerod restarted mid-run reads them.
    var record: (output: FileHandle, exit: URL)?

    init(id: String, label: String, cwd: String, argv: [String], columns: Int, rows: Int) {
        self.id = id; self.label = label; self.cwd = cwd; self.argv = argv; self.columns = columns; self.rows = rows
        screen = Screen(columns: columns, rows: rows)
    }

    var running: Bool { exitCode == nil && pid > 0 }

    /// Starts the program through the user's shell (`zsh -lic 'exec "$@"'`, so their .zshrc's PATH applies), in `cwd`,
    /// on a new pty. The environment starts clean: whoever started the helper (Zero, or an agent's `zero` call)
    /// mustn't hand the agent its own session's variables.
    func start(columns: Int, rows: Int, queue: DispatchQueue) throws {
        let own = ProcessInfo.processInfo.environment
        var env = own.filter { ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG"].contains($0.key) }
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["ZERO_HOST_TERMINAL"] = id
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        let words = ["/bin/zsh", "-lic", "exec \"$@\"", "zsh"] + argv
        // Everything the child needs is made before fork: after it, only exec-safe calls.
        let cArgs = words.map { strdup($0) } + [nil]
        let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let cDir = strdup(cwd)
        defer { (cArgs + cEnv).forEach { free($0) }; free(cDir) }
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
        var fd: Int32 = -1
        let child = forkpty(&fd, nil, nil, &size)
        if child < 0 { throw NSError(domain: "zero-host", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "forkpty failed"]) }
        if child == 0 {
            // Only the terminal: no socket or file of the helper's leaks into the agent (an inherited client
            // connection would never close).
            let limit = getdtablesize()
            var descriptor: Int32 = 3
            while descriptor < limit { Darwin.close(descriptor); descriptor += 1 }
            chdir(cDir)
            execve("/bin/zsh", cArgs, cEnv)
            _exit(127)
        }
        master = fd
        pid = child
        screen.reply = { [weak self] data in self?.write(data) }
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        reader.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 65536)
            let count = read(self.master, &buffer, buffer.count)
            guard count > 0 else { self.reader?.cancel(); return }
            let output = Data(buffer[0..<count])
            self.lastActivity = Date()
            self.screen.feed(output)
            self.record?.output.write(output)
            // ponytail: written inline, so a stalled viewer stalls the host; a per-viewer queue if that ever bites
            for viewer in self.viewers.values { output.withUnsafeBytes { _ = Darwin.write(viewer.fd, $0.baseAddress!, $0.count) } }
        }
        reader.resume()
        self.reader = reader
        let exitWatch = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: queue)
        exitWatch.setEventHandler { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            waitpid(self.pid, &status, 0)
            let exited = status & 0x7f == 0
            self.exitCode = exited ? (status >> 8) & 0xff : -1
            self.exitWatch?.cancel()
            if let record = self.record {
                // What it printed last is read first: the exit code lands after, whole (written aside, then moved).
                var rest = [UInt8](repeating: 0, count: 65536)
                while true { let n = read(self.master, &rest, rest.count); if n <= 0 { break }; record.output.write(Data(rest[0..<n])) }
                try? record.output.close()
                let aside = record.exit.appendingPathExtension("part")
                try? "\(self.exitCode ?? -1)\n".write(to: aside, atomically: false, encoding: .utf8)
                try? FileManager.default.moveItem(at: aside, to: record.exit)
            }
        }
        exitWatch.resume()
        self.exitWatch = exitWatch
    }

    func write(_ data: Data) {
        guard master >= 0 else { return }
        lastActivity = Date()
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(master, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }

    func resize(columns: Int, rows: Int) {
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)
        screen.resize(columns: columns, rows: rows)
    }

    /// Shows the terminal in another one, at that one's size, until it lets go: the screen as it is, then the
    /// program's output as it comes, while what is typed there goes to the program. Runs on the client's thread.
    func attach(_ client: UnixSocket, columns: Int?, rows: Int?) {
        queue.sync {
            if let columns, let rows { resize(columns: columns, rows: rows) }
            let redraw = Data(("\u{1B}[H\u{1B}[2J" + screen.redraw()).utf8)
            redraw.withUnsafeBytes { _ = Darwin.write(client.fd, $0.baseAddress!, $0.count) }
            viewers[client.fd] = client
        }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(client.fd, &buffer, buffer.count)
            guard count > 0 else { break }
            let input = Data(buffer[0..<count])
            queue.async { self.write(input) }
        }
        queue.sync {
            viewers[client.fd] = nil
            // Back to the size Zero reads it at, once nobody is looking.
            if viewers.isEmpty { resize(columns: self.columns, rows: self.rows) }
        }
    }

    /// Ends the program and lets go of the terminal.
    func close() {
        if running { kill(pid, SIGHUP); kill(pid, SIGTERM) }
        reader?.cancel()
        if master >= 0 { Darwin.close(master); master = -1 }
    }

    /// When its program last wrote or was typed to: how long a terminal has sat at its prompt.

    var lastActivity = Date()


    var summary: HostLink.Terminal {
        HostLink.Terminal(id: id, label: label, cwd: cwd, argv: argv, running: running, exitCode: exitCode,
                          status: screen.status?.state, statusMessage: screen.status?.message, idle: Int(Date().timeIntervalSince(lastActivity)))
    }
}

/// Every request is handled on this one queue, so terminals need no locks.
let queue = DispatchQueue(label: "zero-host")
var terminals: [String: Terminal] = [:]
var order: [String] = []

func handle(_ request: HostLink.Request) -> HostLink.Response {
    switch request.op {
    case "hello":
        return HostLink.Response(ok: true, version: HostLink.version)
    case "spawn":
        guard let argv = request.argv, !argv.isEmpty, let cwd = request.cwd else { return HostLink.Response(ok: false, error: "spawn needs argv and cwd") }
        let columns = request.columns ?? 120, rows = request.rows ?? 40
        let terminal = Terminal(id: "term-" + UUID().uuidString.prefix(8).lowercased(), label: request.label ?? argv[0],
                                cwd: cwd, argv: argv, columns: columns, rows: rows)
        if request.record == true {
            let runs = Paths.dir.appendingPathComponent("host")
            try? FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
            let output = runs.appendingPathComponent(terminal.id + ".out")
            FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
            if let handle = try? FileHandle(forWritingTo: output) { terminal.record = (handle, runs.appendingPathComponent(terminal.id + ".exit")) }
        }
        do { try terminal.start(columns: columns, rows: rows, queue: queue) } catch {
            return HostLink.Response(ok: false, error: error.localizedDescription)
        }
        terminals[terminal.id] = terminal
        order.append(terminal.id)
        return HostLink.Response(ok: true, terminal: terminal.summary)
    case "write":
        guard let terminal = request.id.flatMap({ terminals[$0] }) else { return HostLink.Response(ok: false, error: "no such terminal") }
        if let text = request.text { terminal.write(Data(text.utf8)) }
        if let bytes = request.bytes { terminal.write(Data(bytes)) }
        return HostLink.Response(ok: true)
    case "screen":
        guard let terminal = request.id.flatMap({ terminals[$0] }) else { return HostLink.Response(ok: false, error: "no such terminal") }
        return HostLink.Response(ok: true, terminal: terminal.summary, screen: terminal.screen.text())
    case "state":
        guard let terminal = request.id.flatMap({ terminals[$0] }) else { return HostLink.Response(ok: false, error: "no such terminal") }
        return HostLink.Response(ok: true, terminal: terminal.summary)
    case "resize":
        guard let terminal = request.id.flatMap({ terminals[$0] }), let columns = request.columns, let rows = request.rows else {
            return HostLink.Response(ok: false, error: "resize needs a terminal, columns and rows")
        }
        terminal.resize(columns: columns, rows: rows)
        return HostLink.Response(ok: true)
    case "close":
        guard let id = request.id, let terminal = terminals[id] else { return HostLink.Response(ok: false, error: "no such terminal") }
        terminal.close()
        terminals[id] = nil
        order.removeAll { $0 == id }
        return HostLink.Response(ok: true)
    case "list":
        return HostLink.Response(ok: true, terminals: order.compactMap { terminals[$0]?.summary })
    default:
        return HostLink.Response(ok: false, error: "unknown op \(request.op)")
    }
}

// The terminals follow the system between light and dark, as Zero's window does.
// ponytail: looks every 2 s; the distributed theme notification once zero-host runs a run loop.
let themeWatch = DispatchSource.makeTimerSource(queue: queue)
themeWatch.schedule(deadline: .now() + 2, repeating: 2)
themeWatch.setEventHandler {
    let dark = Appearance.dark
    for terminal in terminals.values where terminal.screen.dark != dark { terminal.screen.appearance(dark: dark) }
}
themeWatch.resume()

// A session of its own: Zero quitting, or the terminal that started it closing, doesn't end its agents.
setsid()
signal(SIGPIPE, SIG_IGN)
signal(SIGHUP, SIG_IGN)
try? FileManager.default.createDirectory(at: Paths.dir, withIntermediateDirectories: true)
if HostLink.call(HostLink.Request(op: "hello")) != nil { exit(0) } // one helper is enough
unlink(HostLink.socket)
guard let listener = try? UnixSocket.listen(path: HostLink.socket) else { fputs("zero-host: can't listen on \(HostLink.socket)\n", stderr); exit(1) }
Thread.detachNewThread {
    while let client = try? listener.accept() {
        Thread.detachNewThread {
            defer { client.close() }
            guard let request = client.receive(HostLink.Request.self) else { return }
            if request.op == "attach" {
                guard let terminal = queue.sync(execute: { request.id.flatMap { terminals[$0] } }) else {
                    try? client.send(HostLink.Response(ok: false, error: "no such terminal")); return
                }
                try? client.send(HostLink.Response(ok: true, terminal: queue.sync { terminal.summary }))
                terminal.attach(client, columns: request.columns, rows: request.rows)
                return
            }
            let response = queue.sync { handle(request) }
            try? client.send(response)
        }
    }
}
dispatchMain()
