import AppKit
import ApplicationServices
import Carbon
import SwiftUI
import ZeroCore

/// The desktop tools' hands: Zero.app holds the Mac's Accessibility and Screen Recording permissions, so zerod sends it
/// each desktop_ call a task makes (crates/zerod/src/desktop.rs), approved there already. Everything is done in the
/// background where it can be: accessibility actions, and events sent to the app alone, never moving the pointer or
/// bringing the app forward. The real pointer only when the agent asks for it, and only once the user is idle.
@MainActor @Observable final class Desktop {
    static let shared = Desktop()

    /// The task acting on the desktop now and the app it acts in: the control bar shows it, with Stop.
    struct Driving: Equatable {
        var session: String
        var task: String
        var app: String
    }
    private(set) var driving: Driving?

    @ObservationIgnored private weak var link: ZerodLink?
    @ObservationIgnored private var settle: Task<Void, Never>?
    /// AX calls block until the app answers: one at a time, off the main thread (which answers Zero's own).
    @ObservationIgnored private let queue = DispatchQueue(label: "zero.desktop")

    /// Zero.app as zerod's desktop, on each new connection.
    func attach(_ link: ZerodLink) {
        self.link = link
        link.onDesktop = { [weak self] message in
            Task { @MainActor in self?.receive(message) }
        }
        Task { _ = try? await link.call("desktopAttach") }
    }

    /// The user's Stop: zerod takes the desktop back from the task.
    func stop() {
        guard let driving else { return }
        self.driving = nil
        Task { [link] in _ = try? await link?.call("desktopStop", ["session": driving.session]) }
    }

    private func receive(_ message: [String: Any]) {
        if let session = message["stop"] as? String {
            if driving?.session == session { driving = nil }
            // Its recording too: the file is kept, and the task's own stop says where.
            DispatchQueue.global().async { _ = try? DesktopHands.stopRecording(session, keep: true) }
            return
        }
        guard let call = message["call"] as? Int, let tool = message["tool"] as? String else { return }
        var args = message["args"] as? [String: Any] ?? [:]
        let task = message["task"] as? [String: Any] ?? [:]
        // Whose recording: zerod's word for the task, never the agent's.
        args["session"] = task["session"]
        if tool != "resolve", tool != "desktop_apps", let session = task["session"] as? String {
            let app = (args["bundle"] as? String).flatMap {
                NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.localizedName
            }
            driving = Driving(
                session: session, task: task["name"] as? String ?? "A task", app: app ?? (args["app"] as? String ?? "the screen"))
            settle?.cancel()
        }
        let link = link
        let work = {
            var answer: [String: Any] = ["call": call]
            do {
                answer["result"] = try DesktopHands.perform(tool, args)
            } catch {
                answer["error"] = (error as? DesktopError)?.message ?? error.localizedDescription
            }
            link?.post("desktopAnswer", ["args": answer])
            Task { @MainActor in self.settled() }
        }
        // Zero's own elements are used where they live: in-process, AX runs on the calling thread, so a press from the
        // queue ran SwiftUI's button action off the main thread (a trap), and a read took minutes. Nothing here waits
        // on main (waitForIdle refuses instead). A recording waits on ScreenCaptureKit, so it never runs there.
        if args["pid"] as? Int == Int(getpid()), tool != "desktop_record" { work() } else { queue.async(execute: work) }
    }

    /// The bar's row stays a moment after the last call, so a run of steps reads as one; and while the task films,
    /// whatever it calls, so Stop is there all along (the recording's end settles it again).
    func settled() {
        settle?.cancel()
        settle = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let session = driving?.session else { return }
            if !DesktopHands.recordingsLock.withLock({ DesktopHands.recordings[session] != nil }) { driving = nil }
        }
    }
}

struct DesktopError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// What marks a view agents may never act in, though it's Zero's own: an ask's card, an approval, the inbox.
extension View {
    func agentProof() -> some View { accessibilityElement(children: .contain).accessibilityIdentifier(DesktopHands.guarded) }
}

/// The calls themselves, on the desktop's queue.
enum DesktopHands {
    static let guarded = "zero.agent-proof"

    static func perform(_ tool: String, _ args: [String: Any]) throws -> Any {
        switch tool {
        case "resolve": return try resolve(args["app"] as? String ?? "")
        case "desktop_apps": return text(apps(approved: Set(args["approved"] as? [String] ?? [])))
        default: break
        }
        if tool == "desktop_record", args["action"] as? String == "stop" {
            return text(try stopRecording(args["session"] as? String ?? ""))
        }
        if args["bundle"] as? String == "screen" {
            if locked { throw DesktopError("The screen is locked: try again once the user unlocks it.") }
            if tool == "desktop_screenshot" { return try screenshot(nil, args) }
            if tool == "desktop_record" { return text(try record(nil, args)) }
        }
        let pid = pid_t(args["pid"] as? Int ?? 0)
        guard pid > 0, let app = NSRunningApplication(processIdentifier: pid) else { throw DesktopError("That app isn't running any more") }
        if locked { throw DesktopError("The screen is locked: try again once the user unlocks it.") }
        // Zero's own tree needs no permission; another app's does.
        if pid != getpid(), !AXIsProcessTrusted() {
            throw DesktopError("Zero hasn't got the Accessibility permission: ask the user to grant it in Zero's Settings › Desktop.")
        }
        let background = args["background"] as? Bool == true
        let target = Target(pid: pid, app: app, element: AXUIElementCreateApplication(pid), background: background)
        AXUIElementSetMessagingTimeout(target.element, 3)
        switch tool {
        case "desktop_read": return try text(read(target, args))
        case "desktop_click": return try text(click(target, args))
        case "desktop_type": return try text(type(target, args))
        case "desktop_key": return try text(key(target, args))
        case "desktop_scroll": return try text(scroll(target, args))
        case "desktop_screenshot": return try screenshot(target, args)
        case "desktop_record": return text(try record(target, args))
        case "desktop_drag": return try text(drag(target, args))
        default: throw DesktopError("No desktop tool \(tool)")
        }
    }

    struct Target {
        let pid: pid_t
        let app: NSRunningApplication
        let element: AXUIElement
        let background: Bool
        var name: String { app.localizedName ?? app.bundleIdentifier ?? "the app" }
    }

    static func text(_ said: String) -> [String: Any] { ["content": [["type": "text", "text": said]]] }

    static var locked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true
    }

    // MARK: Apps

    static func resolve(_ name: String) throws -> [String: Any] {
        let wanted = name.lowercased()
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy != .prohibited }
        let found =
            apps.first { $0.bundleIdentifier?.lowercased() == wanted } ?? apps.first { $0.localizedName?.lowercased() == wanted }
            ?? apps.first { $0.activationPolicy == .regular && ($0.localizedName?.lowercased().contains(wanted) ?? false) }
        guard let found, let bundle = found.bundleIdentifier, !wanted.isEmpty else {
            throw DesktopError(
                "No running app named \(name): desktop_apps lists them. If it was running, macOS may have quit it (an app in the background with no window): open it again, with a window, and call again."
            )
        }
        return ["bundle": bundle, "name": found.localizedName ?? bundle, "pid": Int(found.processIdentifier)]
    }

    static func apps(approved: Set<String>) -> String {
        var lines = [
            "Accessibility: \(AXIsProcessTrusted() ? "granted" : "not granted (ask the user: Zero's Settings › Desktop)")",
            "Screen Recording: \(CGPreflightScreenCaptureAccess() ? "granted" : "not granted (ask the user: Zero's Settings › Desktop)")",
        ]
        lines.append("Screen: \(locked ? "locked (nothing can be used until the user unlocks it)" : "unlocked")")
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let bundle = app.bundleIdentifier ?? ""
            lines.append("\(app.localizedName ?? bundle) (\(bundle))\(app.processIdentifier == front ? ", frontmost" : "")")
            // Window titles say what the user is doing: only for the apps the task may use.
            // Locked, the window server gives no windows (ids 0, sizes 0x0): none listed, the Screen line says why.
            guard approved.contains(bundle), !locked, app.processIdentifier == getpid() || AXIsProcessTrusted() else { continue }
            let open = windows(AXUIElementCreateApplication(app.processIdentifier))
            if open.isEmpty { lines.append("  no window open: \(noWindow)") }
            for window in open {
                let frame = frameOf(window)
                let title = string(window, kAXTitleAttribute) ?? ""
                let minimized = bool(window, kAXMinimizedAttribute) == true ? ", minimized" : ""
                lines.append("  window \(windowID(window) ?? 0) \"\(title)\" \(Int(frame.width))x\(Int(frame.height))\(minimized)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Read

    /// Each app's elements from its last read, by id: what refs point to.
    nonisolated(unsafe) private static var refs: [pid_t: [Int: AXUIElement]] = [:]
    /// Zero's own reads write them on the main thread, others' on the desktop's queue.
    private static let refsLock = NSLock()

    static func read(_ target: Target, _ args: [String: Any]) throws -> String {
        let window = try window(target, args)
        let origin = frameOf(window).origin
        let root: AXUIElement
        if let ref = args["ref"] as? String { root = try element(target, ref) } else { root = window }
        var elements: [Int: AXUIElement] = [:]
        var count = 0
        func node(_ element: AXUIElement, depth: Int) -> DesktopNode {
            count += 1
            let id = count
            elements[id] = element
            let a = batch(element)
            let role = a[kAXRoleAttribute] as? String ?? "AXUnknown"
            let frame = CGRect(origin: axPoint(a[kAXPositionAttribute]), size: axSize(a[kAXSizeAttribute]))
            let value = a[kAXValueAttribute]
            var made = DesktopNode(
                id: id, role: role, subrole: a[kAXSubroleAttribute] as? String,
                title: (a[kAXTitleAttribute] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? a[kAXDescriptionAttribute] as? String,
                value: (value as? String) ?? (value as? NSNumber).map { "\($0)" },
                frame: (Int(frame.minX - origin.x), Int(frame.minY - origin.y), Int(frame.width), Int(frame.height)),
                actions: actions(element), settable: textRoles.contains(role) && settable(element, kAXValueAttribute),
                enabled: (a[kAXEnabledAttribute] as? NSNumber)?.boolValue ?? true,
                focused: (a[kAXFocusedAttribute] as? NSNumber)?.boolValue ?? false)
            if depth < 60, count < 5000 {
                made.children = (a[kAXChildrenAttribute] as? [AXUIElement] ?? []).map { node($0, depth: depth + 1) }
            }
            return made
        }
        let tree = node(root, depth: 0)
        refsLock.withLock { refs[target.pid] = elements }
        let title = string(window, kAXTitleAttribute) ?? ""
        let size = frameOf(window).size
        return "\(target.name), window \(windowID(window) ?? 0) \"\(title)\" \(Int(size.width))x\(Int(size.height)):\n"
            + tree.lines(all: args["all"] as? Bool == true)
    }

    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSlider"]

    // MARK: Act

    static func click(_ target: Target, _ args: [String: Any]) throws -> String {
        let right = args["button"] as? String == "right"
        let count = max(1, args["count"] as? Int ?? 1)
        let modifiers = try flags(args["modifiers"] as? String)
        if let ref = args["ref"] as? String {
            let element = try element(target, ref)
            try guardZero(target, element)
            let names = actions(element)
            if count == 1, modifiers == 0, args["pointer"] as? Bool != true {
                if right, names.contains("AXShowMenu") {
                    try act(element, "AXShowMenu")
                    return "Opened \(ref)'s menu"
                }
                if !right, let press = ["AXPress", "AXConfirm", "AXPick", "AXOpen"].first(where: names.contains) {
                    try act(element, press)
                    return "Pressed \(ref)"
                }
            }
            let frame = frameOf(element)
            return try mouse(target, at: CGPoint(x: frame.midX, y: frame.midY), right: right, count: count, flags: modifiers, args)
        }
        let point = try screenPoint(target, args)
        if target.pid == getpid() {
            guard let element = elementAt(target, point) else { throw refusedInZero }
            try guardZero(target, element)
        }
        return try mouse(target, at: point, right: right, count: count, flags: modifiers, args)
    }

    static func type(_ target: Target, _ args: [String: Any]) throws -> String {
        let text = args["text"] as? String ?? ""
        if IsSecureEventInputEnabled() {
            throw DesktopError("A password field has the keyboard: typing is refused. Ask the user to type it.")
        }
        if let ref = args["ref"] as? String {
            let element = try element(target, ref)
            try guardZero(target, element)
            // Set through accessibility: no keyboard, no focus taken.
            if args["replace"] as? Bool == true, settable(element, kAXValueAttribute) {
                try set(element, kAXValueAttribute, text)
                return "Set \(ref)'s value"
            }
            if settable(element, kAXSelectedTextAttribute) {
                try set(element, kAXSelectedTextAttribute, text)
                return "Typed into \(ref)"
            }
            if settable(element, kAXValueAttribute) {
                try set(element, kAXValueAttribute, (string(element, kAXValueAttribute) ?? "") + text)
                return "Added to \(ref)'s value"
            }
            if target.background {
                throw DesktopError("\(ref) takes no text through accessibility, and \(target.name) is used in the background only")
            }
            try set(element, kAXFocusedAttribute, true as CFBoolean)
        } else {
            try guardFocus(target)
        }
        try trusted()
        try waitIfUserIsIn(target)
        let source = CGEventSource(stateID: .privateState)
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if line.offset > 0 { press(36, flags: 0, to: target.pid, source: source) }
            var units = Array(line.element.utf16)[...]
            while !units.isEmpty {
                let chunk = Array(units.prefix(16))
                units = units.dropFirst(16)
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                    event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                    event?.postToPid(target.pid)
                }
            }
        }
        return "Typed \(text.count) characters into \(target.name)"
    }

    static func key(_ target: Target, _ args: [String: Any]) throws -> String {
        let keys = args["keys"] as? String ?? ""
        let chord: (code: UInt16, flags: UInt64)
        switch DesktopKeys.chord(keys) {
        case .success(let found): chord = found
        case .failure(let error): throw DesktopError(error.message)
        }
        if IsSecureEventInputEnabled() { throw DesktopError("A password field has the keyboard: keys are refused") }
        // A shortcut of the app's menus is its menu item, pressed through accessibility: a background app doesn't
        // take menu shortcuts sent to it as keys. Never Zero's own menus (Quit, Settings…): its keys go to a field only.
        if target.pid != getpid(), let (item, path) = menuItem(target, keys: keys, chord: chord) {
            for _ in 0..<max(1, min(100, args["repeat"] as? Int ?? 1)) { try act(item, "AXPress") }
            return "Pressed \(keys): \(target.name)'s menu item \(path), through accessibility"
        }
        try guardFocus(target)
        try trusted()
        try waitIfUserIsIn(target)
        let source = CGEventSource(stateID: .privateState)
        for _ in 0..<max(1, min(100, args["repeat"] as? Int ?? 1)) { press(chord.code, flags: chord.flags, to: target.pid, source: source) }
        return "Pressed \(keys) in \(target.name) as keys sent to it (no menu item has that shortcut): an app in the background may ignore "
            + "them, so check with desktop_read"
    }

    static func scroll(_ target: Target, _ args: [String: Any]) throws -> String {
        let dx = args["dx"] as? Double ?? 0, dy = args["dy"] as? Double ?? 0
        let point: CGPoint
        if let ref = args["ref"] as? String {
            let element = try element(target, ref)
            try guardZero(target, element)
            if dx == 0, dy == 0 {
                try act(element, "AXScrollToVisible")
                return "Scrolled \(ref) into view"
            }
            let frame = frameOf(element)
            point = CGPoint(x: frame.midX, y: frame.midY)
        } else {
            point = try screenPoint(target, args)
            if target.pid == getpid() {
                guard let element = elementAt(target, point) else { throw refusedInZero }
                try guardZero(target, element)
            }
        }
        try trusted()
        let before = state(target, at: point)
        let event = CGEvent(
            scrollWheelEvent2Source: CGEventSource(stateID: .privateState), units: .pixel, wheelCount: 2, wheel1: Int32(-dy),
            wheel2: Int32(-dx),
            wheel3: 0)
        event?.location = point
        event?.postToPid(target.pid)
        Thread.sleep(forTimeInterval: 0.15)
        let did = "Scrolled \(target.name) by \(Int(dx)),\(Int(dy))"
        if let changed = DesktopChange.said(before, state(target, at: point)) { return "\(did): \(changed)" }
        return "\(did), but the scroll position didn't change (at its end already, or nothing scrolls there)"
    }

    // MARK: Events

    /// A click as events sent to the app alone; with `pointer`, the real one, once the user is idle.
    static func mouse(_ target: Target, at point: CGPoint, right: Bool, count: Int, flags: UInt64, _ args: [String: Any]) throws -> String {
        try trusted()
        let real = args["pointer"] as? Bool == true && !target.background
        let (down, up): (CGEventType, CGEventType) = right ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
        let source = CGEventSource(stateID: real ? .hidSystemState : .privateState)
        let window = windowNumber(at: point, pid: target.pid)
        var back: CGPoint?
        if real {
            try waitForIdle()
            back = CGEvent(source: nil)?.location
            target.app.activate()
            Thread.sleep(forTimeInterval: 0.2)
        }
        for click in 1...count {
            for type in [down, up] {
                let event = CGEvent(
                    mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: right ? .right : .left)
                event?.setIntegerValueField(.mouseEventClickState, value: Int64(click))
                event?.flags = CGEventFlags(rawValue: flags)
                // Which window the event is for: an app given a click it didn't get through the window server routes it by these.
                if let window {
                    event?.setIntegerValueField(CGEventField(rawValue: 91)!, value: Int64(window))
                    event?.setIntegerValueField(CGEventField(rawValue: 92)!, value: Int64(window))
                }
                if real { event?.post(tap: .cghidEventTap) } else { event?.postToPid(target.pid) }
            }
        }
        if let back { CGWarpMouseCursorPosition(back) }
        let at = "\(Int(point.x)),\(Int(point.y))"
        return real ? "Clicked at \(at) with the real pointer: \(target.name) came forward" : "Clicked at \(at) in the background"
    }

    static func press(_ code: UInt16, flags: UInt64, to pid: pid_t, source: CGEventSource?) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            event?.flags = CGEventFlags(rawValue: flags)
            event?.postToPid(pid)
        }
    }

    /// The enabled menu item whose shortcut is this chord, and its place in the menus ("File › Close").
    static func menuItem(_ target: Target, keys: String, chord: (code: UInt16, flags: UInt64)) -> (AXUIElement, String)? {
        guard let bar = attribute(target.element, kAXMenuBarAttribute) else { return nil }
        let key = keys.lowercased().split(separator: "+").last.map { $0.trimmingCharacters(in: .whitespaces) }
        let char = key?.count == 1 ? key : nil
        // AX's modifiers: shift 1, option 2, control 4, and 8 for no command.
        var mask = 0
        if chord.flags & DesktopKeys.shift != 0 { mask |= 1 }
        if chord.flags & DesktopKeys.option != 0 { mask |= 2 }
        if chord.flags & DesktopKeys.control != 0 { mask |= 4 }
        if chord.flags & DesktopKeys.command == 0 { mask |= 8 }
        let names = [
            kAXTitleAttribute, kAXMenuItemCmdCharAttribute, kAXMenuItemCmdModifiersAttribute, kAXMenuItemCmdVirtualKeyAttribute,
            kAXEnabledAttribute, kAXChildrenAttribute,
        ]
        func walk(_ element: AXUIElement, _ path: [String], depth: Int) -> (AXUIElement, String)? {
            for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                var values: CFArray?
                guard AXUIElementCopyMultipleAttributeValues(child, names as CFArray, [], &values) == .success,
                    let got = values as? [AnyObject]
                else { continue }
                let title = got[0] as? String ?? "", shortcut = (got[1] as? String ?? "").lowercased()
                let modifiers = (got[2] as? NSNumber)?.intValue ?? 0, virtual = (got[3] as? NSNumber)?.intValue
                let matches = shortcut.isEmpty ? virtual == Int(chord.code) && char == nil : shortcut == char
                if matches, modifiers == mask, (got[4] as? NSNumber)?.boolValue != false {
                    return (child, (path + [title]).joined(separator: " › "))
                }
                if depth < 4, !(got[5] as? [AXUIElement] ?? []).isEmpty,
                    let found = walk(child, title.isEmpty ? path : path + [title], depth: depth + 1)
                {
                    return found
                }
            }
            return nil
        }
        return walk(bar as! AXUIElement, [], depth: 0)
    }

    static func flags(_ modifiers: String?) throws -> UInt64 {
        guard let modifiers, !modifiers.isEmpty else { return 0 }
        switch DesktopKeys.chord(modifiers + "+a") {
        case .success(let chord): return chord.flags
        case .failure(let error): throw DesktopError(error.message)
        }
    }

    static func trusted() throws {
        if !AXIsProcessTrusted() {
            throw DesktopError("Zero hasn't got the Accessibility permission: ask the user to grant it in Zero's Settings › Desktop.")
        }
    }

    /// Seconds since the user last touched the mouse or keyboard (our own events come from a private source: not counted).
    static var idle: Double { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!) }

    static func waitForIdle() throws {
        // Zero's own calls run on its main thread: waiting there would freeze Zero under the user's hands.
        if Thread.isMainThread {
            if idle >= 2 { return }
            throw DesktopError("The user is using Zero: try again in a moment")
        }
        for _ in 0..<300 {
            if idle >= 2 { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw DesktopError("The user is using the Mac: try again in a while, or without the real pointer")
    }

    /// Keys sent to the app the user is typing in would land among theirs: they wait until the user pauses.
    static func waitIfUserIsIn(_ target: Target) throws {
        if target.app.isActive { try waitForIdle() }
    }

    // MARK: Zero's own

    /// Zero itself, used by an agent: never on an ask, an approval, the inbox or the control bar (panels), or Settings.
    static func guardZero(_ target: Target, _ element: AXUIElement) throws {
        guard target.pid == getpid() else { return }
        var current: AXUIElement? = element
        var steps = 0
        while let element = current, steps < 200 {
            if string(element, kAXIdentifierAttribute) == guarded { throw refusedInZero }
            current = attribute(element, kAXParentAttribute).map { $0 as! AXUIElement }
            steps += 1
        }
        // The element's own window: a panel (the control bar, the inbox, a menu) or Settings is the user's; none found, no.
        let number = attribute(element, kAXWindowAttribute).flatMap { windowID($0 as! AXUIElement) }
        let allowed = onMain { () -> Bool in
            guard let number, let window = NSApp.window(withWindowNumber: Int(number)) else { return false }
            return !(window is NSPanel) && (NSApp.delegate as? AppDelegate)?.navigation.place != .settings
        }
        if !allowed { throw refusedInZero }
    }

    /// Keys in Zero go only to a text field (the composer, a search) that isn't the user's: elsewhere, Return could answer
    /// the ask on screen, as its first option is the default button.
    static func guardFocus(_ target: Target) throws {
        guard target.pid == getpid() else { return }
        if onMain({ NSApp.keyWindow is NSPanel }) { throw refusedInZero }
        guard let focused = attribute(target.element, kAXFocusedUIElementAttribute).map({ $0 as! AXUIElement }),
            textRoles.contains(string(focused, kAXRoleAttribute) ?? "")
        else { throw DesktopError("In Zero, keys go only to a text field: give desktop_type the field's ref, or click one first") }
        try guardZero(target, focused)
    }

    static let refusedInZero = DesktopError(
        "Agents can't act on Zero's asks, approvals, inbox, control bar or Settings: those are the user's. Ask the user (zero ask) instead."
    )

    // MARK: AX

    static func window(_ target: Target, _ args: [String: Any]) throws -> AXUIElement {
        let all = windows(target.element)
        if let id = args["window"] as? Int {
            guard let window = all.first(where: { windowID($0) == CGWindowID(id) }) else {
                throw DesktopError("\(target.name) has no window \(id)")
            }
            return window
        }
        if let focused = attribute(target.element, kAXFocusedWindowAttribute) { return focused as! AXUIElement }
        guard let first = all.first else { throw DesktopError("\(target.name) has no window open: \(noWindow)") }
        return first
    }

    /// An app with no window: what to do, and why it matters (macOS quits such an app in the background on its own).
    static let noWindow = "open one (desktop_key cmd+n, or from the shell), as macOS may quit an app in the background without one"

    static func windows(_ app: AXUIElement) -> [AXUIElement] { attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] }

    static func element(_ target: Target, _ ref: String) throws -> AXUIElement {
        guard let id = Int(ref.trimmingCharacters(in: CharacterSet(charactersIn: "e"))),
            let element = refsLock.withLock({ refs[target.pid]?[id] })
        else {
            throw DesktopError("No element \(ref) in \(target.name)'s last read: read it again (desktop_read)")
        }
        return element
    }

    /// A point given in a window's points, on the screen (the window's position added).
    static func screenPoint(_ target: Target, _ args: [String: Any]) throws -> CGPoint {
        guard let x = args["x"] as? Double, let y = args["y"] as? Double else { throw DesktopError("Where? A ref, or x and y") }
        let origin = frameOf(try window(target, args)).origin
        return CGPoint(x: origin.x + x, y: origin.y + y)
    }

    static func elementAt(_ target: Target, _ point: CGPoint) -> AXUIElement? {
        var found: AXUIElement?
        return AXUIElementCopyElementAtPosition(target.element, Float(point.x), Float(point.y), &found) == .success ? found : nil
    }

    static func windowNumber(at point: CGPoint, pid: pid_t) -> CGWindowID? {
        let app = AXUIElementCreateApplication(pid)
        return windows(app).first { frameOf($0).contains(point) }.flatMap(windowID)
    }

    static let batched = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXPositionAttribute,
        kAXSizeAttribute, kAXEnabledAttribute, kAXFocusedAttribute, kAXChildrenAttribute,
    ]

    /// An element's attributes a read shows, in one call (one message to the app, not ten); those it hasn't, left out.
    static func batch(_ element: AXUIElement) -> [String: Any] {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, batched as CFArray, [], &values) == .success,
            let values = values as? [AnyObject]
        else { return [:] }
        var found: [String: Any] = [:]
        for (name, value) in zip(batched, values) {
            // A missing attribute comes back as an AXValue holding its error.
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { continue }
            found[name] = value
        }
        return found
    }

    static func axPoint(_ value: Any?) -> CGPoint {
        var point = CGPoint.zero
        if let value, CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() { AXValueGetValue(value as! AXValue, .cgPoint, &point) }
        return point
    }

    static func axSize(_ value: Any?) -> CGSize {
        var size = CGSize.zero
        if let value, CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() { AXValueGetValue(value as! AXValue, .cgSize, &size) }
        return size
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    static func string(_ element: AXUIElement, _ name: String) -> String? { attribute(element, name) as? String }
    static func bool(_ element: AXUIElement, _ name: String) -> Bool? { (attribute(element, name) as? NSNumber)?.boolValue }
    static func children(_ element: AXUIElement) -> [AXUIElement] { attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }

    static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        return AXUIElementCopyActionNames(element, &names) == .success ? names as? [String] ?? [] : []
    }

    static func settable(_ element: AXUIElement, _ name: String) -> Bool {
        var can: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, name as CFString, &can) == .success && can.boolValue
    }

    static func set(_ element: AXUIElement, _ name: String, _ value: CFTypeRef) throws {
        let error = AXUIElementSetAttributeValue(element, name as CFString, value)
        if error != .success { throw DesktopError("Couldn't set \(name): accessibility error \(error.rawValue)") }
    }
    static func set(_ element: AXUIElement, _ name: String, _ value: String) throws { try set(element, name, value as CFString) }

    static func act(_ element: AXUIElement, _ action: String) throws {
        let error = AXUIElementPerformAction(element, action as CFString)
        if error != .success { throw DesktopError("\(action) failed: accessibility error \(error.rawValue)") }
    }

    /// An element's frame on the screen, top-left origin.
    static func frameOf(_ element: AXUIElement) -> CGRect {
        var point = CGPoint.zero, size = CGSize.zero
        if let value = attribute(element, kAXPositionAttribute) { AXValueGetValue(value as! AXValue, .cgPoint, &point) }
        if let value = attribute(element, kAXSizeAttribute) { AXValueGetValue(value as! AXValue, .cgSize, &size) }
        return CGRect(origin: point, size: size)
    }

    static func windowID(_ window: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(window, &id) == .success ? id : nil
    }
}

/// On the main thread, from wherever: run there and waited for, or at once when already on it.
func onMain<T: Sendable>(_ work: @MainActor () -> T) -> T {
    Thread.isMainThread ? MainActor.assumeIsolated(work) : DispatchQueue.main.sync { MainActor.assumeIsolated(work) }
}

/// The window server's id of an AX window: private, but the only way from one to the other (every window manager uses it).
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Settings › Desktop: the two permissions the desktop tools need, which only the user grants. Asking for one is the
/// system's own prompt, so it's only ever this page's button, never Zero by itself; Zero Dev never asks.
struct DesktopPage: View {
    @State private var accessibility = AXIsProcessTrusted()
    @State private var screen = CGPreflightScreenCaptureAccess()

    var body: some View {
        Sections {
            SettingsSection(title: "Permissions") {
                Rows {
                    SettingRow(.accessibility) {
                        grant(accessibility) {
                            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
                        }
                    }
                    SettingRow(.screenRecording) { grant(screen) { CGRequestScreenCaptureAccess() } }
                }
            }
        }
        // Granted in System Settings, so looked at again while the page is open.
        .task {
            while !Task.isCancelled {
                accessibility = AXIsProcessTrusted()
                screen = CGPreflightScreenCaptureAccess()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder private func grant(_ granted: Bool, _ ask: @escaping () -> Void) -> some View {
        if granted {
            Text("Granted").font(.system(size: 12)).foregroundStyle(.secondary)
        } else {
            RowButton(title: "Grant", enabled: !DevBuild.on) { if !DevBuild.on { ask() } }
                .tip(DevBuild.on ? "Zero Dev never asks for permissions" : "macOS asks you, then lists Zero in System Settings")
        }
    }
}
