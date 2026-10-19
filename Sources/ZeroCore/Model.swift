import Foundation

/// `note` needs no answer: it is an agent saying where it is. `message` goes the other way: Arsen to the agent.
public enum AskKind: String, Codable, Sendable { case question, choice, approve, run, note, message }

public enum AskState: String, Codable, Sendable {
    case waiting, pending, running, answered, declined, expired
    public var isFinal: Bool { self == .answered || self == .declined || self == .expired }
}

public struct AgentIdentity: Codable, Hashable, Sendable {
    public var name: String
    public var host: String
    public var cwd: String?
    public var soloProcessID: Int?
    /// Solo scopes its calls to a project; every call about the process carries this one.
    public var soloProjectID: Int?
    public var ticket: String?

    public init(name: String, host: String, cwd: String? = nil, soloProcessID: Int? = nil, soloProjectID: Int? = nil, ticket: String? = nil) {
        self.name = name; self.host = host; self.cwd = cwd; self.soloProcessID = soloProcessID; self.soloProjectID = soloProjectID; self.ticket = ticket
    }
}

public struct Ask: Codable, Identifiable, Sendable {
    public var id: String
    public var kind: AskKind
    public var title: String
    public var body: String
    public var options: [String]
    public var command: String?
    public var cwd: String?
    public var agent: AgentIdentity
    public var createdAt: Date
    public var expiresAt: Date
    public var state: AskState
    public var answer: String?
    public var output: String
    public var exitCode: Int32?
    public var answeredAt: Date?
    /// For notes: "blocked" or "done"; nil means working.
    public var status: String?
    /// Index of the option Arsen picked, when he picked one.
    public var choice: Int?

    /// An option ending with "…" asks for text: picking it opens an input, and the answer is "label: text".
    public static func expectsText(_ option: String) -> Bool { option.hasSuffix("…") || option.hasSuffix("...") }

    public init(kind: AskKind, title: String, body: String = "", options: [String] = [],
                command: String? = nil, cwd: String? = nil, agent: AgentIdentity, ttl: TimeInterval = 3600) {
        id = Ask.newID()
        self.kind = kind; self.title = title; self.body = body; self.options = options
        self.command = command; self.cwd = cwd; self.agent = agent
        createdAt = Date(); expiresAt = createdAt.addingTimeInterval(ttl)
        state = .waiting; output = ""
    }

    public static func newID() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<6).map { _ in alphabet.randomElement()! })
    }
}

/// One JSON object per line over the socket. `op`: create | wait | status | list.
public struct Request: Codable, Sendable {
    public var op: String
    public var ask: Ask?
    public var id: String?
    public var wait: Bool?
    public init(op: String, ask: Ask? = nil, id: String? = nil, wait: Bool? = nil) {
        self.op = op; self.ask = ask; self.id = id; self.wait = wait
    }
}

/// `op`: created | ask | asks | output | done | error.
public struct Response: Codable, Sendable {
    public var op: String
    public var id: String?
    public var ask: Ask?
    public var asks: [Ask]?
    public var chunk: String?
    public var message: String?
    public init(op: String, id: String? = nil, ask: Ask? = nil, asks: [Ask]? = nil, chunk: String? = nil, message: String? = nil) {
        self.op = op; self.id = id; self.ask = ask; self.asks = asks; self.chunk = chunk; self.message = message
    }
}

public enum Paths {
    public static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zero")
    public static let socket = dir.appendingPathComponent("zero.sock").path
    public static let log = dir.appendingPathComponent("asks.jsonl")
}

public let jsonEncoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
public let jsonDecoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
