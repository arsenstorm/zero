import AppKit
import Testing
import ZeroBrowserHost

/// Zero Browser's page tree as VoiceOver hears it, from Chromium's updates as Chromium sends them.
@MainActor struct PageAccessibilityTests {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [], backing: .buffered, defer: true)
    let tree = ZBAXTree()

    init() {
        tree.view = window.contentView
    }

    static let page = "P"
    static let frame = "F"

    /// The page: a live region (with `live` as its text, if any) and an iframe.
    static func page(live: String?, clear: Bool = false, events: String = "[]") -> String {
        let text = live.map { #",{"id":5,"role":"staticText","attributes":{"name":"\#($0)","containerLiveStatus":"polite"}}"# } ?? ""
        let kids = live == nil ? "" : "5"
        return #"""
            {"ax_tree_id":"P","events":\#(events),"updates":[{\#(clear ? #""node_id_to_clear":1,"# : "")"has_tree_data":true,"tree_data":{"focus_id":1},"root_id":1,"nodes":[
            {"id":1,"role":"rootWebArea","child_ids":[2,3]},
            {"id":2,"role":"genericContainer","child_ids":[\#(kids)],"attributes":{"liveStatus":"polite","containerLiveStatus":"polite"}},
            {"id":3,"role":"iframe","attributes":{"childTreeId":"F"}}\#(text)]}]}
            """#
    }
    static let frameDoc = #"""
        {"ax_tree_id":"F","updates":[{"has_tree_data":true,"tree_data":{"parent_tree_id":"P","focus_id":1},"root_id":1,"nodes":[
        {"id":1,"role":"rootWebArea","child_ids":[2]},{"id":2,"role":"heading","attributes":{"name":"In frame","hierarchicalLevel":3}}]}]}
        """#

    func announcements(_ apply: () -> Void) -> [String] {
        var said: [String] = []
        tree.posted = { _, name, info in
            if name == NSAccessibility.Notification.announcementRequested.rawValue,
                let text = info?[NSAccessibility.NotificationUserInfoKey.announcement] as? String
            {
                said.append(text)
            }
        }
        apply()
        return said
    }

    @Test func liveTextIsSaidOnceWhenItComesNotWhenChromiumSendsItAgain() {
        #expect(announcements { tree.apply(Self.page(live: nil, events: #"[{"event_type":"loadComplete","id":1}]"#)) } == [])
        #expect(announcements { tree.apply(Self.page(live: "Saved")) } == ["Saved"])
        #expect(announcements { tree.apply(Self.page(live: "Saved", clear: true)) } == [])
        #expect(announcements { tree.apply(Self.page(live: "Done", clear: true)) } == ["Done"])
    }

    @Test func aHiddenPageSaysNothing() {
        tree.apply(Self.page(live: nil))
        window.contentView?.isHidden = true
        #expect(announcements { tree.apply(Self.page(live: "Saved")) } == [])
    }

    @Test func anIframesDocumentIsTheIframesChildWhicheverComesFirstAndAfterAResend() {
        tree.apply(Self.frameDoc)
        tree.apply(Self.page(live: nil))
        func frameRoot() -> ZBAXNode? {
            (tree.root?.accessibilityChildren()?.last as? ZBAXNode)?.accessibilityChildren()?.first as? ZBAXNode
        }
        let iframe = tree.root?.accessibilityChildren()?.last as? ZBAXNode
        #expect(iframe?.accessibilityRole() == .group)
        #expect(frameRoot()?.accessibilityParent() as? ZBAXNode === iframe)
        tree.apply(Self.page(live: nil, clear: true))
        let again = tree.root?.accessibilityChildren()?.last as? ZBAXNode
        #expect(again !== iframe)
        #expect(frameRoot()?.accessibilityParent() as? ZBAXNode === again)
        let found =
            tree.root?.accessibilityAttributeValue(
                .init(rawValue: "AXUIElementsForSearchPredicate"), forParameter: ["AXSearchKey": "AXHeadingSearchKey"]) as? [ZBAXNode]
        #expect(found?.map { $0.accessibilityLabel() } == ["In frame"])
    }
}
