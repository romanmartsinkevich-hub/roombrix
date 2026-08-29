import Foundation
import RoombrixDSP
import RoombrixAcoustics
import RoombrixValidation

/// One completed measurement, formatted identically to the CLI so results
/// are directly comparable against the REW reference workflow.
struct MeasurementResult: Identifiable {
    let id = UUID()
    let date: Date
    let report: AcousticReport
    let markerConfidenceDB: Double
    let latencySeconds: Double
    let preMarkerQuietDB: Double?
    let clockDriftPPM: Double?
    let snrDB: Double?
    let sampleRate: Double
    let inputDescription: String
    /// Set when the sweep arrived at a clearly different level than the
    /// pink-noise pass — the user changed the volume between stages.
    let levelChangeWarning: String?
    /// The raw capture, saved as WAV into Documents for hand-back
    /// verification against the CLI.
    let recordingURL: URL?

    var reportText: String {
        var lines: [String] = []
        lines.append("Roombrix measurement — \(date.formatted(date: .abbreviated, time: .standard))")
        lines.append("Input: \(inputDescription) @ \(Int(sampleRate)) Hz")
        lines.append(String(format: "Marker confidence: %.1f dB; latency %.3f s", markerConfidenceDB, latencySeconds))
        if let quiet = preMarkerQuietDB {
            lines.append(String(format: "Pre-marker quiet: %.1f dB", quiet))
        }
        if let snr = snrDB {
            lines.append(String(format: "SNR estimate: %.1f dB", snr))
        }
        if let drift = clockDriftPPM {
            lines.append(String(format: "Clock drift: %+.0f ppm", drift))
        }
        if let warning = levelChangeWarning {
            lines.append("WARNING: \(warning)")
        }
        lines.append("")
        lines.append("Band (Hz) |   EDT   |   T20   |   T30   | Range | Metric")
        for band in report.bandDecays {
            func fmt(_ v: Double?) -> String { v.map { String(format: "%.3f s", $0) } ?? "   —   " }
            let range = band.usableDecayRangeDB.map { String(format: "%2.0f dB", $0) } ?? "  —  "
            lines.append(String(
                format: "%9.0f | %@ | %@ | %@ | %@ | %@",
                band.centerFrequency, fmt(band.edt), fmt(band.t20), fmt(band.t30),
                range, band.selectedMetric.rawValue
            ))
        }
        if let mid = report.midBandRT60 {
            lines.append(String(format: "Mid-band RT60: %.3f s", mid))
        }
        if let ratio = report.lowToMidDecayRatio {
            lines.append(String(format: "LF/mid decay ratio: %.2f", ratio))
        }
        if let c80 = report.c80 {
            lines.append(String(format: "C80: %+.1f dB", c80))
        }
        lines.append("(Estimates from a consumer microphone, not lab measurements.)")
        return lines.joined(separator: "\n")
    }
}

/// Failure carrying a user-facing message (String itself is not an Error).
struct MeasurementFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Flow constants. Deliberately OUTSIDE the @MainActor coordinator class:
/// statics of a MainActor type inherit its isolation, and the nonisolated
/// processing path must be able to read these.
enum MeasurementConstants {
    static let ambientSeconds = 5
    static let sweepDuration = 10.0
    static let decayTailSeconds = 3.0
    static let targetSNRdB = 45.0
    static let snrBands: [Double] = [250, 500, 1_000, 2_000, 4_000]
    static let maxSweepRecordingSeconds = 180.0
}

/// Per-band live/ambient level for the UI.
struct BandLevel: Identifiable {
    var id: Double { frequency }
    let frequency: Double
    let levelDB: Double
}

struct BandSNR: Identifiable {
    var id: Double { frequency }
    let frequency: Double
    let snrDB: Double
}

/// Three-stage measurement flow. The phone NEVER plays audio — the user
/// plays the stimulus package (pink noise for level setting, then the
/// sweep) through their own system while the phone records:
///
///   AMBIENT  → 5 s of silence, per-band noise floor
///   LEVEL SET → user loops pink noise; live per-band SNR vs the ambient
///               floor; target ≥ 45 dB in 250 Hz–4 kHz (makes T30 usable
///               in every band); traffic-light UI
///   MEASURE  → user plays the sweep at the SAME volume; auto-stop after
///               signal + decay tail; intake gates; metrics
@MainActor
final class MeasurementCoordinator: ObservableObject {

    enum Phase: Equatable {
        case idle
        case preparing
        case capturingAmbient(secondsLeft: Int)
        case ambientReview
        case levelSetting
        case waitingForSweep
        case recordingSweep
        case processing
        case done
        case failed(String)
    }

    enum TrafficLight {
        case tooQuiet, good, clipping
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var result: MeasurementResult?
    @Published private(set) var ambientBandLevels: [BandLevel] = []
    @Published private(set) var ambientWarning: String?
    @Published private(set) var liveSNR: [BandSNR] = []
    @Published private(set) var trafficLight: TrafficLight = .tooQuiet

    private let engine = AudioMeasurementEngine()
    private var ambientBuffer: [Double] = []
    private var ambientBandsByFrequency: [Double: Double] = [:]
    private var pinkLevelDB: Double?
    private var meteringTask: Task<Void, Never>?
    private var sweepWatchTask: Task<Void, Never>?

    #if canImport(AVFAudio)

    // MARK: - Stage A: ambient

    func startAmbient() async {
        phase = .preparing
        result = nil
        ambientWarning = nil

        guard await AudioMeasurementEngine.requestPermission() else {
            phase = .failed(AudioMeasurementEngine.EngineError.permissionDenied.localizedDescription)
            return
        }
        do {
            _ = try engine.configureSession()
            try engine.startCapture()
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        for remaining in stride(from: MeasurementConstants.ambientSeconds, to: 0, by: -1) {
            phase = .capturingAmbient(secondsLeft: remaining)
            try? await Task.sleep(for: .seconds(1))
        }
        ambientBuffer = engine.stopCapture()

        let fs = engine.sampleRate
        var bands: [BandLevel] = []
        ambientBandsByFrequency.removeAll()
        for center in OctaveBand.standardCenters where center < fs / 2 {
            let level = Self.bandLevelDB(ambientBuffer, center: center, sampleRate: fs)
            bands.append(BandLevel(frequency: center, levelDB: level))
            ambientBandsByFrequency[center] = level
        }
        ambientBandLevels = bands

        let broadband = Self.broadbandLevelDB(ambientBuffer)
        if broadband > -45 {
            ambientWarning = "Background noise is on the high side. If something is running — HVAC, fridge, open window, traffic — turning it off now will make every result more reliable."
        }
        phase = .ambientReview
    }

    // MARK: - Stage B: level setting (pink noise)

    func startLevelSetting() {
        do {
            try engine.startCapture()
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        phase = .levelSetting
        meteringTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                await self?.updateLiveMeters()
            }
        }
    }

    private func updateLiveMeters() {
        guard phase == .levelSetting else { return }
        let fs = engine.sampleRate
        let recent = engine.recentSamples(1.0)
        guard recent.count > Int(0.5 * fs) else { return }

        let clippedCount = recent.lazy.filter { abs($0) >= 0.99 }.count
        var snrs: [BandSNR] = []
        var worst = Double.infinity
        for center in MeasurementConstants.snrBands where center < fs / 2 {
            let live = Self.bandLevelDB(recent, center: center, sampleRate: fs)
            let ambient = ambientBandsByFrequency[center] ?? -100
            let snr = live - ambient
            snrs.append(BandSNR(frequency: center, snrDB: snr))
            worst = min(worst, snr)
        }
        liveSNR = snrs
        if clippedCount > 5 {
            trafficLight = .clipping
        } else if worst >= MeasurementConstants.targetSNRdB {
            trafficLight = .good
        } else {
            trafficLight = .tooQuiet
        }
    }

    /// User confirms the volume is set (ideally on green). Captures the
    /// pink-noise level as the expectation for the sweep pass.
    func confirmLevel() {
        meteringTask?.cancel()
        let recent = engine.recentSamples(1.0)
        pinkLevelDB = recent.isEmpty ? nil : Self.broadbandLevelDB(recent)
        _ = engine.stopCapture() // level-setting audio is discarded
        startSweepRecording()
    }

    // MARK: - Stage C: sweep

    private func startSweepRecording() {
        do {
            try engine.startCapture()
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        phase = .waitingForSweep

        let fs = engine.sampleRate
        let ambientBroadband = Self.broadbandLevelDB(ambientBuffer)
        sweepWatchTask = Task { [weak self] in
            var signalSeconds = 0.0
            var quietSecondsAfterSignal = 0.0
            let tick = 0.5
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(tick))
                guard let self else { return }
                let elapsed = self.engine.capturedDuration
                let recent = self.engine.recentSamples(1.0)
                guard recent.count > Int(0.5 * fs) else { continue }
                let level = Self.broadbandLevelDB(recent)

                await MainActor.run {
                    if level > ambientBroadband + 15, self.phase == .waitingForSweep {
                        self.phase = .recordingSweep
                    }
                }
                if level > ambientBroadband + 15 {
                    signalSeconds += tick
                    quietSecondsAfterSignal = 0
                } else if signalSeconds > 0 {
                    quietSecondsAfterSignal += tick
                }

                // Auto-stop: enough signal seen (sweep ≈ 10 s) and quiet for
                // decay tail + margin — or the hard cap.
                let sawSweep = signalSeconds >= MeasurementConstants.sweepDuration * 0.7
                let tailDone = quietSecondsAfterSignal >= MeasurementConstants.decayTailSeconds + 1.5
                if (sawSweep && tailDone) || elapsed > MeasurementConstants.maxSweepRecordingSeconds {
                    await MainActor.run { self.finishSweep() }
                    return
                }
            }
        }
    }

    /// Manual stop (always available); also called by the auto-stop watcher.
    func finishSweep() {
        guard phase == .waitingForSweep || phase == .recordingSweep else { return }
        sweepWatchTask?.cancel()
        phase = .processing
        let recording = engine.stopCapture()
        let fs = engine.sampleRate
        let inputDescription = engine.inputDescription
        let ambient = ambientBuffer
        let pinkLevel = pinkLevelDB

        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = Self.process(
                recording: recording, ambient: ambient,
                pinkLevelDB: pinkLevel, sampleRate: fs,
                inputDescription: inputDescription
            )
            await MainActor.run {
                guard let self else { return }
                switch outcome {
                case .success(let result):
                    self.result = result
                    self.phase = .done
                case .failure(let failure):
                    self.phase = .failed(failure.message)
                }
            }
        }
    }

    func cancel() {
        meteringTask?.cancel()
        sweepWatchTask?.cancel()
        _ = engine.stopCapture()
        phase = .idle
    }
    #endif

    // MARK: - Level helpers

    nonisolated static func bandLevelDB(_ samples: [Double], center: Double, sampleRate: Double) -> Double {
        guard !samples.isEmpty else { return -120 }
        let banded = OctaveBand.filtered(samples, center: center, sampleRate: sampleRate)
        let power = banded.reduce(0) { $0 + $1 * $1 } / Double(banded.count)
        return 10 * log10(max(power, 1e-14))
    }

    nonisolated static func broadbandLevelDB(_ samples: [Double]) -> Double {
        guard !samples.isEmpty else { return -120 }
        let power = samples.reduce(0) { $0 + $1 * $1 } / Double(samples.count)
        return 10 * log10(max(power, 1e-14))
    }

    // MARK: - Processing (pure; mirrors the CLI gates one for one)

    nonisolated static func process(
        recording: [Double],
        ambient: [Double],
        pinkLevelDB: Double?,
        sampleRate fs: Double,
        inputDescription: String
    ) -> Result<MeasurementResult, MeasurementFailure> {
        let sweep = SineSweep(parameters: .init(
            startFrequency: 20, endFrequency: 20_000,
            duration: MeasurementConstants.sweepDuration, sampleRate: fs
        ))
        let marker = TimingReference.makeMarker(sampleRate: fs)

        // Clipping gate.
        let clipped = recording.lazy.filter { abs($0) >= 0.99 }.count
        if clipped > 10 {
            return .failure(MeasurementFailure("Clipping detected (\(clipped) samples at full scale). Lower the volume slightly and measure again."))
        }

        // Length gate.
        let guardSamples = Int(marker.guardInterval * fs)
        let requiredTrailing = marker.samples.count + guardSamples + sweep.samples.count
        guard recording.count >= requiredTrailing + Int(3 * fs) else {
            return .failure(MeasurementFailure("The recording ended before the sweep finished. Let the sweep play to the end, then wait a few seconds before stopping."))
        }

        // Marker detection with plausibility gates.
        let spacing = TimingReference.expectedMarkerSpacing(marker: marker, payloadCount: sweep.samples.count)
        guard let detection = TimingReference.detect(
            marker: marker, in: recording,
            expectedMarkerSpacing: spacing,
            requiredTrailingSamples: requiredTrailing
        ), detection.confidenceDB >= TimingReference.minimumConfidenceDB else {
            return .failure(MeasurementFailure("The timing chirp was not detected. Make sure you played the Roombrix sweep file (it starts with a short chirp) at the volume you set, and measure again."))
        }
        if let quiet = detection.preMarkerQuietDB, quiet < TimingReference.minimumPreMarkerQuietDB {
            return .failure(MeasurementFailure("The chirp was not preceded by silence — possibly a false detection, or the pink noise was still playing. Stop the pink noise fully before starting the sweep, then measure again."))
        }
        if let drift = detection.clockDriftPPM, abs(drift) > TimingReference.maximumPlausibleDriftPPM {
            return .failure(MeasurementFailure("Playback timing was inconsistent (possible dropout or stutter). Measure again; if it repeats, try a different playback source."))
        }

        // SNR from the dedicated ambient stage.
        let sweepStart = min(detection.stimulusStartIndex, recording.count - 1)
        let sweepEnd = min(sweepStart + sweep.samples.count, recording.count)
        let sweepRegion = Array(recording[sweepStart..<sweepEnd])
        let snr = NoiseFloor.signalToNoiseDB(signal: sweepRegion, ambient: ambient)

        // Level continuity vs the pink-noise pass. Both files are peak
        // -6 dBFS; the sweep's payload RMS sits ~9 dB above pink RMS, so
        // expected sweep level = pink level + digital offset of the files.
        var levelChangeWarning: String?
        if let pinkLevelDB {
            let sweepFileRMS = 10 * log10(
                sweep.samples.reduce(0) { $0 + $1 * $1 } / Double(sweep.samples.count)
            ) - 6 // payload is unit-peak; file is scaled to −6 dBFS peak
            let pinkFileRMS = -6.0 - StimulusPackage.pinkCrestFactorDB
            let expectedOffset = sweepFileRMS - pinkFileRMS
            let measuredSweep = broadbandLevelDB(sweepRegion)
            let deviation = (measuredSweep - pinkLevelDB) - expectedOffset
            if abs(deviation) > 6 {
                levelChangeWarning = String(
                    format: "The sweep arrived %.0f dB %@ than the level you set with pink noise — the volume changed between stages. Consider redoing the measurement at the confirmed level.",
                    abs(deviation), deviation > 0 ? "louder" : "quieter"
                )
            }
        }

        // Deconvolution + metrics.
        let aligned = Array(recording[sweepStart...])
        let deconvolved = Deconvolution.impulseResponse(from: aligned, sweep: sweep)
        let ir = ImpulseResponse(
            samples: deconvolved.impulseResponse,
            sampleRate: deconvolved.sampleRate,
            directIndex: deconvolved.peakIndex
        )
        let report = RoomAnalyzer.analyze(primary: ir, ambient: ambient)

        // Save the raw capture for CLI cross-verification.
        var savedURL: URL?
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let url = documents.appendingPathComponent("roombrix_capture_\(stamp).wav")
            do {
                try WAVFile.writeFloat32Mono(samples: recording, sampleRate: fs, to: url)
                savedURL = url
            } catch {
                savedURL = nil // non-fatal
            }
        }

        return .success(MeasurementResult(
            date: Date(),
            report: report,
            markerConfidenceDB: detection.confidenceDB,
            latencySeconds: Double(detection.markerStartIndex) / fs,
            preMarkerQuietDB: detection.preMarkerQuietDB,
            clockDriftPPM: detection.clockDriftPPM,
            snrDB: snr,
            sampleRate: fs,
            inputDescription: inputDescription,
            levelChangeWarning: levelChangeWarning,
            recordingURL: savedURL
        ))
    }
}
