// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "RoombrixCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "RoombrixDSP", targets: ["RoombrixDSP"]),
        .library(name: "RoombrixAcoustics", targets: ["RoombrixAcoustics"]),
        .library(name: "RoombrixGeometry", targets: ["RoombrixGeometry"]),
        .library(name: "RoombrixScoring", targets: ["RoombrixScoring"]),
        .library(name: "RoombrixDiagnosis", targets: ["RoombrixDiagnosis"]),
        .library(name: "RoombrixValidation", targets: ["RoombrixValidation"]),
        .executable(name: "roombrix-validate", targets: ["roombrix-validate"]),
    ],
    targets: [
        // Layer 0: pure signal processing. No acoustics knowledge.
        .target(name: "RoombrixDSP"),

        // Layer 1: impulse-response analysis (RT60, clarity, flutter, FR).
        .target(name: "RoombrixAcoustics", dependencies: ["RoombrixDSP"]),

        // Layer 1: room geometry (modes, Sabine, image-source). No DSP dependency.
        .target(name: "RoombrixGeometry"),

        // Layer 2: versioned Room Score from acoustic + geometric analysis.
        .target(name: "RoombrixScoring", dependencies: ["RoombrixAcoustics", "RoombrixGeometry"]),

        // Layer 3: rule-based problems -> treatment recommendations.
        .target(name: "RoombrixDiagnosis", dependencies: ["RoombrixScoring"]),

        // Validation harness: REW import, WAV I/O, engine-vs-reference diffing.
        .target(name: "RoombrixValidation", dependencies: ["RoombrixAcoustics"]),
        .executableTarget(
            name: "roombrix-validate",
            dependencies: ["RoombrixValidation", "RoombrixAcoustics", "RoombrixDSP"]
        ),

        .testTarget(name: "RoombrixDSPTests", dependencies: ["RoombrixDSP"]),
        .testTarget(name: "RoombrixAcousticsTests", dependencies: ["RoombrixAcoustics", "RoombrixDSP"]),
        .testTarget(name: "RoombrixGeometryTests", dependencies: ["RoombrixGeometry"]),
        .testTarget(name: "RoombrixScoringTests", dependencies: ["RoombrixScoring"]),
        .testTarget(name: "RoombrixDiagnosisTests", dependencies: ["RoombrixDiagnosis"]),
        .testTarget(name: "RoombrixValidationTests", dependencies: ["RoombrixValidation"]),
    ]
)
