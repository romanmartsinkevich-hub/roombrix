import XCTest
@testable import RoombrixDSP

final class FFTTests: XCTestCase {

    /// Deterministic pseudo-random generator so tests are reproducible.
    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    func randomSignal(count: Int, seed: UInt64) -> [Double] {
        var rng = SplitMix64(seed: seed)
        return (0..<count).map { _ in Double.random(in: -1...1, using: &rng) }
    }

    func testMatchesNaiveDFT() {
        let n = 256
        let signal = randomSignal(count: n, seed: 1)
        var re = signal
        var im = [Double](repeating: 0, count: n)
        FFT.transform(real: &re, imag: &im)

        for k in [0, 1, 7, 100, 128, 255] {
            var expectedRe = 0.0
            var expectedIm = 0.0
            for t in 0..<n {
                let angle = -2 * Double.pi * Double(k * t) / Double(n)
                expectedRe += signal[t] * cos(angle)
                expectedIm += signal[t] * sin(angle)
            }
            XCTAssertEqual(re[k], expectedRe, accuracy: 1e-8, "bin \(k) real")
            XCTAssertEqual(im[k], expectedIm, accuracy: 1e-8, "bin \(k) imag")
        }
    }

    func testRoundTrip() {
        let n = 1_024
        let signal = randomSignal(count: n, seed: 2)
        var re = signal
        var im = [Double](repeating: 0, count: n)
        FFT.transform(real: &re, imag: &im)
        FFT.transform(real: &re, imag: &im, inverse: true)
        for i in 0..<n {
            XCTAssertEqual(re[i], signal[i], accuracy: 1e-10)
            XCTAssertEqual(im[i], 0, accuracy: 1e-10)
        }
    }

    func testConvolutionMatchesDirect() {
        let a = randomSignal(count: 37, seed: 3)
        let b = randomSignal(count: 12, seed: 4)
        let fast = FFT.convolve(a, b)
        XCTAssertEqual(fast.count, a.count + b.count - 1)
        for k in 0..<fast.count {
            var direct = 0.0
            for i in 0..<a.count where k - i >= 0 && k - i < b.count {
                direct += a[i] * b[k - i]
            }
            XCTAssertEqual(fast[k], direct, accuracy: 1e-9)
        }
    }

    func testCrossCorrelationFindsTemplate() {
        let template = randomSignal(count: 100, seed: 5)
        var signal = [Double](repeating: 0, count: 1_000)
        let offset = 400
        for (i, v) in template.enumerated() { signal[offset + i] = v }

        let correlation = FFT.crossCorrelate(signal: signal, template: template)
        let peak = correlation.enumerated().max { $0.element < $1.element }!
        XCTAssertEqual(peak.offset, offset)
    }

    func testNextPowerOfTwo() {
        XCTAssertEqual(FFT.nextPowerOfTwo(1), 1)
        XCTAssertEqual(FFT.nextPowerOfTwo(2), 2)
        XCTAssertEqual(FFT.nextPowerOfTwo(3), 4)
        XCTAssertEqual(FFT.nextPowerOfTwo(1_000), 1_024)
    }
}
