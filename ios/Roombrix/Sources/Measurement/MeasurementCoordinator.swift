import Foundation
import RoombrixDSP
import RoombrixAcoustics
import RoombrixGeometry
import RoombrixScoring
import RoombrixDiagnosis

/// Orchestrates one full measurement:
/// ambient capture → stimulus playback (or listen-only for exported files)
/// → timing-reference alignment → deconvolution → analysis → score → diagnosis.
///
/// Playback paths (brief §5.2), in build order:
/// 1. `exportedFile`: user plays the exported stimulus WAV from their
///    streamer/Roon/USB stick; the app only listens. Most robust — built first.
/// 2. `phoneConnected`: app plays via AirPlay/Bluetooth/wired. Latency is
///    variable and untrusted; alignment relies on the acoustic marker.
@MainActor
final class MeasurementCoordinator: ObservableObject {

    enum PlaybackPath {
        case exportedFile
        case phoneConnected
    }

    enum MeasurementState {
        case idle
        case capturingAmbient
        case waitingForStimulus
        case capturing
        case processing
        case done(RoomScore, Diagnosis)
        case failed(String)
    }

    @Published private(set) var state: MeasurementState = .idle

    let sweep = SineSweep(parameters: .init(
        startFrequency: 20, endFrequency: 20_000, duration: 10, sampleRate: 48_000
    ))
    let marker = TimingReference.makeMarker(sampleRate: 48_000)

    /// The exportable stimulus (timing marker + guard + sweep) for path 1.
    var exportableStimulus: [Double] {
        TimingReference.assembleStimulus(marker: marker, payload: sweep.samples)
    }

    /// Process a completed capture into score + diagnosis.
    /// Pure function of the recording — runs off-main, meets the < 60 s
    /// post-capture budget comfortably (full pipeline is O(n log n)).
    func process(
        recording: [Double],
        ambient: [Double],
        geometry: RoomGeometry?,
        purpose: RoomPurpose,
        microphone: MicrophoneProfile
    ) async {
        state = .processing
        let sweep = self.sweep
        let marker = self.marker

        let result: Result<(RoomScore, Diagnosis), String> = await Task.detached(priority: .userInitiated) {
            // 1. Locate the timing marker; refuse low-confidence alignments.
            guard let detection = TimingReference.detect(marker: marker, in: recording),
                  detection.confidenceDB >= TimingReference.minimumConfidenceDB
            else {
                return .failure("Could not detect the timing reference in the recording. Increase the volume or reduce background noise, then try again.")
            }

            // 2. Deconvolve from the aligned stimulus start.
            let aligned = Array(recording[min(detection.stimulusStartIndex, recording.count - 1)...])
            let deconvolved = Deconvolution.impulseResponse(from: aligned, sweep: sweep)
            let ir = ImpulseResponse(
                samples: deconvolved.impulseResponse,
                sampleRate: deconvolved.sampleRate,
                directIndex: deconvolved.peakIndex
            )

            // 3. Metrics → score → diagnosis.
            let report = RoomAnalyzer.analyze(primary: ir, ambient: ambient)
            let score = ScoreEngine.score(.init(
                report: report, geometry: geometry, purpose: purpose, microphone: microphone
            ))
            let diagnosis = DiagnosisEngine.diagnose(.init(
                report: report, geometry: geometry, purpose: purpose
            ))
            return .success((score, diagnosis))
        }.value

        switch result {
        case .success(let (score, diagnosis)):
            state = .done(score, diagnosis)
        case .failure(let message):
            state = .failed(message)
        }
    }
}
