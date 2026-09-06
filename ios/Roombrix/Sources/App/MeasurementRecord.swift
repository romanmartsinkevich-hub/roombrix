import Foundation
import SwiftData
import RoombrixScoring
import RoombrixAcoustics

/// Per-band decay summary persisted with each measurement — the data the
/// before/after comparison is built from.
struct BandSummary: Codable, Identifiable {
    var id: Double { centerFrequency }
    let centerFrequency: Double
    /// nil = band was honestly unmeasurable in this capture.
    let rt60: Double?
    /// Metric label (t30/t20/topt/unmeasurable) for the report.
    let metric: String

    init(from decay: ReverbTime.BandDecay) {
        self.centerFrequency = decay.centerFrequency
        self.rt60 = ReverbTime.bestEstimate(decay)
        self.metric = decay.selectedMetric.rawValue
    }
}

/// Persisted measurement: derived metrics and the score only — raw audio is
/// never stored beyond the exported capture WAV in Documents (privacy
/// invariant: audio is processed on-device and discarded).
@Model
final class MeasurementRecord {
    var date: Date
    var scoreValue: Double
    var scoreLow: Double
    var scoreHigh: Double
    var scoreEngineVersion: String
    /// Full RoomScore (subscores + explanations), JSON-encoded.
    var scoreJSON: Data?
    var midBandRT60: Double?
    var lowToMidDecayRatio: Double?
    var c80: Double?
    var topProblemText: String?
    var qualityAdvice: [String]
    var reportText: String
    var recordingFileName: String?
    /// Per-band RT60 summaries, JSON-encoded ([BandSummary]).
    var bandsJSON: Data?
    /// The "before" reference for before/after comparison. At most one
    /// record should carry this at a time (enforced in the UI).
    var isBaseline: Bool = false

    init(from result: MeasurementResult) {
        self.date = result.date
        self.scoreValue = result.score.value
        self.scoreLow = result.score.range.lowerBound
        self.scoreHigh = result.score.range.upperBound
        self.scoreEngineVersion = result.score.engineVersion
        self.scoreJSON = try? JSONEncoder().encode(result.score)
        self.midBandRT60 = result.report.midBandRT60
        self.lowToMidDecayRatio = result.report.lowToMidDecayRatio
        self.c80 = result.report.c80
        self.topProblemText = result.topProblemText
        self.qualityAdvice = result.qualityAdvice
        self.reportText = result.reportText
        self.recordingFileName = result.recordingURL?.lastPathComponent
        let bands = result.report.bandDecays.map { BandSummary(from: $0) }
        self.bandsJSON = try? JSONEncoder().encode(bands)
        self.isBaseline = false
    }

    var decodedScore: RoomScore? {
        scoreJSON.flatMap { try? JSONDecoder().decode(RoomScore.self, from: $0) }
    }

    var decodedBands: [BandSummary] {
        bandsJSON.flatMap { try? JSONDecoder().decode([BandSummary].self, from: $0) } ?? []
    }
}
