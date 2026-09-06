import Foundation

/// Exponential sine sweep (ESS) stimulus per Farina (2000).
///
/// ESS is chosen over MLS/noise because harmonic distortion of the playback
/// chain (phone speakers, consumer amps) deconvolves into *negative* time,
/// where it can be windowed away from the linear impulse response.
public struct SineSweep: Sendable {

    public struct Parameters: Sendable {
        public var startFrequency: Double
        public var endFrequency: Double
        public var duration: Double
        public var sampleRate: Double
        /// Raised-cosine fade applied to both ends, seconds.
        public var fadeDuration: Double

        public init(
            startFrequency: Double = 20,
            endFrequency: Double = 20_000,
            duration: Double = 10,
            sampleRate: Double = 48_000,
            fadeDuration: Double = 0.02
        ) {
            precondition(startFrequency > 0 && endFrequency > startFrequency)
            precondition(duration > 0 && sampleRate > 0)
            self.startFrequency = startFrequency
            self.endFrequency = endFrequency
            self.duration = duration
            self.sampleRate = sampleRate
            self.fadeDuration = fadeDuration
        }
    }

    public let parameters: Parameters
    /// The sweep signal itself, peak-normalized to ±1.
    public let samples: [Double]
    /// Amplitude-compensated time reversal of the sweep. Convolving the
    /// recorded response with this yields the impulse response.
    public let inverseFilter: [Double]

    public init(parameters: Parameters = Parameters()) {
        self.parameters = parameters
        let fs = parameters.sampleRate
        let count = Int(parameters.duration * fs)
        let w1 = 2 * Double.pi * parameters.startFrequency
        let w2 = 2 * Double.pi * parameters.endFrequency
        // Farina: x(t) = sin(K (e^{t/L} - 1)), L = T / ln(w2/w1), K = w1 * L.
        let L = parameters.duration / log(w2 / w1)
        let K = w1 * L

        var sweep = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / fs
            sweep[i] = sin(K * (exp(t / L) - 1))
        }

        // Fades avoid spectral splatter at the sweep edges.
        let fadeSamples = min(Int(parameters.fadeDuration * fs), count / 2)
        for i in 0..<fadeSamples {
            let gain = 0.5 * (1 - cos(Double.pi * Double(i) / Double(fadeSamples)))
            sweep[i] *= gain
            sweep[count - 1 - i] *= gain
        }
        self.samples = sweep

        // Inverse filter: time-reversed sweep with a +6 dB/octave amplitude
        // envelope (equivalently, e^{-t/L} applied before reversal) so that
        // sweep ⊛ inverse ≈ bandlimited delta.
        var inverse = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / fs
            inverse[count - 1 - i] = sweep[i] * exp(-t / L)
        }
        // Normalize so that convolving the pristine sweep yields a unit peak.
        let reference = FFT.convolve(sweep, inverse)
        let peak = reference.map(abs).max() ?? 1
        if peak > 0 {
            for i in 0..<count { inverse[i] /= peak }
        }
        self.inverseFilter = inverse
    }
}
