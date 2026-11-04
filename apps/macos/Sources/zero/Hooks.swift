import Foundation
import ZeroCore

/// Prints a hook's JSON answer to Claude Code and exits 0.
func hookReply(_ object: [String: Any]) -> Never {
    if let data = try? JSONSerialization.data(withJSONObject: object) { FileHandle.standardOutput.write(data + Data("\n".utf8)) }
    exit(0)
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

/// Claude Code's PermissionRequest hook input on stdin; the user's answer goes back as the hook's decision. If Zero
/// can't be reached or the ask expires, nothing is printed and Claude Code's own permission flow carries on.
@MainActor func permissionCommand() {
    let hook = FileHandle.standardInput.readDataToEndOfFile()
    // Claude Code's own questions are answered by the question hook, as questions, not as a permission.
    if (((try? JSONSerialization.jsonObject(with: hook)) as? [String: Any])?["tool_name"] as? String) == "AskUserQuestion" { exit(0) }
    guard let ask = Ask.permission(hook: hook, agent: agentIdentity(), ttl: ttl) else { fail("zero: no permission request on stdin") }
    let suggestions = ((try? JSONSerialization.jsonObject(with: hook)) as? [String: Any])?["permission_suggestions"] as? [Any] ?? []
    create(ask) { done in permissionDecision(done, suggestions: suggestions) }
}

/// The permission ask's outcome as the hook's decision: allowed (always, with Claude Code's suggestions), denied, or none.
private func permissionDecision(_ done: Ask, suggestions: [Any]) -> Never {
    switch done.state {
    case .answered:
        var decision: [String: Any] = ["behavior": "allow"]
        if done.answer == "Always allow", !suggestions.isEmpty { decision["updatedPermissions"] = suggestions }
        hookReply(["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]])
    case .declined:
        hookReply(["hookSpecificOutput": ["hookEventName": "PermissionRequest",
                                          "decision": ["behavior": "deny", "message": "The user said no in Zero" + (reason(done).map { ": \($0)" } ?? "")]]])
    default:
        exit(0)
    }
}

/// Claude Code's PreToolUse hook input for its AskUserQuestion tool: each question becomes a Zero question,
/// and the answers go back as the tool's input, so its terminal picker never shows. Anything short of answers
/// for all of them prints nothing, and the picker shows in the terminal as usual.
@MainActor func questionCommand() {
    let hook = (try? JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile())) as? [String: Any] ?? [:]
    guard let input = hook["tool_input"] as? [String: Any], let questions = input["questions"] as? [[String: Any]], !questions.isEmpty else { exit(0) }
    var answers: [String: String] = [:]
    for item in questions {
        guard let question = item["question"] as? String else { exit(0) }
        let options = (item["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
        let several = item["multiSelect"] as? Bool == true
        var ask = Ask(kind: .choice, title: item["header"] as? String ?? question, body: question,
                      options: options + [several ? "Several, or something else…" : "Something else…"],
                      cwd: hook["cwd"] as? String, agent: agentIdentity(), ttl: ttl)
        ask.detail = optionDescriptions(item)
        guard let done = askAndWait(ask), done.state == .answered, let answer = done.answer else { exit(0) }
        answers[question] = options.contains(answer) ? answer : (reason(done) ?? answer)
    }
    var updated = input
    updated["answers"] = answers
    hookReply(["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "allow", "updatedInput": updated]])
}

/// A question's options that have a description, "label: description" a line; nil when none has.
private func optionDescriptions(_ item: [String: Any]) -> String? {
    let descriptions = (item["options"] as? [[String: Any]] ?? []).compactMap { option -> String? in
        guard let label = option["label"] as? String, let text = option["description"] as? String, !text.isEmpty else { return nil }
        return "\(label): \(text)"
    }
    return descriptions.isEmpty ? nil : descriptions.joined(separator: "\n")
}

/// The plugin's UserPromptSubmit hook. Works out who sent the prompt: a Solo timer or a background result
/// (machinery), Zero (an answer or a message from the inbox), the lead (a worker's brief), or the user typing in
/// the terminal. Records it for the stop hook and tells the agent how to treat the turn.
@MainActor func promptCommand() {
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
    let zeroSaid = ["The user answered your ask", "The user declined your ask", "The user ran your command", "The user rejected your command", "Your ask "]
        .contains { prompt.hasPrefix($0) }
    let brief = prompt.range(of: #"\b(BRIEF|FIX|REVIEW|TEST)[\w.-]*\.md\b"#, options: .regularExpression) != nil
    var source: String
    if previous == "worker" || brief { source = "worker" }
    // A timer, a background result or Zero's answer arriving while the user is in the chat (often mid-turn) doesn't
    // mean they left: within ten minutes of their last typed prompt the turn stays theirs. After that, Zero's rules again.
    else if machinery || zeroSaid { source = typedRecently ? "human" : "zero" }
    else { source = sourceZeroKnows(prompt, session: session) }
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let stamp = source == "human" && typedRecently && (machinery || zeroSaid) ? (saved?.dropFirst().first.map(String.init) ?? "") : String(Int(Date().timeIntervalSince1970))
    try? "\(source) \(stamp)".write(to: file, atomically: true, encoding: .utf8)
    let context: String? = switch source {
    case "human": "The user typed this in the terminal and is at the keyboard: answer them here in the chat. This turn needs no Zero note and no [zero: …] ending, and anything you'd ask them, ask here."
    case "worker": "You were started from a brief by a lead agent: report to that lead as the brief says, not to the user. Don't post Zero notes or asks and don't end turns with [zero: …]. Only use zero run, with --why, for a command only the user can run on their Mac."
    default: nil
    }
    guard let context else { exit(0) }
    hookReply(["hookSpecificOutput": ["hookEventName": "UserPromptSubmit", "additionalContext": context]])
}

/// Zero's own inbox messages look typed; Zero knows what it sent. Unknown without Zero: treat as typed.
@MainActor private func sourceZeroKnows(_ prompt: String, session: String) -> String {
    let socket = try? UnixSocket.connect(path: Paths.socket)
    var identity = agentIdentity()
    identity.session = session.isEmpty ? nil : session // so Zero can name the agent by its session's title
    try? socket?.send(Request(op: "prompt", ask: Ask(kind: .message, title: "Prompt", body: prompt, agent: identity)))
    return socket?.receive(Response.self)?.message ?? "human"
}
