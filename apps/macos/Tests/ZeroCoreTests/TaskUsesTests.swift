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

/// What a task left running as zerod sends it (left.rs): its things, and what they hold together.
@Test func leftRunningReadsAsZerodSendsIt() throws {
    let json =
        #"{"task":"Site","archived":true,"settled":true,"things":[{"id":"p1-2","kind":"process","name":"node astro dev","since":1000,"memory":300000000,"cpu":0.5},{"id":"simulator-A","kind":"simulator","name":"iPhone 18 Pro","since":2000,"memory":2000000000,"cpu":0.0}]}"#
    let left = try JSONDecoder().decode(LeftRunning.self, from: Data(json.utf8))
    #expect(left.things.map(\.kind) == [.process, .simulator])
    #expect(left.memory == 2_300_000_000)
    #expect(left.settled && left.archived)
}
