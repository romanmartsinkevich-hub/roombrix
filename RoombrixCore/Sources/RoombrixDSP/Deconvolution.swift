import Foundation

/// Turns a recorded sweep response back into an impulse response.
public enum Deconvolution {

    public struct Result: Sendable {
        /// Causal impulse response, starting slightly before the direct sound.
        public var impulseResponse: [Double]
        /// Index of the direct-sound peak inside `impulseResponse`.
        public var peakIndex: Int
        public var sampleRate: Double
    }

    /// Convolve the recording with the sweep's inverse filter and extract the
    /// causal part. Harmonic distortion products land before the linear peak
    /// and are discarded by the pre-peak window.
    ///
    /// - Parameters:
    ///   - recording: microphone capture of the sweep played through the system.
    ///   - sweep: the stimulus that was played.
    ///   - prePeakSeconds: how much lead-in to keep ahead of the direct sound.
    ///   - lengthSeconds: IR length to keep after the direct sound. Defaults to
    ///     3 s, enough for RT60 up to ~2.5 s with usable decay range.
    public static func impulseResponse(
        from recording: [Double],
        sweep: SineSweep,
        prePeakSeconds: Double = 0.01,
        lengthSeconds: Double = 3.0
    ) -> Result {
        precondition(!recording.isEmpty)
        let fs = sweep.parameters.sampleRate
        let full = FFT.convolve(recording, sweep.inverseFilter)

        // The linear IR peak is the global maximum of |full|; distortion
        // orders sit earlier in time and at lower level.
        var peakIndex = 0
        var peakValue = 0.0
        for (i, v) in full.enumerated() where abs(v) > peakValue {
            peakValue = abs(v)
            peakIndex = i
        }

        let pre = Int(prePeakSeconds * fs)
        let post = Int(lengthSeconds * fs)
        let start = max(0, peakIndex - pre)
        let end = min(full.count, peakIndex + post)
        let ir = Array(full[start..<end])
        return Result(impulseResponse: ir, peakIndex: peakIndex - start, sampleRate: fs)
    }
}
