import PhotosUI
import SwiftUI

/// Showing a task what's on the phone: screenshots and photos now, the screen recorded next.
struct RecordView: View {
    let model: PhoneModel
    @State private var picked: [PhotosPickerItem] = []
    @State private var images: [Data] = []
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
            } footer: {
                Text("Recording your screen, with what you say, comes next.")
            }
            if !images.isEmpty {
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
            try await model.send(words, images: images, to: task)
            picked = []; images = []; words = ""; problem = nil
            model.tab = .tasks
            model.path = [task]
        } catch {
            problem = "Couldn't send: \(error.localizedDescription)"
        }
    }
}
