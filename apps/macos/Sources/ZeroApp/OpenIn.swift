import AppKit
import SwiftUI
import ZeroCore

/// Where a task's folder opens (its ⋯ menus, the details pane): Finder, the editors
/// installed, a window of the terminal app in it, or its path copied. The last one used is listed first.
/// Continuing the session itself in the terminal is an action of its own, not a place.
@MainActor
struct OpenTarget {
    let id: String
    let title: String
    let glyph: String
    var image: Image? = nil
    let open: () -> Void

    nonisolated static let lastKey = "openIn"

    /// Editors and IDEs by name and bundle id, offered in this order where installed (Xcode only for a folder it opens).
    private static let editors = [
        ("Cursor", "com.todesktop.230313mzl4w4u92"), ("VS Code", "com.microsoft.VSCode"),
        ("VS Code Insiders", "com.microsoft.VSCodeInsiders"), ("Windsurf", "com.exafunction.windsurf"), ("Zed", "dev.zed.Zed"),
        ("Zed Preview", "dev.zed.Zed-Preview"), ("IntelliJ IDEA", "com.jetbrains.intellij"),
        ("IntelliJ IDEA CE", "com.jetbrains.intellij.ce"), ("PyCharm", "com.jetbrains.pycharm"), ("PyCharm CE", "com.jetbrains.pycharm.ce"),
        ("WebStorm", "com.jetbrains.WebStorm"), ("GoLand", "com.jetbrains.goland"), ("RubyMine", "com.jetbrains.rubymine"),
        ("RustRover", "com.jetbrains.rustrover"), ("CLion", "com.jetbrains.CLion"), ("PhpStorm", "com.jetbrains.PhpStorm"),
        ("Rider", "com.jetbrains.rider"), ("Android Studio", "com.google.android.studio"), ("Sublime Text", "com.sublimetext.4"),
        ("Sublime Text 3", "com.sublimetext.3"), ("Nova", "com.panic.Nova"), ("BBEdit", "com.barebones.bbedit"),
        ("TextMate", "com.macromates.TextMate"),
    ]
    // ponytail: looked up once per launch; an editor installed later shows after Zero restarts.
    private static let installed = editors.compactMap { name, bundle in
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle).map { (id: bundle, name: name, url: $0) }
    }
    private static let xcode = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode")
    private static var xcodeFiles: [String: URL?] = [:]

    /// What Xcode opens for a folder: its workspace, else its project, else its package; nil for none. Kept per folder.
    private static func xcodeFile(_ folder: String) -> URL? {
        if let kept = xcodeFiles[folder] { return kept }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        let name =
            names.first { $0.hasSuffix(".xcworkspace") } ?? names.first { $0.hasSuffix(".xcodeproj") }
            ?? names.first { $0 == "Package.swift" }
        let file = name.map { URL(fileURLWithPath: folder).appendingPathComponent($0) }
        xcodeFiles[folder] = file
        return file
    }

    /// A task's places: the last one used (else the first editor, else Finder), then Finder, the editors and the
    /// terminal app; then its path.
    static func groups(
        _ conversation: Conversation, in workspace: Workspace, last: String = UserDefaults.standard.string(forKey: OpenTarget.lastKey) ?? ""
    ) -> [[OpenTarget]] { places(conversation.cwd, last: last) }

    /// A path written in a message or an ask, clicked: a file shown in Finder, a folder opened where the task's
    /// folders open (the place first in "Open in").
    static func open(path: String) {
        var folder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &folder) else { return }
        if folder.boolValue {
            places(path, last: UserDefaults.standard.string(forKey: lastKey) ?? "")[0][0].open()
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }

    private static func places(_ path: String, last: String) -> [[OpenTarget]] {
        let folder = URL(fileURLWithPath: path)
        let terminal = TerminalApp.shared
        func opening(_ url: URL, in app: URL) -> () -> Void {
            { NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) }
        }
        var apps = [
            OpenTarget(id: "finder", title: "Finder", glyph: "folder", image: TerminalApp.icon("/System/Library/CoreServices/Finder.app")) {
                NSWorkspace.shared.open(folder)
            }
        ]
        apps += installed.map {
            OpenTarget(id: $0.id, title: $0.name, glyph: "code", image: TerminalApp.icon($0.url.path), open: opening(folder, in: $0.url))
        }
        if let xcode, let file = xcodeFile(path) {
            apps.append(
                OpenTarget(id: "xcode", title: "Xcode", glyph: "code", image: TerminalApp.icon(xcode.path), open: opening(file, in: xcode)))
        }
        apps.append(
            OpenTarget(id: "folder", title: terminal.name, glyph: "terminal", image: terminal.icon) { TerminalApp.openFolder(path) })
        if let first = apps.firstIndex(where: { $0.id == last }) ?? apps.dropFirst().firstIndex(where: { $0.id != "folder" }) {
            apps.insert(apps.remove(at: first), at: 0)
        }
        let copy = OpenTarget(id: "copy", title: "Copy path", glyph: "copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        }
        return [apps, [copy]]
    }

    /// Opens it, kept as the last one used (copying the path isn't a place to open).
    func run() {
        if id != "copy" { UserDefaults.standard.set(id, forKey: Self.lastKey) }
        open()
    }

    /// The session itself in the terminal app, on its CLI's own resume, or back from there; nil for one with no session.
    static func continueItem(_ conversation: Conversation, in workspace: Workspace) -> MenuItem? {
        let id = conversation.id, terminal = TerminalApp.shared
        if conversation.terminal != nil { return MenuItem("Back to Zero", "terminal") { Task { await workspace.closeTerminal(id) } } }
        guard conversation.thread != nil else { return nil }
        return MenuItem("Continue in \(terminal.name)", "terminal", image: terminal.icon) { Task { await workspace.openTerminal(id) } }
    }

    var item: MenuItem { MenuItem(title, glyph, image: image) { run() } }

    /// "Open in" as a row of a task's menu, its targets in a menu of their own.
    static func menuItem(_ conversation: Conversation, in workspace: Workspace) -> MenuItem {
        MenuItem("Open in", "folder", children: groups(conversation, in: workspace).joined().map(\.item))
    }
}

/// The details pane's "Open in": the last one used and a chevron; a click lists them all in Zero's menu.
struct OpenInButton: View {
    let workspace: Workspace
    let conversation: Conversation
    @AppStorage(OpenTarget.lastKey) private var last = ""
    @State private var anchor = CGRect.zero

    var body: some View {
        let main = OpenTarget.groups(conversation, in: workspace, last: last)[0][0]
        let open = WorkspaceSelector.shared.open == "open-in"
        Button(action: unlessClicked(list)) {
            HStack(spacing: 4) {
                TaskDetails.linked(main.title)
                NucleoIcon("chevron-down", size: 10).foregroundStyle(.secondary).rotationEffect(.degrees(open ? 180 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).opensOnPress(list).tip("Open in…")
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
        } action: {
            anchor = $0
        }
    }

    private func list() {
        WorkspaceSelector.shared.toggle("open-in", kind: .menu, anchor: anchor) { [workspace, conversation] in
            ZeroContextMenu.sections(OpenTarget.groups(conversation, in: workspace).map { $0.map(\.item) })
        }
    }
}

extension View {
    /// A path's link in SwiftUI text (an ask's words) opens as one in a message does: OpenTarget.open(path:).
    func opensPaths() -> some View {
        environment(
            \.openURL,
            OpenURLAction { url in
                guard url.isFileURL else { LinearLinks.open(url); return .handled }
                OpenTarget.open(path: url.path)
                return .handled
            })
    }
}
