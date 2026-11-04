import Testing
@testable import ZeroCore

@Test func openCodesOwnListIsItsModelsByProvider() {
    let listed = OpenCodeModels.parse("opencode-go/glm-5.3\ncliproxy-openai/gpt-5.6-sol\n\nnot a model line\n")
    #expect(listed.map(\.id) == ["opencode-go/glm-5.3", "cliproxy-openai/gpt-5.6-sol"], "the id OpenCode's own selector takes")
    #expect(listed.map(\.name) == ["glm-5.3", "gpt-5.6-sol"])
    #expect(listed.map(\.provider) == ["opencode-go", "cliproxy-openai"])
}
