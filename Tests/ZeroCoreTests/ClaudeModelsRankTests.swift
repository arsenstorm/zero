import Testing
@testable import ZeroCore

@Test func claudeModelsRankFamilyThenVersion() {
    let names = ["Haiku 5.5", "Fable 5", "Opus 5.5", "Fable 5.1", "Sonnet 5.5", "Mythos 5.1", "Daybreak Blue"]
    #expect(names.sorted { ClaudeModels.rank($0) < ClaudeModels.rank($1) }
            == ["Mythos 5.1", "Fable 5.1", "Fable 5", "Opus 5.5", "Sonnet 5.5", "Haiku 5.5", "Daybreak Blue"])
}
