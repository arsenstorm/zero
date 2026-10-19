import Foundation

/// A way to deliver Arsen's words into an agent's session. Solo is the first; a Hyperfocus or bench adapter
/// would implement the same two calls.
public protocol AgentAdapter: Sendable {
    var name: String { get }
    func canReach(_ agent: AgentIdentity) -> Bool
    func send(_ text: String, to agent: AgentIdentity) async throws
}

public struct AdapterError: LocalizedError {
    public let errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}

/// Talks to the running Solo app through its bundled MCP stdio helper: one helper per message, three
/// JSON-RPC lines (initialize, initialized, tools/call send_input), then it exits.
public struct SoloAdapter: AgentAdapter {
    public let name = "solo"
    public var helper = "/Applications/Solo.app/Contents/MacOS/mcp"
    public var timeout: TimeInterval = 10

    public init() {}

    public func canReach(_ agent: AgentIdentity) -> Bool {
        agent.soloProcessID != nil && FileManager.default.isExecutableFile(atPath: helper)
    }

    public func send(_ text: String, to agent: AgentIdentity) async throws {
        guard let processID = agent.soloProcessID else { throw AdapterError("\(agent.name) has no Solo process id") }
        let result = try await call(tool: "send_input", arguments: ["process_id": processID, "input": text, "submit": true])
        if let isError = result["isError"] as? Bool, isError {
            let content = (result["content"] as? [[String: Any]])?.first?["text"] as? String
            throw AdapterError(content ?? "Solo refused the input")
        }
    }

    // ponytail: a fresh helper per call keeps this stateless; pool one helper if messages ever get chatty.
    private func call(tool: String, arguments: [String: Any]) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                do { continuation.resume(returning: try callBlocking(tool: tool, arguments: arguments)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func callBlocking(tool: String, arguments: [String: Any]) throws -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "SOLO_PROCESS_ID") // Zero speaks as itself, not as whichever agent launched it
        process.environment = env
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel(); if process.isRunning { process.terminate() } }

        func write(_ object: [String: Any]) throws {
            input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: object) + Data("\n".utf8))
        }
        try write(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
            "protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "zero", "version": "0.1"]]])
        try write(["jsonrpc": "2.0", "method": "notifications/initialized"])
        try write(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": tool, "arguments": arguments]])

        var buffer = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { throw AdapterError("Solo's MCP helper closed without answering") }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      message["id"] as? Int == 2 else { continue }
                if let error = message["error"] as? [String: Any] {
                    throw AdapterError(error["message"] as? String ?? "Solo returned an error")
                }
                return message["result"] as? [String: Any] ?? [:]
            }
        }
    }
}
