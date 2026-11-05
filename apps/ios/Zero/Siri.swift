import AppIntents
import CoreSpotlight
import GeoToolbox
import LinkPresentation
import SwiftUI

// Zero to Siri (iOS 27's App Intents and App Schemas). A task is a conversation in the messages domain, its agent a
// person in it, its answers messages: "Tell Zero development to run the tests" sends the words, "Draft a message to
// SEC-TEAM" opens its composer with them. Then actions of Zero's own: what needs you, how a task is doing, opening one,
// saving it for later, pausing and resuming the agents. Each runs in the app, in the background where it can, through
// the tunnel to the Mac as the app's own words do: nothing here calls an AI service.

// MARK: Entities

/// A task, as Siri knows conversations.
@AppEntity(schema: .messages.conversation)
struct ZeroTask: IndexedEntity {
    static let defaultQuery = ZeroTaskQuery()
    var id: String
    var displayName: String
    var conversationName: String?
    var recipients: [ZeroAgent]
    var previewText: AttributedString
    var isRead: Bool
    var attributes: Set<ZeroConversationAttribute>
    var dateLastActive: Date?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)", subtitle: "\(String(previewText.characters))")
    }

    @MainActor init(_ row: BoardRow) {
        id = row.session
        displayName = row.task
        conversationName = row.task
        recipients = [ZeroAgent(row)]
        let look = StateGlyph.look(row.ownState)
        let now = row.needs ?? row.now
        previewText = AttributedString(look.name + (now.map { ": " + TaskAlerts.plain($0) } ?? ""))
        // Read unless it's waiting on you, or replied and not yet looked at.
        isRead = ![.needsYou, .answered, .handed].contains(row.ownState)
        attributes = []
        dateLastActive = nil
    }
}

struct ZeroTaskQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [ZeroTask] {
        _ = await PhoneModel.shared.ready()
        return PhoneModel.shared.rows.filter { identifiers.contains($0.session) }.map(ZeroTask.init)
    }

    /// By name: "SEC-TEAM", "the Zero development task".
    @MainActor func entities(matching string: String) async throws -> [ZeroTask] {
        _ = await PhoneModel.shared.ready()
        let words = string.lowercased().split(separator: " ").filter { !["the", "task", "zero", "in"].contains($0) }
        // Every workspace's tasks: Siri isn't on the phone's page.
        return PhoneModel.shared.rows.filter { row in words.allSatisfy { row.task.lowercased().contains($0) } }.map(ZeroTask.init)
    }

    /// As the Mac's sidebar lists them: the first are the likeliest.
    @MainActor func suggestedEntities() async throws -> [ZeroTask] {
        _ = await PhoneModel.shared.ready()
        return PhoneModel.shared.tasks.map(ZeroTask.init) + PhoneModel.shared.rows.filter { row in !PhoneModel.shared.tasks.contains { $0.session == row.session } }.map(ZeroTask.init)
    }
}

/// A task's agent, as the person on the other end of its conversation; "me" is the user.
@AppEntity(schema: .messages.messagePerson)
struct ZeroAgent {
    static let defaultQuery = ZeroAgentQuery()
    var id: String
    var person: IntentPerson

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    private var name: String { if case let .displayName(name) = person.name { name } else { "Agent" } }

    @MainActor init(_ row: BoardRow) {
        id = row.session
        person = IntentPerson(identifier: .applicationDefined(row.session), name: .displayName(row.task), handle: IntentPerson.Handle(applicationDefined: row.session))
    }

    init(me: Void) {
        id = "me"
        person = IntentPerson(identifier: .applicationDefined("me"), name: .displayName("You"), handle: nil, isMe: true)
    }
}

struct ZeroAgentQuery: EntityStringQuery {
    static let persistentIdentifier = "ZeroAgentQuery"
    @MainActor func entities(for identifiers: [String]) async throws -> [ZeroAgent] {
        _ = await PhoneModel.shared.ready()
        return identifiers.compactMap { id in
            id == "me" ? ZeroAgent(me: ()) : PhoneModel.shared.rows.first { $0.session == id }.map(ZeroAgent.init)
        }
    }

    /// "Zero development", "SEC-TEAM": the task's agent, by the task's name.
    @MainActor func entities(matching string: String) async throws -> [ZeroAgent] {
        return try await ZeroTaskQuery().entities(matching: string).compactMap { task in PhoneModel.shared.rows.first { $0.session == task.id }.map(ZeroAgent.init) }
    }

    @MainActor func suggestedEntities() async throws -> [ZeroAgent] {
        _ = await PhoneModel.shared.ready()
        return PhoneModel.shared.tasks.map(ZeroAgent.init)
    }
}

/// A message in a task: yours, or its agent's answer.
@AppEntity(schema: .messages.message)
struct ZeroMessage {
    static let defaultQuery = ZeroMessageQuery()
    var id: String
    var messageType: ZeroMessageType
    var author: ZeroAgent
    var isRead: Bool
    var attributes: Set<ZeroMessageAttribute>
    var conversation: ZeroTask
    var date: Date
    var subject: AttributedString?
    var body: AttributedString?
    var attachments: [IntentFile]
    var audioMessage: IntentFile?
    var customAttachments: [ZeroAttachment]
    var locations: [PlaceDescriptor]
    var links: [LinkMetadata]
    var messageEffect: ZeroMessageEffect?
    var reaction: ZeroReadReaction?
    var referencedMessage: ZeroMessage?
    var notificationIdentifier: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(conversation.displayName)", subtitle: "\(body.map { String($0.characters) } ?? "")")
    }

    @MainActor init(id: String, task: ZeroTask, author: ZeroAgent, text: String, date: Date) {
        self.id = id
        messageType = .unspecified
        self.author = author
        isRead = true
        attributes = []
        conversation = task
        self.date = date
        subject = nil
        body = AttributedString(TaskAlerts.plain(text, limit: 2000))
        attachments = []
        audioMessage = nil
        customAttachments = []
        locations = []
        links = []
        messageEffect = nil
        reaction = nil
        referencedMessage = nil
        notificationIdentifier = task.id
    }
}

struct ZeroMessageQuery: EntityQuery {
    static let persistentIdentifier = "ZeroMessageQuery"
    /// "<session>/<item>": the task's loaded items; "<session>/latest": its latest word, as its notification shows it
    /// (what a notification's "reply…" is to).
    @MainActor func entities(for identifiers: [String]) async throws -> [ZeroMessage] {
        _ = await PhoneModel.shared.ready()
        return identifiers.compactMap { id in
            let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, let row = PhoneModel.shared.rows.first(where: { $0.session == parts[0] }) else { return nil }
            if parts[1] == "latest" {
                let words = row.asks.first?.title ?? row.needs ?? row.now ?? StateGlyph.look(row.ownState).name
                return ZeroMessage(id: id, task: ZeroTask(row), author: ZeroAgent(row), text: words, date: Date())
            }
            guard let item = PhoneModel.shared.conversation(parts[0])?.items.first(where: { $0.id == parts[1] }) else { return nil }
            return ZeroMessage(item, in: row)
        }
    }
}

extension ZeroMessage {
    @MainActor init?(_ item: ConversationItem, in row: BoardRow) {
        let task = ZeroTask(row)
        switch item.kind {
        case let .agent(text, true): self.init(id: row.session + "/" + item.id, task: task, author: ZeroAgent(row), text: ZeroEnding.split(text).0, date: item.date ?? Date())
        case let .user(text, _) where ConversationItem.from(text) == nil: self.init(id: row.session + "/" + item.id, task: task, author: ZeroAgent(me: ()), text: text, date: item.date ?? Date())
        default: return nil
        }
    }
}

/// Messages here carry no attachments of their own kind; the schema asks for the type.
@AppEntity(schema: .messages.customAttachment)
struct ZeroAttachment {
    static let defaultQuery = ZeroAttachmentQuery()
    var id: String
    var sourceName: String?
    var description: String?
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(description ?? "Attachment")") }
}

struct ZeroAttachmentQuery: EntityQuery {
    static let persistentIdentifier = "ZeroAttachmentQuery"
    func entities(for identifiers: [String]) async throws -> [ZeroAttachment] { [] }
}

// MARK: The schema's enums and unions (Zero has no such attributes, effects or reactions: one placeholder case each)

@AppEnum(schema: .messages.conversationAttribute)
enum ZeroConversationAttribute: String {
    case none
    static let caseDisplayRepresentations: [ZeroConversationAttribute: DisplayRepresentation] = [.none: "None"]
}

@AppEnum(schema: .messages.messageAttribute)
enum ZeroMessageAttribute: String {
    case none
    static let caseDisplayRepresentations: [ZeroMessageAttribute: DisplayRepresentation] = [.none: "None"]
}

@AppEnum(schema: .messages.messageEffect)
enum ZeroMessageEffect: String {
    case none
    static let caseDisplayRepresentations: [ZeroMessageEffect: DisplayRepresentation] = [.none: "None"]
}

@AppEnum(schema: .messages.messageType)
enum ZeroMessageType: String {
    case unspecified
    static let caseDisplayRepresentations: [ZeroMessageType: DisplayRepresentation] = [.unspecified: "Message"]
}

@AppEnum(schema: .messages.customReaction)
enum ZeroCustomReaction: String {
    case none
    static let caseDisplayRepresentations: [ZeroCustomReaction: DisplayRepresentation] = [.none: "None"]
}

@UnionValue
enum ZeroReadReaction {
    case customReaction(ZeroCustomReaction)
    case attributedString(AttributedString)
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Reaction"
    static let caseDisplayRepresentations: [Cases: DisplayRepresentation] = [.customReaction: "Reaction", .attributedString: "Text"]
}

/// Who a message is for: a task's agent, named by its task ("Zero development"), as the person it's sent to.
@UnionValue
enum ZeroDestination {
    case people([IntentPerson])
    case messagePerson(ZeroAgent)
    case messagePeople([ZeroAgent])
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Recipients"
    static let caseDisplayRepresentations: [Cases: DisplayRepresentation] = [
        .people: "People", .messagePerson: "Task", .messagePeople: "Tasks"]

    /// The task it means.
    @MainActor var session: String? {
        switch self {
        case let .messagePerson(agent): return agent.id == "me" ? nil : agent.id
        case let .messagePeople(agents): return agents.first { $0.id != "me" }?.id
        case let .people(people):
            // A name Siri heard: the task whose name has it.
            for person in people {
                if case let .applicationDefined(id) = person.identifier, PhoneModel.shared.rows.contains(where: { $0.session == id }) { return id }
                if case let .displayName(name) = person.name, let row = PhoneModel.shared.rows.first(where: { $0.task.localizedCaseInsensitiveContains(name) }) { return row.session }
            }
            return nil
        }
    }
}

// MARK: Messages: send and draft

@AppIntent(schema: .messages.sendMessage)
struct SendToTaskIntent {
    var content: AttributedString?
    var destination: ZeroDestination
    var subject: AttributedString?
    var attachments: [IntentFile]
    var audioMessage: IntentFile?
    var locations: [PlaceDescriptor]
    var links: [URL]
    var scheduledDate: Date?

    @MainActor func perform() async throws -> some ReturnsValue<[ZeroMessage]> & ProvidesDialog {
        guard await PhoneModel.shared.ready() else { throw ZeroSiriError.offline }
        guard let session = destination.session, let row = PhoneModel.shared.rows.first(where: { $0.session == session }) else { throw ZeroSiriError.noTask }
        let words = [subject, content].compactMap { $0.map { String($0.characters) } }.joined(separator: "\n\n")
            + (links.isEmpty ? "" : "\n\n" + links.map(\.absoluteString).joined(separator: "\n"))
        let images = attachments.filter { $0.type?.conforms(to: .image) ?? false }.map(\.data)
        guard !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else { throw ZeroSiriError.nothingToSend }
        try await PhoneModel.shared.send(words, images: images, to: session)
        let sent = ZeroMessage(id: session + "/sent-" + UUID().uuidString, task: ZeroTask(row), author: ZeroAgent(me: ()), text: words, date: Date())
        return .result(value: [sent], dialog: IntentDialog(full: "Sent to \(row.task).", supporting: "Sent"))
    }
}

@AppIntent(schema: .messages.draftMessage)
struct DraftToTaskIntent {
    var content: AttributedString?
    var destination: ZeroDestination?
    var subject: AttributedString?
    var attachments: [IntentFile]
    var audioMessage: IntentFile?
    var locations: [PlaceDescriptor]
    var links: [URL]
    var scheduledDate: Date?

    @MainActor func perform() async throws -> some IntentResult {
        let model = PhoneModel.shared
        _ = await model.ready()
        guard let session = destination?.session else { throw ZeroSiriError.noTask }
        let words = [subject, content].compactMap { $0.map { String($0.characters) } }.joined(separator: "\n\n")
        if !words.isEmpty { model.drafts[session] = words }
        model.tab = .tasks
        model.path = [session]
        return .result()
    }
}

// MARK: Zero's own actions

/// "What needs me in Zero?": the tasks waiting on you, and the asks.
struct NeedsYouIntent: AppIntent {
    static let title: LocalizedStringResource = "What needs me"
    static let description = IntentDescription("The tasks and questions waiting on you in Zero.")

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = PhoneModel.shared
        guard await model.ready() else { throw ZeroSiriError.offline }
        let tasks = model.tasks.filter { $0.state == .needsYou }
        let asks = model.waiting.filter { ask in !tasks.contains { $0.session == ask.session } }
        if tasks.isEmpty && asks.isEmpty { return .result(dialog: IntentDialog(full: "Nothing needs you right now.", supporting: "Nothing needs you")) }
        var lines = tasks.map { row in row.task + (row.asks.first.map { ": " + TaskAlerts.plain($0.title, limit: 120) } ?? "") }
        lines += asks.map { TaskAlerts.plain($0.title, limit: 120) }
        let count = lines.count == 1 ? "One thing needs you" : "\(lines.count) things need you"
        let said = "\(count). " + lines.joined(separator: ". ") + "."
        return .result(dialog: IntentDialog(full: "\(said)", supporting: "\(count)"))
    }
}

/// "How is Zero development doing?": its state and where it is.
struct TaskStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "How a task is doing"
    static let description = IntentDescription("A Zero task's state and what it's doing now.")
    @Parameter(title: "Task") var task: ZeroTask

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = PhoneModel.shared
        guard await model.ready(), let row = model.rows.first(where: { $0.session == task.id }) else { throw ZeroSiriError.noTask }
        let state = StateGlyph.look(row.ownState).name
        let now = (row.needs ?? row.now).map { TaskAlerts.plain($0, limit: 300) }
        let said = "\(row.task) is \(state.lowercased())" + (now.map { ". " + $0 } ?? ".")
        return .result(dialog: IntentDialog(full: "\(said)", supporting: "\(state)"))
    }
}

/// Opens a task's conversation.
struct OpenTaskIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open task"
    @Parameter(title: "Task") var target: ZeroTask

    @MainActor func perform() async throws -> some IntentResult {
        PhoneModel.shared.tab = .tasks
        PhoneModel.shared.path = [target.id]
        return .result()
    }
}

/// Asks a task's agent to save what it has for later (it writes the note and the artifact).
struct SaveForLaterIntent: AppIntent {
    static let title: LocalizedStringResource = "Save a task for later"
    static let description = IntentDescription("Asks the task's agent to write down what's left, in Zero's Later.")
    @Parameter(title: "Task") var task: ZeroTask

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard await PhoneModel.shared.ready() else { throw ZeroSiriError.offline }
        await PhoneModel.shared.askToSaveForLater(task.id)
        return .result(dialog: IntentDialog(full: "Asked \(task.displayName) to save it for later.", supporting: "Saving for later"))
    }
}

/// Puts every task on hold with its workers (each wraps up first), as `zero pause` does.
struct PauseAgentsIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause my agents"
    static let description = IntentDescription("Every Zero task and its workers finish the step they're on and stop, until you resume them.")

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard await PhoneModel.shared.ready() else { throw ZeroSiriError.offline }
        try await requestConfirmation(dialog: "Pause every task and its workers?")
        // Zero waits for each to wrap up (minutes): asked, and answered now.
        Task { _ = await PhoneModel.shared.pause() }
        return .result(dialog: IntentDialog(full: "Pausing your agents. Each finishes the step it's on, then stops.", supporting: "Pausing"))
    }
}

struct ResumeAgentsIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume my agents"
    static let description = IntentDescription("Takes Zero's tasks off hold; those with words waiting carry on.")

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard await PhoneModel.shared.ready() else { throw ZeroSiriError.offline }
        let resumed = await PhoneModel.shared.unpause()
        let count = resumed.isEmpty ? "Nothing was paused" : resumed.count == 1 ? "Resumed one task" : "Resumed \(resumed.count) tasks"
        return .result(dialog: IntentDialog(full: "\(count).", supporting: "\(count)"))
    }
}

enum ZeroSiriError: Error, CustomLocalizedStringResourceConvertible {
    case offline, noTask, nothingToSend
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .offline: "Zero can't reach your Mac. Zero needs to be open there."
        case .noTask: "There's no Zero task by that name."
        case .nothingToSend: "There's nothing to send."
        }
    }
}

// MARK: Phrases

struct ZeroShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: NeedsYouIntent(), phrases: [
            "What needs me in \(.applicationName)", "What's waiting for me in \(.applicationName)", "Anything need me in \(.applicationName)",
        ], shortTitle: "What needs me", systemImageName: "hand.raised")
        AppShortcut(intent: TaskStatusIntent(), phrases: [
            "How is \(\.$task) doing in \(.applicationName)", "What's \(\.$task) doing in \(.applicationName)", "Check on \(\.$task) in \(.applicationName)",
        ], shortTitle: "Check a task", systemImageName: "checklist")
        AppShortcut(intent: OpenTaskIntent(), phrases: ["Open \(\.$target) in \(.applicationName)"], shortTitle: "Open a task", systemImageName: "bubble.left")
        AppShortcut(intent: SaveForLaterIntent(), phrases: ["Save \(\.$task) for later in \(.applicationName)"], shortTitle: "Save for later", systemImageName: "bookmark")
        AppShortcut(intent: PauseAgentsIntent(), phrases: ["Pause my agents in \(.applicationName)", "Pause \(.applicationName)"], shortTitle: "Pause agents", systemImageName: "pause.circle")
        AppShortcut(intent: ResumeAgentsIntent(), phrases: ["Resume my agents in \(.applicationName)", "Unpause \(.applicationName)"], shortTitle: "Resume agents", systemImageName: "play.circle")
    }
}

// MARK: Spotlight and Siri's index

/// The tasks in the system's index (Spotlight, and Siri's search by meaning), kept as the board changes: indexed
/// when their names or states change, taken out when they leave the board.
@MainActor enum ZeroIndex {
    private static var indexed: [String: String] = [:]

    static func update(_ rows: [BoardRow]) {
        let now = Dictionary(rows.map { ($0.session, $0.task + "|" + $0.ownState.rawValue + "|" + ($0.needs ?? $0.now ?? "")) }, uniquingKeysWith: { a, _ in a })
        guard now != indexed else { return }
        let changed = rows.filter { indexed[$0.session] != now[$0.session] }.map(ZeroTask.init)
        let gone = indexed.keys.filter { now[$0] == nil }
        indexed = now
        Task {
            let index = CSSearchableIndex.default()
            if !changed.isEmpty { try? await index.indexAppEntities(changed) }
            if !gone.isEmpty { try? await index.deleteAppEntities(identifiedBy: Array(gone), ofType: ZeroTask.self) }
        }
    }
}
