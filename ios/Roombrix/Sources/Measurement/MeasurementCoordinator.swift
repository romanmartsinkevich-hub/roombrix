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
    /// The raw capture, saved as WAV into Documents for hand-back
    /// verification against the CLI.
    let recordingURL: URL?

    /// CLI-equivalent text report (band table + summary), shareable.
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

/// Drives one full measurement:
/// ambient capture → stimulus playback (or listen-only) → intake gates
/// (clipping, length, marker confidence, quiet precedence, drift) →
/// deconvolution → metrics. Mirrors `roombrix-validate measure` exactly.
@MainActor
final class MeasurementCoordinator: ObservableObject {

    enum Phase: Equatable {
        case idle
        case preparing
        case capturingAmbient(secondsLeft: Int)
        case playing(secondsLeft: Int)
        case waitingForExternalPlayback
        case processing
        case done
        case failed(String)
    }

    enum PlaybackPath {
        /// The app plays the stimulus through the current output route.
        case inApp
        /// The user plays the exported stimulus file from their own system;
        /// the app only listens.
        case listenOnly
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var result: MeasurementResult?

    private let engine = AudioMeasurementEngine()
    private var sweep: SineSweep?
    private var marker: TimingReference.Marker?

    static let sweepDuration = 10.0
    static let ambientSeconds = 3
    static let decayTailSeconds = 3.0

    #if canImport(AVFAudio)
    func start(path: PlaybackPath) async {
        phase = .preparing
        result = nil

        guard await AudioMeasurementEngine.requestPermission() else {
            phase = .failed(AudioMeasurementEngine.EngineError.permissionDenied.localizedDescription)
            return
        }
        let fs: Double
        do {
            fs = try engine.configureSession()
            try engine.startCapture()
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        // Stimulus DSP at the ACTUAL hardware rate (never assume 48 kHz).
        let sweep = SineSweep(parameters: .init(
            startFrequency: 20, endFrequency: 20_000,
            duration: Self.sweepDuration, sampleRate: fs
        ))
        let marker = TimingReference.makeMarker(sampleRate: fs)
        self.sweep = sweep
        self.marker = marker

        // Ambient lead-in (doubles as the noise-floor estimate).
        for remaining in stride(from: Self.ambientSeconds, to: 0, by: -1) {
            phase = .capturingAmbient(secondsLeft: remaining)
            try? await Task.sleep(for: .seconds(1))
        }

        switch path {
        case .inApp:
            let stimulus = TimingReference.assembleStimulus(
                marker: marker, payload: sweep.samples, includeEndMarker: true
            ).map { $0 * 0.5 } // −6 dBFS headroom
            engine.play(stimulus: stimulus)
            let playSeconds = Int(Double(stimulus.count) / fs) + Int(Self.decayTailSeconds) + 1
            for remaining in stride(from: playSeconds, to: 0, by: -1) {
                phase = .playing(secondsLeft: remaining)
                try? await Task.sleep(for: .seconds(1))
            }
            finishCapture()
        case .listenOnly:
            phase = .waitingForExternalPlayback
            // UI calls `finishListenOnly()` when the user's file has ended.
        }
    }

    func finishListenOnly() {
        guard phase == .waitingForExternalPlayback else { return }
        finishCapture()
    }

    func cancel() {
        _ = engine.stopCapture()
        phase = .idle
    }

    private func finishCapture() {
        phase = .processing
        let recording = engine.stopCapture()
        guard let sweep, let marker else {
            phase = .failed("Internal error: stimulus not prepared.")
            return
        }
        let fs = engine.sampleRate
        let inputDescription = engine.inputDescription

        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = Self.process(
                recording: recording, sweep: sweep, marker: marker,
                sampleRate: fs, inputDescription: inputDescription
            )
            await MainActor.run {
                guard let self else { return }
                switch outcome {
                case .success(let result):
                    self.result = result
                    self.phase = .done
                case .failure(let message):
                    self.phase = .failed(message)
                }
            }
        }
    }
    #endif

    // MARK: - Processing (pure; mirrors the CLI gates one for one)

    nonisolated static func process(
        recording: [Double],
        sweep: SineSweep,
        marker: TimingReference.Marker,
        sampleRate fs: Double,
        inputDescription: String
    ) -> Result<MeasurementResult, String> {
        // Clipping gate.
        let clipped = recording.lazy.filter { abs($0) >= 0.99 }.count
        if clipped > 10 {
            return .failure("Clipping detected (\(clipped) samples at full scale). Lower the volume slightly and measure again.")
        }

        // Length gate.
        let guardSamples = Int(marker.guardInterval * fs)
        let minimum = marker.samples.count + guardSamples + sweep.samples.count + Int(3 * fs)
        guard recording.count >= minimum else {
            return .failure("The recording ended before the sweep finished. Keep the app running until the countdown completes.")
        }

        // Marker detection with plausibility gates.
        let spacing = TimingReference.expectedMarkerSpacing(marker: marker, payloadCount: sweep.samples.count)
        let requiredTrailing = marker.samples.count + guardSamples + sweep.samples.count
        guard let detection = TimingReference.detect(
            marker: marker, in: recording,
            expectedMarkerSpacing: spacing,
            requiredTrailingSamples: requiredTrailing
        ), detection.confidenceDB >= TimingReference.minimumConfidenceDB else {
            return .failure("The timing chirp was not detected. Raise the playback volume (the chirp at the start should be clearly audible) and measure again.")
        }
        if let quiet = detection.preMarkerQuietDB, quiet < TimingReference.minimumPreMarkerQuietDB {
            return .failure("The measurement signal was not preceded by silence — possibly a false detection or loud background noise. Keep the room quiet during the countdown and measure again.")
        }
        if let drift = detection.clockDriftPPM, abs(drift) > TimingReference.maximumPlausibleDriftPPM {
            return .failure("Playback timing was inconsistent (possible dropout or stutter). Measure again; if it repeats, try a wired or different playback route.")
        }

        // SNR estimate from the ambient lead-in.
        var snr: Double?
        let ambientEnd = max(0, detection.markerStartIndex - Int(0.05 * fs))
        if ambientEnd > Int(0.3 * fs) {
            let ambient = Array(recording[..<ambientEnd])
            let sweepStart = min(detection.stimulusStartIndex, recording.count - 1)
            let sweepEnd = min(sweepStart + sweep.samples.count, recording.count)
            snr = NoiseFloor.signalToNoiseDB(
                signal: Array(recording[sweepStart..<sweepEnd]), ambient: ambient
            )
        }

        // Deconvolution + metrics.
        let aligned = Array(recording[min(detection.stimulusStartIndex, recording.count - 1)...])
        let deconvolved = Deconvolution.impulseResponse(from: aligned, sweep: sweep)
        let ir = ImpulseResponse(
            samples: deconvolved.impulseResponse,
            sampleRate: deconvolved.sampleRate,
            directIndex: deconvolved.peakIndex
        )
        let ambient = ambientEnd > 0 ? Array(recording[..<ambientEnd]) : nil
        let report = RoomAnalyzer.analyze(primary: ir, ambient: ambient)

        // Save the raw capture for CLI cross-verification.
        var savedURL: URL?
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        if let documents {
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let url = documents.appendingPathComponent("roombrix_capture_\(stamp).wav")
            do {
                try WAVFile.writeFloat32Mono(samples: recording, sampleRate: fs, to: url)
                savedURL = url
            } catch {
                savedURL = nil // non-fatal: metrics still stand
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
            recordingURL: savedURL
        ))
    }
}
