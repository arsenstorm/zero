import AppKit
import SwiftUI
import ZeroCore

/// A conversation's message being written (ConversationView's draft): observed by the composer alone.
@Observable final class DraftBox {
    var text = "" { didSet { if text != oldValue { saved(text) } } }
    @ObservationIgnored var saved: (String) -> Void = { _ in }
}

/// The message box, as the control bar's: its field ("/" for commands, "@" for the folder's files), the images going
/// with it, and a row of chips with the send button at its end.
struct Composer<Controls: View>: View {
    @Binding var draft: String
    let placeholder: String
    var canSend = true
    /// Where "@" finds files: the task's folder.
    var folder: String?
    /// Where the + finds scratchpads.
    var workspace: Workspace?
    /// Images going with the message: pasted, dropped, or picked with the +.
    @Binding var images: [URL]
    /// On the page shown; a composer on a page kept behind it gives the keyboard up.
    var active = true
    /// While the agent works: the send button stops it instead.
    var stop: (() -> Void)?
    /// While the agent works: what Return does (the message waits for after this turn); ⌘⏎ still sends to steer.
    var queue: (() -> Void)?
    /// A digit (1–9) typed with the composer empty, while a question waits above it: its option picked, as the
    /// inbox's numbers do. False leaves the digit to the composer.
    var pick: ((Int) -> Bool)?
    let send: () -> Void
    /// See-through, over the new task page's backdrop, which frosts what's under it (and a little way out, fading):
    /// the card itself draws nothing, no edge and no shadow.
    var translucent = false
    @ViewBuilder var controls: Controls
    @State private var focused = false
    /// Edits to the field from here (an image's token, a thumbnail's ×), undoable as typing is.
    @State private var handle = ComposeHandle()
    /// More text above or below what the field shows: a fade at that edge.
    @State private var fades = (top: false, bottom: false)
    /// Whether the text has focus, where the paste handler (AppKit's, outside SwiftUI's updates) can read it.
    @State private var focus = FocusBox()
    @State private var dropping = false
    @State private var monitor: Any?
    @State private var fieldHeight = ComposeField.lineHeight * 2
    /// The "/" or "@" suggestions open over the composer, and where the caret goes after one is taken.
    @State private var mention: InboxController.MentionState?
    @State private var mentionTask: Task<Void, Never>?
    @State private var mentionHeight: CGFloat = 0
    @State private var caret: Int?
    /// The + menu, open on its first page or on the scratchpads; where it and the + are, for a click outside it.
    @State private var adding: AddMenu.Page?
    @State private var addHeight: CGFloat = 0
    @State private var addFrame = CGRect.zero
    @State private var plusFrame = CGRect.zero
    @State private var addMonitor: Any?

    final class FocusBox { var on = false }
    /// Whether this composer's page is the one shown, where the typing and paste monitor (AppKit's, outside SwiftUI's
    /// updates) can read it: a page kept behind the shown one must leave the keyboard and the clipboard alone.
    @State private var shown = FocusBox()
    /// `pick` as it is now, for the monitor (made once, at appearing).
    final class PickBox { var pick: ((Int) -> Bool)? }
    @State private var picker = PickBox()

    /// The same switches as the control bar's composer (Settings → Inbox).
    private var suggestCommands: Bool { UserDefaults.standard.object(forKey: "suggestCommands") as? Bool ?? true }
    private var suggestFiles: Bool { UserDefaults.standard.object(forKey: "suggestFiles") as? Bool ?? false }

    var body: some View {
        // The images whose pill is in the words: one whose pills were deleted is out of the strip (and back with ⌘Z).
        let named = Set(ImageToken.find(in: draft).map(\.number))
        let attached = images.enumerated().filter { named.contains($0.offset + 1) }
        let ready = canSend && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attached.isEmpty)
        VStack(alignment: .leading, spacing: 12) {
            if !attached.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(attached, id: \.offset) { number, url in
                            // A click puts the image's token where the caret is; its pill opens the image.
                            let video = Attachments.isVideo(url)
                            Thumbnail(
                                path: (video ? Attachments.poster(url) : nil) ?? url.path,
                                tap: { insert(ImageToken.text(number + 1, video: video)) }, remove: { handle.remove(number + 1) }
                            )
                            .overlay { if video { VideoBadge() } }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
            ComposeField(
                text: $draft, placeholder: placeholder, focused: active && focused, editable: true,
                caret: caret, onCaretApplied: { caret = nil },
                onFocus: {
                    focused = $0; focus.on = $0
                },
                onSubmit: { if ready { (queue ?? send)() } },
                onCommandSubmit: queue == nil ? nil : { if ready { send() } },
                onTrigger: suggest, onKey: key, highlightFiles: suggestFiles,
                onImage: { number in
                    guard images.indices.contains(number - 1) else { return }
                    // A video's pill plays it, in the Mac's own player.
                    if Attachments.isVideo(images[number - 1]) { NSWorkspace.shared.open(images[number - 1]); return }
                    ImageViewer.shared.show(
                        images[number - 1].path, among: images.map(\.path).filter { !Attachments.isVideo(URL(fileURLWithPath: $0)) })
                },
                onAttach: { attach($0) },
                handle: handle, onEdges: { fades = (top: $0, bottom: $1) }, height: $fieldHeight
            )
            .frame(height: fieldHeight)
            .padding(.horizontal, -TokenTextView.inset.width) // the text still starts on the card's 14 pt
            // Scrolled inside: the text fades at an edge with more beyond it, so that more is seen to be there.
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [fades.top ? .clear : .black, .black], startPoint: .top, endPoint: .bottom).frame(height: 14)
                    Color.black
                    LinearGradient(colors: [.black, fades.bottom ? .clear : .black], startPoint: .top, endPoint: .bottom).frame(height: 14)
                }
            }
            HStack(spacing: translucent ? 2 : 6) {
                Button {
                    adding = adding == nil ? .add : nil
                } label: {
                    NucleoIcon("plus", size: translucent ? 17 : 15).foregroundStyle(.primary).frame(
                        width: translucent ? 32 : 28, height: translucent ? 32 : 28
                    )
                    .background(adding == nil ? .clear : translucent ? Theme.frostFill : Theme.row, in: Circle())
                }
                .buttonStyle(
                    Hovering(
                        radius: translucent ? 16 : 14, fill: translucent ? Theme.frostFill : Theme.row,
                        hover: translucent ? Theme.frostFill : Theme.row)
                )
                .tip("Add files, folders or a scratchpad")
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .global)
                } action: {
                    plusFrame = $0
                }
                // Roomy: 14 pt between one chip's words and the next (6 + 2 + 6); 24 read as gaps.
                HStack(spacing: translucent ? 2 : 6) { controls }.frame(maxWidth: .infinity, alignment: .leading).environment(
                    \.roomyComposer, translucent)
                if let stop {
                    Button(action: stop) {
                        NucleoIcon("media-stop", fill: "glyph", size: 12).foregroundStyle(Theme.onKnob).frame(width: 28, height: 28)
                            .background(Theme.knob, in: Circle())
                    }
                    .buttonStyle(.plain).keyboardShortcut(".", modifiers: .command).tip("Stop", shortcut: "⌘.")
                } else {
                    Button(action: send) {
                        // A solid paper plane: the thin arrow rendered soft. Nudged off-centre, as its point is up and right.
                        NucleoIcon("paper-plane", fill: "glyph", size: translucent ? 15 : 13).foregroundStyle(ready ? Theme.onKnob : .white)
                            .offset(x: -0.5, y: 0.5)
                            .frame(width: translucent ? 32 : 28, height: translucent ? 32 : 28).background(
                                ready ? Theme.knob : Theme.sendIdle, in: Circle())
                    }
                    .buttonStyle(.plain).keyboardShortcut(.return, modifiers: .command).disabled(!ready).tip("Send", shortcut: "⌘↩")
                }
            }
        }
        .padding(14)
        // The whole card focuses the text, not just its line; the chips and buttons keep their own clicks.
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .onTapGesture {
            focused = false
            DispatchQueue.main.async { focused = true }
        }
        // Codex's card: white on a hairline, lifted by a wide, soft shadow (and a close one that firms its edge), which
        // also falls on the folder tab behind its top.
        // Translucent, nothing of its own: the backdrop draws the frost under it (Dither's frost).
        .background(translucent ? .clear : Theme.field, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(dropping ? Color.accentColor : translucent ? .clear : Theme.fieldEdge, lineWidth: dropping ? 2 : 1)
        )
        .compositingGroup()
        // No card to lift when translucent: its words and chips would cast it.
        .shadow(color: .black.opacity(translucent ? 0 : 0.06), radius: 14, y: 5)
        .shadow(color: .black.opacity(translucent ? 0 : 0.03), radius: 1.5, y: 1)
        .overlay(alignment: .top) {
            if let mention {
                MentionList(state: mention, pick: accept, hover: { self.mention?.selected = $0 })
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height
                    } action: {
                        mentionHeight = $0
                    }
                    .offset(y: -mentionHeight - 6)
            }
        }
        // The + menu, as Codex's: the composer's width, just above it.
        .overlay(alignment: .top) {
            if let page = adding {
                AddMenu(
                    page: Binding(get: { page }, set: { adding = $0 }), pads: workspace?.pads ?? [],
                    files: {
                        adding = nil; addFiles()
                    },
                    pad: { pad in
                        adding = nil; insert("[\(pad.title)](\(pad.link))")
                    }
                )
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .global)
                } action: {
                    addFrame = $0; addHeight = $0.height
                }
                .offset(y: -addHeight - 6)
            }
        }
        .onChange(of: adding == nil) { _, closed in closed ? stopWatchingAdd() : watchAdd() }
        .task(id: workspace?.loopsVersion) { await workspace?.loadLoops() }
        .onChange(of: adding) { _, page in if page == .pads { Task { await workspace?.loadPads() } } }
        .onDrop(of: [.fileURL, .image], isTargeted: $dropping) { providers in
            Attachments.fromDrop(providers) { attach($0) }
            return true
        }
        // ⌘V with an image on the clipboard attaches it; anything else pastes into the text as usual. With nothing that
        // takes typing focused (a click into the conversation, say), typing or pasting goes to the composer, focused.
        .onAppear {
            guard monitor == nil else { return }
            let (focus, draft, focused, caret) = (focus, $draft, $focused, $caret)
            let attach = { (urls: [URL]) in attach(urls) }
            let shown = shown, picker = picker, images = $images
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard shown.on else { return event }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if flags.isDisjoint(with: [.command, .control, .option]), draft.wrappedValue.isEmpty, images.wrappedValue.isEmpty,
                    let digit = event.charactersIgnoringModifiers.flatMap(Int.init), (1...9).contains(digit),
                    (focus.on || !Self.takesTyping(event.window?.firstResponder)), picker.pick?(digit) == true
                {
                    return nil
                }
                let paste = flags == .command && event.charactersIgnoringModifiers == "v"
                if focus.on {
                    guard paste, let urls = Attachments.fromPasteboard(), !urls.isEmpty else { return event }
                    attach(urls)
                    return nil
                }
                // Only in the workspace's window (not a panel), and only when nothing there takes typing already: a
                // field, the inbox card's reply, a terminal. An answer's text (selectable, not editable) doesn't.
                guard let window = event.window, !(window is NSPanel), !Self.takesTyping(window.firstResponder) else { return event }
                let land = { (text: String) in
                    draft.wrappedValue += text
                    caret.wrappedValue = (draft.wrappedValue as NSString).length
                    focused.wrappedValue = true
                }
                if paste {
                    if let urls = Attachments.fromPasteboard(), !urls.isEmpty {
                        attach(urls)
                    } else if let text = NSPasteboard.general.string(forType: .string) {
                        land(text)
                    } else {
                        return event
                    }
                    return nil
                }
                // Words, not shortcuts (⌘, ⌃) or keys that move about (Return, Tab, Esc, arrows, Space).
                guard flags.isDisjoint(with: [.command, .control]), let typed = event.characters, Self.isWords(typed) else { return event }
                land(typed)
                return nil
            }
        }
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil; stopWatchingAdd()
        }
        .onChange(of: active, initial: true) {
            shown.on = active; if !active { focus.on = false }
        }
        .onAppear { picker.pick = pick }
        .onChange(of: pick == nil) { picker.pick = pick }
    }

    /// Whether what has the keyboard takes typing: an editable text view (a field's editor too), or anything that reads
    /// keys as text (a terminal). An answer's text view, selectable but not editable, doesn't.
    private static func takesTyping(_ responder: NSResponder?) -> Bool {
        if let text = responder as? NSTextView { return text.isEditable }
        return responder is NSTextInputClient
    }

    /// Printable characters other than a lone space: what starts a message.
    private static func isWords(_ text: String) -> Bool {
        guard !text.isEmpty, text != " " else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            // AppKit's arrow and function keys.
            !CharacterSet.controlCharacters.contains(scalar) && !(0xF700...0xF8FF).contains(scalar.value)
        }
    }

    // The + menu.

    /// Files and folders from an open panel: images go with the message, anything else into it as its path (from the
    /// task's folder when it's inside it), which the agent reads.
    private func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var paths: [String] = []
        var pictures: [URL] = []
        for url in panel.urls {
            if Attachments.isImage(url), let copied = Attachments.copy(url) { pictures.append(copied); continue }
            // A video: one attachment, its pill "Video"; stills from it go with it when it's sent (ImageToken.withVideos).
            if Attachments.isVideo(url), let copied = Attachments.copy(url) { pictures.append(copied); continue }
            var path = url.path
            if let folder, path.hasPrefix(folder + "/") { path = String(path.dropFirst(folder.count + 1)) }
            paths.append(path.contains(" ") ? "\"\(path)\"" : "@" + path)
        }
        if !paths.isEmpty { insert(paths.joined(separator: " ")) }
        attach(pictures)
    }

    /// Images attached, each leaving its token in the words: at the caret (a paste while typing is about that spot),
    /// else at the end.
    private func attach(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let first = images.count + 1
        images += urls
        for url in urls where Attachments.isVideo(url) { Attachments.prepare(url) }
        insert(urls.enumerated().map { ImageToken.text(first + $0.offset, video: Attachments.isVideo($0.element)) }.joined(separator: " "))
    }

    /// Words put in at the caret, through the field (undoable); it's focused after.
    private func insert(_ text: String) {
        handle.insert(text)
        if !focused { focused = true }
    }

    /// While the menu is open: a click outside it (and outside the +, which toggles it) or Esc closes it.
    private func watchAdd() {
        stopWatchingAdd()
        let (menu, plus, close) = ({ addFrame }, { plusFrame }, { adding = nil })
        addMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { event in
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event }
                close()
                return nil
            }
            guard let content = event.window?.contentView else { return event }
            // SwiftUI's global frames are in the window's content, from its top left.
            let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
            if !menu().contains(point) && !plus().contains(point) { close() }
            return event
        }
    }

    private func stopWatchingAdd() {
        if let addMonitor { NSEvent.removeMonitor(addMonitor) }
        addMonitor = nil
    }

    // Suggestions, as the control bar's composer makes them (InboxController.updateMention).

    private func suggest(_ trigger: MentionTrigger?) {
        mentionTask?.cancel()
        guard let trigger, trigger.symbol == "/" ? suggestCommands : true else { mention = nil; return }
        if trigger.symbol == "@" {
            // Loops first, always; the folder's files after them when that's on.
            let query = trigger.query.lowercased()
            let loops = (workspace?.loops ?? []).filter {
                query.isEmpty || $0.name.contains(query) || $0.description.lowercased().contains(query)
            }
            .map { Mention(kind: .loop, insert: "@" + $0.name, detail: $0.description.isEmpty ? "Loop" : $0.description) }
            guard suggestFiles, let folder else { show(trigger, loops); return }
            mentionTask = Task {
                let files = await ProjectFiles.list(folder)
                guard !Task.isCancelled else { return }
                show(
                    trigger,
                    loops + ProjectFiles.match(trigger.query, in: files).map { Mention(kind: .file, insert: "@" + $0, detail: nil) })
            }
            return
        }
        if trigger.symbol == "/" {
            let query = trigger.query.lowercased()
            let all = ClaudeCommands.all(projectPath: folder)
            let name = { (m: Mention) in m.insert.dropFirst().lowercased() }
            show(
                trigger,
                Array(
                    (all.filter { name($0).hasPrefix(query) } + all.filter { !name($0).hasPrefix(query) && name($0).contains(query) })
                        .prefix(8)))
        } else {
            guard let folder else { mention = nil; return }
            mentionTask = Task {
                let files = await ProjectFiles.list(folder)
                guard !Task.isCancelled else { return }
                show(trigger, ProjectFiles.match(trigger.query, in: files).map { Mention(kind: .file, insert: "@" + $0, detail: nil) })
            }
        }
    }

    private func show(_ trigger: MentionTrigger, _ items: [Mention]) {
        guard !items.isEmpty else { mention = nil; return }
        let sameWord = mention?.trigger.range.location == trigger.range.location
        mention = .init(key: "", trigger: trigger, items: items, selected: sameWord ? min(mention?.selected ?? 0, items.count - 1) : 0)
    }

    /// Arrows move, Tab or Return takes the highlighted suggestion, Esc closes the list.
    private func key(_ key: ComposeKey) -> Bool {
        guard var state = mention else { return false }
        switch key {
        case .up: state.selected = max(0, state.selected - 1); mention = state
        case .down: state.selected = min(state.items.count - 1, state.selected + 1); mention = state
        case .accept: accept(state.selected)
        case .dismiss: mention = nil
        }
        return true
    }

    /// The whole word under the caret replaced by the suggestion, a space after it unless one follows already.
    private func accept(_ index: Int) {
        guard let state = mention, state.items.indices.contains(index) else { return }
        let text = draft as NSString
        let word = state.trigger.word
        guard NSMaxRange(word) <= text.length else { mention = nil; return }
        let spaced =
            NSMaxRange(word) < text.length
            && text.substring(with: NSRange(location: NSMaxRange(word), length: 1)).rangeOfCharacter(from: .whitespacesAndNewlines) != nil
        let insert = state.items[index].insert + (spaced ? "" : " ")
        draft = text.replacingCharacters(in: word, with: insert)
        caret = word.location + (insert as NSString).length + (spaced ? 1 : 0)
        mention = nil
    }
}

extension Composer where Controls == EmptyView {
    init(
        draft: Binding<String>, placeholder: String, canSend: Bool = true, folder: String? = nil, workspace: Workspace? = nil,
        images: Binding<[URL]>,
        stop: (() -> Void)? = nil, send: @escaping () -> Void
    ) {
        self.init(
            draft: draft, placeholder: placeholder, canSend: canSend, folder: folder, workspace: workspace, images: images, stop: stop,
            send: send
        ) { EmptyView() }
    }
}

/// A video's tile: a play mark over its first still, so it reads as a video.
struct VideoBadge: View {
    var body: some View {
        NucleoIcon("media-play", fill: "glyph", size: 13).foregroundStyle(.white)
            .frame(width: 30, height: 30).background(.black.opacity(0.55), in: Circle()).allowsHitTesting(false)
    }
}
