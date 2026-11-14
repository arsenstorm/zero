import Foundation
import Testing
@testable import ZeroCore

/// New task opens on the model and effort last picked there, each CLI its own; nothing picked yet, the CLI's first.
@Test func newTaskKeepsEachCLIsLastModel() throws {
    let defaults = try #require(UserDefaults(suiteName: "zero-tests-new-task"))
    defaults.removePersistentDomain(forName: "zero-tests-new-task")
    #expect(NewTaskChoice.kept(for: .claude, in: defaults) == ("", ""), "nothing kept: the CLI's first")
    NewTaskChoice.keep(.claude, model: "opus", effort: "high", in: defaults)
    NewTaskChoice.keep(.codex, model: "gpt-5.5", effort: "", in: defaults)
    NewTaskChoice.keep(.claude, model: "claude-opus-4-8", effort: "max", in: defaults)
    #expect(NewTaskChoice.kept(for: .claude, in: defaults) == ("claude-opus-4-8", "max"), "the last pick")
    #expect(NewTaskChoice.kept(for: .codex, in: defaults) == ("gpt-5.5", ""), "each CLI its own")
    #expect(NewTaskChoice.kept(for: .opencode, in: defaults) == ("", ""))
}
