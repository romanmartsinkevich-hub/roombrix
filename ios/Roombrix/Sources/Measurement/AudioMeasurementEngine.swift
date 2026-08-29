import Foundation
#if canImport(AVFAudio)
import AVFAudio
#endif

/// Plays the measurement stimulus and records the room simultaneously.
///
/// Session policy (device-quirks sensitive — verify per model against
/// docs/DEVICE_QUIRKS.md):
/// - `.playAndRecord` + `.measurement` mode: disables Apple's AGC and
///   input processing as far as the platform allows.
/// - CHANNEL POLICY (product requirement): exactly ONE input channel is
///   analyzed — the first channel of the input format. Channels are never
///   summed: downmixing a stereo/mid-side external mic cancels reverberant
///   energy and corrupts decay measurements.
final class AudioMeasurementEngine {

    enum EngineError: Error, LocalizedError {
        case permissionDenied
        case sessionConfiguration(Error)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Microphone access is required to measure the room. Enable it in Settings → Privacy → Microphone."
            case .sessionConfiguration(let error):
                return "Audio session could not be configured: \(error.localizedDescription)"
            }
        }
    }

    #if canImport(AVFAudio)
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var chunks: [[Double]] = []
    private let chunkLock = NSLock()
    private(set) var sampleRate: Double = 48_000

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Configure the session for measurement-grade capture. Must be called
    /// before `startCapture`. Returns the actual hardware sample rate —
    /// always read back, never assumed (preferred rates can be silently
    /// overridden; see device quirks table).
    func configureSession() throws -> Double {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.allowBluetoothA2DP, .defaultToSpeaker]
            )
            try session.setPreferredSampleRate(48_000)
            try session.setActive(true)
            sampleRate = session.sampleRate
            return sampleRate
        } catch {
            throw EngineError.sessionConfiguration(error)
        }
    }

    /// Human-readable description of the active input route (for reports
    /// and the device-quirks table).
    var inputDescription: String {
        let session = AVAudioSession.sharedInstance()
        let inputs = session.currentRoute.inputs
            .map { "\($0.portName) (\($0.portType.rawValue))" }
            .joined(separator: ", ")
        return inputs.isEmpty ? "unknown input" : inputs
    }

    /// Start capturing. Samples accumulate until `stopCapture()`.
    func startCapture() throws {
        chunkLock.lock()
        chunks.removeAll()
        chunkLock.unlock()

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        sampleRate = format.sampleRate

        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, _ in
            guard let self, let channelData = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            // First channel only — see channel policy above.
            var chunk = [Double](repeating: 0, count: frames)
            for i in 0..<frames {
                chunk[i] = Double(channelData[0][i])
            }
            self.chunkLock.lock()
            self.chunks.append(chunk)
            self.chunkLock.unlock()
        }
        if engine.attachedNodes.contains(player) == false {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: nil)
        }
        engine.prepare()
        try engine.start()
    }

    /// Schedule stimulus playback through the current output route.
    /// Returns immediately; playback duration = samples.count / sampleRate.
    func play(stimulus: [Double]) {
        let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: 1
        )!
        let frameCount = AVAudioFrameCount(stimulus.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        if let data = buffer.floatChannelData {
            for i in 0..<stimulus.count {
                data[0][i] = Float(stimulus[i])
            }
        }
        player.scheduleBuffer(buffer)
        player.play()
    }

    /// Stop everything and return the full mono recording.
    func stopCapture() -> [Double] {
        player.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        chunkLock.lock()
        let recording = chunks.flatMap { $0 }
        chunks.removeAll()
        chunkLock.unlock()
        return recording
    }
    #endif
}
