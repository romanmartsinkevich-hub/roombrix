import Foundation
#if canImport(AVFAudio)
import AVFAudio
#endif

/// Microphone capture for acoustic measurement.
///
/// Uses AVAudioSession `.measurement` mode to disable Apple's AGC and signal
/// processing. Known minefield: per-device behavior varies — verify against
/// `docs/DEVICE_QUIRKS.md` and keep that table current (Sprint 0 spike #1).
final class CaptureEngine {

    enum CaptureError: Error {
        case permissionDenied
        case sessionConfiguration(Error)
        case notRunning
    }

    #if canImport(AVFAudio)
    private let engine = AVAudioEngine()
    private var buffers: [[Double]] = []
    private(set) var sampleRate: Double = 48_000

    /// Configure the audio session for measurement-grade capture.
    /// Must be called before `start()`.
    func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            // `.measurement` disables system-supplied signal processing
            // (AGC, noise suppression). `.playAndRecord` so the same session
            // can emit the stimulus when using phone-connected playback.
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.allowBluetoothA2DP, .defaultToSpeaker]
            )
            try session.setPreferredSampleRate(48_000)
            try session.setActive(true)
            sampleRate = session.sampleRate
        } catch {
            throw CaptureError.sessionConfiguration(error)
        }
    }

    func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Start capturing. Samples accumulate until `stop()` is called.
    func start() throws {
        buffers.removeAll()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        sampleRate = format.sampleRate

        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, _ in
            guard let self, let channelData = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            var chunk = [Double](repeating: 0, count: frames)
            for i in 0..<frames {
                chunk[i] = Double(channelData[0][i])
            }
            self.buffers.append(chunk)
        }
        engine.prepare()
        try engine.start()
    }

    /// Stop capturing and return the full recording.
    func stop() -> [Double] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let recording = buffers.flatMap { $0 }
        buffers.removeAll()
        return recording
    }
    #endif
}
