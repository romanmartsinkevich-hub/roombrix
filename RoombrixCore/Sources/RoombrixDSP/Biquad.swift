import Foundation

/// Direct-form-I biquad section with RBJ Audio-EQ-Cookbook designs.
public struct Biquad: Sendable {
    public var b0, b1, b2, a1, a2: Double

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    /// Constant-skirt-gain bandpass (RBJ), peak gain = Q.
    public static func bandpass(center: Double, q: Double, sampleRate: Double) -> Biquad {
        let w0 = 2 * Double.pi * center / sampleRate
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        return Biquad(
            b0: alpha / a0,
            b1: 0,
            b2: -alpha / a0,
            a1: -2 * cos(w0) / a0,
            a2: (1 - alpha) / a0
        )
    }

    public static func lowpass(cutoff: Double, q: Double = 0.7071, sampleRate: Double) -> Biquad {
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cw = cos(w0)
        let a0 = 1 + alpha
        return Biquad(
            b0: (1 - cw) / 2 / a0,
            b1: (1 - cw) / a0,
            b2: (1 - cw) / 2 / a0,
            a1: -2 * cw / a0,
            a2: (1 - alpha) / a0
        )
    }

    public static func highpass(cutoff: Double, q: Double = 0.7071, sampleRate: Double) -> Biquad {
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cw = cos(w0)
        let a0 = 1 + alpha
        return Biquad(
            b0: (1 + cw) / 2 / a0,
            b1: -(1 + cw) / a0,
            b2: (1 + cw) / 2 / a0,
            a1: -2 * cw / a0,
            a2: (1 - alpha) / a0
        )
    }

    /// Magnitude response |H(e^{jω})| at a frequency.
    public func magnitude(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let cw = cos(w), sw = sin(w)
        let c2w = cos(2 * w), s2w = sin(2 * w)
        let numRe = b0 + b1 * cw + b2 * c2w
        let numIm = -(b1 * sw + b2 * s2w)
        let denRe = 1 + a1 * cw + a2 * c2w
        let denIm = -(a1 * sw + a2 * s2w)
        return hypot(numRe, numIm) / hypot(denRe, denIm)
    }

    /// Single-pass filtering with zeroed initial state.
    public func process(_ input: [Double]) -> [Double] {
        var output = [Double](repeating: 0, count: input.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in 0..<input.count {
            let x0 = input[i]
            let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            output[i] = y0
            x2 = x1; x1 = x0
            y2 = y1; y1 = y0
        }
        return output
    }
}

/// Cascade of biquad sections, with optional zero-phase (forward-backward)
/// filtering. Zero-phase mode is used for decay analysis so band filters do
/// not smear the Schroeder curve asymmetrically.
public struct BiquadCascade: Sendable {
    public var sections: [Biquad]

    public init(sections: [Biquad]) {
        self.sections = sections
    }

    public func process(_ input: [Double]) -> [Double] {
        sections.reduce(input) { signal, section in section.process(signal) }
    }

    public func magnitude(at frequency: Double, sampleRate: Double) -> Double {
        sections.reduce(1.0) { $0 * $1.magnitude(at: frequency, sampleRate: sampleRate) }
    }

    /// Forward-backward filtering: squared magnitude response, zero phase.
    public func processZeroPhase(_ input: [Double]) -> [Double] {
        let forward = process(input)
        let backward = process(Array(forward.reversed()))
        return Array(backward.reversed())
    }
}
