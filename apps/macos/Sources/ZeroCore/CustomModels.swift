import Foundation
import Observation

/// Models the user added to Zero for a CLI, Zero-wide (zerod's settings): one its own list doesn't have yet, by the id
/// the CLI is started with. The pickers list them with the CLI's own, on the Mac and the phone.
@MainActor @Observable public final class CustomModels {
    public struct Model: Codable, Equatable, Sendable, Identifiable {
        public var cli: Provider
        public var id: String
        public var name: String
        public init(cli: Provider, id: String, name: String) { self.cli = cli; self.id = id; self.name = name }
    }

    public static let shared = CustomModels()
    public internal(set) var models: [Model] = []
    init() {}

    /// Read from zerod: at launch and as Settings opens.
    public func load() async {
        guard let link = try? ZerodLink(), let kept = try? await link.customModels() else { return }
        if kept != models { models = kept }
    }

    public func add(_ model: Model) async {
        await save(models.filter { !($0.cli == model.cli && $0.id == model.id) } + [model])
    }

    public func remove(_ model: Model) async { await save(models.filter { $0 != model }) }

    private func save(_ list: [Model]) async {
        models = list
        try? await (try? ZerodLink())?.setCustomModels(list)
    }

    /// A CLI's list with the user's models added: after its own, each with that CLI's effort levels; one the CLI
    /// lists itself isn't added twice.
    public func adding(to own: [SpawnChoice], for cli: Provider) -> [SpawnChoice] {
        let levels = cli == .claude ? ClaudeModels.levels : []
        let added = models.filter { $0.cli == cli && !own.map(\.id).contains($0.id) }.map { model in
            SpawnChoice(
                id: model.id, name: model.name, detail: "Added in Zero · \(model.id)", icon: cli == .claude ? "claude" : nil,
                provider: cli == .claude ? "Anthropic" : nil, levels: levels, defaultLevel: cli == .claude ? "high" : nil)
        }
        return own + added
    }
}
