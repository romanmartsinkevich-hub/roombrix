import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// Radix-2 FFT with a portable pure-Swift implementation and an Accelerate
/// fast path on Apple platforms. All Roombrix spectral processing goes
/// through this type so the DSP kernel stays testable on Linux CI.
public enum FFT {

    /// Smallest power of two >= n.
    public static func nextPowerOfTwo(_ n: Int) -> Int {
        precondition(n > 0)
        var p = 1
        while p < n { p <<= 1 }
        return p
    }

    /// In-place complex FFT. `real.count` must equal `imag.count` and be a power of two.
    /// The inverse transform includes the 1/N normalization.
    public static func transform(real: inout [Double], imag: inout [Double], inverse: Bool = false) {
        let n = real.count
        precondition(n == imag.count, "real/imag length mismatch")
        precondition(n > 0 && (n & (n - 1)) == 0, "FFT length must be a power of two")

        // Bit-reversal permutation.
        var j = 0
        for i in 0..<(n - 1) {
            if i < j {
                real.swapAt(i, j)
                imag.swapAt(i, j)
            }
            var m = n >> 1
            while m >= 1 && j & m != 0 {
                j ^= m
                m >>= 1
            }
            j |= m
        }

        // Danielson–Lanczos butterflies.
        var length = 2
        while length <= n {
            let angle = (inverse ? 2.0 : -2.0) * Double.pi / Double(length)
            let wReal = cos(angle)
            let wImag = sin(angle)
            var start = 0
            while start < n {
                var curReal = 1.0
                var curImag = 0.0
                for k in 0..<(length / 2) {
                    let evenIndex = start + k
                    let oddIndex = start + k + length / 2
                    let tReal = curReal * real[oddIndex] - curImag * imag[oddIndex]
                    let tImag = curReal * imag[oddIndex] + curImag * real[oddIndex]
                    real[oddIndex] = real[evenIndex] - tReal
                    imag[oddIndex] = imag[evenIndex] - tImag
                    real[evenIndex] += tReal
                    imag[evenIndex] += tImag
                    let nextReal = curReal * wReal - curImag * wImag
                    curImag = curReal * wImag + curImag * wReal
                    curReal = nextReal
                }
                start += length
            }
            length <<= 1
        }

        if inverse {
            let scale = 1.0 / Double(n)
            for i in 0..<n {
                real[i] *= scale
                imag[i] *= scale
            }
        }
    }

    /// Magnitude spectrum of a real signal, zero-padded to the next power of two.
    /// Returns `paddedLength / 2 + 1` bins (DC through Nyquist).
    public static func magnitudeSpectrum(of signal: [Double]) -> [Double] {
        let n = nextPowerOfTwo(max(signal.count, 2))
        var re = signal + [Double](repeating: 0, count: n - signal.count)
        var im = [Double](repeating: 0, count: n)
        transform(real: &re, imag: &im)
        return (0...(n / 2)).map { hypot(re[$0], im[$0]) }
    }

    /// Linear convolution of two real signals via FFT (overlap-free, single block).
    /// Output length is `a.count + b.count - 1`.
    public static func convolve(_ a: [Double], _ b: [Double]) -> [Double] {
        precondition(!a.isEmpty && !b.isEmpty)
        let outLength = a.count + b.count - 1
        let n = nextPowerOfTwo(outLength)
        var aRe = a + [Double](repeating: 0, count: n - a.count)
        var aIm = [Double](repeating: 0, count: n)
        var bRe = b + [Double](repeating: 0, count: n - b.count)
        var bIm = [Double](repeating: 0, count: n)
        transform(real: &aRe, imag: &aIm)
        transform(real: &bRe, imag: &bIm)
        for i in 0..<n {
            let re = aRe[i] * bRe[i] - aIm[i] * bIm[i]
            let im = aRe[i] * bIm[i] + aIm[i] * bRe[i]
            aRe[i] = re
            aIm[i] = im
        }
        transform(real: &aRe, imag: &aIm, inverse: true)
        return Array(aRe[0..<outLength])
    }

    /// Cross-correlation of `signal` against `template` (matched filtering).
    /// `result[k]` is the correlation with the template starting at sample `k`
    /// of the signal; the array has `signal.count` entries.
    public static func crossCorrelate(signal: [Double], template: [Double]) -> [Double] {
        let reversed = Array(template.reversed())
        let full = convolve(signal, reversed)
        // Full correlation has length signal + template - 1; lag 0 (template
        // aligned at signal start) sits at index template.count - 1.
        let start = template.count - 1
        return Array(full[start..<(start + signal.count)])
    }
}
