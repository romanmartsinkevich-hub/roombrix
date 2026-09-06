import Foundation
import SwiftData
import RoombrixScoring

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
    }

    var decodedScore: RoomScore? {
        scoreJSON.flatMap { try? JSONDecoder().decode(RoomScore.self, from: $0) }
    }
}
