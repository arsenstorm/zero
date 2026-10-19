import Foundation
import ZeroCore

/// Accepts CLI connections on the Unix socket. A `create`/`wait` connection stays parked until its ask is final,
/// receiving `output` lines for run asks and one `done` line at the end.
final class Server {
    private let store: Store
    private var listener: UnixSocket?
    private var waiters: [String: [UnixSocket]] = [:]
    private let lock = NSLock()

    init(store: Store) { self.store = store }

    @MainActor func start() throws {
        try FileManager.default.createDirectory(at: Paths.dir, withIntermediateDirectories: true)
        let listener = try UnixSocket.listen(path: Paths.socket)
        self.listener = listener
        store.onChange = { [weak self] ask in self?.changed(ask) }
        store.onOutput = { [weak self] ask, chunk in self?.output(ask.id, chunk) }
        Thread.detachNewThread { [weak self] in
            while let client = try? listener.accept() {
                Thread.detachNewThread { self?.serve(client) }
            }
        }
    }

    private func onMain<T>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated(body) }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }

    private func serve(_ client: UnixSocket) {
        guard let request = client.receive(Request.self) else { client.close(); return }
        switch request.op {
        case "create":
            guard let incoming = request.ask else { return reject(client, "create needs an ask") }
            let ask = onMain { store.create(incoming) }
            try? client.send(Response(op: "created", id: ask.id))
            if request.wait ?? true { park(client, id: ask.id) } else { client.close() }
        case "wait":
            guard let id = request.id else { return reject(client, "wait needs an id") }
            park(client, id: id)
        case "status":
            guard let id = request.id, let ask = onMain({ store.ask(id) }) else { return reject(client, "no such ask \(request.id ?? "")") }
            try? client.send(Response(op: "ask", ask: ask))
            client.close()
        case "list":
            try? client.send(Response(op: "asks", asks: onMain { store.asks }))
            client.close()
        case "message":
            // Arsen's words to an agent, from a script: the same path as the inbox's message box.
            guard let agent = request.agent, let text = request.text else { return reject(client, "message needs an agent and text") }
            onMain { Task { await store.message(text, to: agent) } }
            try? client.send(Response(op: "created"))
            client.close()
        default:
            reject(client, "unknown op \(request.op)")
        }
    }

    private func reject(_ client: UnixSocket, _ message: String) {
        try? client.send(Response(op: "error", message: message))
        client.close()
    }

    private func park(_ client: UnixSocket, id: String) {
        guard let ask = onMain({ store.ask(id) }) else { return reject(client, "no such ask \(id)") }
        if ask.state.isFinal { return done(client, ask) }
        if !ask.output.isEmpty { try? client.send(Response(op: "output", id: id, chunk: ask.output)) }
        lock.withLock { waiters[id, default: []].append(client) }
        // The ask may have finished between the check and the append; whoever removes the waiter delivers `done`.
        if let now = onMain({ store.ask(id) }), now.state.isFinal, remove(client, from: id) { return done(client, now) }
        _ = client.readLine() // blocks until the client hangs up or `changed` shuts the socket down
        _ = remove(client, from: id)
        client.close()
    }

    private func remove(_ client: UnixSocket, from id: String) -> Bool {
        lock.withLock {
            guard let index = waiters[id]?.firstIndex(where: { $0 === client }) else { return false }
            waiters[id]?.remove(at: index)
            return true
        }
    }

    private func done(_ client: UnixSocket, _ ask: Ask) {
        try? client.send(Response(op: "done", ask: ask))
        client.shutdown()
        client.close()
    }

    private func changed(_ ask: Ask) {
        guard ask.state.isFinal else { return }
        let clients = lock.withLock { waiters.removeValue(forKey: ask.id) ?? [] }
        for client in clients {
            try? client.send(Response(op: "done", ask: ask))
            client.shutdown() // wakes the parked thread, which closes the fd
        }
    }

    private func output(_ id: String, _ chunk: String) {
        let clients = lock.withLock { waiters[id] ?? [] }
        for client in clients { try? client.send(Response(op: "output", id: id, chunk: chunk)) }
    }
}
