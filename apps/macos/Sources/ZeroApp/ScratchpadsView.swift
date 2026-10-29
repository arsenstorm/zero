import AppKit
import SwiftUI
import ZeroCore

// Scratchpads: Markdown notes in folders, kept by zerod as files under ~/.zero/scratchpads and shared with agents
// through Zero's MCP server. A pad's link (zero://pad/<id>, #<section> for one heading) opens it here.

/// Copying links: plain (and as a URL, so apps that take links get one) or as Markdown with the pad's title.
enum PadLinks {
    static func copy(_ link: String, title: String, markdown: Bool = false) {
        let board = NSPasteboard.general
        board.clearContents()
        if markdown {
            board.setString("[\(title)](\(link))", forType: .string)
        } else {
            board.setString(link, forType: .string)
            if let url = URL(string: link) { board.writeObjects([url as NSURL]) }
        }
    }

    static func section(_ pad: String, _ slug: String) -> String { "zero://pad/\(pad)#\(slug)" }

    /// A zero://pad link's id and section.
    static func parse(_ url: URL) -> (id: String, section: String?)? {
        guard url.scheme == "zero", url.host() == "pad" else { return nil }
        let id = url.path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return id.isEmpty ? nil : (id, url.fragment())
    }
}

struct ScratchpadsPage: View {
    let workspace: Workspace
    @Bindable var navigation: Navigation
    @State private var search = ""
    /// The folders shown open, one per line.
    @AppStorage("padsOpen") private var open = ""
    @State private var naming: Naming?

    /// What the name sheet is for.
    private enum Naming: Identifiable {
        case folder(in: String), rename(PadSummary)
        var id: String { switch self { case .folder(let parent): "folder:\(parent)"; case .rename(let pad): "rename:\(pad.id)" } }
    }

    private var shown: String? { if case .pad(let id) = navigation.place { id } else { nil } }

    var body: some View {
        HStack(spacing: 0) {
            SidebarColumn(title: "Scratchpads") {
                searchBar.padding(.bottom, 6)
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) { rows }.padding(.bottom, 8)
                }
                .thinScrollbar(outset: 10, remember: "sidebar.pads") // in the sidebar's padding: at its edge, clear of the rows
                .scrollIndicators(.never)
            }
            Rectangle().fill(Theme.stroke).frame(width: 1)
            Group {
                if let shown {
                    PadEditor(workspace: workspace, navigation: navigation, id: shown).id(shown)
                } else {
                    ContentUnavailableView {
                        NucleoLabel("No scratchpad open", icon: "note-3", size: 20)
                    } description: {
                        Text("Notes you and your agents share. Copy a pad's link, or a section's, to hand it to an agent.")
                    } actions: {
                        Button("New scratchpad") { create(in: "") }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.card)
        }
        // Agents add and change pads too: read again when zerod says one changed, and every half minute for files
        // edited outside Zero.
        .task(id: workspace.padsVersion) {
            while !Task.isCancelled {
                await workspace.loadPads()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .sheet(item: $naming) { naming in
            switch naming {
            case .folder(let parent):
                NameSheet(title: parent.isEmpty ? "New folder" : "New folder in \(parent)", name: "", action: "Create") { name in
                    let path = parent.isEmpty ? name : "\(parent)/\(name)"
                    Task { await workspace.makePadFolder(path); toggle(path, to: true); if !parent.isEmpty { toggle(parent, to: true) } }
                }
            case .rename(let pad):
                NameSheet(title: "Rename", name: pad.title, action: "Rename") { name in Task { await workspace.renamePad(pad.id, to: name) } }
            }
        }
    }

    /// Search, with New and New folder beside it; once something is typed the field takes the row and the two slide
    /// off to the right.
    private var searchBar: some View {
        let searching = !search.isEmpty
        return HStack(spacing: 4) {
            HStack(spacing: 7) {
                NucleoIcon("magnifier", size: 13).foregroundStyle(.secondary)
                TextField("Search", text: $search).textFieldStyle(.plain).font(.system(size: 13))
                if searching {
                    Button { search = "" } label: { NucleoIcon("xmark", size: 11).foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("Clear")
                }
            }
            .padding(.horizontal, 9).frame(height: 30)
            .background(Theme.chip.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            if !searching {
                Group {
                    Button { create(in: "") } label: { NucleoIcon("compose", size: 15).frame(width: 30, height: 30) }
                        .buttonStyle(Hovering()).help("New scratchpad")
                    Button { naming = .folder(in: "") } label: { NucleoIcon("folder-plus", size: 15).frame(width: 30, height: 30) }
                        .buttonStyle(Hovering()).help("New folder")
                }
                .foregroundStyle(.secondary)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.28, bounce: 0), value: searching)
        .clipped()
    }

    // The tree: top-level pads, then each folder with its pads and folders when it's open. A search shows matches flat.

    @ViewBuilder private var rows: some View {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            ForEach(workspace.pads.filter { $0.title.lowercased().contains(query) || $0.folder.lowercased().contains(query) }) { pad in
                padRow(pad, depth: 0, showFolder: true)
            }
        } else {
            tree(in: "", depth: 0)
        }
    }

    private func tree(in folder: String, depth: Int) -> AnyView {
        let opened = Set(open.split(separator: "\n").map(String.init))
        let children = workspace.padFolders.filter { parent(of: $0) == folder }
        return AnyView(Group {
            ForEach(children, id: \.self) { child in
                folderRow(child, depth: depth, isOpen: opened.contains(child))
                if opened.contains(child) { tree(in: child, depth: depth + 1) }
            }
            ForEach(workspace.pads.filter { $0.folder == folder }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }) { pad in
                padRow(pad, depth: depth, showFolder: false)
            }
        })
    }

    private func folderRow(_ folder: String, depth: Int, isOpen: Bool) -> some View {
        Button { toggle(folder, to: !isOpen) } label: {
            HStack(spacing: 7) {
                NucleoIcon("chevron-down", size: 10).foregroundStyle(.secondary).rotationEffect(.degrees(isOpen ? 0 : -90)).frame(width: 10)
                NucleoIcon("folder", size: 15).foregroundStyle(.secondary)
                Text(name(of: folder)).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 0)
                Text("\(workspace.pads.filter { $0.folder == folder || $0.folder.hasPrefix(folder + "/") }.count)")
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary).monospacedDigit()
            }
            .padding(.leading, 10 + CGFloat(depth) * 14).padding(.trailing, 10).frame(height: 30)
        }
        .buttonStyle(Hovering())
        .contextMenu {
            Button("New scratchpad here") { create(in: folder) }
            Button("New folder inside") { naming = .folder(in: folder) }
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.open(Self.root.appendingPathComponent(folder)) }
        }
    }

    private func padRow(_ pad: PadSummary, depth: Int, showFolder: Bool) -> some View {
        Button { navigation.place = .pad(pad.id) } label: {
            HStack(spacing: 9) {
                NucleoIcon("file-content", size: 15).foregroundStyle(.secondary)
                Text(pad.title).font(.system(size: 13)).lineLimit(1)
                if showFolder && !pad.folder.isEmpty { Text(pad.folder).font(.system(size: 11.5)).foregroundStyle(.tertiary).lineLimit(1) }
                Spacer(minLength: 0)
            }
            .padding(.leading, 10 + CGFloat(depth) * 14 + (depth > 0 || !workspace.padFolders.isEmpty ? 17 : 0)).padding(.trailing, 10).frame(height: 30)
        }
        .buttonStyle(Hovering(selected: shown == pad.id))
        .draggable(pad.link)
        .contextMenu {
            Button("Copy link") { PadLinks.copy(pad.link, title: pad.title) }
            Button("Copy Markdown link") { PadLinks.copy(pad.link, title: pad.title, markdown: true) }
            Divider()
            Button("Rename…") { naming = .rename(pad) }
            Menu("Move to") {
                Button("Scratchpads (top)") { Task { await workspace.movePad(pad.id, to: "") } }.disabled(pad.folder.isEmpty)
                ForEach(workspace.padFolders, id: \.self) { folder in
                    Button(folder) { Task { await workspace.movePad(pad.id, to: folder) } }.disabled(folder == pad.folder)
                }
            }
            Button("Show in Finder") {
                let file = Self.root.appendingPathComponent(pad.folder).appendingPathComponent(pad.title + ".md")
                NSWorkspace.shared.activateFileViewerSelecting([file])
            }
            Divider()
            Button("Move to Trash") {
                Task {
                    await workspace.deletePad(pad.id)
                    if shown == pad.id { navigation.place = .pads }
                }
            }
        }
    }

    static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zero/scratchpads")

    private func create(in folder: String) {
        Task {
            guard let pad = await workspace.createPad(in: folder) else { return }
            if !folder.isEmpty { toggle(folder, to: true) }
            navigation.place = .pad(pad.id)
        }
    }

    private func toggle(_ folder: String, to on: Bool) {
        var opened = Set(open.split(separator: "\n").map(String.init))
        if on { opened.insert(folder) } else { opened.remove(folder) }
        open = opened.sorted().joined(separator: "\n")
    }

    private func parent(of folder: String) -> String { folder.split(separator: "/").dropLast().joined(separator: "/") }
    private func name(of folder: String) -> String { folder.split(separator: "/").last.map(String.init) ?? folder }
}

/// A name asked for in a sheet: a new folder's, or a pad's new title.
private struct NameSheet: View {
    let title: String
    @State var name: String
    let action: String
    let done: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 15, weight: .semibold))
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action, action: submit).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18).frame(width: 340)
    }

    private func submit() {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        done(name)
        dismiss()
    }
}

/// One pad: its title (renamed when changed), what's in it, and its links. Typing saves a moment later, naming the
/// revision it started from; a pad changed meanwhile (an agent wrote to it) is reloaded when nothing is unsaved, and
/// otherwise asks which to keep.
private struct PadEditor: View {
    let workspace: Workspace
    @Bindable var navigation: Navigation
    let id: String
    @State private var pad: Pad?
    @State private var text = ""
    @State private var title = ""
    /// The text as last saved or loaded; typing makes `text` differ from it.
    @State private var saved = ""
    @State private var conflict: String?
    @State private var save: Task<Void, Never>?
    @State private var scrollTo: String?
    @State private var missing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let pad {
                header(pad)
                if let conflict { banner(conflict) }
                MarkdownEditor(text: $text, scrollTo: $scrollTo, sectionLink: { slug in
                    pad.sections.first { $0.slug == slug }.map { section in (PadLinks.section(pad.id, section.slug), "\(pad.title) › \(section.title)") }
                }, padLink: (pad.link, pad.title), sections: pad.sections)
                .onChange(of: text) { _, now in if now != saved { scheduleSave() } }
            } else if missing {
                ContentUnavailableView("No such scratchpad", systemImage: "", description: Text("It may have been moved to the trash."))
            }
        }
        .task {
            await load()
            scrollTo = navigation.padSection
            navigation.padSection = nil
        }
        // Someone else's change (an agent's, through zerod) as it happens; one made outside Zero within half a minute.
        .task(id: workspace.padsVersion) {
            await refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await refresh()
            }
        }
        .onChange(of: navigation.padSection) { _, section in
            if let section { scrollTo = section; navigation.padSection = nil }
        }
        .onDisappear { flush() }
    }

    private func header(_ pad: Pad) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                TextField("Untitled", text: $title)
                    .textFieldStyle(.plain).font(.system(size: 26, weight: .semibold))
                    .onSubmit(rename)
                Spacer()
                Menu {
                    Button("Copy link") { PadLinks.copy(pad.link, title: pad.title) }
                    Button("Copy Markdown link") { PadLinks.copy(pad.link, title: pad.title, markdown: true) }
                    if !pad.sections.isEmpty {
                        Divider()
                        Section("Link to a section") {
                            ForEach(pad.sections, id: \.slug) { section in
                                Button(String(repeating: "   ", count: max(0, section.level - 1)) + section.title) {
                                    PadLinks.copy(PadLinks.section(pad.id, section.slug), title: "\(pad.title) › \(section.title)", markdown: true)
                                }
                            }
                        }
                    }
                } label: {
                    NucleoLabel("Copy link", icon: "link", size: 14).font(.system(size: 12.5, weight: .medium))
                } primaryAction: {
                    PadLinks.copy(pad.link, title: pad.title)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Copy this pad's link; the arrow has a Markdown link and each section's")
            }
            Text([pad.folder.isEmpty ? "Scratchpads" : pad.folder, "Edited " + Date(timeIntervalSince1970: TimeInterval(pad.updated)).formatted(.relative(presentation: .named))]
                .joined(separator: " · "))
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 48).padding(.top, 28).padding(.bottom, 12)
    }

    private func banner(_ message: String) -> some View {
        HStack(spacing: 10) {
            NucleoIcon("triangle-warning", size: 14).foregroundStyle(.orange)
            Text("Changed elsewhere while you were typing.").font(.system(size: 12.5))
            Spacer()
            Button("Keep mine") { Task { await write(force: true) } }
            Button("Take theirs") { Task { conflict = nil; await load() } }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 44).padding(.bottom, 8)
        .help(message)
    }

    private func load() async {
        guard let fresh = await workspace.readPad(id) else { missing = true; return }
        pad = fresh
        title = fresh.title
        saved = fresh.content
        text = fresh.content
    }

    /// Someone else's change, taken when nothing here is unsaved.
    private func refresh() async {
        guard let fresh = await workspace.readPad(id), fresh.revision != pad?.revision else { return }
        if text == saved && save == nil {
            pad = fresh
            saved = fresh.content
            text = fresh.content
            if title == pad?.title || title.isEmpty { title = fresh.title }
        } else {
            pad?.sections = fresh.sections
        }
    }

    private func scheduleSave() {
        save?.cancel()
        save = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await write(force: false)
        }
    }

    /// Saves now what's waiting to be saved, as the page goes.
    private func flush() {
        guard save != nil, text != saved else { return }
        save?.cancel()
        let (id, content, revision, workspace) = (id, text, pad?.revision, workspace)
        Task { _ = try? await workspace.writePad(id, content: content, revision: revision) }
    }

    private func write(force: Bool) async {
        let content = text
        do {
            let written = try await workspace.writePad(id, content: content, revision: force ? nil : pad?.revision)
            pad = written
            saved = content
            conflict = nil
        } catch {
            conflict = error.localizedDescription
        }
        save = nil
    }

    private func rename() {
        let name = title.trimmingCharacters(in: .whitespaces)
        guard let pad, !name.isEmpty, name != pad.title else { title = pad?.title ?? title; return }
        Task {
            if let renamed = await workspace.renamePad(id, to: name) { self.pad?.title = renamed.title; title = renamed.title } else { title = pad.title }
        }
    }
}

/// Markdown as you type it, styled as it reads: headings large, emphasis and code shown, links clickable (a
/// zero://pad link opens that pad). Right-click copies the link of the section under the pointer.
private struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var scrollTo: String?
    let sectionLink: (String) -> (link: String, title: String)?
    let padLink: (link: String, title: String)
    let sections: [PadSection]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.verticalScroller = ThinScroller()
        scroll.scrollerStyle = .overlay
        let view = scroll.documentView as! NSTextView
        view.delegate = context.coordinator
        view.textStorage?.delegate = context.coordinator
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.font = MarkdownStyle.body
        view.typingAttributes = MarkdownStyle.base
        // Markdown is meant as typed: no curly quotes, dashes or replaced text.
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.linkTextAttributes = [.foregroundColor: NSColor.controlAccentColor, .cursor: NSCursor.pointingHand]
        view.textContainerInset = NSSize(width: 44, height: 8)
        view.string = text
        context.coordinator.view = view
        // A column at most about 720 wide, centred as the window widens.
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.resized), name: NSView.frameDidChangeNotification, object: scroll.contentView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text {
            let selection = view.selectedRanges
            view.string = text
            view.selectedRanges = selection.filter { $0.rangeValue.upperBound <= (text as NSString).length }
        }
        if let slug = scrollTo, let section = sections.first(where: { $0.slug == slug }) {
            DispatchQueue.main.async {
                scrollTo = nil
                let lines = (view.string as NSString)
                var location = 0
                for _ in 1..<section.line { location = NSMaxRange(lines.lineRange(for: NSRange(location: location, length: 0))) }
                let range = lines.lineRange(for: NSRange(location: min(location, lines.length), length: 0))
                view.scrollRangeToVisible(range)
                view.setSelectedRange(NSRange(location: range.location, length: 0))
                view.showFindIndicator(for: range)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: MarkdownEditor
        weak var view: NSTextView?
        init(_ parent: MarkdownEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view else { return }
            parent.text = view.string
        }

        func textStorage(_ storage: NSTextStorage, didProcessEditing edited: NSTextStorageEditActions, range: NSRange, changeInLength: Int) {
            guard edited.contains(.editedCharacters) else { return }
            MarkdownStyle.apply(to: storage)
        }

        @objc func resized(_ note: Notification) {
            guard let view, let clip = note.object as? NSView else { return }
            view.textContainerInset = NSSize(width: max(44, (clip.bounds.width - 720) / 2), height: 8)
        }

        func textView(_ view: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return false }
            NSWorkspace.shared.open(url)
            return true
        }

        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            let line = (view.string as NSString).substring(to: min(charIndex, (view.string as NSString).length)).filter { $0 == "\n" }.count + 1
            var items: [NSMenuItem] = []
            if let section = parent.sections.last(where: { $0.line <= line }), let found = parent.sectionLink(section.slug) {
                items.append(LinkItem(title: "Copy Link to “\(section.title)”", link: found.link, label: found.title))
            }
            items.append(LinkItem(title: "Copy Link to Scratchpad", link: parent.padLink.link, label: parent.padLink.title))
            for (index, item) in items.enumerated() { menu.insertItem(item, at: index) }
            menu.insertItem(.separator(), at: items.count)
            return menu
        }
    }

    /// A menu item that copies a Markdown link.
    final class LinkItem: NSMenuItem {
        let link: String, label: String
        init(title: String, link: String, label: String) {
            self.link = link
            self.label = label
            super.init(title: title, action: #selector(copyLink), keyEquivalent: "")
            target = self
        }
        required init(coder: NSCoder) { fatalError() }
        @objc func copyLink() { PadLinks.copy(link, title: label, markdown: true) }
    }
}

/// How Markdown is shown: the text stays as typed, its marks dimmed, its meaning styled.
enum MarkdownStyle {
    static let body = NSFont.systemFont(ofSize: 14)
    static let mono = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.3
        style.paragraphSpacing = 2
        return style
    }()
    static let base: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = [.anchorsMatchLines]) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }
    private static let fence = regex("^(```|~~~)[^\\n]*\\n[\\s\\S]*?(^(```|~~~)[ \\t]*$|\\z)")
    private static let heading = regex("^(#{1,6})[ \\t]+.*$")
    private static let bold = regex("(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1")
    private static let italic = regex("(?<![*_\\w])([*_])(?=\\S)([^*_\\n]+?)(?<=\\S)\\1(?![*_\\w])")
    private static let code = regex("`[^`\\n]+`")
    private static let link = regex("\\[([^\\]\\n]+)\\]\\(([^)\\s]+)\\)")
    private static let bare = regex("(?<![(<\\[])\\b(zero|https?)://[^\\s)>\\]]+")
    private static let marker = regex("^[ \\t]*([-*+]|\\d+[.)])[ \\t]+(\\[[ xX]\\][ \\t]+)?")
    private static let quote = regex("^>[^\\n]*")
    private static let rule = regex("^(-{3,}|\\*{3,})[ \\t]*$")

    static func apply(to storage: NSTextStorage) {
        let text = storage.string
        let whole = NSRange(location: 0, length: (text as NSString).length)
        storage.setAttributes(base, range: whole)
        let dim = NSColor.tertiaryLabelColor
        var fenced: [NSRange] = []
        for match in fence.matches(in: text, range: whole) {
            fenced.append(match.range)
            storage.addAttributes([.font: mono, .foregroundColor: NSColor.secondaryLabelColor, .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.08)], range: match.range)
        }
        let outside = { (range: NSRange) in !fenced.contains { NSIntersectionRange($0, range).length > 0 } }
        for match in heading.matches(in: text, range: whole) where outside(match.range) {
            let level = match.range(at: 1).length
            let size: CGFloat = [24, 20, 17, 15, 14, 14][level - 1]
            storage.addAttributes([.font: NSFont.systemFont(ofSize: size, weight: level <= 2 ? .bold : .semibold)], range: match.range)
            storage.addAttribute(.foregroundColor, value: dim, range: match.range(at: 1))
        }
        for match in bold.matches(in: text, range: whole) where outside(match.range) {
            let font = (storage.attribute(.font, at: match.range.location, effectiveRange: nil) as? NSFont) ?? body
            storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask), range: match.range)
            for mark in [NSRange(location: match.range.location, length: 2), NSRange(location: NSMaxRange(match.range) - 2, length: 2)] {
                storage.addAttribute(.foregroundColor, value: dim, range: mark)
            }
        }
        for match in italic.matches(in: text, range: whole) where outside(match.range) {
            let font = (storage.attribute(.font, at: match.range.location, effectiveRange: nil) as? NSFont) ?? body
            storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask), range: match.range)
        }
        for match in code.matches(in: text, range: whole) where outside(match.range) {
            storage.addAttributes([.font: mono, .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.12)], range: match.range)
        }
        for match in marker.matches(in: text, range: whole) where outside(match.range) {
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: match.range)
        }
        for match in quote.matches(in: text, range: whole) where outside(match.range) {
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: match.range)
        }
        for match in rule.matches(in: text, range: whole) where outside(match.range) {
            storage.addAttribute(.foregroundColor, value: dim, range: match.range)
        }
        for match in link.matches(in: text, range: whole) where outside(match.range) {
            let target = (text as NSString).substring(with: match.range(at: 2))
            if let url = URL(string: target) { storage.addAttribute(.link, value: url, range: match.range(at: 1)) }
            storage.addAttribute(.foregroundColor, value: dim, range: NSRange(location: match.range(at: 1).location + match.range(at: 1).length, length: match.range(at: 2).length + 3))
        }
        for match in bare.matches(in: text, range: whole) where outside(match.range) {
            if let url = URL(string: (text as NSString).substring(with: match.range)) { storage.addAttribute(.link, value: url, range: match.range) }
        }
    }
}
