import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Zero in the share sheet: the images (or a video) shared, sent to a task (or a new one in a project) with a line to go
/// with them, through the tunnel as the app does. A video goes as Record's do: frames through it, said what they are.
/// The Mac keeps each image where zerod reads it (its "upload"), and the message carries their paths.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
            .filter {
                $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
                    || $0.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
            }
        let view = ShareView(providers: providers) { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        let host = UIHostingController(rootView: view.tint(Theme.knob))
        // Zero's ink for the caret and selection too, as the app's (its AccentColor), not the system blue.
        host.view.tintColor = UIColor(Theme.knob)
        addChild(host)
        host.view.frame = self.view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}

struct ShareView: View {
    let providers: [NSItemProvider]
    let done: () -> Void
    @State private var link: ZerodLink?
    @State private var rows: [BoardRow] = []
    @State private var projects: [String] = []
    /// What it goes to: a task ("task:" and its session) or a new task in a place ("new:" and its folder).
    @State private var picked: String?
    @State private var text = ""
    @State private var problem: String?
    @State private var sending = false
    @State private var thumbnails: [UIImage] = []
    @State private var choosingPlace = false
    @FocusState private var writing: Bool
    /// The video shared, if one was: it goes as its frames.
    private var video: NSItemProvider? { providers.first { $0.hasItemConformingToTypeIdentifier(UTType.movie.identifier) } }

    /// The new task's place, when one is picked.
    private var place: String? { picked.flatMap { $0.hasPrefix("new:") ? String($0.dropFirst(4)) : nil } }

    var body: some View {
        VStack(spacing: 0) {
            top
            // As the app's Tasks list: the same rows, in the same order (TaskRow), ticked when picked; then a new task's
            // place, picked as New task picks one.
            List {
                box.listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 12, trailing: 16)).listRowSeparator(.hidden)
                if let problem {
                    Text(problem).foregroundStyle(.red).font(.footnote).listRowSeparator(.hidden)
                }
                Section {
                    ForEach(rows) { row in
                        TaskRow(row: row, said: row.needs ?? row.now, picked: picked == "task:" + row.session) {
                            picked = "task:" + row.session
                            writing = false
                        }
                    }
                } header: {
                    heading("Send to a task")
                }
                if !projects.isEmpty {
                    Section {
                        placePill.listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 16, trailing: 16)).listRowSeparator(.hidden)
                        if choosingPlace {
                            places.listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 16, trailing: 16)).listRowSeparator(.hidden)
                        }
                    } header: {
                        heading("Or start one in")
                    }
                }
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.interactively)
        }
        .task { await connect() }
        .task { await loadThumbnails() }
    }

    /// As New task's: close on the left, what's shared in the middle, send on the right (the accent's once it can go).
    private var top: some View {
        HStack {
            Button(action: done) { glyph("xmark-outline") }
                .buttonStyle(.plain).glassEffect(.regular.interactive(), in: Circle()).accessibilityLabel("Close")
            Spacer(minLength: 12)
            Text(video != nil ? "1 video" : providers.count == 1 ? "1 image" : "\(providers.count) images").font(.headline)
            Spacer(minLength: 12)
            SendCircle(ready: picked != nil, sending: sending) { Task { await send() } }
        }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 8)
    }

    /// As the app's composer, open: what's shared above the words, in one glass box.
    private var box: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !thumbnails.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, image in
                            Image(uiImage: image).resizable().scaledToFill().frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay {
                                    if video != nil {
                                        Image("media-play-glyph").resizable().frame(width: 10, height: 10).foregroundStyle(.white)
                                            .frame(width: 22, height: 22).background(.black.opacity(0.55), in: Circle())
                                    }
                                }
                        }
                    }
                }
                .scrollClipDisabled()
            }
            TextField("What should it look at?", text: $text, axis: .vertical).lineLimit(1...6).focused($writing)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28))
    }

    /// New task's place pill: the folder, picked from Zero's own list.
    private var placePill: some View {
        Button {
            choosingPlace.toggle()
        } label: {
            HStack(spacing: 8) {
                Image("folder-glyph").resizable().frame(width: 18, height: 18).foregroundStyle(.blue)
                Text(place.map { ($0 as NSString).lastPathComponent } ?? "Folder").font(.body.weight(.medium)).lineLimit(1)
                if place != nil {
                    Image("circle-check-glyph").resizable().frame(width: 18, height: 18).foregroundStyle(Theme.knob)
                }
            }
            .padding(.horizontal, 16).frame(height: 44).contentShape(Capsule())
        }
        .buttonStyle(.plain).glassEffect(.regular.interactive(), in: Capsule())
    }

    /// The places, under the pill: drawn in place (a popover from a list's row didn't open in the share sheet).
    private var places: some View {
        ChoiceList(rows: projects.map { (id: $0, title: ($0 as NSString).lastPathComponent) }, selected: place ?? "") {
            picked = "new:" + $0
            choosingPlace = false
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).textCase(nil)
    }

    private func glyph(_ name: String) -> some View {
        Image(name).resizable().frame(width: 20, height: 20).frame(width: 44, height: 44).contentShape(Circle())
    }

    /// What's shared, small: each image, or the video's first frame.
    private func loadThumbnails() async {
        if let video {
            guard let file = await movie(video) else { return }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 168, height: 168)
            if let frame = try? await generator.image(at: .zero).image { thumbnails = [UIImage(cgImage: frame)] }
            return
        }
        for provider in providers.prefix(8) {
            if let data = await imageData(provider),
                let image = UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 168, height: 168))
            {
                thumbnails.append(image)
            }
        }
    }

    private func imageData(_ provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { done in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in done.resume(returning: data) }
        }
    }

    private func connect() async {
        guard let pairing = Pairing.load(), let lines = try? TunnelLines(pairing: pairing) else {
            #if DEBUG && targetEnvironment(simulator)
                // Unpaired in the Simulator: a few tasks as the Mac lists them, to see the sheet with.
                let now = Int(Date().timeIntervalSince1970 * 1000)
                let sample: [[String: Any]] = [
                    [
                        "session": "a", "task": "Server status dashboard", "state": "working", "provider": "claude",
                        "now": "Wiring the uptime checks into the page", "at": now - 60_000,
                    ],
                    [
                        "session": "b", "task": "Zero", "state": "answered", "provider": "claude",
                        "now": "The fade above the composer now shows only while text runs under it.", "at": now - 300_000,
                    ],
                    [
                        "session": "c", "task": "HaloPSA (U-9378)", "state": "handed", "provider": "codex", "now": "Ready for your review",
                        "at": now - 3_600_000,
                    ],
                    ["session": "d", "task": "Website and docs for Zero", "state": "idle", "provider": "claude", "at": now - 86_400_000],
                ].map { $0.merging(["place": "/work", "online": true, "asks": [], "workers": 0, "workspace": "zero"]) { a, _ in a } }
                rows = sample.compactMap { try? JSONDecoder().decode(BoardRow.self, from: JSONSerialization.data(withJSONObject: $0)) }
                projects = ["/Users/me/zero", "/Users/me/site", "/Users/me/hallow"]
            #else
                problem = "Pair Zero with your Mac first."
            #endif
            return
        }
        let link = ZerodLink(connection: lines)
        self.link = link
        do {
            // The Tasks list's: the app's workspace, the Mac's sidebar arrangement.
            let workspace = Keychain.read("workspace").map { String(decoding: $0, as: UTF8.self) } ?? "zero"
            let sidebar = (try? await link.call("sidebar", [:])) as? [String: String] ?? [:]
            rows = BoardRow.sorted(
                try await link.board().filter { $0.workspace == workspace },
                by: BoardRow.Sort(rawValue: sidebar["sort"] ?? "") ?? .state, order: sidebar["order"] ?? "")
            projects = (try? await link.call("projects")) as? [String] ?? []
        } catch {
            problem = "Can't reach \(Pairing.load()?.name ?? "your Mac"). Zero needs to be open there."
        }
    }

    private func send() async {
        guard let link, let picked else { return }
        sending = true
        defer { sending = false }
        do {
            var images: [Data] = []
            var about: String?
            if let video {
                guard let file = await movie(video), let recording = await Recording.read(file, transcribe: false) else {
                    problem = "Couldn't read that video."
                    return
                }
                images = recording.frames
                about = recording.text
            } else {
                for provider in providers { if let image = await jpeg(provider) { images.append(image) } }
            }
            var paths: [String] = []
            for (index, image) in images.enumerated() {
                if let path = try await link.call("upload", ["name": "shared-\(index + 1).jpg", "data": image.base64EncodedString()])
                    as? String
                {
                    paths.append(path)
                }
            }
            let asked =
                text.isEmpty ? (about == nil ? "Have a look at \(paths.count == 1 ? "this" : "these")." : "Have a look at this.") : text
            let words = [asked, about].compactMap { $0 }.joined(separator: "\n\n")
            if picked.hasPrefix("task:") {
                try await link.send(session: String(picked.dropFirst(5)), text: words, images: paths)
            } else {
                // With the agent New task last started one with, as the app would.
                let provider =
                    Keychain.read("newTaskProvider").flatMap { Provider(rawValue: String(decoding: $0, as: UTF8.self)) } ?? .claude
                _ = try await link.start(provider: provider, cwd: String(picked.dropFirst(4)), prompt: words, images: paths)
            }
            done()
        } catch {
            problem = "Couldn't send: \(error.localizedDescription)"
        }
    }

    /// The video as a file of the extension's own, to read its frames from (the one handed over goes when this returns).
    private func movie(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { done in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                guard let url else { done.resume(returning: nil); return }
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(
                    url.pathExtension)
                done.resume(returning: (try? FileManager.default.copyItem(at: url, to: copy)) != nil ? copy : nil)
            }
        }
    }

    /// The image as a JPEG, whatever it was (a screenshot's PNG, a photo's HEIC): what every agent reads.
    private func jpeg(_ provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { done in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                done.resume(returning: data.flatMap(UIImage.init(data:))?.jpegData(compressionQuality: 0.9))
            }
        }
    }
}
