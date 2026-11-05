import Foundation

/// How Zero talks to zero-host, the helper that keeps its own agents' terminals: one JSON line each way per
/// request, over a Unix socket in ~/.zero.
public enum HostLink {
    public static let socket = Paths.dir.appendingPathComponent("host.sock").path
    /// Bumped when the requests change, so Zero can tell an older helper from a current one.
    /// 2: a terminal spawned with `record` keeps its output and exit code in files, for a run zerod follows (runs.rs).
    public static let version = 2

    public struct Request: Codable, Sendable {
        /// hello | spawn | write | screen | state | resize | close | list | attach
        public var op: String
        public var id: String?
        public var cwd: String?
        public var argv: [String]?
        public var label: String?
        /// For write: what to type, as UTF-8 text or raw bytes (keys).
        public var text: String?
        public var bytes: [UInt8]?
        public var columns: Int?
        public var rows: Int?
        /// For spawn: keep the program's output in runs/<id>.out and its exit code in <id>.exit (Paths.dir/host).
        public var record: Bool?
        public init(op: String, id: String? = nil, cwd: String? = nil, argv: [String]? = nil, label: String? = nil,
                    text: String? = nil, bytes: [UInt8]? = nil, columns: Int? = nil, rows: Int? = nil, record: Bool? = nil) {
            self.op = op; self.id = id; self.cwd = cwd; self.argv = argv; self.label = label
            self.text = text; self.bytes = bytes; self.columns = columns; self.rows = rows; self.record = record
        }
    }

    public struct Terminal: Codable, Sendable {
        public var id: String
        public var label: String
        public var cwd: String
        public var argv: [String]
        public var running: Bool
        public var exitCode: Int32?
        /// What the program last reported about itself (Program Status Protocol): idle, working, blocked, done, error.
        public var status: String?
        public var statusMessage: String?
        /// Seconds since its program last wrote or was typed to.
        public var idle: Int?
        public init(id: String, label: String, cwd: String, argv: [String], running: Bool, exitCode: Int32?, status: String?, statusMessage: String?, idle: Int? = nil) {
            self.id = id; self.label = label; self.cwd = cwd; self.argv = argv; self.running = running
            self.exitCode = exitCode; self.status = status; self.statusMessage = statusMessage; self.idle = idle
        }
    }

    public struct Response: Codable, Sendable {
        public var ok: Bool
        public var error: String?
        public var version: Int?
        public var terminal: Terminal?
        public var terminals: [Terminal]?
        public var screen: String?
        public init(ok: Bool, error: String? = nil, version: Int? = nil, terminal: Terminal? = nil, terminals: [Terminal]? = nil, screen: String? = nil) {
            self.ok = ok; self.error = error; self.version = version; self.terminal = terminal; self.terminals = terminals; self.screen = screen
        }
    }

    /// One request and its answer; nil when the helper isn't running.
    public static func call(_ request: Request) -> Response? {
        guard let socket = try? UnixSocket.connect(path: socket) else { return nil }
        defer { socket.close() }
        try? socket.send(request)
        return socket.receive(Response.self)
    }

    public static func call(_ request: Request) async -> Response? {
        await Task.detached { call(request) }.value
    }

    /// zero-host next to this program (Zero.app's MacOS folder, or the build folder), else the installed app's.
    static var executable: String {
        let sibling = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
            .appendingPathComponent("zero-host").path
        return FileManager.default.isExecutableFile(atPath: sibling) ? sibling : "/Applications/Zero.app/Contents/MacOS/zero-host"
    }

    /// Starts zero-host if it isn't running and waits up to three seconds for it to answer.
    public static func ensureRunning() async -> Bool {
        if await call(Request(op: "hello")) != nil { return true }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        let log = Paths.dir.appendingPathComponent("host.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        process.standardOutput = try? FileHandle(forWritingTo: log)
        process.standardError = process.standardOutput
        guard (try? process.run()) != nil else { return false }
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(100))
            if await call(Request(op: "hello")) != nil { return true }
        }
        return false
    }
}
