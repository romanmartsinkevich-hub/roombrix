import Foundation
import RoombrixDSP
import RoombrixAcoustics

/// The full measurement pipeline (marker detection → gates → deconvolution
/// → analysis) as a library call, shared by the CLI, the campaign harness,
/// and the acceptance tests. Mirrors the app's processing one for one.
public enum CapturePipeline {

    public struct Output {
        public let decays: [ReverbTime.BandDecay]
        public let snrDB: Double?
        public let report: AcousticReport
        public let markerConfidenceDB: Double
        public let sampleRate: Double
    }

    public enum PipelineError: Error, CustomStringConvertible {
        case markerNotFound(String)

        public var description: String {
            switch self {
            case .markerNotFound(let file):
                return "timing marker not detected in \(file)"
            }
        }
    }

    /// In-process memo: acceptance tests and the campaign harness analyze
    /// the same captures repeatedly; deconvolution dominates runtime.
    private static var cache: [String: Output] = [:]
    private static let cacheLock = NSLock()

    public static func analyze(url: URL) throws -> Output {
        cacheLock.lock()
        if let cached = cache[url.path] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let audio = try WAVFile.read(url: url)
        let fs = audio.sampleRate
        let sweep = SineSweep(parameters: .init(
            startFrequency: 20, endFrequency: 20_000, duration: 10, sampleRate: fs
        ))
        let marker = TimingReference.makeMarker(sampleRate: fs)
        let spacing = TimingReference.expectedMarkerSpacing(
            marker: marker, payloadCount: sweep.samples.count
        )
        let guardSamples = Int(marker.guardInterval * fs)
        let requiredTrailing = marker.samples.count + guardSamples + sweep.samples.count

        guard let detection = TimingReference.detect(
            marker: marker, in: audio.samples,
            expectedMarkerSpacing: spacing,
            requiredTrailingSamples: requiredTrailing
        ), detection.confidenceDB >= TimingReference.minimumConfidenceDB else {
            throw PipelineError.markerNotFound(url.lastPathComponent)
        }

        let snr = NoiseFloor.peakToNoiseGapDB(
            recording: audio.samples,
            markerStartIndex: detection.markerStartIndex,
            sampleRate: fs
        )
        let aligned = Array(audio.samples[min(detection.stimulusStartIndex, audio.samples.count - 1)...])
        let deconvolved = Deconvolution.impulseResponse(from: aligned, sweep: sweep)
        let ir = ImpulseResponse(
            samples: deconvolved.impulseResponse,
            sampleRate: deconvolved.sampleRate,
            directIndex: deconvolved.peakIndex
        )
        let report = RoomAnalyzer.analyze(primary: ir)
        let output = Output(
            decays: report.bandDecays,
            snrDB: snr,
            report: report,
            markerConfidenceDB: detection.confidenceDB,
            sampleRate: fs
        )
        cacheLock.lock()
        cache[url.path] = output
        cacheLock.unlock()
        return output
    }
}
