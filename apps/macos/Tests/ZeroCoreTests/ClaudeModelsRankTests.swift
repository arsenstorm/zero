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
