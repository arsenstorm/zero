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
    @State private var draft = ""
    @State private var picked: [PhotosPickerItem] = []
    @State private var images: [UIImage] = []
    @State private var models: [PhoneModel.ModelChoice] = []
    /// Chosen here for the next message; until then, the task's own.
    @State private var chosen: (model: String, effort: String?)?
    @State private var dictation = Dictation()
    @State private var selecting = false
    @State private var sending = false
    @FocusState private var focused: Bool

    private var empty: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty }
    /// Not being written in (the keyboard down, nothing typed or attached, not listening): one slim capsule.
    private var compact: Bool { !focused && empty && !dictation.listening }

    private var photos: some View {
        PhotosPicker(selection: $picked, maxSelectionCount: 10, matching: .images) {
            Image("plus-outline").resizable().frame(width: 20, height: 20).frame(width: 40, height: 40)
        }
    }

    private var microphone: some View {
        Button { dictation.listening ? dictation.stop() : dictation.start(after: draft) { draft = $0 } } label: {
            Image("microphone-outline").resizable().frame(width: 20, height: 20)
                .foregroundStyle(dictation.listening ? Color.white : Color.primary)
                .frame(width: 40, height: 40)
                .background(dictation.listening ? Color.red : .clear, in: Circle())
        }
    }

    private var sendButton: some View {
        Button(action: send) {
            Image("arrow-up-outline").resizable().frame(width: 18, height: 18)
                .foregroundStyle(Color(uiColor: .systemBackground))
                .frame(width: 40, height: 40)
                .background(Color.primary.opacity(empty ? 0.25 : 1), in: Circle())
        }
        .disabled(empty || sending)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                            Image(uiImage: image).resizable().scaledToFill().frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(alignment: .topTrailing) {
                                    Button { images.remove(at: index); if index < picked.count { picked.remove(at: index) } } label: {
                                        Text("✕").font(.caption2.weight(.bold)).foregroundStyle(.white)
                                            .frame(width: 18, height: 18).background(.black.opacity(0.6), in: Circle())
                                    }
                                    .padding(3)
                                }
                        }
                    }
                    .padding(.horizontal, 14).padding(.top, 14)
                }
            }
            // One field in both shapes, so focusing it doesn't make a new one: the controls arrange around it.
            HStack(alignment: .center, spacing: 0) {
                if compact { photos }
                TextField(dictation.listening ? "Listening…" : "Write to this task", text: $draft, axis: .vertical)
                    .lineLimit(1...8)
                    .focused($focused)
                    .padding(.leading, compact ? 4 : 18).padding(.trailing, compact ? 4 : 18)
                    .padding(.top, compact ? 0 : 16).padding(.bottom, compact ? 0 : 6)
                if compact { microphone; sendButton }
            }
            .padding(.horizontal, compact ? 4 : 0)
            if !compact {
                HStack(spacing: 4) {
                    photos
                    Spacer()
                    modelMenu
                    microphone
                    sendButton
                }
                .padding(.horizontal, 8).padding(.bottom, 8)
                .transition(.opacity)
            }
        }
        .foregroundStyle(.primary)
        .frame(minHeight: compact ? 48 : nil)
        // Concentric: the 40 pt buttons sit 4 pt in a 48 pt capsule (20 + 4), 8 pt in the open box (20 + 8). Closed, it
        // also sits further in from the screen's edges, so its round ends follow the screen's corners.
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: compact ? 24 : 28))
        .padding(.horizontal, compact ? 30 : 12).padding(.bottom, compact ? 2 : 8)
        .animation(.smooth(duration: 0.28), value: compact)
        .onChange(of: picked) {
            Task {
                var loaded: [UIImage] = []
                for item in picked {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) { loaded.append(image) }
                }
                images = loaded
            }
        }
        .task(id: conversation?.provider) {
            if let provider = conversation?.provider { models = await model.models(provider) }
        }
        .onDisappear { dictation.stop() }
        // Words drafted elsewhere (Siri's "draft a message to …"): into the box, to look over and send.
        .onChange(of: model.drafts[session], initial: true) { _, words in
            guard let words else { return }
            draft = draft.isEmpty ? words : draft + "\n" + words
            model.drafts[session] = nil
        }
    }

    // The model and its effort, as "Opus 5.5 High": opens the Mac's selector, as a sheet.
    private var modelMenu: some View {
        let id = chosen?.model ?? conversation?.model
        let effort = chosen?.effort ?? conversation?.effort
        let current = models.first { $0.id == id }
        let name = current?.name ?? id ?? conversation?.provider.title ?? ""
        let level = current?.levels.first { $0.id == effort }?.name ?? effort?.capitalized
        return Button { selecting = true } label: {
            (Text(name).fontWeight(.medium) + Text(level.map { " " + $0 } ?? "").foregroundStyle(.secondary))
                .font(.subheadline).lineLimit(1).padding(.horizontal, 6).frame(height: 40)
        }
        .buttonStyle(.plain)
        .disabled(models.isEmpty)
        .sheet(isPresented: $selecting) {
            if let provider = conversation?.provider {
                ModelSelector(provider: provider, models: models, current: (id, effort)) { model, level in chosen = (model, level) }
            }
        }
    }

    private func send() {
        dictation.stop()
        let text = draft, photos = images.compactMap { $0.jpegData(compressionQuality: 0.8) }, choice = chosen
        draft = ""; images = []; picked = []; chosen = nil
        sending = true
        Task {
            defer { sending = false }
            do { try await model.send(text, images: photos, to: session, model: choice?.model, effort: choice?.effort) }
            catch { draft = text } // Back in the box, to send again.
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
                    if let said { write(before.isEmpty ? said : before + " " + said) }
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
        let speech = await withCheckedContinuation { done in SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0 == .authorized) } }
        return speech ? await AVAudioApplication.requestRecordPermission() : false
    }
}
