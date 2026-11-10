import Foundation
import ZeroCore

@MainActor func spawnCommand() async {
    var prompt = positional.joined(separator: " ")
    // The loop heads the worker's brief: zerod gives its words in place of the name.
    if let loop = flag("loop") { prompt = "@\(loop)" + (prompt.isEmpty ? "" : " " + prompt) }
    if let brief = flag("brief") {
        let path = URL(
            fileURLWithPath: (brief as NSString).expandingTildeInPath,
            relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        ).standardized.path
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
            return try await link.spawn(
                lead: lead, provider: provider, prompt: prompt, cwd: flag("cwd"), model: flag("model"), effort: flag("effort"),
                permissions: permissions, label: flag("label"), ticket: flag("ticket"), workspace: flag("workspace"))
        }
        let id = try await link.start(
            provider: provider ?? .claude, cwd: flag("cwd") ?? FileManager.default.currentDirectoryPath, prompt: prompt,
            model: flag("model"), effort: flag("effort"), permissions: permissions ?? .auto, workspace: flag("workspace"))
        if flag("label") != nil || flag("ticket") != nil { try await link.label(session: id, label: flag("label"), ticket: flag("ticket")) }
        return id
    }
    print(session)
}

@MainActor func sendCommand() async {
    guard positional.count >= 2 else { usage() }
    let text = positional[1...].joined(separator: " ")
    // From inside a task: another task's words, marked as its and given between turns (as a worker's report is),
    // never passed off as the user's or steering a turn.
    if let me = ProcessInfo.processInfo.environment["ZERO_SESSION"], me != positional[0] {
        await zerod { try await $0.notify(session: positional[0], text: text, from: me) }
    } else {
        await zerod { try await $0.send(session: positional[0], text: text) }
    }
}

@MainActor func notifyCommand() async {
    guard positional.count >= 2 else { usage() }
    await zerod { try await $0.notify(session: positional[0], text: positional[1...].joined(separator: " ")) }
}

@MainActor func waitSessionsCommand() async {
    let settled = await zerod {
        try await $0.wait(on: positional, any: flag("any") != nil, timeout: flag("timeout").flatMap(Int.init).map { $0 * 60 })
    }
    for session in settled { print(describe(session)) }
}

/// A settled session as `zero wait` prints it: how it ended, then its answer or what's wrong.
func describe(_ session: [String: Any]) -> String {
    let id = session["id"] as? String ?? "?"
    let name = (session["label"] as? String).map { "\($0) " } ?? ""
    let attention = session["attention"] as? String ?? "?"
    let detail = session["answer"] as? String ?? session["error"] as? String ?? session["stalled"] as? String ?? ""
    return "\(name)\(id) \(attention)" + (detail.isEmpty ? "" : ":\n\(detail)")
}

@MainActor func resultCommand() async {
    guard let session = positional.first else { usage() }
    guard let answer = await zerod({ try await $0.result(of: session) }) else { fail("zero: \(session) has no answer yet", 3) }
    print(answer)
}

@MainActor func closeCommand() async {
    guard !positional.isEmpty else { usage() }
    for session in positional { await zerod { try await $0.archive(session: session) } }
}

@MainActor func pauseCommand(_ command: String) async {
    let done = await zerod { command == "pause" ? try await $0.pause(sessions: positional) : try await $0.unpause(sessions: positional) }
    print(done.isEmpty ? "zero: nothing to \(command)" : "zero: \(command)d \(done.joined(separator: " "))")
}

@MainActor func workersCommand() async {
    guard let lead = targetSession() else { fail("zero: workers of which session? (--session ID)") }
    let workers = await zerod { try await $0.workers(of: lead) }
    for (worker, attention) in workers {
        print(
            "\(worker.id)  \(attention.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0))  \(Workspace.label(of: worker))\(worker.ticket.map { "  (\($0))" } ?? "")"
        )
    }
}

@MainActor func adoptCommand() async {
    guard let target = positional.first, let lead = targetSession() else {
        fail("zero: adopt which task, into which session? (zero adopt ID, from inside a session or with --session ID)")
    }
    print(await zerod { try await $0.adopt(lead: lead, target: target) })
}

@MainActor func detachCommand() async {
    guard let target = positional.first else { fail("zero: detach which worker? (zero detach ID)") }
    await zerod { try await $0.detach(target) }
    print("zero: \(target) is a task of its own")
}

@MainActor func migrateCommand() async {
    guard let thread = positional.first else {
        fail("zero: migrate which session? (zero migrate ID: a Claude Code, Codex or OpenCode session's id)")
    }
    print(await zerod { try await $0.migrate(thread, label: flag("label"), workspace: flag("workspace")) })
}

@MainActor func tasksCommand() async {
    for task in await zerod({ try await $0.list() }) {
        // Its folder last: what another task needs to tell whether this one works on what it touches.
        let columns = [
            task.id, task.status.rawValue, task.parent.map { "under \($0)" } ?? "lead", task.ticket ?? "-", task.thread ?? "-",
            Workspace.label(of: task),
            (task.cwd as NSString).abbreviatingWithTildeInPath,
        ]
        print(columns.joined(separator: "  "))
    }
}

@MainActor func workspacesCommand() async {
    for w in await zerod({ try await $0.workspaces() }) {
        print("\(w.id)  \(w.name)")
    }
}

@MainActor func loopsCommand() async {
    for loop in await zerod({ try await $0.loops() }) {
        print(
            "\(loop.name)  \(loop.description)"
                + (loop.children.isEmpty ? "" : "  → " + loop.children.map { "@" + $0 }.joined(separator: " ")))
    }
}

@MainActor func loopCommand() async {
    guard let name = positional.first else { usage() }
    print(await zerod { try await $0.loop(name) }.body)
}

@MainActor func usageCommand() async {
    for (provider, usage) in await zerod({ try await $0.usage() }) {
        let reset =
            usage.resetsAt.map { " until " + Date(timeIntervalSince1970: TimeInterval($0)).formatted(date: .omitted, time: .shortened) }
            ?? ""
        let windows = usage.windows.map { "\($0.name) \(Int(($0.used * 100).rounded()))%" }.joined(separator: " · ")
        print("\(provider.title)  \(usage.limited ? "limited\(reset)" : "ok")  \(windows)")
    }
}

@MainActor func browserCommand() async {
    guard let name = positional.first else { usage() }
    let tool = name.hasPrefix("browser_") ? name : "browser_" + name
    let input = positional.dropFirst().joined(separator: " ")
    guard let args = (input.isEmpty ? [:] : (try? JSONSerialization.jsonObject(with: Data(input.utf8))) as? [String: Any]) else {
        fail("zero: the input is a JSON object, such as '{\"url\": \"example.com\"}'")
    }
    let session = targetSession()
    // Each image a file of its own: one answer can have several (browser_compare's, one per browser).
    for (index, part) in await zerod({ try await $0.browserCall(session: session, tool: tool, args: args) }).enumerated() {
        if let text = part["text"] as? String { print(text) }
        if let data = (part["data"] as? String).flatMap({ Data(base64Encoded: $0) }) {
            let kind = (part["mimeType"] as? String) == "image/png" ? "png" : "jpg"
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(
                "zero-screenshot-\(Int(Date().timeIntervalSince1970 * 1000))-\(index).\(kind)")
            try? data.write(to: file)
            print("[image: \(file.path)]")
        }
    }
}

/// `zero attach`: one of zero-host's terminals in this one, raw, until ⌃] (or the terminal closes). The agent is
/// named as Zero names it (claude-<the terminal id's last six>), by its terminal id, or by the start of its label.
func attach(_ which: String?) -> Never {
    guard let list = HostLink.call(HostLink.Request(op: "list")), let terminals = list.terminals else {
        fail("zero: none of Zero's own agents are running")
    }
    guard let which else {
        for terminal in terminals {
            print("claude-\(terminal.id.suffix(6))  \(terminal.running ? "running" : "exited ")  \(terminal.label)")
        }
        exit(0)
    }
    let lowered = which.lowercased()
    guard
        let terminal = terminals.first(where: { which.hasSuffix(String($0.id.suffix(6))) || $0.id == which })
            ?? terminals.first(where: { $0.label.lowercased().hasPrefix(lowered) })
    else { fail("zero: no agent \(which) in Zero's terminals") }
    var size = winsize()
    _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &size)
    guard let socket = try? UnixSocket.connect(path: HostLink.socket) else { fail("zero: Zero's terminal host isn't running") }
    try? socket.send(
        HostLink.Request(
            op: "attach", id: terminal.id, columns: size.ws_col > 0 ? Int(size.ws_col) : nil, rows: size.ws_row > 0 ? Int(size.ws_row) : nil
        ))
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

/// `zero video`: a video as frames an agent can read, at the times asked for.
@MainActor func videoCommand() async {
    guard let path = positional.first else { usage() }
    let video = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    guard FileManager.default.fileExists(atPath: video.path) else { fail("zero: no video at \(video.path)") }
    let info: VideoFrames.Info
    do { info = try await VideoFrames.info(of: video) } catch { fail("zero: \(error.localizedDescription)") }
    let seconds = info.seconds
    let number = { (key: String) in flag(key).flatMap { Double($0) } }
    let times: [Double]
    if let at = flag("at") {
        times = at.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }.filter { $0 >= 0 && $0 <= seconds }
    } else if let step = number("every") {
        times = VideoFrames.every(step, from: number("from") ?? 0, to: number("to") ?? seconds, seconds: seconds)
        guard times.count <= 600 else { fail("zero: that's \(times.count) frames; take a shorter stretch, or a larger --every") }
    } else {
        times = VideoFrames.spread(Int(number("frames") ?? 12), over: seconds)
    }
    let out =
        flag("out").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            ".zero/video/\(video.deletingPathExtension().lastPathComponent)-\(Int(Date().timeIntervalSince1970))")
    print(
        "\(video.lastPathComponent): \(VideoFrames.stamp(seconds)) long, \(info.width)×\(info.height), \(String(format: "%.0f", info.fps)) fps"
    )
    do {
        for frame in try await VideoFrames.frames(of: video, at: times, into: out) {
            print("\(VideoFrames.stamp(frame.at))  \(frame.path)")
        }
    } catch { fail("zero: \(error.localizedDescription)") }
}
