import AVFoundation
import PhotosUI
import ScreenCaptureKit
import Speech
import SwiftUI
import UniformTypeIdentifiers

/// Showing a task what's on the phone: screenshots and photos, or a screen recording (iOS's own, from Control Center)
/// turned into what an agent reads: frames through it, each with its time, and what was said over it.
struct RecordView: View {
    let model: PhoneModel
    @State private var picked: [PhotosPickerItem] = []
    @State private var images: [Data] = []
    @State private var video: PhotosPickerItem?
    @State private var recording: Recording?
    @State private var reading = false
    @State private var recorder = ScreenRecorder()
    @State private var task: String?
    @State private var words = ""
    @State private var sending = false
    @State private var problem: String?

    var body: some View {
        List {
            Section {
                PhotosPicker(selection: $picked, maxSelectionCount: 10, matching: .images) {
                    Label(images.isEmpty ? "Choose screenshots or photos" : images.count == 1 ? "1 image" : "\(images.count) images",
                          image: "images-glyph")
                }
                if !images.isEmpty {
                    TextField("What should it look at?", text: $words, axis: .vertical).lineLimit(2...6)
                }
            } header: {
                Text("Record")
            }
            Section {
                // The system's picker (the screen, the microphone's switch), then everything on it until it's stopped,
                // here or with the red pill at the top; then the recording is read.
                if recorder.recording {
                    Button { recorder.stop() } label: {
                        HStack(spacing: 10) {
                            Image("media-stop-glyph").resizable().frame(width: 14, height: 14).foregroundStyle(.red)
                            Text("Stop recording").foregroundStyle(.red)
                            Spacer()
                            Text(recorder.started, style: .timer).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Button { recorder.start() } label: { Label("Record the screen", image: "record-glyph") }
                        .disabled(reading || !recorder.available)
                }
                PhotosPicker(selection: $video, matching: .videos) {
                    if reading {
                        HStack(spacing: 10) { Spinner().frame(width: 16, height: 16); Text("Reading the recording…").foregroundStyle(.secondary) }
                    } else {
                        Label(recording.map { "\($0.length) · \($0.frames.count) frames" + ($0.said == nil ? "" : " · what you said") } ?? "Choose a recording from Photos",
                              image: "images-glyph")
                    }
                }
                .disabled(reading)
                if recording != nil, images.isEmpty {
                    TextField("What should it look at?", text: $words, axis: .vertical).lineLimit(2...6)
                }
            } footer: {
                Text("Turn the microphone on in the sheet to talk it through, and stop with the red pill at the top of the screen. The task gets frames through the recording and what you said.")
            }
            if !images.isEmpty || recording != nil {
                Section("Send to") {
                    Picker("Task", selection: $task) {
                        ForEach(model.tasks) { row in Text(row.task).lineLimit(1).tag(Optional(row.session)) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
                Button { Task { await send() } } label: {
                    if sending { Spinner(color: .white).frame(width: 16, height: 16).frame(maxWidth: .infinity) } else { Text("Send").frame(maxWidth: .infinity) }
                }
                .buttonStyle(.glassProminent)
                .disabled(task == nil || sending)
                .listRowBackground(Color.clear)
            }
        }
        // A recording finished: read as a chosen one is.
        .onChange(of: recorder.finished) { _, file in
            guard let file else { return }
            recorder.finished = nil
            reading = true
            Task { recording = await Recording.read(file); reading = false }
        }
        .onChange(of: recorder.problem) { _, why in if let why { problem = why } }
        .onChange(of: video) {
            guard let video else { return }
            reading = true
            Task {
                defer { reading = false }
                if let movie = try? await video.loadTransferable(type: Movie.self) { recording = await Recording.read(movie.url) }
                else { problem = "Couldn't open that recording" }
            }
        }
        .onChange(of: picked) {
            Task {
                var loaded: [Data] = []
                for item in picked {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data),
                       let jpeg = image.jpegData(compressionQuality: 0.8) { loaded.append(jpeg) }
                }
                images = loaded
            }
        }
    }

    private func send() async {
        guard let task else { return }
        sending = true
        defer { sending = false }
        do {
            try await model.send([words, recording?.text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n"),
                                 images: images + (recording?.frames ?? []), to: task)
            picked = []; images = []; words = ""; problem = nil; video = nil; recording = nil
            model.tab = .tasks
            model.path = [task]
        } catch {
            problem = "Couldn't send: \(error.localizedDescription)"
        }
    }
}

/// A video chosen from Photos, as a file of the app's own to read.
private struct Movie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Movie(url: copy)
        }
    }
}

/// A screen recording as an agent can take it: frames evenly through it (one every few seconds, twelve at most), and
/// its sound as words, recognised on the phone when it can be.
struct Recording {
    var duration: Double
    var times: [Double]
    var frames: [Data]
    var said: String?

    var length: String { Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)) }

    /// What the message says of it, so the agent knows what the images are.
    var text: String {
        let at = times.map { Duration.seconds($0).formatted(.time(pattern: .minuteSecond)) }.joined(separator: ", ")
        return "A screen recording from my phone, \(length) long: the images are frames from it at \(at)."
            + (said.map { "\nWhat I said over it: \u{201C}\($0)\u{201D}" } ?? "")
    }

    static func read(_ url: URL) async -> Recording? {
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration > 0 else { return nil }
        let count = min(12, max(1, Int(duration / 3) + 1))
        let times = (0..<count).map { duration * (Double($0) + 0.5) / Double(count) }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1600, height: 1600)
        var frames: [Data] = []
        for time in times {
            if let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image,
               let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.7) { frames.append(jpeg) }
        }
        return Recording(duration: duration, times: times, frames: frames, said: await transcript(of: url))
    }

    /// Its sound as words; nothing when it has none, or speech isn't allowed.
    private static func transcript(of url: URL) async -> String? {
        let allowed = await withCheckedContinuation { done in SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0 == .authorized) } }
        guard allowed, let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { return nil }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = true
        let words: String? = await withCheckedContinuation { done in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let result, result.isFinal { finished = true; done.resume(returning: result.bestTranscription.formattedString) }
                else if error != nil { finished = true; done.resume(returning: nil) }
            }
        }
        return words?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}


/// The screen recorded from the app, as iOS 27's ScreenCaptureKit has it: the system's picker chooses the screen (and
/// whether the microphone is on), a stream records it into a file of the app's, until it's stopped here or from the
/// system's own control.
@MainActor @Observable final class ScreenRecorder: NSObject, SCContentSharingPickerObserver, SCStreamDelegate, SCRecordingOutputDelegate {
    private(set) var recording = false
    private(set) var started = Date()
    /// A whole recording, for the view to take.
    var finished: URL?
    var problem: String?
    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var file: URL?

    var available: Bool { SCContentSharingPicker.shared.isAvailable }

    func start() {
        let picker = SCContentSharingPicker.shared
        var configuration = picker.defaultConfiguration
        configuration.showsMicrophoneControl = true
        picker.defaultConfiguration = configuration
        picker.add(self)
        picker.isActive = true
        picker.present(using: .display)
    }

    func stop() {
        Task { try? await stream?.stopCapture() }
    }

    private func record(_ filter: SCContentFilter) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("recording-\(UUID().uuidString).mp4")
        let output = SCRecordingOutputConfiguration()
        output.outputURL = file
        let stream = SCStream(filter: filter, configuration: SCStreamConfiguration(), delegate: self)
        do {
            try stream.addRecordingOutput(SCRecordingOutput(configuration: output, delegate: self))
        } catch {
            problem = "Couldn't record: \(error.localizedDescription)"
            return
        }
        (self.stream, self.file) = (stream, file)
        Task {
            do { try await stream.startCapture(); started = Date(); recording = true }
            catch { problem = "Couldn't record: \(error.localizedDescription)"; ended() }
        }
    }

    private func ended() {
        recording = false
        stream = nil
        SCContentSharingPicker.shared.isActive = false
        SCContentSharingPicker.shared.remove(self)
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in self.record(filter) }
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in self.ended() }
    }
    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Task { @MainActor in self.problem = "Couldn't record: \(error.localizedDescription)"; self.ended() }
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor in self.ended() }
    }
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.finished = self.file; self.ended() }
    }
    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        Task { @MainActor in self.problem = "The recording failed: \(error.localizedDescription)"; self.ended() }
    }
}
