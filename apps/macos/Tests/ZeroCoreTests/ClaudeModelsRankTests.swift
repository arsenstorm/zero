import Foundation
import Testing
@testable import ZeroCore

@Test func claudeModelsRankVersionThenFamily() {
    let names = ["Haiku 5.5", "Fable 5", "Opus 5.5", "Fable 5.1 (1M)", "Fable 5.1", "Sonnet 5.5", "Mythos 5.1", "Daybreak Blue"]
    #expect(
        names.sorted { ClaudeModels.rank($0) < ClaudeModels.rank($1) }
            == ["Opus 5.5", "Sonnet 5.5", "Haiku 5.5", "Mythos 5.1", "Fable 5.1", "Fable 5.1 (1M)", "Fable 5", "Daybreak Blue"])
}

@Test func aModelIdReadsAsPeopleSayIt() {
    #expect(ModelNames.readable("claude-opus-5-5") == "Opus 5.5")
    #expect(ModelNames.readable("claude-fable-5-1[1m]") == "Fable 5.1 (1M)")
    #expect(ModelNames.readable("claude-sonnet-6") == "Sonnet 6")
    #expect(ModelNames.readable("opus") == "Opus")
    #expect(ModelNames.readable("gpt-5.5-codex") == "GPT-5.5 Codex")
    #expect(ModelNames.readable("gpt-5.5") == "GPT-5.5")
    #expect(ModelNames.readable("zai/glm-5.3") == "GLM-5.3", "OpenCode's: the provider dropped")
    #expect(ModelNames.readable("openrouter/moonshotai/kimi-k2") == "Kimi K2")
}

/// Each family is Claude Code's alias, named by the newest version of it a task has run; every version run (or typed)
/// is a choice of its own that stays on it, newest first. The one the alias runs now isn't listed twice.
@Test func claudeFamiliesAreNamedByTheVersionsTasksRan() {
    let used = ["claude-opus-5-1", "claude-sonnet-5-5", "claude-opus-5-5", "claude-fable-5-1[1m]", "claude-opus-5"]
    let choices = ClaudeModels.choices(used: used, extras: [SpawnChoice(id: "fable[1m]", name: "Fable 5.1 (1M)")])
    #expect(choices.prefix(4).map(\.id) == ["fable", "opus", "sonnet", "haiku"])
    #expect(choices.prefix(4).map(\.name) == ["Fable 5.1", "Opus 5.5", "Sonnet 5.5", "Haiku"], "the 1M variant names Fable too")
    #expect(choices[4].id == "fable[1m]", "Claude Code's own extras next")
    #expect(choices.dropFirst(5).map(\.id) == ["claude-fable-5-1[1m]", "claude-opus-5-1", "claude-opus-5"])
    #expect(choices[1].detail?.contains("latest Opus") == true)
    #expect(choices[5].detail?.contains("Stays on") == true)
}

/// A model typed in the picker is remembered, and listed from then on; aliases and blanks aren't.
@Test func aTypedClaudeModelIsRemembered() throws {
    let defaults = try #require(UserDefaults(suiteName: "zero-tests-claude-models"))
    defaults.removePersistentDomain(forName: "zero-tests-claude-models")
    ClaudeModels.remember(" claude-opus-5 ", typed: true, in: defaults)
    ClaudeModels.remember("opus", typed: true, in: defaults)
    ClaudeModels.remember("", typed: true, in: defaults)
    ClaudeModels.remember("claude-opus-5", typed: true, in: defaults)
    #expect(ClaudeModels.used(in: defaults, typed: true) == ["claude-opus-5"])
    #expect(ClaudeModels.used(in: defaults).isEmpty, "typed apart from what tasks ran")
    // Listed, but it doesn't name the family: Opus follows the latest, whatever was typed.
    let choices = ClaudeModels.choices(used: [], typed: ["claude-opus-5"], extras: [])
    #expect(choices[1].name == "Opus")
    #expect(choices.last?.id == "claude-opus-5")
}

/// A task carries the version Claude Code resolved ("claude-opus-5-5"): its row is the one with that id (a version
/// picked), else the alias now named by it (started on "opus", or "fable[1m]").
@Test func aTaskRunningAResolvedVersionShowsOnItsRow() {
    let choices = ClaudeModels.choices(
        used: ["claude-opus-5-5", "claude-opus-5-1", "claude-fable-5-1[1m]"],
        extras: [SpawnChoice(id: "fable[1m]", name: "Fable 5.1 (1M)")])
    #expect(ClaudeModels.row(for: "claude-opus-5-5", in: choices) == "opus")
    #expect(ClaudeModels.row(for: "claude-opus-5-1", in: choices) == "claude-opus-5-1")
    #expect(ClaudeModels.row(for: "claude-fable-5-1[1m]", in: choices) == "claude-fable-5-1[1m]", "a version of its own")
    #expect(ClaudeModels.row(for: "opus", in: choices) == "opus")
    #expect(ClaudeModels.row(for: "claude-sonnet-6", in: choices) == "claude-sonnet-6", "unknown: as it is")
    let fresh = ClaudeModels.choices(used: ["claude-fable-5-1[1m]"], extras: [SpawnChoice(id: "fable[1m]", name: "Fable 5.1 (1M)")])
    #expect(ClaudeModels.row(for: "claude-fable-5-1[1m]", in: fresh) == "claude-fable-5-1[1m]")
}
