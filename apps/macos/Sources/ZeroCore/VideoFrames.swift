import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// A video as an agent can look at it: the CLIs take images, not video, so frames are cut from it as PNGs, at the times
/// asked for (`zero video`, and the composer's overview of a video attached).
public enum VideoFrames {
    public struct Info: Sendable { public let seconds: Double; public let width: Int; public let height: Int; public let fps: Double }
    public struct Frame: Sendable { public let at: Double; public let path: String }

    public static func info(of video: URL) async throws -> Info {
        let asset = AVURLAsset(url: video)
        let seconds = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure("\(video.lastPathComponent) has no video in it") }
        let (size, transform, fps) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let shown = size.applying(transform)
        return Info(seconds: seconds, width: Int(abs(shown.width)), height: Int(abs(shown.height)), fps: Double(fps))
    }

    /// `count` times spread evenly over `seconds`, each in the middle of its share (not the black first frame).
    public static func spread(_ count: Int, over seconds: Double) -> [Double] {
        guard count > 0, seconds > 0 else { return [] }
        return (0..<count).map { seconds * (Double($0) + 0.5) / Double(count) }
    }

    /// Every `step` seconds from `from` to `to`, both ends kept within the video.
    public static func every(_ step: Double, from: Double, to: Double, seconds: Double) -> [Double] {
        guard step > 0 else { return [] }
        let start = max(0, from), end = min(to, seconds)
        return Swift.stride(from: start, through: end, by: step).map { $0 }
    }

    /// The frames at `times`, saved in `folder` as PNGs at most `largest` on their longer side.
    public static func frames(of video: URL, at times: [Double], into folder: URL, largest: CGFloat = 1600) async throws -> [Frame] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: largest, height: largest)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var frames: [Frame] = []
        for at in times {
            let (image, _) = try await generator.image(at: CMTime(seconds: at, preferredTimescale: 600))
            let file = folder.appendingPathComponent(String(format: "frame-%08.3f.png", at))
            // ImageIO, not AppKit: ZeroCore is in every `zero` command, and AppKit cost each one a millisecond to load.
            guard let out = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(out, image, nil)
            guard CGImageDestinationFinalize(out) else { continue }
            frames.append(Frame(at: at, path: file.path))
        }
        return frames
    }

    /// 1:05.250
    public static func stamp(_ seconds: Double) -> String {
        String(format: "%d:%06.3f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }

    public struct Failure: LocalizedError { public let errorDescription: String?; init(_ message: String) { errorDescription = message } }
}
