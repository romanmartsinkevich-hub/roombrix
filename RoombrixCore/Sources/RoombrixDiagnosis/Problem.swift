import Foundation
import RoombrixGeometry

/// A named, explainable acoustic problem identified by the rule engine.
public struct Problem: Sendable {
    public enum Kind: String, Sendable, Codable {
        case excessiveDecay          // long mid/HF reverberation
        case bassDecayImbalance      // LF rings much longer than mids
        case modalPeaks              // strong isolated modes below Schroeder
        case earlyReflections        // poor C80 / strong discrete reflections
        case flutterEcho             // periodic echo between parallel walls
        case overdamped              // decay below target (rare, but honest)
    }

    /// 0…1, drives ordering and the free tier's "top problem".
    public let severity: Double
    public let kind: Kind
    public let title: String
    /// Plain-language explanation of what is wrong and why it sounds that way.
    public let explanation: String

    public init(kind: Kind, severity: Double, title: String, explanation: String) {
        self.kind = kind
        self.severity = min(1, max(0, severity))
        self.title = title
        self.explanation = explanation
    }
}

/// A concrete, physically honest treatment prescription.
public struct Recommendation: Sendable {
    public let problem: Problem.Kind
    public let treatment: TreatmentType?
    /// Surface area to install, m² (nil for positional/zero-cost advice).
    public let areaSquareMeters: Double?
    /// Where to put it (surfaces and/or coordinates from the image-source calc).
    public let placement: Placement
    /// Predicted Room Score impact, points (a range — never a promise).
    public let predictedScoreImpact: ClosedRange<Double>
    public let costTier: CostTier
    public let effortTier: EffortTier
    /// The "why" paragraph. Required on every recommendation (brief §5.4).
    public let rationale: String
    /// Priority within the plan (1 = do first).
    public let priority: Int

    public struct Placement: Sendable {
        public let surfaces: [Surface]
        /// Exact wall coordinates when derived from the image-source model.
        public let points: [Point3D]
        public let description: String

        public init(surfaces: [Surface] = [], points: [Point3D] = [], description: String) {
            self.surfaces = surfaces
            self.points = points
            self.description = description
        }
    }

    public init(
        problem: Problem.Kind,
        treatment: TreatmentType?,
        areaSquareMeters: Double?,
        placement: Placement,
        predictedScoreImpact: ClosedRange<Double>,
        costTier: CostTier,
        effortTier: EffortTier,
        rationale: String,
        priority: Int
    ) {
        self.problem = problem
        self.treatment = treatment
        self.areaSquareMeters = areaSquareMeters
        self.placement = placement
        self.predictedScoreImpact = predictedScoreImpact
        self.costTier = costTier
        self.effortTier = effortTier
        self.rationale = rationale
        self.priority = priority
    }
}

/// The full diagnosis: ordered problems plus an ordered treatment plan.
public struct Diagnosis: Sendable {
    public let problems: [Problem]
    public let recommendations: [Recommendation]
    /// The single most severe problem (the free tier shows only this).
    public var topProblem: Problem? { problems.first }

    public init(problems: [Problem], recommendations: [Recommendation]) {
        self.problems = problems.sorted { $0.severity > $1.severity }
        self.recommendations = recommendations.sorted { $0.priority < $1.priority }
    }
}
