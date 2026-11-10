import AVFoundation
import Speech
import UIKit

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

    /// Its frames, and (`transcribe`) what was said over it: not from the share sheet, whose extension has neither
    /// speech's permission nor the memory to spare.
    static func read(_ url: URL, transcribe: Bool = true) async -> Recording? {
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
                let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.7)
            {
                frames.append(jpeg)
            }
        }
        return Recording(duration: duration, times: times, frames: frames, said: transcribe ? await transcript(of: url) : nil)
    }

    /// Its sound as words; nothing when it has none, or speech isn't allowed.
    private static func transcript(of url: URL) async -> String? {
        let allowed = await withCheckedContinuation { done in
            SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0 == .authorized) }
        }
        guard allowed, let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { return nil }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = true
        let words: String? = await withCheckedContinuation { done in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let result, result.isFinal {
                    finished = true; done.resume(returning: result.bestTranscription.formattedString)
                } else if error != nil {
                    finished = true; done.resume(returning: nil)
                }
            }
        }
        return words?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
