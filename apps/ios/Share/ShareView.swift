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
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) || $0.hasItemConformingToTypeIdentifier(UTType.movie.identifier) }
        let view = ShareView(providers: providers) { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        let host = UIHostingController(rootView: view)
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
    @State private var picked: String?
    @State private var text = ""
    @State private var problem: String?
    @State private var sending = false
    /// The video shared, if one was: it goes as its frames.
    private var video: NSItemProvider? { providers.first { $0.hasItemConformingToTypeIdentifier(UTType.movie.identifier) } }

    var body: some View {
        NavigationStack {
            List(selection: $picked) {
                Section { TextField("What should it look at?", text: $text, axis: .vertical).lineLimit(2...6) }
                if let problem { Text(problem).foregroundStyle(.red).font(.footnote) }
                Section("Send to a task") {
                    ForEach(rows) { row in Text(row.task).lineLimit(1).tag("task:" + row.session) }
                }
                if !projects.isEmpty {
                    Section("Or start one in") {
                        ForEach(projects, id: \.self) { folder in Text((folder as NSString).lastPathComponent).tag("new:" + folder) }
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle(video != nil ? "1 video" : providers.count == 1 ? "1 image" : "\(providers.count) images")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: done) }
                ToolbarItem(placement: .confirmationAction) {
                    if sending { Spinner().frame(width: 18, height: 18) } else { Button("Send") { Task { await send() } }.disabled(picked == nil) }
                }
            }
            .task { await connect() }
        }
    }

    private func connect() async {
        guard let pairing = Pairing.load(), let lines = try? TunnelLines(pairing: pairing) else { problem = "Pair Zero with your Mac first."; return }
        let link = ZerodLink(connection: lines)
        self.link = link
        do {
            rows = try await link.board()
            projects = (try? await link.call("projects")) as? [String] ?? []
        } catch {
            problem = "Can't reach your Mac: Zero needs to be running there."
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
                if let path = try await link.call("upload", ["name": "shared-\(index + 1).jpg", "data": image.base64EncodedString()]) as? String { paths.append(path) }
            }
            let asked = text.isEmpty ? (about == nil ? "Have a look at \(paths.count == 1 ? "this" : "these")." : "Have a look at this.") : text
            let words = [asked, about].compactMap { $0 }.joined(separator: "\n\n")
            if picked.hasPrefix("task:") {
                try await link.send(session: String(picked.dropFirst(5)), text: words, images: paths)
            } else {
                _ = try await link.start(provider: .claude, cwd: String(picked.dropFirst(4)), prompt: words, images: paths)
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
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
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
