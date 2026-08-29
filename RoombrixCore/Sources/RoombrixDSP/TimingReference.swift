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
        /// NOTE: threshold tuned on marker+noise synthetics only — see
        /// docs/VALIDATION.md before trusting it on real sweep recordings.
        public let confidenceDB: Double
        /// Start of the end-of-stimulus marker, when one was found.
        public let endMarkerStartIndex: Int?
        /// Estimated clock drift between the playback DAC and the phone ADC,
        /// in parts per million, measured from the spacing of the two markers
        /// over the stimulus duration. Positive = playback clock runs slow
        /// relative to capture. v1 reports the drift; correction comes later.
        public let clockDriftPPM: Double?
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

    /// Full stimulus = marker + guard silence + payload
    /// [+ guard silence + end marker].
    ///
    /// The optional end marker enables clock-drift estimation: the spacing
    /// between the two detected markers, compared to the known assembled
    /// spacing, measures the playback-DAC vs capture-ADC rate mismatch over
    /// the sweep duration.
    public static func assembleStimulus(
        marker: Marker,
        payload: [Double],
        includeEndMarker: Bool = false
    ) -> [Double] {
        let guardSamples = [Double](repeating: 0, count: Int(marker.guardInterval * marker.sampleRate))
        var stimulus = marker.samples + guardSamples + payload
        if includeEndMarker {
            stimulus += guardSamples + marker.samples
        }
        return stimulus
    }

    /// Sample distance between the starts of the two markers in a stimulus
    /// assembled with `includeEndMarker: true`. Pass this to `detect` to get
    /// a drift estimate.
    public static func expectedMarkerSpacing(marker: Marker, payloadCount: Int) -> Int {
        let guardCount = Int(marker.guardInterval * marker.sampleRate)
        return marker.samples.count + 2 * guardCount + payloadCount
    }

    /// Locate the marker in a recording via FFT cross-correlation.
    /// Returns nil when the recording is shorter than the marker.
    ///
    /// - Parameter expectedMarkerSpacing: when the stimulus was assembled
    ///   with an end marker, the known start-to-start marker distance in
    ///   stimulus samples. The detector then searches for the end marker
    ///   near that offset (±1 %) and reports the measured clock drift.
    public static func detect(
        marker: Marker,
        in recording: [Double],
        expectedMarkerSpacing: Int? = nil
    ) -> Detection? {
        guard recording.count >= marker.samples.count else { return nil }
        let rawCorrelation = FFT.crossCorrelate(signal: recording, template: marker.samples)

        // NORMALIZED cross-correlation: divide by the local window energy.
        // Raw correlation rewards sheer energy, so the loud sweep region can
        // out-correlate the true marker as the sweep passes through the
        // marker's frequency band (observed on a reverberant synthetic
        // fixture: detector locked onto the sweep at +8 s). Normalizing by
        // the sliding RMS removes the loudness advantage; only genuine shape
        // matches score high.
        var prefixEnergy = [Double](repeating: 0, count: recording.count + 1)
        for i in 0..<recording.count {
            prefixEnergy[i + 1] = prefixEnergy[i] + recording[i] * recording[i]
        }
        let markerEnergy = marker.samples.reduce(0) { $0 + $1 * $1 }
        // Epsilon keeps digitally-silent windows from dividing by zero.
        let epsilon = max(prefixEnergy[recording.count] / Double(recording.count) * 1e-3, 1e-12)

        var correlation = [Double](repeating: 0, count: recording.count)
        for i in 0..<recording.count {
            let end = min(i + marker.samples.count, recording.count)
            let windowEnergy = prefixEnergy[end] - prefixEnergy[i]
            correlation[i] = rawCorrelation[i] / ((windowEnergy + epsilon) * markerEnergy).squareRoot()
        }

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

        // Start and end markers are identical, so the global correlation peak
        // may be either one. Search a ±1 % window at both ±spacing (drift is
        // well below 1000 ppm; the window also absorbs mild BT jitter) and
        // resolve the pair by whichever companion peak is stronger.
        var startIndex = peakIndex
        var endMarkerIndex: Int?
        var driftPPM: Double?
        if let spacing = expectedMarkerSpacing, spacing > 0 {
            let tolerance = max(spacing / 100, 32)
            func windowPeak(center: Int) -> (index: Int, value: Double)? {
                let lo = max(0, center - tolerance)
                let hi = min(correlation.count - 1, center + tolerance)
                guard lo < hi else { return nil }
                var bestIndex = lo
                var bestValue = 0.0
                for i in lo...hi where abs(correlation[i]) > bestValue {
                    bestValue = abs(correlation[i])
                    bestIndex = i
                }
                return (bestIndex, bestValue)
            }
            let forward = windowPeak(center: peakIndex + spacing)
            let backward = windowPeak(center: peakIndex - spacing)

            // Require a real companion peak, not window noise: the end marker
            // plays at the same level as the start marker, so demand a
            // comparable correlation magnitude.
            let floor = peakValue * 0.25
            let forwardValue = forward.map { $0.value } ?? 0
            let backwardValue = backward.map { $0.value } ?? 0
            if backwardValue >= floor, backwardValue >= forwardValue, let backward {
                // Global peak was the END marker.
                startIndex = backward.index
                endMarkerIndex = peakIndex
            } else if forwardValue >= floor, let forward {
                endMarkerIndex = forward.index
            }
            if let endMarkerIndex {
                let measured = Double(endMarkerIndex - startIndex)
                driftPPM = (measured - Double(spacing)) / Double(spacing) * 1_000_000
            }
        }

        let stimulusStart = startIndex + marker.samples.count
            + Int(marker.guardInterval * marker.sampleRate)
        return Detection(
            markerStartIndex: startIndex,
            stimulusStartIndex: stimulusStart,
            confidenceDB: confidence,
            endMarkerStartIndex: endMarkerIndex,
            clockDriftPPM: driftPPM
        )
    }
}
