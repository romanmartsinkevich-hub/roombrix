import Foundation
import RoombrixValidation

/// Loads audio for analysis. WAV is parsed natively; anything else
/// (QuickTime .aifc, .m4a/ALAC, .aiff, .caf, .flac, …) is decoded to a
/// temporary 32-bit-float WAV by shelling out to `ffmpeg` (any platform)
/// or `afconvert` (macOS), preserving the native sample rate and channels.
/// Lossless inputs therefore analyze bit-identically to a WAV original.
enum AudioLoader {

    enum LoaderError: Error, CustomStringConvertible {
        case noDecoder(String)
        case decodeFailed(tool: String, message: String)

        var description: String {
            switch self {
            case .noDecoder(let ext):
                return """
                Cannot decode .\(ext) files: neither `ffmpeg` nor `afconvert` was found.
                Install ffmpeg (e.g. `apt-get install ffmpeg` / `brew install ffmpeg`)
                or convert the file to WAV and try again.
                """
            case .decodeFailed(let tool, let message):
                return "Decoding failed (\(tool)): \(message)"
            }
        }
    }

    /// Load any supported audio file as mono-usable PCM samples.
    static func load(url: URL) throws -> WAVFile.Audio {
        if url.pathExtension.lowercased() == "wav" {
            return try WAVFile.read(url: url)
        }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("roombrix-decode-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: temp) }

        if let ffmpeg = findExecutable("ffmpeg") {
            try run(
                tool: ffmpeg,
                arguments: [
                    "-hide_banner", "-loglevel", "error", "-y",
                    "-i", url.path,
                    "-c:a", "pcm_f32le",  // lossless float; rate and channels untouched
                    temp.path,
                ]
            )
        } else if let afconvert = findExecutable("afconvert") {
            try run(
                tool: afconvert,
                arguments: ["-f", "WAVE", "-d", "LEF32", url.path, temp.path]
            )
        } else {
            throw LoaderError.noDecoder(url.pathExtension.lowercased())
        }
        return try WAVFile.read(url: temp)
    }

    // MARK: - Process helpers

    private static func findExecutable(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", name]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let path = String(
            decoding: stdout.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private static func run(tool: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let stderr = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw LoaderError.decodeFailed(tool: tool, message: "\(error)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(
                decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            throw LoaderError.decodeFailed(
                tool: (tool as NSString).lastPathComponent,
                message: message.isEmpty ? "exit code \(process.terminationStatus)" : message
            )
        }
    }
}
