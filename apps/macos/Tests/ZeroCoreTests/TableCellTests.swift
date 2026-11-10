import Testing
@testable import ZeroCore

@Test func tableCellsReadAsRiskStateEmptyOrText() {
    #expect(
        TableCell.of("medium. No dry run for the backfill", column: "Merge risk")
            == .risk(level: "medium", gaps: "No dry run for the backfill"))
    #expect(TableCell.of("Merge risk: high", column: "Risk") == .risk(level: "high", gaps: ""))
    // A risk word outside a risk column is words; a risk column's other words are too.
    #expect(TableCell.of("high", column: "Priority") == .text("high"))
    #expect(TableCell.of("unknown", column: "Risk") == .text("unknown"))
    #expect(TableCell.of("Done", column: "State") == .state(.done))
    #expect(TableCell.of("in trouble", column: "Risk") == .state(.trouble))
    for dash in ["", "-", "—", "–"] { #expect(TableCell.of(dash, column: "Notes") == .empty) }
    #expect(TableCell.of("`make test` passes", column: "Notes") == .text("`make test` passes"))
}
