import Foundation

/// The desktop tools' parts that need no app to run (ZeroApp's Desktop.swift does the rest): a chord's key code and
/// modifiers, and an accessibility tree as the lines an agent reads, each element it can act on with a ref.
public enum DesktopKeys {
    /// CGEventFlags' raw values (CoreGraphics' own, spelled out so this stays free of it).
    public static let shift: UInt64 = 0x20000, control: UInt64 = 0x40000, option: UInt64 = 0x80000, command: UInt64 = 0x100000

    /// Virtual key codes of the US layout's keys, as the Mac numbers them.
    static let codes: [String: UInt16] = {
        var codes: [String: UInt16] = [
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
            "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
            "left": 123, "right": 124, "down": 125, "up": 126,
            "-": 27, "=": 24, "[": 33, "]": 30, "\\": 42, ";": 41, "'": 39, ",": 43, ".": 47, "/": 44, "`": 50,
        ]
        for (key, code) in zip("asdfhgzxcv", [0, 1, 2, 3, 4, 5, 6, 7, 8, 9] as [UInt16]) { codes[String(key)] = code }
        for (key, code) in zip("bqweryt", [11, 12, 13, 14, 15, 16, 17] as [UInt16]) { codes[String(key)] = code }
        for (key, code) in zip("oupilj", [31, 32, 35, 34, 37, 38] as [UInt16]) { codes[String(key)] = code }
        for (key, code) in zip("knm", [40, 45, 46] as [UInt16]) { codes[String(key)] = code }
        for (key, code) in zip("1234567890", [18, 19, 20, 21, 23, 22, 26, 28, 25, 29] as [UInt16]) { codes[String(key)] = code }
        for (n, code) in [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111].enumerated() { codes["f\(n + 1)"] = UInt16(code) }
        return codes
    }()

    /// "cmd+shift+p" as its key code and modifiers; nil with the part it doesn't know.
    public static func chord(_ text: String) -> Result<(code: UInt16, flags: UInt64), ChordError> {
        // "+" alone, or a chord ending in it ("cmd++"), is the plus key's own: shift and =.
        var parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
        var flags: UInt64 = 0
        if text.hasSuffix("+") && (text == "+" || text.hasSuffix("++")) {
            parts.append("=")
            flags |= shift
        }
        guard let key = parts.popLast() else { return .failure(ChordError(part: text)) }
        for part in parts {
            switch part {
            case "cmd", "command", "⌘", "meta", "super": flags |= command
            case "shift", "⇧": flags |= shift
            case "ctrl", "control", "⌃": flags |= control
            case "alt", "opt", "option", "⌥": flags |= option
            default: return .failure(ChordError(part: part))
            }
        }
        guard let code = codes[key] else { return .failure(ChordError(part: key)) }
        return .success((code, flags))
    }

    public struct ChordError: Error, Equatable {
        public let part: String
        public var message: String { "No key \"\(part)\": use names like cmd, shift, ctrl, option, return, escape, tab, up, f5" }
    }
}

/// An app window's accessibility tree, built by the app from AX elements: `id` is how it finds each one again.
public struct DesktopNode: Equatable {
    public var id: Int
    public var role: String
    public var subrole: String?
    public var title: String?
    public var value: String?
    /// Left, top, width and height, in points from the window's top-left corner.
    public var frame: (x: Int, y: Int, width: Int, height: Int)
    public var actions: [String]
    public var settable: Bool
    public var enabled: Bool
    public var focused: Bool
    public var children: [DesktopNode]

    public init(
        id: Int, role: String, subrole: String? = nil, title: String? = nil, value: String? = nil,
        frame: (Int, Int, Int, Int) = (0, 0, 0, 0),
        actions: [String] = [], settable: Bool = false, enabled: Bool = true, focused: Bool = false, children: [DesktopNode] = []
    ) {
        self.id = id; self.role = role; self.subrole = subrole; self.title = title; self.value = value
        self.frame = (frame.0, frame.1, frame.2, frame.3)
        self.actions = actions; self.settable = settable; self.enabled = enabled; self.focused = focused; self.children = children
    }

    public static func == (a: DesktopNode, b: DesktopNode) -> Bool {
        a.id == b.id && a.role == b.role && a.subrole == b.subrole && a.title == b.title && a.value == b.value && a.frame == b.frame
            && a.actions == b.actions && a.settable == b.settable && a.enabled == b.enabled && a.focused == b.focused
            && a.children == b.children
    }

    static let acting: Set<String> = ["AXPress", "AXShowMenu", "AXConfirm", "AXPick", "AXIncrement", "AXDecrement", "AXOpen"]
    static let texts: Set<String> = ["AXStaticText", "AXHeading"]

    /// Controls by their role: another process's elements in a window (a save sheet, from its panel service) often
    /// list no actions, though AXPress works on them.
    static let controls: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXComboBox", "AXTextField", "AXTextArea",
        "AXSearchField", "AXLink", "AXSlider", "AXDisclosureTriangle", "AXIncrementor",
    ]

    /// Something an agent can act on: it has an action, or a value it can set, or it's a control.
    public var interactive: Bool { settable || actions.contains { Self.acting.contains($0) } || Self.controls.contains(role) }

    /// The tree as lines: each interactive element with a ref (`e` and its id), and the text between them; with `all`,
    /// every element. At most `limit` lines, then how many more.
    public func lines(all: Bool = false, limit: Int = 800) -> String {
        var out: [String] = [], more = 0
        func walk(_ node: DesktopNode) {
            let shown = all || node.interactive || (Self.texts.contains(node.role) && !(node.value ?? node.title ?? "").isEmpty)
            if shown {
                if out.count < limit { out.append(node.line) } else { more += 1 }
            }
            node.children.forEach(walk)
        }
        walk(self)
        if more > 0 { out.append("… \(more) more: read one element's part of the tree with ref") }
        return out.joined(separator: "\n")
    }

    var line: String {
        let kind = (subrole.flatMap { $0 == "AXStandardWindow" ? nil : $0 } ?? role).dropFirst(2).reduce(into: "") { name, c in
            name += c.isUppercase && !name.isEmpty ? " " + c.lowercased() : c.lowercased()
        }
        let clip = { (text: String) in text.count > 80 ? String(text.prefix(79)) + "…" : text }
        let text = Self.texts.contains(role) && !interactive
        // Text reads as itself ("text \"Today\""); anything else as its kind, its name, then its value.
        let (name, shown) = text ? (value ?? title, nil) : (title, value == title ? nil : value)
        var line = text ? (role == "AXHeading" ? "heading" : "text") : "[e\(id)] \(kind)"
        if let name, !name.isEmpty { line += " \"\(clip(name.replacingOccurrences(of: "\n", with: " ")))\"" }
        if let shown, !shown.isEmpty { line += " = \"\(clip(shown.replacingOccurrences(of: "\n", with: "⏎")))\"" }
        line += " \(frame.x),\(frame.y) \(frame.width)x\(frame.height)"
        if !enabled { line += " (disabled)" }
        if focused { line += " (focused)" }
        return line
    }

    /// The node with this id, anywhere under this one.
    public func find(_ id: Int) -> DesktopNode? {
        if self.id == id { return self }
        for child in children { if let found = child.find(id) { return found } }
        return nil
    }
}

/// What an action changed, as accessibility shows it before and after (the selection, a value, the scroll, the window's
/// place): the result proves it did something, or says it can't tell.
public enum DesktopChange {
    public static func said(_ before: [String: String], _ after: [String: String]) -> String? {
        let changed = Set(before.keys).union(after.keys).sorted().filter { before[$0] != after[$0] }
        return changed.isEmpty ? nil : changed.map { "\($0) \(before[$0] ?? "none") → \(after[$0] ?? "none")" }.joined(separator: ", ")
    }
}
