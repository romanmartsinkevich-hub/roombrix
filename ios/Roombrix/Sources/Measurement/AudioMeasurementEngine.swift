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
        case directionalMicLocked(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Microphone access is required to measure the room. Enable it in Settings → Privacy → Microphone."
            case .sessionConfiguration(let error):
                return "Audio session could not be configured: \(error.localizedDescription)"
            case .directionalMicLocked(let pattern):
                return "The microphone is locked to a directional pattern (\(pattern)) and cannot be switched to omnidirectional. A directional pattern suppresses reverberant energy and corrupts decay measurements — this device/route cannot be used for measurement."
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

    /// Input pinning details for reports and the device-quirks table.
    private(set) var setupReport: String = ""

    /// Configure the session for measurement-grade capture. Returns the
    /// actual hardware sample rate — always read back, never assumed.
    ///
    /// Input pinning (never left to the system default): the built-in mic
    /// port is selected explicitly; among its data sources one supporting
    /// the omnidirectional polar pattern is preferred and that pattern is
    /// requested. If a directional pattern is in effect and cannot be
    /// changed, configuration FAILS rather than silently reproducing the
    /// MV88-style reverb-suppression failure mode.
    func configureSession() throws -> Double {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement)

            var reportLines: [String] = []
            var requestedPattern = "n/a (fixed capsule)"

            if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try? session.setPreferredInput(builtIn)
                if let sources = builtIn.dataSources, !sources.isEmpty {
                    let omniCapable = sources.first {
                        $0.supportedPolarPatterns?.contains(.omnidirectional) == true
                    }
                    let chosen = omniCapable ?? sources[0]
                    try? builtIn.setPreferredDataSource(chosen)
                    if omniCapable != nil {
                        requestedPattern = "omnidirectional"
                        try? chosen.setPreferredPolarPattern(.omnidirectional)
                    }
                    reportLines.append("Data source: \(chosen.dataSourceName) (of \(sources.count))")
                } else {
                    reportLines.append("Data source: none exposed by this device")
                }
            }

            try session.setPreferredSampleRate(48_000)
            try session.setActive(true)
            sampleRate = session.sampleRate

            // Verify what was actually granted.
            let activeInput = session.currentRoute.inputs.first
            let activeSource = activeInput?.selectedDataSource
            var grantedPattern = "n/a (fixed capsule)"
            if let pattern = activeSource?.selectedPolarPattern {
                grantedPattern = pattern.rawValue
                if pattern != .omnidirectional {
                    let canBeOmni = activeSource?.supportedPolarPatterns?
                        .contains(.omnidirectional) ?? false
                    if canBeOmni {
                        try? activeSource?.setPreferredPolarPattern(.omnidirectional)
                    } else {
                        throw EngineError.directionalMicLocked(pattern.rawValue)
                    }
                }
            }

            reportLines.insert(
                "Input port: \(activeInput?.portName ?? "unknown") (\(activeInput?.portType.rawValue ?? "?"))",
                at: 0
            )
            reportLines.append("Polar pattern requested: \(requestedPattern); granted: \(grantedPattern)")
            reportLines.append("Sample rate: \(Int(session.sampleRate)) Hz (preferred 48000)")
            reportLines.append("Mode .measurement accepted: \(session.mode == .measurement)")
            setupReport = reportLines.joined(separator: "\n")

            return sampleRate
        } catch let error as EngineError {
            throw error
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
