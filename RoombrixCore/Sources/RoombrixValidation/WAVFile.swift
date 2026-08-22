import Foundation

/// Minimal RIFF/WAVE reader-writer for the validation pipeline
/// (mono or first-channel extraction; PCM 16/24/32-bit int and 32/64-bit float).
public enum WAVFile {

    public struct Audio: Sendable {
        public var samples: [Double]
        public var sampleRate: Double
    }

    public enum WAVError: Error, CustomStringConvertible {
        case notRIFF, noFormatChunk, noDataChunk
        case unsupportedFormat(String)

        public var description: String {
            switch self {
            case .notRIFF: return "Not a RIFF/WAVE file"
            case .noFormatChunk: return "Missing fmt chunk"
            case .noDataChunk: return "Missing data chunk"
            case .unsupportedFormat(let detail): return "Unsupported WAV format: \(detail)"
            }
        }
    }

    // MARK: - Reading

    public static func read(url: URL) throws -> Audio {
        try parse(data: Data(contentsOf: url))
    }

    public static func parse(data: Data) throws -> Audio {
        guard data.count > 44,
              data[0..<4].elementsEqual("RIFF".utf8),
              data[8..<12].elementsEqual("WAVE".utf8)
        else { throw WAVError.notRIFF }

        var offset = 12
        var formatTag: Int = 0
        var channels = 0
        var sampleRate = 0
        var bitsPerSample = 0
        var sampleData: Data?

        while offset + 8 <= data.count {
            let chunkID = String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
            let chunkSize = Int(readUInt32(data, offset + 4))
            let body = offset + 8
            switch chunkID {
            case "fmt ":
                guard body + 16 <= data.count else { throw WAVError.noFormatChunk }
                formatTag = Int(readUInt16(data, body))
                channels = Int(readUInt16(data, body + 2))
                sampleRate = Int(readUInt32(data, body + 4))
                bitsPerSample = Int(readUInt16(data, body + 14))
            case "data":
                let end = min(body + chunkSize, data.count)
                sampleData = data.subdata(in: body..<end)
            default:
                break
            }
            offset = body + chunkSize + (chunkSize & 1)
        }

        guard channels > 0, sampleRate > 0 else { throw WAVError.noFormatChunk }
        guard let payload = sampleData else { throw WAVError.noDataChunk }

        let bytesPerSample = bitsPerSample / 8
        let frameSize = bytesPerSample * channels
        guard frameSize > 0 else { throw WAVError.unsupportedFormat("zero frame size") }
        let frameCount = payload.count / frameSize
        var samples = [Double](repeating: 0, count: frameCount)

        // WAVE_FORMAT_EXTENSIBLE (0xFFFE) is treated by bit depth.
        let isFloat = formatTag == 3
            || (formatTag == 0xFFFE && (bitsPerSample == 32 || bitsPerSample == 64) && false)

        for frame in 0..<frameCount {
            let p = frame * frameSize  // first channel only
            switch (isFloat, bitsPerSample) {
            case (true, 32):
                samples[frame] = Double(readFloat32(payload, p))
            case (true, 64):
                samples[frame] = readFloat64(payload, p)
            case (false, 16):
                samples[frame] = Double(readInt16(payload, p)) / 32_768
            case (false, 24):
                samples[frame] = Double(readInt24(payload, p)) / 8_388_608
            case (false, 32):
                samples[frame] = Double(readInt32(payload, p)) / 2_147_483_648
            default:
                throw WAVError.unsupportedFormat("tag \(formatTag), \(bitsPerSample)-bit")
            }
        }
        return Audio(samples: samples, sampleRate: Double(sampleRate))
    }

    // MARK: - Writing (32-bit float mono; used for stimulus export + fixtures)

    public static func writeFloat32Mono(samples: [Double], sampleRate: Double, to url: URL) throws {
        var data = Data()
        let byteRate = UInt32(sampleRate) * 4
        let dataSize = UInt32(samples.count * 4)

        data.append(contentsOf: "RIFF".utf8)
        appendUInt32(&data, 36 + dataSize)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        appendUInt32(&data, 16)
        appendUInt16(&data, 3) // IEEE float
        appendUInt16(&data, 1) // mono
        appendUInt32(&data, UInt32(sampleRate))
        appendUInt32(&data, byteRate)
        appendUInt16(&data, 4) // block align
        appendUInt16(&data, 32) // bits
        data.append(contentsOf: "data".utf8)
        appendUInt32(&data, dataSize)
        for s in samples {
            var v = Float(s).bitPattern.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        try data.write(to: url)
    }

    // MARK: - Byte helpers

    private static func readUInt16(_ d: Data, _ o: Int) -> UInt16 {
        UInt16(d[d.startIndex + o]) | (UInt16(d[d.startIndex + o + 1]) << 8)
    }

    private static func readUInt32(_ d: Data, _ o: Int) -> UInt32 {
        var v: UInt32 = 0
        for i in (0..<4).reversed() { v = (v << 8) | UInt32(d[d.startIndex + o + i]) }
        return v
    }

    private static func readInt16(_ d: Data, _ o: Int) -> Int16 {
        Int16(bitPattern: readUInt16(d, o))
    }

    private static func readInt24(_ d: Data, _ o: Int) -> Int32 {
        let raw = UInt32(d[d.startIndex + o])
            | (UInt32(d[d.startIndex + o + 1]) << 8)
            | (UInt32(d[d.startIndex + o + 2]) << 16)
        // Sign-extend 24 → 32 bits.
        return Int32(bitPattern: raw & 0x800000 != 0 ? raw | 0xFF00_0000 : raw)
    }

    private static func readInt32(_ d: Data, _ o: Int) -> Int32 {
        Int32(bitPattern: readUInt32(d, o))
    }

    private static func readFloat32(_ d: Data, _ o: Int) -> Float {
        Float(bitPattern: readUInt32(d, o))
    }

    private static func readFloat64(_ d: Data, _ o: Int) -> Double {
        var bits: UInt64 = 0
        for i in (0..<8).reversed() { bits = (bits << 8) | UInt64(d[d.startIndex + o + i]) }
        return Double(bitPattern: bits)
    }

    private static func appendUInt16(_ d: inout Data, _ v: UInt16) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { d.append(contentsOf: $0) }
    }

    private static func appendUInt32(_ d: inout Data, _ v: UInt32) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { d.append(contentsOf: $0) }
    }
}
