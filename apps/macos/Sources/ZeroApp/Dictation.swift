import AVFoundation
import CoreAudio
import Foundation
import Observation
import Speech

/// On-device live transcription from the default microphone (Speech framework, macOS 26 SpeechAnalyzer).
@MainActor @Observable
final class Dictation {
    private(set) var listening = false
    /// CoreAudio device UID to listen on; nil means the system default input.
    @ObservationIgnored var deviceUID: String?

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var input: AsyncStream<AnalyzerInput>.Continuation?
    @ObservationIgnored private var results: Task<Void, Never>?

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// Calls `onText` with the full transcript so far (finalized text plus the current volatile guess).
    func start(onText: @escaping @MainActor (String) -> Void) async throws {
        guard !listening else { return }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw Failure(errorDescription: "Microphone access denied") }
        let locale = Locale(identifier: "en_US")
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw Failure(errorDescription: "No audio format for transcription")
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let engine = AVAudioEngine()
        let node = engine.inputNode
        if let deviceUID, let deviceID = Dictation.audioDeviceID(forUID: deviceUID), let unit = node.audioUnit {
            var id = deviceID
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let inputFormat = node.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw Failure(errorDescription: "Cannot convert microphone audio")
        }
        node.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            let frames = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / inputFormat.sampleRate) + 16
            guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            var consumed = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil, converted.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: converted)) }
        }
        engine.prepare()
        try engine.start()
        try await analyzer.start(inputSequence: stream)

        self.engine = engine
        self.analyzer = analyzer
        self.input = continuation
        listening = true
        results = Task {
            var finalized = ""
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        finalized += (finalized.isEmpty ? "" : " ") + text
                        onText(finalized)
                    } else {
                        onText(finalized + (finalized.isEmpty ? "" : " ") + text)
                    }
                }
            } catch {}
        }
    }

    /// Microphones available right now, as (name, UID), for the Settings picker.
    static func inputDevices() -> [(name: String, uid: String)] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.map { ($0.localizedName, $0.uniqueID) }
    }

    private static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), uidPointer, &size, &deviceID)
        }
        return status == noErr && deviceID != 0 ? deviceID : nil
    }

    func stop() async {
        guard listening else { return }
        listening = false
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        input?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        _ = await results?.value
        engine = nil; analyzer = nil; input = nil; results = nil
    }
}
