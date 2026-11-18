import Testing
@testable import ZeroCore

/// desktop_key's chords, as an agent writes them.
@Test func chordsBecomeAKeyCodeAndModifiers() throws {
    let save = try DesktopKeys.chord("cmd+s").get()
    #expect(save.code == 1 && save.flags == DesktopKeys.command)
    let palette = try DesktopKeys.chord("Cmd+Shift+P").get()
    #expect(palette.code == 35 && palette.flags == DesktopKeys.command | DesktopKeys.shift)
    #expect(try DesktopKeys.chord("return").get().code == 36)
    #expect(try DesktopKeys.chord("f12").get().code == 111)
    let zoom = try DesktopKeys.chord("cmd++").get()
    #expect(zoom.code == 24 && zoom.flags == DesktopKeys.command | DesktopKeys.shift, "plus is shift and =")
    #expect(throws: DesktopKeys.ChordError(part: "hyper")) { try DesktopKeys.chord("hyper+k").get() }
    #expect(throws: DesktopKeys.ChordError(part: "launch")) { try DesktopKeys.chord("launch").get() }
}

/// desktop_read: what an agent can act on, with refs, and the text around it; the rest only when it asks for all.
@Test func aTreeReadsAsLinesWithRefs() {
    let window = DesktopNode(
        id: 0, role: "AXWindow", subrole: "AXStandardWindow", title: "Notes", frame: (0, 0, 800, 600),
        children: [
            DesktopNode(
                id: 1, role: "AXGroup",
                children: [
                    DesktopNode(id: 2, role: "AXStaticText", value: "Today", frame: (10, 40, 100, 20)),
                    DesktopNode(id: 3, role: "AXButton", title: "New Note", frame: (700, 10, 28, 28), actions: ["AXPress"]),
                    DesktopNode(
                        id: 4, role: "AXTextArea", value: "line one\nline two", frame: (200, 60, 580, 500), settable: true, focused: true),
                    DesktopNode(id: 5, role: "AXButton", title: "Share", frame: (740, 10, 28, 28), actions: ["AXPress"], enabled: false),
                ])
        ])
    #expect(
        window.lines() == """
            text "Today" 10,40 100x20
            [e3] button "New Note" 700,10 28x28
            [e4] text area = "line one⏎line two" 200,60 580x500 (focused)
            [e5] button "Share" 740,10 28x28 (disabled)
            """)
    #expect(window.lines(all: true).hasPrefix("[e0] window \"Notes\" 0,0 800x600\n[e1] group 0,0 0x0\n"))
    #expect(window.lines(limit: 2).hasSuffix("… 2 more: read one element's part of the tree with ref"))
    #expect(DesktopNode(id: 9, role: "AXTextField", subrole: "AXSearchField", settable: true).lines().hasPrefix("[e9] search field"))
}

@Test func aChangeSaysWhatMovedOrNothing() {
    #expect(
        DesktopChange.said(["selection": "0+0", "window": "10,10"], ["selection": "3+12", "window": "10,10"]) == "selection 0+0 → 3+12")
    #expect(DesktopChange.said(["scroll": "0.00"], ["scroll": "0.00"]) == nil)
    #expect(DesktopChange.said([:], ["value": "5"]) == "value none → 5")
}

/// A save sheet's controls come from another process, often with no actions listed: still refs to act on.
@Test func anotherProcesssControlsInAWindowGetRefs() {
    let sheet = DesktopNode(
        id: 1, role: "AXSheet", children: [DesktopNode(id: 2, role: "AXButton", title: "Save"), DesktopNode(id: 3, role: "AXGroup")])
    #expect(sheet.lines() == "[e2] button \"Save\" 0,0 0x0")
}
