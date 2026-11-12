import Foundation
import Testing
@testable import ZeroCore

/// What a task uses as zerod sends it (uses.rs): its parts, and their totals for the pane.
@Test func usesReadAsZerodSendsThemAndAddUp() throws {
    let json = #"{"cli":{"memory":250000000,"cpu":1.5},"mcp":{"memory":300000000,"cpu":0.0},"commands":{"memory":700000000,"cpu":12.5}}"#
    let uses = try JSONDecoder().decode(TaskUses.self, from: Data(json.utf8))
    #expect(uses.memory == 1_250_000_000)
    #expect(uses.cpu == 14)
}
