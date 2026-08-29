import Foundation
#if canImport(AVFAudio)
import AVFAudio
#endif

/// Measurement-grade microphone capture. RECORD ONLY — by product decision
/// the phone never plays measurement audio; the user plays the stimulus
/// package through their own system and the phone is purely the instrument.
///
/// Session policy (device-quirks sensitive — verify per model against
/// docs/DEVICE_QUIRKS.md):
/// - `.record` category + `.measurement` mode: disables Apple's AGC and
///   input processing as far as the platform allows.
/// - No Bluetooth input option is set: BT microphones are codec-processed
///   and unusable for measurement.
/// - CHANNEL POLICY (product requirement): exactly ONE input channel is
///   analyzed — the first channel. Channels are never summed: downmixing a
///   stereo/mid-side external mic cancels reverberant energy and corrupts
///   decay measurements.
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
    private var chunks: [[Double]] = []
    private var recent: [Double] = []
    private let lock = NSLock()
    private(set) var sampleRate: Double = 48_000

    /// Rolling live-metering window, seconds.
    static let recentWindowSeconds = 1.5

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Configure the session for measurement-grade capture. Returns the
    /// actual hardware sample rate — always read back, never assumed.
    func configureSession() throws -> Double {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement)
            try session.setPreferredSampleRate(48_000)
            try session.setActive(true)
            sampleRate = session.sampleRate
            return sampleRate
        } catch {
            throw EngineError.sessionConfiguration(error)
        }
    }

    /// Human-readable active input (for reports and the quirks table).
    var inputDescription: String {
        let inputs = AVAudioSession.sharedInstance().currentRoute.inputs
            .map { "\($0.portName) (\($0.portType.rawValue))" }
            .joined(separator: ", ")
        return inputs.isEmpty ? "unknown input" : inputs
    }

    func startCapture() throws {
        lock.lock()
        chunks.removeAll()
        recent.removeAll()
        lock.unlock()

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        sampleRate = format.sampleRate
        let recentCapacity = Int(Self.recentWindowSeconds * format.sampleRate)

        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, _ in
            guard let self, let channelData = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            // First channel only — see channel policy above.
            var chunk = [Double](repeating: 0, count: frames)
            for i in 0..<frames {
                chunk[i] = Double(channelData[0][i])
            }
            self.lock.lock()
            self.chunks.append(chunk)
            self.recent.append(contentsOf: chunk)
            if self.recent.count > recentCapacity {
                self.recent.removeFirst(self.recent.count - recentCapacity)
            }
            self.lock.unlock()
        }
        engine.prepare()
        try engine.start()
    }

    /// Snapshot of the last `seconds` of capture, for live metering.
    func recentSamples(_ seconds: Double) -> [Double] {
        lock.lock()
        defer { lock.unlock() }
        let wanted = Int(seconds * sampleRate)
        guard recent.count > 0 else { return [] }
        return Array(recent.suffix(wanted))
    }

    /// Seconds captured so far.
    var capturedDuration: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(chunks.reduce(0) { $0 + $1.count }) / sampleRate
    }

    /// Stop and return the full mono recording.
    func stopCapture() -> [Double] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        let recording = chunks.flatMap { $0 }
        chunks.removeAll()
        recent.removeAll()
        lock.unlock()
        return recording
    }
    #endif
}
