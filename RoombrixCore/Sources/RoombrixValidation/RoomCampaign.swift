import Foundation
import RoombrixAcoustics

/// Multi-room validation campaign harness. A new room is added with ZERO
/// code changes: create `validation/rooms/<room-name>/` containing
/// - one or more capture WAVs (consecutive takes of the same position), and
/// - the reference: either a REW RT60 text export whose name contains
///   "rt60", or `reference.json` mapping band centers to RT60 seconds,
///   e.g. `{"250": 1.041, "500": 0.763, "1000": 0.685}`.
/// Optional `notes.md` for session context.
///
/// Acceptance per room (the Milestone 1 format):
/// - every capture within ±15 % of the reference across 250 Hz–4 kHz,
/// - consecutive captures pairwise within 3 % per band,
/// - identical fit windows per band across captures.
public enum RoomCampaign {

    public static let criteriaBands: [Double] = [250, 500, 1_000, 2_000, 4_000]
    public static let accuracyTolerance = 0.15
    public static let repeatabilityTolerance = 0.03

    public struct BandRow {
        public let band: Double
        /// RT60 per capture (nil = unmeasurable).
        public let values: [Double?]
        public let referenceRT60: Double?
        /// Worst |error| vs reference across captures, fraction.
        public let worstError: Double?
        /// Worst pairwise spread across captures, fraction.
        public let worstSpread: Double?
        public let windowsMatch: Bool
    }

    public struct RoomResult {
        public let name: String
        public let captureNames: [String]
        public let rows: [BandRow]
        public let passedAccuracy: Bool
        public let passedRepeatability: Bool
        public var passed: Bool { passedAccuracy && passedRepeatability }

        public var summaryText: String {
            var lines: [String] = []
            lines.append("=== \(name) (\(captureNames.count) captures) ===")
            lines.append("Band (Hz) | " + captureNames.map { _ in "RT60   " }.joined(separator: " | ")
                + " | Reference | Worst err | Spread | Windows")
            for row in rows {
                let values = row.values
                    .map { $0.map { String(format: "%.3f s", $0) } ?? "  —    " }
                    .joined(separator: " | ")
                let ref = row.referenceRT60.map { String(format: "%.3f s", $0) } ?? "   —   "
                let err = row.worstError.map { String(format: "%+.1f %%", $0 * 100) } ?? "  —  "
                let spread = row.worstSpread.map { String(format: "%.1f %%", $0 * 100) } ?? " —  "
                lines.append(String(
                    format: "%9.0f | %@ | %@ | %@ | %@ | %@",
                    row.band, values, ref, err, spread, row.windowsMatch ? "match" : "DIFFER"
                ))
            }
            lines.append("Accuracy (±\(Int(accuracyTolerance * 100)) % vs reference): \(passedAccuracy ? "PASS" : "FAIL")")
            lines.append("Repeatability (≤\(Int(repeatabilityTolerance * 100)) % pairwise): \(passedRepeatability ? "PASS" : "FAIL")")
            return lines.joined(separator: "\n")
        }
    }

    public enum CampaignError: Error, CustomStringConvertible {
        case noCaptures(String)
        case noReference(String)

        public var description: String {
            switch self {
            case .noCaptures(let room): return "room \(room) contains no capture WAVs"
            case .noReference(let room): return "room \(room) has neither a REW RT60 export (*rt60*.txt) nor reference.json"
            }
        }
    }

    /// Room folders under `roomsURL`, sorted by name.
    public static func discoverRooms(in roomsURL: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: roomsURL, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Reference RT60 per band center: reference.json takes precedence,
    /// else the first REW RT60 text export in the folder.
    public static func loadReference(roomURL: URL) throws -> [Double: Double] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: roomURL, includingPropertiesForKeys: nil
        )) ?? []

        if let json = files.first(where: { $0.lastPathComponent == "reference.json" }) {
            let data = try Data(contentsOf: json)
            let raw = try JSONDecoder().decode([String: Double].self, from: data)
            var reference: [Double: Double] = [:]
            for (key, value) in raw {
                if let band = Double(key) { reference[band] = value }
            }
            return reference
        }

        if let rew = files.first(where: {
            $0.pathExtension.lowercased() == "txt"
                && $0.lastPathComponent.lowercased().contains("rt60")
        }) {
            let text = try String(contentsOf: rew, encoding: .utf8)
            let rows = try REWImport.parseRT60(text: text)
            var reference: [Double: Double] = [:]
            for band in criteriaBands {
                // Exact band-center match (REW third-octave tables include
                // the octave centers).
                if let row = rows.first(where: { abs($0.bandCenter - band) < 0.5 }),
                   let rt = row.t30 ?? row.t20 {
                    reference[band] = rt
                }
            }
            return reference
        }
        throw CampaignError.noReference(roomURL.lastPathComponent)
    }

    /// Analyze every capture in a room folder and evaluate acceptance.
    public static func analyze(roomURL: URL) throws -> RoomResult {
        let name = roomURL.lastPathComponent
        let captures = ((try? FileManager.default.contentsOfDirectory(
            at: roomURL, includingPropertiesForKeys: nil
        )) ?? [])
            .filter { $0.pathExtension.lowercased() == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !captures.isEmpty else { throw CampaignError.noCaptures(name) }

        let reference = try loadReference(roomURL: roomURL)
        let outputs = try captures.map { try CapturePipeline.analyze(url: $0) }

        var rows: [BandRow] = []
        var accuracyOK = true
        var repeatabilityOK = true

        for band in criteriaBands {
            let decays = outputs.map { output in
                output.decays.first { $0.centerFrequency == band }
            }
            let values = decays.map { $0.flatMap { ReverbTime.bestEstimate($0) } }
            let ref = reference[band]

            var worstError: Double?
            if let ref, ref > 0 {
                let errors = values.compactMap { $0.map { ($0 - ref) / ref } }
                if errors.count == values.count, !errors.isEmpty {
                    worstError = errors.max { abs($0) < abs($1) }
                    if abs(worstError!) > accuracyTolerance { accuracyOK = false }
                } else {
                    accuracyOK = false // unmeasurable criteria band
                }
            }

            var worstSpread: Double?
            let measured = values.compactMap { $0 }
            if measured.count >= 2 {
                var spread = 0.0
                for i in 0..<measured.count {
                    for j in (i + 1)..<measured.count {
                        spread = max(spread, abs(measured[i] - measured[j]) / min(measured[i], measured[j]))
                    }
                }
                worstSpread = spread
                if spread > repeatabilityTolerance { repeatabilityOK = false }
            }

            let windows = decays.map { $0.map { ($0.windowStartDB, $0.windowEndDB) } }
            let windowsMatch = Set(windows.map { "\($0?.0 ?? .nan):\($0?.1 ?? .nan)" }).count == 1
            if !windowsMatch { repeatabilityOK = false }

            rows.append(BandRow(
                band: band,
                values: values,
                referenceRT60: ref,
                worstError: worstError,
                worstSpread: worstSpread,
                windowsMatch: windowsMatch
            ))
        }

        return RoomResult(
            name: name,
            captureNames: captures.map { $0.lastPathComponent },
            rows: rows,
            passedAccuracy: accuracyOK,
            passedRepeatability: repeatabilityOK
        )
    }
}
