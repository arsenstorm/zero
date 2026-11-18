import Foundation
import Testing
@testable import ZeroCore

/// New task opens on the model, effort and advisor last picked there, each CLI its own; nothing picked yet, Claude's
/// Opus with Fable as its advisor, the other CLIs' first model.
@Test func newTaskKeepsEachCLIsLastModel() throws {
    let defaults = try #require(UserDefaults(suiteName: "zero-tests-new-task"))
    defaults.removePersistentDomain(forName: "zero-tests-new-task")
    #expect(NewTaskChoice.kept(for: .claude, in: defaults) == ("opus", "", "fable"), "nothing kept: Opus advised by Fable")
    #expect(NewTaskChoice.kept(for: .codex, in: defaults) == ("", "", ""), "nothing kept: the CLI's first")
    NewTaskChoice.keep(.claude, model: "", effort: "", in: defaults)
    #expect(NewTaskChoice.kept(for: .claude, in: defaults) == ("", "", ""), "a choice kept wins, even the CLI's first")
    NewTaskChoice.keep(.claude, model: "opus", effort: "high", in: defaults)
    NewTaskChoice.keep(.codex, model: "gpt-5.5", effort: "", in: defaults)
    NewTaskChoice.keep(.claude, model: "claude-opus-4-8", effort: "max", advisor: "fable", in: defaults)
    #expect(NewTaskChoice.kept(for: .claude, in: defaults) == ("claude-opus-4-8", "max", "fable"), "the last pick")
    #expect(NewTaskChoice.kept(for: .codex, in: defaults) == ("gpt-5.5", "", ""), "each CLI its own")
    #expect(NewTaskChoice.kept(for: .opencode, in: defaults) == ("", "", ""))
}

/// New task opens on the permissions last picked for the CLI, each its own; Auto at first, and for anything kept that
/// isn't a permission Zero has (zerod maps both of Zero's onto each CLI's own: Claude's bypassPermissions, Codex's
/// full access, OpenCode's asks allowed).
@Test func newTaskKeepsEachCLIsLastPermissions() throws {
    let defaults = try #require(UserDefaults(suiteName: "zero-tests-new-task-permissions"))
    defaults.removePersistentDomain(forName: "zero-tests-new-task-permissions")
    #expect(Provider.allCases.allSatisfy { NewTaskChoice.permissions(for: $0, in: defaults) == .auto }, "nothing kept: Auto")
    NewTaskChoice.keep(.claude, permissions: .unrestricted, in: defaults)
    #expect(NewTaskChoice.permissions(for: .claude, in: defaults) == .unrestricted, "the last pick")
    #expect(NewTaskChoice.permissions(for: .codex, in: defaults) == .auto, "each CLI its own")
    NewTaskChoice.keep(.codex, permissions: .unrestricted, in: defaults)
    NewTaskChoice.keep(.claude, permissions: .auto, in: defaults)
    #expect(NewTaskChoice.permissions(for: .claude, in: defaults) == .auto)
    #expect(NewTaskChoice.permissions(for: .codex, in: defaults) == .unrestricted)
    NewTaskChoice.keep(.claude, model: "opus", effort: "high", in: defaults)
    #expect(NewTaskChoice.permissions(for: .codex, in: defaults) == .unrestricted, "kept apart from the model")
    defaults.set(["opencode": "bypassPermissions"], forKey: "newTaskPermissions")
    #expect(NewTaskChoice.permissions(for: .opencode, in: defaults) == .auto, "one Zero doesn't have: Auto")
}

/// The advisors a Claude model can have: Claude Code's (`/advisor`), each at least as capable as the model.
@Test func aClaudeModelsAdvisorsAreAtLeastAsCapable() {
    let ids = { (model: String) in ClaudeModels.advisors(for: model).map(\.id) }
    #expect(ids("claude-opus-5-5") == ["fable", "opus"])
    #expect(ids("opus") == ["fable", "opus"])
    #expect(ids("claude-sonnet-5-5") == ["fable", "opus", "sonnet"])
    #expect(ids("haiku") == ["fable", "opus", "sonnet"])
    #expect(ids("claude-fable-5-2[1m]") == ["fable"])
    #expect(ids("claude-mythos-5-2") == ["fable"])
    #expect(ids("gpt-5.5").isEmpty, "not a Claude model")
    #expect(ClaudeModels.advisors(for: "sonnet").first?.name == "Fable")
}

@Test func anAdvisedAgentReadsAsBothModels() {
    #expect(ModelNames.agent("Opus 5.5", effort: "High", advisor: "fable") == "Opus 5.5 + Fable", "its effort is in the selector")
    #expect(ModelNames.agent("Opus 5.5", effort: "High", advisor: nil) == "Opus 5.5 · High")
    #expect(ModelNames.agent("Opus 5.5", effort: nil, advisor: "") == "Opus 5.5")
}

@Test func anAdvisorCallReadsAsAskingIt() {
    #expect(ToolNames.name("advisor") == "Asked its advisor")
}

/// A step about a web page names it as a link its line opens; a step with none has no link.
@Test func aStepAboutAWebPageLinksIt() {
    #expect(ToolNames.link(#"{"url":"https://nginx.org/en/security_advisories.html","prompt":"list them"}"#)?.host == "nginx.org")
    #expect(ToolNames.link(#"{"file_path":"/tmp/a","pattern":"http"}"#) == nil)
    #expect(ToolNames.link("not json") == nil)
}
