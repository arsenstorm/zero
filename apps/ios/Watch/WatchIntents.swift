import AppIntents
import Foundation

// Zero to Siri on the watch: what needs you, how a task is doing, answering an ask, messaging a task, starting one.
// The same actions as the phone's (Siri.swift), done through the phone (WatchBridge), which reaches the Mac.

@MainActor private func model() async -> WatchModel {
    let model = WatchModel.shared
    model.start()
    return model
}

struct WatchTask: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Task"
    static let defaultQuery = WatchTaskQuery()
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct WatchTaskQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [WatchTask] {
        await model().state.tasks.filter { identifiers.contains($0.id) }.map { WatchTask(id: $0.id, name: $0.name) }
    }
    @MainActor func entities(matching string: String) async throws -> [WatchTask] {
        let words = string.lowercased().split(separator: " ").filter { !["the", "task", "zero", "in"].contains($0) }
        return try await suggestedEntities().filter { task in words.allSatisfy { task.name.lowercased().contains($0) } }
    }
    @MainActor func suggestedEntities() async throws -> [WatchTask] {
        await model().state.tasks.map { WatchTask(id: $0.id, name: $0.name) }
    }
}

struct WatchAsk: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Question"
    static let defaultQuery = WatchAskQuery()
    var id: String
    var title: String
    var from: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)", subtitle: "\(from)") }
}

struct WatchAskQuery: EntityQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [WatchAsk] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }
    @MainActor func suggestedEntities() async throws -> [WatchAsk] {
        await model().state.asks.map { WatchAsk(id: $0.id, title: $0.title, from: $0.from) }
    }
}

struct WatchProject: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Project"
    static let defaultQuery = WatchProjectQuery()
    var id: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\((id as NSString).lastPathComponent)") }
}

struct WatchProjectQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [WatchProject] { identifiers.map(WatchProject.init) }
    @MainActor func entities(matching string: String) async throws -> [WatchProject] {
        let said = string.lowercased()
        return try await suggestedEntities().filter { ($0.id as NSString).lastPathComponent.lowercased().contains(said) }
    }
    @MainActor func suggestedEntities() async throws -> [WatchProject] {
        ((await model().ask(["op": "projects"]))?["projects"] as? [String] ?? []).map(WatchProject.init)
    }
}

/// The phone's answer, or the reason it failed, said.
@MainActor private func done(_ message: [String: Any]) async throws -> [String: Any] {
    let model = await model()
    guard let reply = await model.ask(message) else { throw WatchSiriError(model.trouble ?? "Your iPhone didn't answer") }
    return reply
}

struct WatchSiriError: Error, CustomLocalizedStringResourceConvertible {
    let words: String
    init(_ words: String) { self.words = words }
    var localizedStringResource: LocalizedStringResource { "\(words)" }
}

struct WatchNeedsYouIntent: AppIntent {
    static let title: LocalizedStringResource = "What needs me"
    static let description = IntentDescription("The questions waiting on you in Zero.")

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = await model()
        await model.refresh()
        let asks = model.state.asks
        if asks.isEmpty { return .result(dialog: "Nothing needs you right now.") }
        let count = asks.count == 1 ? "One thing needs you" : "\(asks.count) things need you"
        let said = "\(count). " + asks.map { $0.from + ": " + $0.title }.joined(separator: ". ")
        return .result(dialog: IntentDialog(full: "\(said).", supporting: "\(count)"))
    }
}

struct WatchTaskStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "How a task is doing"
    @Parameter(title: "Task") var task: WatchTask

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = await model()
        await model.refresh()
        guard let found = model.state.tasks.first(where: { $0.id == task.id }) else { throw WatchSiriError("There's no such task") }
        let state = Look.of(found.state).name
        let said = "\(found.name) is \(state.lowercased())" + (found.line.map { ". " + $0 } ?? ".")
        return .result(dialog: IntentDialog(full: "\(said)", supporting: "\(state)"))
    }
}

struct WatchAnswerIntent: AppIntent {
    static let title: LocalizedStringResource = "Answer a question"
    @Parameter(title: "Question") var ask: WatchAsk?
    @Parameter(title: "Answer", requestValueDialog: "What's your answer?") var answer: String

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = await model()
        guard let id = ask?.id ?? model.state.asks.first?.id else { throw WatchSiriError("Nothing is waiting on you") }
        let reply = try await done(["op": "say", "ask": id, "text": answer])
        return .result(dialog: IntentDialog(full: "Answered: \(reply["said"] as? String ?? answer).", supporting: "Answered"))
    }
}

struct WatchMessageIntent: AppIntent {
    static let title: LocalizedStringResource = "Message a task"
    @Parameter(title: "Task") var task: WatchTask
    @Parameter(title: "Message", requestValueDialog: "What should I send?") var text: String

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try await done(["op": "send", "session": task.id, "text": text])
        return .result(dialog: IntentDialog(full: "Sent to \(task.name).", supporting: "Sent"))
    }
}

struct WatchStartTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a task"
    @Parameter(title: "What to do", requestValueDialog: "What should it do?") var prompt: String
    @Parameter(title: "Project", requestValueDialog: "In which project?") var project: WatchProject

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try await done(["op": "start", "text": prompt, "folder": project.id])
        return .result(dialog: IntentDialog(full: "Started it in \((project.id as NSString).lastPathComponent).", supporting: "Started"))
    }
}

struct WatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: WatchNeedsYouIntent(), phrases: ["What needs me in \(.applicationName)", "Anything need me in \(.applicationName)"],
            shortTitle: "What needs me", systemImageName: "hand.raised")
        AppShortcut(
            intent: WatchTaskStatusIntent(),
            phrases: ["How is \(\.$task) doing in \(.applicationName)", "Check on \(\.$task) in \(.applicationName)"],
            shortTitle: "Check a task", systemImageName: "checklist")
        AppShortcut(
            intent: WatchAnswerIntent(), phrases: ["Answer \(.applicationName)", "Answer a question in \(.applicationName)"],
            shortTitle: "Answer", systemImageName: "hand.raised")
        AppShortcut(
            intent: WatchMessageIntent(), phrases: ["Message \(\.$task) in \(.applicationName)", "Tell \(\.$task) in \(.applicationName)"],
            shortTitle: "Message a task", systemImageName: "bubble.left")
        AppShortcut(
            intent: WatchStartTaskIntent(),
            phrases: ["Start a task in \(.applicationName)", "Start a task in \(\.$project) in \(.applicationName)"],
            shortTitle: "Start a task", systemImageName: "plus.bubble")
    }
}
