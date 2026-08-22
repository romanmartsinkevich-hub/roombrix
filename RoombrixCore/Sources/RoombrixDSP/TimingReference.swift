import Foundation

/// Acoustic timing reference for playback paths with unknown, variable latency
/// (AirPlay, Bluetooth, exported stimulus files played from a streamer).
///
/// A short known chirp is prepended to the stimulus. After capture we locate
/// the chirp in the recording by matched filtering and align everything to it,
/// so system latency reporting is never trusted.
public struct TimingReference: Sendable {

    public struct Marker: Sendable {
        public let samples: [Double]
        public let sampleRate: Double
        /// Silence inserted between the marker and the main stimulus, seconds.
        public let guardInterval: Double
    }

    public struct Detection: Sendable {
        /// Sample index in the recording where the marker starts.
        public let markerStartIndex: Int
        /// Sample index where the main stimulus is expected to start.
        public let stimulusStartIndex: Int
        /// Peak-to-RMS ratio of the correlation, in dB. Below ~12 dB the
        /// detection should be treated as failed and the user asked to retry.
        public let confidenceDB: Double
    }

    /// Minimum confidence for a detection to be considered trustworthy.
    public static let minimumConfidenceDB = 12.0

    /// Linear chirp marker, 1–8 kHz over 250 ms by default. That band survives
    /// small speakers, Bluetooth codecs, and phone-mic rolloff at both ends.
    public static func makeMarker(
        sampleRate: Double = 48_000,
        duration: Double = 0.25,
        startFrequency: Double = 1_000,
        endFrequency: Double = 8_000,
        guardInterval: Double = 0.5
    ) -> Marker {
        let count = Int(duration * sampleRate)
        var samples = [Double](repeating: 0, count: count)
        let k = (endFrequency - startFrequency) / duration
        for i in 0..<count {
            let t = Double(i) / sampleRate
            let phase = 2 * Double.pi * (startFrequency * t + 0.5 * k * t * t)
            samples[i] = sin(phase)
        }
        // Hann window keeps the marker click-free on lossy transports.
        for i in 0..<count {
            let w = 0.5 * (1 - cos(2 * Double.pi * Double(i) / Double(count - 1)))
            samples[i] *= w
        }
        return Marker(samples: samples, sampleRate: sampleRate, guardInterval: guardInterval)
    }

    /// Full stimulus = marker + guard silence + payload.
    public static func assembleStimulus(marker: Marker, payload: [Double]) -> [Double] {
        let guardSamples = [Double](repeating: 0, count: Int(marker.guardInterval * marker.sampleRate))
        return marker.samples + guardSamples + payload
    }

    /// Locate the marker in a recording via FFT cross-correlation.
    /// Returns nil when the recording is shorter than the marker.
    public static func detect(marker: Marker, in recording: [Double]) -> Detection? {
        guard recording.count >= marker.samples.count else { return nil }
        let correlation = FFT.crossCorrelate(signal: recording, template: marker.samples)

        var peakIndex = 0
        var peakValue = 0.0
        var sumSquares = 0.0
        for (i, v) in correlation.enumerated() {
            let mag = abs(v)
            sumSquares += v * v
            if mag > peakValue {
                peakValue = mag
                peakIndex = i
            }
        }
        let rms = (sumSquares / Double(correlation.count)).squareRoot()
        let confidence = rms > 0 ? 20 * log10(peakValue / rms) : 0

        let stimulusStart = peakIndex + marker.samples.count
            + Int(marker.guardInterval * marker.sampleRate)
        return Detection(
            markerStartIndex: peakIndex,
            stimulusStartIndex: stimulusStart,
            confidenceDB: confidence
        )
    }
}
