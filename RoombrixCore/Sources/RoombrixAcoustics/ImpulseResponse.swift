import Foundation

/// A measured (or synthetic) room impulse response.
public struct ImpulseResponse: Sendable {
    public let samples: [Double]
    public let sampleRate: Double
    /// Index of the direct-sound arrival (energy peak).
    public let directIndex: Int

    public init(samples: [Double], sampleRate: Double, directIndex: Int? = nil) {
        precondition(!samples.isEmpty && sampleRate > 0)
        self.samples = samples
        self.sampleRate = sampleRate
        if let directIndex {
            self.directIndex = directIndex
        } else {
            var peak = 0
            var peakValue = 0.0
            for (i, v) in samples.enumerated() where abs(v) > peakValue {
                peakValue = abs(v)
                peak = i
            }
            self.directIndex = peak
        }
    }

    public var duration: Double { Double(samples.count) / sampleRate }

    /// Samples from the direct sound onward (what energy-ratio metrics use).
    public var causalPart: [Double] {
        Array(samples[directIndex...])
    }
}
