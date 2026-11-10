import Testing
@testable import ZeroCore

@MainActor @Test func addedModelsFollowTheCLIsOwnOnce() {
    let store = CustomModels()
    store.models = [
        CustomModels.Model(cli: .claude, id: "claude-mythos-5-2", name: "Mythos 5.2"),
        CustomModels.Model(cli: .claude, id: "claude-opus-5-5", name: "Opus 5.5"),
        CustomModels.Model(cli: .codex, id: "gpt-6", name: "GPT-6"),
    ]
    let own = [SpawnChoice(id: "claude-opus-5-5", name: "Opus 5.5")]
    let listed = store.adding(to: own, for: .claude)
    #expect(listed.map(\.id) == ["claude-opus-5-5", "claude-mythos-5-2"])
    #expect(listed.last?.name == "Mythos 5.2" && !(listed.last?.levels.isEmpty ?? true))
    #expect(store.adding(to: [], for: .codex).map(\.id) == ["gpt-6"])
}
