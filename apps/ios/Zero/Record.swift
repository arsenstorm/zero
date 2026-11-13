import AVFoundation
import PhotosUI
#if !targetEnvironment(simulator)
    import ScreenCaptureKit
#endif
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Recording the screen, the page's one big action, as the camera's shutter: a red disc in a ring that turns to a
    /// stop square while it records, its time over it. The system's sheet picks the screen and the microphone; it stops
    /// here or with the red pill at the top; then the recording is read.
    private var shutter: some View {
        VStack(spacing: 14) {
            Button {
                recorder.recording ? recorder.stop() : recorder.start()
            } label: {
                ZStack {
                    Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 4).frame(width: 84, height: 84)
                    RoundedRectangle(cornerRadius: recorder.recording ? 8 : 32, style: .continuous).fill(.red)
                        .frame(width: recorder.recording ? 30 : 64, height: recorder.recording ? 30 : 64)
                }
                .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: recorder.recording)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(reading || !recorder.available)
            .accessibilityLabel(recorder.recording ? "Stop recording" : "Record the screen")
            if recorder.recording {
                Text(recorder.started, style: .timer).font(.headline).monospacedDigit()
            } else {
                Text("Record your screen").font(.headline)
            }
            Text(
                recorder.recording
                    ? "Stop here, or with the red pill at the top of the screen."
                    : "Turn the microphone on to talk it through."
            )
            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32).padding(.vertical, 20)
    }

    /// A small glass button under the record button: the library, for what's already captured.
    private func chip(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(icon).resizable().frame(width: 16, height: 16)
            Text(title).font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 14).frame(height: 38)
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    /// What the task should look at, with what's attached.
    private var wordsField: some View {
        TextField("What should it look at?", text: $words, axis: .vertical).lineLimit(2...6).padding(.vertical, 10)
    }

    var body: some View {
        // The record button, and the library a button away for what's already captured: one group, centred on the
        // page. (iOS's own inline picker as a strip of recent captures showed each one huge and cropped, under its own
        // notice; thumbnails of our own would need the whole library.)
        VStack(spacing: 28) {
            shutter
            // A recording that failed or couldn't be opened: said here, where it was tried (the send sheet isn't open).
            if let problem, images.isEmpty, recording == nil {
                Text(problem).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center).padding(.horizontal, 32)
            }
            HStack(spacing: 8) {
                PhotosPicker(selection: $picked, maxSelectionCount: 10, matching: .images) { chip("Photos", icon: "image-glyph") }
                PhotosPicker(selection: $video, matching: .videos) { chip(reading ? "Reading…" : "Recordings", icon: "record-glyph") }
                    .disabled(reading)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, NavBar.height)
        // Something chosen or recorded: where it goes, in a sheet over the page rather than the page growing.
        .sheet(isPresented: Binding(get: { !images.isEmpty || recording != nil }, set: { if !$0 { clear() } })) { sendSheet }
        // A recording finished: read as a chosen one is.
        .onChange(of: recorder.finished) { _, file in
            guard let file else { return }
            recorder.finished = nil
            reading = true
            Task {
                problem = nil; recording = await Recording.read(file); reading = false
            }
        }
        .onChange(of: recorder.problem) { _, why in if let why { problem = why } }
        .onChange(of: video) {
            guard let video else { return }
            reading = true
            Task {
                defer { reading = false }
                if let movie = try? await video.loadTransferable(type: Movie.self) {
                    recording = await Recording.read(movie.url)
                } else {
                    problem = "Couldn't open that recording"
                }
            }
        }
        .onChange(of: picked) {
            Task {
                var loaded: [Data] = []
                for item in picked {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data),
                        let jpeg = image.jpegData(compressionQuality: 0.8)
                    {
                        loaded.append(jpeg)
                    }
                }
                images = loaded
            }
        }
    }

    /// What was chosen, its words and the task to send it to, as New task's sheet is laid out: close, its name, send.
    private var sendSheet: some View {
        let canSend = task != nil && !sending
        return VStack(spacing: 0) {
            HStack {
                Button {
                    clear()
                } label: {
                    Image("xmark-outline").resizable().frame(width: 20, height: 20).frame(width: 44, height: 44).contentShape(Circle())
                }
                .buttonStyle(.plain).glassEffect(.regular.interactive(), in: Circle()).accessibilityLabel("Close")
                Spacer()
                Text("Send to a task").font(.headline)
                Spacer()
                SendCircle(ready: canSend, sending: sending) { Task { await send() } }
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 8)
            PageScroll {
                VStack(alignment: .leading, spacing: 10) {
                    if !images.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(images.indices, id: \.self) { i in
                                    if let image = UIImage(data: images[i]) {
                                        Image(uiImage: image).resizable().scaledToFill().frame(width: 72, height: 72)
                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                    }
                                }
                            }
                        }
                    } else if let recording {
                        PageRow(
                            title: "\(recording.length) · \(recording.frames.count) frames"
                                + (recording.said == nil ? "" : " · what you said"), icon: "record-glyph")
                    }
                    wordsField
                    if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
                }
                .padding(.horizontal, 20)
                PageGroup(title: "Send to") {
                    // The tasks as the Tasks list draws them, ticked when picked, as the share sheet's.
                    ForEach(model.tasks) { row in
                        TaskRow(row: row, said: row.needs ?? row.now, picked: task == row.session) { task = row.session }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Nothing chosen any more: the sheet closes, the page is as it was.
    private func clear() {
        picked = []; images = []; words = ""; problem = nil; video = nil; recording = nil
    }

    private func send() async {
        guard let task else { return }
        sending = true
        defer { sending = false }
        do {
            try await model.send(
                [words, recording?.text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n"),
                images: images + (recording?.frames ?? []), to: task)
            clear()
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
        FileRepresentation(contentType: .movie) {
            SentTransferredFile($0.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(
                received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Movie(url: copy)
        }
    }
}

/// The screen recorded from the app, as iOS 27's ScreenCaptureKit has it: the system's picker chooses the screen (and
/// whether the microphone is on), a stream records it into a file of the app's, until it's stopped here or from the
/// system's own control.
#if targetEnvironment(simulator)
    /// The Simulator has no ScreenCaptureKit: recording isn't offered there (the UI tests build the app for it).
    @MainActor @Observable final class ScreenRecorder {
        private(set) var recording = false
        private(set) var started = Date()
        var finished: URL?
        var problem: String?
        var available: Bool { false }
        func start() {}
        func stop() {}
    }
#else
    @MainActor @Observable final class ScreenRecorder: NSObject, SCContentSharingPickerObserver, SCStreamDelegate, SCRecordingOutputDelegate
    {
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
                do { try await stream.startCapture(); started = Date(); recording = true } catch {
                    problem = "Couldn't record: \(error.localizedDescription)"; ended()
                }
            }
        }

        private func ended() {
            recording = false
            stream = nil
            SCContentSharingPicker.shared.isActive = false
            SCContentSharingPicker.shared.remove(self)
        }

        nonisolated func contentSharingPicker(
            _ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?
        ) {
            Task { @MainActor in self.record(filter) }
        }
        nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
            Task { @MainActor in self.ended() }
        }
        nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
            Task { @MainActor in
                self.problem = "Couldn't record: \(error.localizedDescription)"; self.ended()
            }
        }
        nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
            Task { @MainActor in self.ended() }
        }
        nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
            Task { @MainActor in
                self.finished = self.file; self.ended()
            }
        }
        nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
            Task { @MainActor in
                self.problem = "The recording failed: \(error.localizedDescription)"; self.ended()
            }
        }
    }
#endif
