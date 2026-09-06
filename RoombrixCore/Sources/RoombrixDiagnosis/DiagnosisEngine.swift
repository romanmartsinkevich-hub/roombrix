import Foundation
import RoombrixAcoustics
import RoombrixGeometry
import RoombrixScoring

/// Rule-based diagnosis v1: deterministic, explainable, no ML.
/// Maps measured metric patterns to named problems and physically honest
/// treatment prescriptions.
public enum DiagnosisEngine {

    /// Bump alongside rule changes; stored with every generated plan.
    public static let version = "1.0.0"

    public struct Input: Sendable {
        public var report: AcousticReport
        public var geometry: RoomGeometry?
        public var purpose: RoomPurpose
        /// User-dropped markers on the floor plan (meters, room coordinates).
        public var speakerPositions: [Point3D]
        public var listenerPosition: Point3D?

        public init(
            report: AcousticReport,
            geometry: RoomGeometry? = nil,
            purpose: RoomPurpose = .listening,
            speakerPositions: [Point3D] = [],
            listenerPosition: Point3D? = nil
        ) {
            self.report = report
            self.geometry = geometry
            self.purpose = purpose
            self.speakerPositions = speakerPositions
            self.listenerPosition = listenerPosition
        }
    }

    public static func diagnose(_ input: Input) -> Diagnosis {
        var problems: [Problem] = []
        var recommendations: [Recommendation] = []
        var priority = 1

        // Rule 1: long mid/HF decay → absorption deficit.
        if let finding = excessiveDecayRule(input, priority: &priority) {
            problems.append(finding.problem)
            recommendations.append(contentsOf: finding.recommendations)
        }

        // Rule 2: LF decay ≫ mid + modal peaks → bass problem (honest output).
        if let finding = bassRule(input, priority: &priority) {
            problems.append(finding.problem)
            recommendations.append(contentsOf: finding.recommendations)
        }

        // Rule 3: poor C80 / strong early reflections → first-reflection points.
        if let finding = earlyReflectionRule(input, priority: &priority) {
            problems.append(finding.problem)
            recommendations.append(contentsOf: finding.recommendations)
        }

        // Rule 4: flutter echo → treat one of the parallel surfaces.
        if let finding = flutterRule(input, priority: &priority) {
            problems.append(finding.problem)
            recommendations.append(contentsOf: finding.recommendations)
        }

        return Diagnosis(problems: problems, recommendations: recommendations)
    }

    private typealias Finding = (problem: Problem, recommendations: [Recommendation])

    // MARK: - Rule 1: excessive mid/HF decay

    private static func excessiveDecayRule(_ input: Input, priority: inout Int) -> Finding? {
        guard let mid = input.report.midBandRT60 else { return nil }
        let volume = input.geometry?.volume ?? 50
        let target = input.purpose.rt60Target(volume: volume)

        if mid < target.lowerBound * 0.8 {
            let problem = Problem(
                kind: .overdamped,
                severity: 0.3,
                title: "Room is overdamped",
                explanation: String(
                    format: "Sound decays in %.2f s, below the ideal %.2f–%.2f s. The room may sound dry and lifeless; consider adding diffusion instead of more absorption.",
                    mid, target.lowerBound, target.upperBound
                )
            )
            let rec = Recommendation(
                problem: .overdamped,
                treatment: .diffuser,
                areaSquareMeters: nil,
                placement: .init(description: "Replace some absorption with diffusion on the back wall to restore liveliness."),
                predictedScoreImpact: 2...5,
                costTier: .medium,
                effortTier: .medium,
                rationale: "Your decay time is already below target. Adding more absorption would make it worse; diffusion preserves energy while breaking up remaining discrete reflections.",
                priority: priority
            )
            priority += 1
            return (problem, [rec])
        }

        guard mid > target.upperBound else { return nil }

        let excess = (mid - target.upperBound) / target.upperBound
        let severity = min(1, 0.4 + excess)
        let problem = Problem(
            kind: .excessiveDecay,
            severity: severity,
            title: "Too much reverberation",
            explanation: String(
                format: "Sound takes %.2f s to die away — the ideal for this room is %.2f–%.2f s. Music smears together and speech loses definition.",
                mid, target.lowerBound, target.upperBound
            )
        )

        // Absorption budget: added sabins to reach the target midpoint.
        let targetRT = (target.lowerBound + target.upperBound) / 2
        let sabins = Absorption.requiredAddedSabins(
            volume: volume, measuredRT60: mid, targetRT60: targetRT
        )
        let treatment = TreatmentType.broadbandAbsorber10cm
        let coefficient = treatment.absorption.value(at: 1_000)
        let area = Absorption.requiredArea(sabins: sabins, coefficient: coefficient) ?? sabins

        let rec = Recommendation(
            problem: .excessiveDecay,
            treatment: treatment,
            areaSquareMeters: (area * 10).rounded() / 10,
            placement: .init(
                surfaces: [.wallLeft, .wallRight, .wallBack, .ceiling],
                description: "Distribute panels across side walls, back wall, and ceiling; prioritize large bare surfaces facing each other."
            ),
            predictedScoreImpact: predictedImpact(severity: severity, weight: SubscoreKind.decay.weight),
            costTier: treatment.costTier,
            effortTier: treatment.effortTier,
            rationale: String(
                format: "Bringing decay from %.2f s to about %.2f s needs roughly %.0f m² of added absorption (≈%.0f sabins at mid frequencies). 10 cm broadband panels absorb efficiently from 250 Hz up. Soft furnishings (rug, curtains, filled bookshelf) count toward this total.",
                mid, targetRT, area, sabins
            ),
            priority: priority
        )
        priority += 1
        return (problem, [rec])
    }

    // MARK: - Rule 2: bass decay imbalance / modal peaks

    private static func bassRule(_ input: Input, priority: inout Int) -> Finding? {
        let ratio = input.report.lowToMidDecayRatio
        let peaks = input.report.lowFrequencyPeaks
        let ratioBad = (ratio ?? 1) > input.purpose.maxDecayRatio
        let peaksBad = !peaks.isEmpty
        guard ratioBad || peaksBad else { return nil }

        // Confirm against geometry when available.
        var modeMatchText = ""
        if let geometry = input.geometry, geometry.modalPredictionIsReliable, peaksBad {
            let predicted = RoomModes.predict(for: geometry, maxFrequency: 300)
            let matches = RoomModes.matchPeaks(
                predicted: predicted,
                measuredPeakFrequencies: peaks.map { $0.frequency }
            )
            if let first = matches.first {
                modeMatchText = String(
                    format: " The %.0f Hz peak matches a standing wave along your room's %@.",
                    first.measuredFrequency,
                    first.mode.drivingAxes.joined(separator: " and ")
                )
            }
        }

        let severity = min(1, (ratioBad ? 0.5 : 0.3) + Double(peaks.count) * 0.1)
        var explanation: String
        if let ratio, ratioBad {
            explanation = String(
                format: "Bass hangs on about %.1f× longer than the midrange, so low notes sound slow and boomy.",
                ratio
            )
        } else {
            explanation = "Strong isolated bass peaks were measured at your listening position."
        }
        explanation += modeMatchText

        let problem = Problem(
            kind: .bassDecayImbalance,
            severity: severity,
            title: "Bass problems below ~250 Hz",
            explanation: explanation
        )

        var recs: [Recommendation] = []

        // Zero-cost positional fix always comes first.
        recs.append(Recommendation(
            problem: .bassDecayImbalance,
            treatment: nil,
            areaSquareMeters: nil,
            placement: .init(description: "Try moving your speakers and seat before buying anything: shift the seat off exact room-fraction positions (1/2, 1/4 of the length) and pull speakers away from corners in 10 cm steps, re-measuring each time."),
            predictedScoreImpact: 1...6,
            costTier: .free,
            effortTier: .low,
            rationale: "Modal peaks and nulls are position-dependent. Moving the listening position or speakers along the worst mode's axis is free and often worth several dB before any treatment is installed.",
            priority: priority
        ))
        priority += 1

        // Physical treatment: honesty rule — only prescribe treatments with
        // real low-frequency depth. Thin panels are never offered here.
        let trap = TreatmentType.cornerBassTrap
        recs.append(Recommendation(
            problem: .bassDecayImbalance,
            treatment: trap,
            areaSquareMeters: nil,
            placement: .init(
                description: "Floor-to-ceiling bass traps in the front two corners first; add the rear corners if the re-measurement still shows long bass decay."
            ),
            predictedScoreImpact: predictedImpact(
                severity: severity,
                weight: SubscoreKind.decayUniformity.weight + SubscoreKind.modalSeverity.weight
            ),
            costTier: trap.costTier,
            effortTier: trap.effortTier,
            rationale: honestBassRationale(),
            priority: priority
        ))
        priority += 1

        return (problem, recs)
    }

    /// The honesty paragraph shown with every bass recommendation.
    /// Physics constraint enforced in copy and in code: no thin-panel
    /// prescriptions for problems below 250 Hz.
    static func honestBassRationale() -> String {
        let panel5 = Absorption.lowestEffectiveFrequency(absorberDepth: 0.05)
        let panel20 = Absorption.lowestEffectiveFrequency(absorberDepth: 0.20)
        return String(
            format: "Honest physics: a porous absorber only works down to roughly the frequency whose quarter-wavelength matches its depth — a 5 cm panel is effective to about %.0f Hz, a 20 cm panel to about %.0f Hz. Thin decorative panels will NOT fix bass problems. Corner traps work because pressure concentrates in corners, letting deep absorbers act on long wavelengths. Room-correction DSP (Dirac, PEQ) can complement this by taming remaining peaks at the listening position, but it cannot shorten the room's bass decay.",
            panel5, panel20
        )
    }

    /// Treatments allowed for sub-250 Hz problems. Guards against any future
    /// rule accidentally prescribing thin panels for bass.
    public static func isValidBassTreatment(_ treatment: TreatmentType) -> Bool {
        treatment.depth >= 0.20
    }

    // MARK: - Rule 3: early reflections / clarity

    private static func earlyReflectionRule(_ input: Input, priority: inout Int) -> Finding? {
        guard let c80 = input.report.c80, c80 < input.purpose.minC80 else { return nil }

        let deficit = input.purpose.minC80 - c80
        let severity = min(1, 0.3 + deficit / 10)
        let problem = Problem(
            kind: .earlyReflections,
            severity: severity,
            title: "Strong early reflections",
            explanation: String(
                format: "Reflected sound arrives almost as loud as the direct sound (C80 = %.1f dB, target ≥ %.0f dB). Stereo imaging blurs and the room sounds confused.",
                c80, input.purpose.minC80
            )
        )

        // Exact reflection points when the user has placed markers.
        var points: [Point3D] = []
        var surfaces: [Surface] = []
        var placementText = "Treat the first-reflection points on the side walls and ceiling. Use the mirror trick: a helper slides a mirror along the wall; wherever you can see a speaker from the seat, that's a treatment point."
        if let geometry = input.geometry, let listener = input.listenerPosition,
           !input.speakerPositions.isEmpty {
            for speaker in input.speakerPositions {
                for reflection in ImageSource.criticalReflections(
                    speaker: speaker, listener: listener, room: geometry
                ) where reflection.surface != .floor {
                    points.append(reflection.point)
                    if !surfaces.contains(reflection.surface) {
                        surfaces.append(reflection.surface)
                    }
                }
            }
            if !points.isEmpty {
                placementText = "Treatment points are marked on your floor plan at the exact first-reflection positions computed from your speaker and seat markers."
            }
        }

        // Absorb in small rooms; diffuse in larger ones where diffusion has
        // room to develop (rule of thumb: listener ≥ ~3 m from the surface).
        let roomIsLarge = (input.geometry?.volume ?? 0) > 80
        let treatment: TreatmentType = roomIsLarge ? .diffuser : .broadbandAbsorber5cm
        let areaPerPoint = 1.0
        let rec = Recommendation(
            problem: .earlyReflections,
            treatment: treatment,
            areaSquareMeters: Double(max(points.count, 4)) * areaPerPoint,
            placement: .init(surfaces: surfaces, points: points, description: placementText),
            predictedScoreImpact: predictedImpact(severity: severity, weight: SubscoreKind.clarity.weight),
            costTier: treatment.costTier,
            effortTier: treatment.effortTier,
            rationale: roomIsLarge
                ? "In your room size, diffusion at the reflection points preserves spaciousness while removing the discrete echo that smears imaging. Reflections in this band are a mid/high-frequency problem, so panel depth is not critical here."
                : "Absorbing the first sidewall/ceiling reflections removes the strongest competing sound arrivals within 20 ms of the direct sound — the main cause of blurred imaging. This is a mid/high-frequency fix; 5 cm panels are sufficient at these frequencies (not for bass).",
            priority: priority
        )
        priority += 1
        return (problem, [rec])
    }

    // MARK: - Rule 4: flutter echo

    private static func flutterRule(_ input: Input, priority: inout Int) -> Finding? {
        guard let flutter = input.report.flutterEcho else { return nil }

        // Identify the wall pair whose spacing matches the detected period.
        var wallPairText = "a pair of parallel reflective surfaces"
        var surfaces: [Surface] = []
        if let geometry = input.geometry {
            let candidates: [(Surface, Double)] = [
                (.wallFront, geometry.length),
                (.wallLeft, geometry.width),
                (.floor, geometry.height),
            ]
            if let match = candidates.min(by: {
                abs($0.1 - flutter.surfaceSpacing) < abs($1.1 - flutter.surfaceSpacing)
            }), abs(match.1 - flutter.surfaceSpacing) < 0.6 {
                surfaces = [match.0, match.0.opposite]
                switch match.0 {
                case .wallFront: wallPairText = "the front and back walls"
                case .wallLeft: wallPairText = "the left and right walls"
                case .floor: wallPairText = "the floor and ceiling"
                default: break
                }
            }
        }

        let severity = min(1, 0.3 + flutter.strength)
        let problem = Problem(
            kind: .flutterEcho,
            severity: severity,
            title: "Flutter echo",
            explanation: String(
                format: "A rapid repeating echo bounces between %@ (about %.1f m apart). Clap your hands and you'll hear a metallic ringing.",
                wallPairText, flutter.surfaceSpacing
            )
        )
        let treatment = TreatmentType.broadbandAbsorber5cm
        let rec = Recommendation(
            problem: .flutterEcho,
            treatment: treatment,
            areaSquareMeters: 2,
            placement: .init(
                surfaces: surfaces,
                description: "Treat ONE side of the identified wall pair — absorption or diffusion on a single surface breaks the ping-pong path. Covering roughly 2 m² at ear/speaker height is usually enough."
            ),
            predictedScoreImpact: predictedImpact(severity: severity, weight: SubscoreKind.clarity.weight / 2),
            costTier: treatment.costTier,
            effortTier: .low,
            rationale: "Flutter needs two bare parallel surfaces; removing the reflectivity of either one kills the echo. A bookshelf, wall hanging, or a few panels on one wall is sufficient — you do not need to treat both sides.",
            priority: priority
        )
        priority += 1
        return (problem, [rec])
    }

    // MARK: - Impact model

    /// Predicted Room Score impact: fraction of the affected subscore weight
    /// recoverable, expressed as a conservative range (never a promise).
    private static func predictedImpact(severity: Double, weight: Double) -> ClosedRange<Double> {
        let ceiling = 100 * weight * severity
        let low = (ceiling * 0.3).rounded()
        let high = max(low + 1, (ceiling * 0.8).rounded())
        return low...high
    }
}
