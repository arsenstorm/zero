import AVFoundation
import PhotosUI
import Speech
import SwiftUI

/// Writing to a task: one glass box, the words on top and its controls under them (photos, the model, dictation,
/// send), as ChatGPT's composer has them.
struct Composer: View {
    let model: PhoneModel
    let conversation: Conversation?
    let session: String
    /// What it opens over the page (photos, the model's sheet) and the choices for the next message, held by the page.
    let panels: ComposerPanels
    @State private var draft = ""
    /// What's attached: photos, and videos (a screen recording) with a still of each.
    @State private var attached: [Attached] = []
    struct Attached {
        let item: PhotosPickerItem
        let image: UIImage
        var video: URL? = nil
    }
    /// Chosen here for the next message; until then, the task's own.
    @State private var dictation = Dictation()
    @State private var sending = false
    /// Being written in: its own text view is first responder (ComposerField).
    @State private var focused = false
    /// How open the box is, 0 (the capsule) to 1 (ComposerLayout): as far as the keyboard is up.
    @State private var open: Double = 0
    /// The keyboard's room now, and when it's all the way up.
    @State private var keyboardRoom: CGFloat = 0
    @State private var keyboardFull: CGFloat = 0
    /// When the field took focus: with no keyboard on screen a moment after, the box opens anyway.
    @State private var focusedAt: Date?
    /// The queue strip's rows as last shown (kept while it folds away).
    @State private var stripRows: [Queued] = []
    /// The box's height: its scroll view (KeyboardDrag) is as tall as it.
    @State private var height: CGFloat = 48

    private var empty: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attached.isEmpty }
    /// Not being written in (the keyboard down, not listening): one slim capsule, whatever's in it. What's written
    /// shows as its first line and sends from there; a tap opens it again, all of it there.
    private var compact: Bool { !focused && !dictation.listening }

    /// Asks for the picker, which hangs off the composer itself: the button moves as the composer folds and opens
    /// (opening the picker takes the keyboard, which folds it), and a sheet on the button went with it, closing at once.
    private var photos: some View {
        Button {
            panels.picking = true
        } label: {
            Image("plus-outline").resizable().frame(width: 20, height: 20).frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add photos")
    }

    private var microphone: some View {
        Button {
            dictation.listening ? dictation.stop() : dictation.start(after: draft) { draft = $0 }
        } label: {
            Image("microphone-outline").resizable().frame(width: 20, height: 20)
                .foregroundStyle(dictation.listening ? Color.white : Color.primary)
                .frame(width: 34, height: 40)
                .background(dictation.listening ? Color.red : .clear, in: Circle())
                .contentShape(Rectangle())
        }
    }

    /// Working (or waiting on you): what's written waits for after this turn, and with nothing written, Stop.
    private var busy: Bool { conversation?.status == .working || conversation?.status == .waiting }

    @ViewBuilder private var sendButton: some View {
        if busy && empty {
            Button {
                Task { await model.interrupt(session) }
            } label: {
                Image("media-stop-glyph").resizable().frame(width: 14, height: 14)
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    // The label's own colour, not .primary: on the glass, .primary is drawn vibrant, and Stop came out grey
                    // (#525252) beside a white Send.
                    .frame(width: 40, height: 40).background(Color(uiColor: .label), in: Circle())
            }
            .accessibilityLabel("Stop")
        } else {
            Button(action: send) {
                Image("arrow-up-outline").resizable().frame(width: 18, height: 18)
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .frame(width: 40, height: 40)
                    .background(Color.primary.opacity(empty ? 0.25 : 1), in: Circle())
            }
            .disabled(empty || sending)
            .accessibilityLabel(busy ? "Queue for after this turn" : "Send")
        }
    }

    /// What waits for after this turn, above the box: each back into it on a tap, Steer to send it now; held since
    /// the agent was stopped, Send lets it go on.
    /// What zerod lists, and what's just been queued from here and isn't listed yet (PhoneModel.queuing).
    private var queuedNow: [Queued] {
        let listed = model.row(session)?.queued ?? []
        return listed + (model.queuing[session] ?? []).filter { mine in !listed.contains { $0.id == mine.id } }
    }

    @ViewBuilder private var queueStrip: some View {
        let row = model.row(session)
        // What zerod lists, and what's just been queued from here and isn't listed yet (PhoneModel.queuing).
        let queued = stripRows
        let held = row?.held == true
        if !queued.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(held ? "media-stop-glyph" : "clock-glyph").resizable().frame(width: 12, height: 12)
                    Text(held ? "Held" : "Queued").font(.footnote.weight(.medium))
                    Spacer()
                    if held {
                        Button("Send") { Task { await model.release(session) } }.font(.footnote.weight(.semibold)).foregroundStyle(.primary)
                    }
                }
                .foregroundStyle(.secondary).padding(.horizontal, 16).frame(height: 32)
                ForEach(queued) { item in
                    HStack(spacing: 8) {
                        Button {
                            Task {
                                if await model.unqueue(session, item: item.id) {
                                    draft = draft.isEmpty ? item.text : draft + "\n" + item.text; focused = true
                                }
                            }
                        } label: {
                            Text(item.text).font(.subheadline).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).contentShape(
                                Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button {
                            Task { _ = await model.unqueue(session, item: item.id) }
                        } label: {
                            Image("trash-outline").resizable().frame(width: 16, height: 16).foregroundStyle(.secondary).frame(
                                width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Delete")
                        Button {
                            Task { await model.steer(session, item: item) }
                        } label: {
                            HStack(spacing: 4) {
                                Text("Steer").font(.footnote.weight(.medium))
                                Image("arrow-turn-up-2-outline").resizable().frame(width: 12, height: 12)
                            }
                            .padding(.horizontal, 10).frame(height: 28).background(.quaternary, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.leading, 16).padding(.trailing, 6).frame(height: 40)
                }
            }
            .padding(.bottom, 4)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 12).padding(.bottom, 6)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Grown in and folded away by its height, not put in and taken out: its room at the page's foot changes a
            // little each frame and the page follows it (taken out in a frame, the page dropped 82 pt at once). What it
            // listed stays in it while it folds.
            Unfold(shown: queuedNow.isEmpty ? 0 : 1) { queueStrip }
                .opacity(queuedNow.isEmpty ? 0 : 1)
                .clipped()
                .accessibilityHidden(queuedNow.isEmpty)
            // In a scroll view of its own, which doesn't scroll: dragged down, iOS's own interactive dismissal takes the
            // keyboard down with the finger and the box rides on it (a box moved by hand went under the keyboard), and a
            // drag cancels its buttons' taps, as in any scroll view.
            ScrollView {
                box.onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    height = $0
                }
                .background(KeyboardDrag())
            }
            .scrollClipDisabled()
            .scrollIndicators(.hidden)
            .scrollDisabled(compact)
            // Not dismissed the way the conversation's is (the keyboard following the finger): Messages' input bar
            // doesn't, a swipe on it closes the keyboard (KeyboardDrag).
            .scrollDismissesKeyboard(.never)
            .frame(height: height)
        }
        .animation(.smooth(duration: 0.25), value: queuedNow.isEmpty)
        .onChange(of: queuedNow, initial: true) { _, now in if !now.isEmpty { stripRows = now } }
        // What's written is kept on the phone as it's typed: back after the app is closed or restarted, gone once sent.
        .onAppear { if draft.isEmpty, let kept = UserDefaults.standard.string(forKey: draftKey) { draft = kept } }
        .onChange(of: draft) { _, text in
            if text.isEmpty {
                UserDefaults.standard.removeObject(forKey: draftKey)
            } else {
                UserDefaults.standard.set(text, forKey: draftKey); model.warm(session)
            }
        }
    }

    private var draftKey: String { "draft." + session }

    /// As the Mac's composer words it: "Reply", "Message to resume it" when it's gone. While it works the phone queues
    /// what's sent for after the turn (it never steers), so it says that, not the Mac's "Steer it while it works".
    private var placeholder: String {
        switch conversation?.status {
        case .offline: "Message to resume it"
        case .working, .waiting: "Queue a message for after this turn"
        default: "Reply"
        }
    }

    /// Open as far as the keyboard is up; all the way for dictation, or once a moment has passed with the field
    /// focused and no keyboard on screen.
    private func follow() {
        let shown = keyboardFull > 0 ? Double(min(1, keyboardRoom / keyboardFull)) : 0
        let noKeyboard = keyboardRoom < 1 && (focusedAt.map { Date().timeIntervalSince($0) > 0.3 } ?? false)
        let target: Double = dictation.listening || (!compact && noKeyboard) ? 1 : shown
        if abs(open - target) > 0.001 { open = target }
    }

    private var box: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Folded too: smaller, so what's attached is still seen.
            if !attached.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: compact ? 6 : 8) {
                        ForEach(Array(attached.enumerated()), id: \.offset) { index, one in
                            Image(uiImage: one.image).resizable().scaledToFill().frame(width: compact ? 40 : 56, height: compact ? 40 : 56)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay {
                                    if one.video != nil {
                                        Image("media-play-glyph").resizable().frame(width: 10, height: 10).foregroundStyle(.white)
                                            .frame(width: 22, height: 22).background(.black.opacity(0.55), in: Circle())
                                    }
                                }
                                .overlay(alignment: .topTrailing) {
                                    Button {
                                        let item = attached.remove(at: index).item
                                        panels.picked.removeAll { $0 == item }
                                    } label: {
                                        Image("xmark-outline").resizable().frame(width: 9, height: 9).foregroundStyle(.white)
                                            .frame(width: 18, height: 18).background(.black.opacity(0.6), in: Circle())
                                    }
                                    .padding(3)
                                }
                        }
                    }
                    .padding(.horizontal, compact ? 12 : 14).padding(.top, compact ? 10 : 14)
                }
            }
            // One box in both shapes, its parts the same views throughout, moved by one layout (ComposerLayout) as
            // `open` goes from 0 to 1 on the keyboard's curve: the field (its line limit never changes, so it never
            // keeps a stale scroll; closed, it's hidden and takes no taps), the closed line, +, the menus, mic and send.
            ComposerLayout(open: open, text: draft) {
                ComposerField(text: $draft, focused: $focused)
                    .overlay(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text(dictation.listening ? "Listening…" : placeholder).foregroundStyle(.tertiary).allowsHitTesting(
                                false)
                        }
                    }
                    // The two placeholders hand over halfway through the box's opening, never both at once (cross-faded,
                    // they showed twice, a ghost).
                    .opacity(max(0, open * 2 - 1))
                    .allowsHitTesting(!compact)
                // Closed: the draft's first line, fading if there's more, or the placeholder.
                Group {
                    if draft.isEmpty {
                        Text(dictation.listening ? "Listening…" : placeholder).foregroundStyle(.tertiary).lineLimit(1)
                    } else {
                        FadingLine(text: draft.split(whereSeparator: \.isNewline).joined(separator: " "), font: .body)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(max(0, 1 - open * 2))
                .allowsHitTesting(false)
                photos
                // In once the box has room for them.
                modelMenu.opacity(max(0, open * 2 - 1)).allowsHitTesting(!compact)
                permissionsMenu.opacity(max(0, open * 2 - 1)).allowsHitTesting(!compact)
                microphone
                sendButton
            }
        }
        .foregroundStyle(.primary)
        // Closed, a tap anywhere on it opens it, the caret at the end (its +, mic and send keep their own taps).
        .contentShape(RoundedRectangle(cornerRadius: 24 + 4 * open))
        .gesture(
            TapGesture().onEnded {
                focused = true
            }, including: compact ? .all : .subviews
        )
        // Clipped to its shape: what's inside never shows outside the glass as it grows. Concentric: the 40 pt buttons
        // sit 4 pt in a 48 pt capsule (20 + 4), 8 pt in the open box (20 + 8). Closed, it also sits further in from the
        // screen's edges, so its round ends follow the screen's corners.
        .clipShape(RoundedRectangle(cornerRadius: 24 + 4 * open))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24 + 4 * open))
        .padding(.horizontal, 30 - 18 * open).padding(.bottom, 2 + 6 * open)
        // Open as far as the keyboard is up, frame by frame (KeyboardFollow): it opens as the keyboard rises and
        // closes as it goes, a finger's drag included, one motion with it. Animated on its own, the box went on
        // closing after a dragged keyboard had gone (measured: 0.2 s late, iOS saying nothing till the finger lifted).
        // Dictation, or a field with no keyboard on screen (a hardware one): open anyway.
        .background {
            KeyboardFollow { room, full in
                keyboardRoom = room
                keyboardFull = full
                follow()
            }
        }
        .onChange(of: compact, initial: true) { _, now in
            focusedAt = now ? nil : Date()
            follow()
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                follow()
            }
        }
        .onChange(of: panels.picked) {
            Task {
                var loaded: [Attached] = []
                for item in panels.picked {
                    if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                        // A video: the file itself, sent as the Mac sends one (PhoneModel.send), a still for its tile.
                        if let video = try? await item.loadTransferable(type: PickedVideo.self) {
                            loaded.append(Attached(item: item, image: await PickedVideo.still(video.url), video: video.url))
                        }
                    } else if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        loaded.append(Attached(item: item, image: image))
                    }
                }
                attached = loaded
            }
        }
        // Its request waits for the link while it reconnects (PhoneModel.linked), so it comes back full.
        .task(id: conversation?.provider) {
            if let provider = conversation?.provider { panels.models = await model.models(provider) }
        }
        .onDisappear { dictation.stop() }
        // Words drafted elsewhere (Siri's "draft a message to …"): into the box, to look over and send.
        .onChange(of: model.drafts[session], initial: true) { _, words in
            guard let words else { return }
            draft = draft.isEmpty ? words : draft + "\n" + words
            model.drafts[session] = nil
        }
    }

    // What the agent may do without asking, as the Mac's chip: changed between turns (the agent starts again with it).
    // Mid-turn, as on the Mac: zerod keeps the change for the next turn, shown with a clock until then.
    private var permissionsMenu: some View {
        let pending = model.row(session)?.next?.permissions
        let shown = pending ?? conversation?.permissions ?? .auto
        let unrestricted = shown == .unrestricted
        // A menu, not a popover: a menu needs no page to be presented from (the composer is the keyboard's accessory).
        return Menu {
            // Each with what it means under it, as the Mac's list; the one in force ticked.
            ForEach(Permissions.choices(conversation?.provider), id: \.0) { choice, title, detail in
                Button {
                    Task { await model.setPermissions(session, choice) }
                } label: {
                    Text(title); Text(detail)
                    if choice == shown { Image("check-outline") }
                }
            }
        } label: {
            Image(unrestricted ? "bolt-lightning-glyph" : "wand-sparkle-outline").resizable().frame(width: 18, height: 18)
                .foregroundStyle(unrestricted ? Color.orange : Color.primary)
                .overlay(alignment: .topTrailing) {
                    if pending != nil {
                        Image("clock-glyph").resizable().frame(width: 9, height: 9).foregroundStyle(.secondary).offset(x: 6, y: -5)
                    }
                }
                .frame(width: 32, height: 40).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(conversation == nil)
        .accessibilityLabel(unrestricted ? "Permissions: unrestricted" : "Permissions: auto")
    }

    // The model and its effort, as "Opus 5.5 · High" (New task's): opens the Mac's selector, as a sheet.
    /// A model's id as people read it, for one not in the list: "claude-opus-5-5" is "Opus 5.5".
    static func readable(_ id: String) -> String {
        guard id.hasPrefix("claude-") else { return id }
        var words: [String] = []
        for part in id.dropFirst(7).split(separator: "-").map(String.init) {
            if let last = words.last, Int(part) != nil, last.last?.isNumber == true {
                words[words.count - 1] = last + "." + part
            } else {
                words.append(Int(part) != nil ? part : part.prefix(1).uppercased() + part.dropFirst())
            }
        }
        return words.joined(separator: " ")
    }

    private var modelMenu: some View {
        let id = panels.chosen?.model ?? conversation?.model
        let effort = panels.chosen?.effort ?? conversation?.effort
        let current = panels.models.first { $0.id == id }
        let name = current?.name ?? id.map(Self.readable) ?? conversation?.provider.title ?? ""
        let level = current?.levels.first { $0.id == effort }?.name ?? effort?.capitalized
        // Its list fetched again if it isn't in yet (a moment the Mac couldn't be reached): never stuck disabled.
        return Button {
            Task {
                if panels.models.isEmpty, let provider = conversation?.provider { panels.models = await model.models(provider) }
                if !panels.models.isEmpty { panels.selecting = true }
            }
        } label: {
            (Text(name).fontWeight(.medium) + Text(level.map { " · " + $0 } ?? "").foregroundStyle(.secondary))
                .font(.subheadline).lineLimit(1).padding(.horizontal, 7).frame(height: 40)
        }
        .buttonStyle(.plain)
    }

    private func send() {
        dictation.stop()
        let text = draft, choice = panels.chosen
        let photos = attached.filter { $0.video == nil }.compactMap { $0.image.jpegData(compressionQuality: 0.8) }
        let videos = attached.compactMap(\.video)
        draft = ""; attached = []; panels.picked = []; panels.chosen = nil
        // The keyboard can put words back that were mid-correction as the box emptied: emptied again once it's done.
        DispatchQueue.main.async { if !draft.isEmpty { draft = "" } }
        sending = true
        Task {
            defer { sending = false }
            do {
                // While it works, always after this turn: never steering it (a model picked mid-turn is zerod's
                // already, for the next turn). Sent with one that was, it interrupted the turn.
                if busy {
                    try await model.queue(text, images: photos, videos: videos, to: session)
                } else {
                    try await model.send(text, images: photos, videos: videos, to: session, model: choice?.model, effort: choice?.effort)
                }
            } catch { draft = text } // Back in the box, to send again.
        }
    }
}

/// Speech into the box as it's said: on the phone when it can, Apple's servers otherwise. What was written before
/// stays, the words follow it.
@MainActor @Observable final class Dictation {
    private(set) var listening = false
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?

    func start(after text: String, _ write: @escaping (String) -> Void) {
        Task {
            guard await Self.allowed(), let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { return }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.record, mode: .measurement, options: .duckOthers)
                try session.setActive(true, options: .notifyOthersOnDeactivation)
                let input = engine.inputNode
                Self.tap(input, into: request)
                engine.prepare()
                try engine.start()
            } catch {
                stop()
                return
            }
            self.request = request
            listening = true
            let before = text.trimmingCharacters(in: .whitespacesAndNewlines)
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let said = result?.bestTranscription.formattedString
                let done = error != nil || result?.isFinal == true
                Task { @MainActor in
                    // Stopped (the message sent, say): the recogniser's last word doesn't write the box again.
                    if let said, self?.listening == true { write(before.isEmpty ? said : before + " " + said) }
                    if done { self?.stop() }
                }
            }
        }
    }

    func stop() {
        guard listening || engine.isRunning else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        request = nil; task = nil
        listening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // Off the main actor: the audio thread calls it.
    nonisolated private static func tap(_ input: AVAudioInputNode, into request: SFSpeechAudioBufferRecognitionRequest) {
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in request.append(buffer) }
    }

    private static func allowed() async -> Bool {
        let speech = await withCheckedContinuation { done in
            SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0 == .authorized) }
        }
        return speech ? await AVAudioApplication.requestRecordPermission() : false
    }
}

/// The composer's parts, placed between their two shapes by `open` (0, the capsule; 1, the open box), so each moves
/// from one place to the other with the box: the field, the closed line, +, the model and permissions menus, mic, send.
/// Closed: + at the left, mic and send at the right, the line between, 48 pt high. Open: the field across the top, the
/// controls along the foot, 7 pt either side of each control's icon or words, 14 between any two.
struct ComposerLayout: Layout {
    var open: Double
    /// The draft: the field's height is measured from it here, so the box grows as it's typed (SwiftUI didn't measure
    /// the field's own text view again as its text changed).
    var text = ""

    var animatableData: Double {
        get { open }
        set { open = newValue }
    }

    private func field(_ subviews: Subviews, width: CGFloat) -> CGFloat {
        let font = UIFont.preferredFont(forTextStyle: .body)
        let fit = (text.isEmpty ? " " : text as NSString).boundingRect(
            with: CGSize(width: max(1, width - 36), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font], context: nil
        ).height
        return ceil(min(max(fit, font.lineHeight), font.lineHeight * 8))
    }

    /// The open box's height: the field (16 above it, 6 below), then the controls' row (40, 8 under it).
    private func openHeight(_ subviews: Subviews, width: CGFloat) -> CGFloat { 16 + field(subviews, width: width) + 6 + 40 + 8 }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 360
        let height = 48 + (openHeight(subviews, width: width) - 48) * open
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let w = bounds.width, x = bounds.minX, y = bounds.minY
        let t = CGFloat(open)
        func between(_ closed: CGFloat, _ opened: CGFloat) -> CGFloat { closed + (opened - closed) * t }
        let fieldHeight = field(subviews, width: w)
        // The field where it is open: hidden (and clipped by the box) while closed.
        subviews[0].place(at: CGPoint(x: x + 18, y: y + 16), proposal: ProposedViewSize(width: w - 36, height: fieldHeight))
        // The row's middle: the capsule's, or the open box's foot.
        let row = y + between(24, 16 + fieldHeight + 6 + 20)
        // + at the left; send and mic at the right (send 4 pt in closed, 8 open; mic 7 pt before it).
        subviews[2].place(at: CGPoint(x: x + between(24, 28), y: row), anchor: .center, proposal: ProposedViewSize(width: 40, height: 40))
        let send = x + w - between(24, 28)
        subviews[6].place(at: CGPoint(x: send, y: row), anchor: .center, proposal: ProposedViewSize(width: 40, height: 40))
        let mic = send - 20 - 7 - 17
        subviews[5].place(at: CGPoint(x: mic, y: row), anchor: .center, proposal: ProposedViewSize(width: 34, height: 40))
        // The menus before the mic, their own widths.
        let permissions = subviews[4].sizeThatFits(.unspecified)
        let model = subviews[3].sizeThatFits(.unspecified)
        let menusEnd = mic - 17
        subviews[4].place(
            at: CGPoint(x: menusEnd - permissions.width / 2, y: row), anchor: .center, proposal: ProposedViewSize(permissions))
        subviews[3].place(
            at: CGPoint(x: menusEnd - permissions.width - model.width / 2, y: row), anchor: .center, proposal: ProposedViewSize(model))
        // The closed line between + and the mic.
        let lineStart = x + 48
        subviews[1].place(
            at: CGPoint(x: lineStart, y: y + 24), anchor: .leading,
            proposal: ProposedViewSize(width: max(0, mic - 17 - 4 - lineStart), height: nil))
    }
}

/// The composer's scroll view, set to be dragged and never scrolled: always draggable (so a drag on the box begins at
/// all, and cancels its buttons' taps), held at its top. A drag down of 28 pt on it closes the keyboard there and then,
/// the finger still down, on the keyboard's own animation, as Messages' input bar does (measured in the Simulator:
/// nothing at 25 pt, closed at 30; the keyboard never follows the finger from the bar, only from the conversation).
struct KeyboardDrag: UIViewRepresentable {
    func makeUIView(context: Context) -> Hook { Hook() }
    func updateUIView(_ view: Hook, context: Context) {}

    final class Hook: UIView {
        /// 28 pt from where the finger came down: the pan counts from where it begins, about 10 pt on.
        static let swipe: CGFloat = 18
        private var watch: NSKeyValueObservation?
        private var swiped = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            isUserInteractionEnabled = false
            guard window != nil, watch == nil else { return }
            var view = superview
            while let next = view, !(next is UIScrollView) { view = next.superview }
            guard let scroll = view as? UIScrollView else { return }
            scroll.alwaysBounceVertical = true
            scroll.showsVerticalScrollIndicator = false
            scroll.panGestureRecognizer.addTarget(self, action: #selector(panned(_:)))
            watch = scroll.observe(\.contentOffset, options: [.new]) { scroll, _ in
                MainActor.assumeIsolated { if scroll.contentOffset.y != 0 { scroll.contentOffset.y = 0 } }
            }
        }

        @objc private func panned(_ pan: UIPanGestureRecognizer) {
            switch pan.state {
            case .began: swiped = false
            case .changed:
                guard !swiped, pan.translation(in: pan.view).y >= Self.swipe else { return }
                swiped = true
                // The drag ends there, as Messages' swipe does: closed while the finger was still moving fast, the
                // keyboard took its speed and was gone in a frame or two (Messages': the usual 10-frame close).
                pan.isEnabled = false
                pan.isEnabled = true
                DispatchQueue.main.async { [weak self] in self?.window?.endEditing(true) }
            default: break
            }
        }
    }
}

/// The composer's field, a text view of its own: one to eight lines as the draft grows, scrolling with UIKit's own
/// bounce past that, the caret at the end when it's opened from the capsule. A short draft doesn't scroll, so a drag
/// on it is the composer's (KeyboardDrag), which takes the keyboard down with the finger.
struct ComposerField: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.keyboardDismissMode = .interactive
        view.accessibilityIdentifier = "composer.field"
        // The swipe down that closes the keyboard, on the text too: its own gestures took the touch, and the box's never
        // began (measured: Messages' field closes on a swipe over typed text).
        let swipe = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swiped(_:)))
        swipe.delegate = context.coordinator
        swipe.cancelsTouchesInView = false
        view.addGestureRecognizer(swipe)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text { view.text = text }
        if focused, !view.isFirstResponder {
            DispatchQueue.main.async {
                guard !view.isFirstResponder, view.becomeFirstResponder() else { return }
                let end = view.endOfDocument
                view.selectedTextRange = view.textRange(from: end, to: end)
            }
        } else if !focused, view.isFirstResponder {
            DispatchQueue.main.async { view.resignFirstResponder() }
        }
    }

    /// As tall as ComposerLayout gives it: the layout measures the draft itself (a draft put back from before is
    /// measured before the text view has it).
    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: UITextView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 300, height: proposal.height ?? view.font?.lineHeight ?? 22)
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        private var swiped = false

        /// Down, and only when the text has nothing to scroll back to (fits, or is at its start): otherwise the drag
        /// is the text's, scrolling it back.
        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard let pan = gesture as? UIPanGestureRecognizer, let view = pan.view as? UITextView else { return false }
            let velocity = pan.velocity(in: view)
            let fits = view.contentSize.height <= view.bounds.height + 4
            let atStart = view.contentOffset.y <= -view.adjustedContentInset.top + 4
            return abs(velocity.y) >= abs(velocity.x) && (fits || atStart)
        }

        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        @objc func swiped(_ pan: UIPanGestureRecognizer) {
            switch pan.state {
            case .began: swiped = false
            case .changed:
                guard !swiped, pan.translation(in: pan.view).y >= KeyboardDrag.Hook.swipe else { return }
                swiped = true
                let view = pan.view as? UITextView
                pan.isEnabled = false
                pan.isEnabled = true
                closed = Date()
                DispatchQueue.main.async { view?.resignFirstResponder() }
            default: break
            }
        }

        var parent: ComposerField
        init(_ parent: ComposerField) { self.parent = parent }
        func textViewDidChange(_ view: UITextView) { parent.text = view.text }
        func textViewDidBeginEditing(_ view: UITextView) { if !parent.focused { parent.focused = true } }

        /// Not again as the finger that swiped it closed lifts off the text: the text view took the lift for a tap and
        /// opened the keyboard again (measured: 0.26 s after it closed).
        func textViewShouldBeginEditing(_ view: UITextView) -> Bool { Date().timeIntervalSince(closed) > 0.6 }
        private var closed = Date.distantPast
        func textViewDidEndEditing(_ view: UITextView) { if parent.focused { parent.focused = false } }
    }
}

/// What the composer opens over the page, and the choices it keeps for the next message: held by the page (TaskView),
/// which presents them.
@MainActor @Observable final class ComposerPanels {
    var picking = false
    var picked: [PhotosPickerItem] = []
    var selecting = false
    var models: [PhoneModel.ModelChoice] = []
    /// Chosen for the next message; until then, the task's own.
    var chosen: (model: String, effort: String?)?
}

/// A video picked to send (a screen recording): its file, copied out of the picker's reach.
struct PickedVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString + "-" + received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedVideo(url: copy)
        }
    }

    /// Its first frame, for its tile; a grey square if it has none.
    static func still(_ url: URL) async -> UIImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        if let frame = try? await generator.image(at: .zero).image { return UIImage(cgImage: frame) }
        return UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in
            UIColor.systemGray4.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }
}

/// Its content as tall as `shown` of its own height, laid out again every frame as `shown` animates (a frame's height
/// animates only in drawing: what's under it, the page's room at its foot, moved in one step).
struct Unfold: Layout {
    var shown: Double
    var animatableData: Double {
        get { shown }
        set { shown = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) ?? .zero
        return CGSize(width: proposal.width ?? size.width, height: size.height * shown)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        let size = content.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        content.place(
            at: CGPoint(x: bounds.minX, y: bounds.maxY - size.height), proposal: ProposedViewSize(width: bounds.width, height: size.height))
    }
}
