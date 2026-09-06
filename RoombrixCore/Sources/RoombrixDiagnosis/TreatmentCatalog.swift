import Foundation
import RoombrixGeometry

/// Generic, vendor-neutral treatment taxonomy. Vendor catalogs (Vicoustic,
/// GIK, Artnovion, own-brand) plug in later as `Product` rows referencing a
/// `TreatmentType` — the recommendation engine only ever reasons about types.
public enum TreatmentType: String, CaseIterable, Sendable, Codable {
    case broadbandAbsorber5cm
    case broadbandAbsorber10cm
    case broadbandAbsorber20cm
    case cornerBassTrap
    case diffuser
    case thickCurtain
    case rug
    case bookshelf

    public var displayName: String {
        switch self {
        case .broadbandAbsorber5cm: return "Broadband absorber (5 cm)"
        case .broadbandAbsorber10cm: return "Broadband absorber (10 cm)"
        case .broadbandAbsorber20cm: return "Broadband absorber (20 cm)"
        case .cornerBassTrap: return "Corner bass trap"
        case .diffuser: return "Diffuser"
        case .thickCurtain: return "Thick curtain"
        case .rug: return "Thick rug"
        case .bookshelf: return "Filled bookshelf"
        }
    }

    /// Random-incidence absorption coefficients at 125/250/500/1k/2k/4k Hz.
    /// Representative published values for the generic class (ISO 354-style
    /// data; cite vendor/ISO sources when a specific SKU is attached).
    public var absorption: Absorption.Coefficients {
        switch self {
        case .broadbandAbsorber5cm:
            return .init(values: [0.15, 0.45, 0.85, 0.95, 0.95, 0.95])
        case .broadbandAbsorber10cm:
            return .init(values: [0.40, 0.85, 1.00, 1.00, 1.00, 1.00])
        case .broadbandAbsorber20cm:
            return .init(values: [0.85, 1.00, 1.00, 1.00, 1.00, 1.00])
        case .cornerBassTrap:
            return .init(values: [0.90, 1.00, 1.00, 0.95, 0.90, 0.85])
        case .diffuser:
            // Diffusers scatter rather than absorb; small residual absorption.
            return .init(values: [0.10, 0.15, 0.20, 0.25, 0.25, 0.25])
        case .thickCurtain:
            return .init(values: [0.10, 0.25, 0.55, 0.75, 0.80, 0.80])
        case .rug:
            return .init(values: [0.05, 0.10, 0.25, 0.40, 0.55, 0.65])
        case .bookshelf:
            return .init(values: [0.30, 0.40, 0.40, 0.35, 0.30, 0.30])
        }
    }

    /// Nominal material depth, meters (drives the honesty rule on LF efficacy).
    public var depth: Double {
        switch self {
        case .broadbandAbsorber5cm: return 0.05
        case .broadbandAbsorber10cm: return 0.10
        case .broadbandAbsorber20cm: return 0.20
        case .cornerBassTrap: return 0.35
        case .diffuser: return 0.15
        case .thickCurtain: return 0.05
        case .rug: return 0.02
        case .bookshelf: return 0.30
        }
    }

    public var costTier: CostTier {
        switch self {
        case .rug, .bookshelf: return .low
        case .thickCurtain, .broadbandAbsorber5cm: return .low
        case .broadbandAbsorber10cm, .diffuser: return .medium
        case .broadbandAbsorber20cm, .cornerBassTrap: return .high
        }
    }

    public var effortTier: EffortTier {
        switch self {
        case .rug, .thickCurtain, .bookshelf: return .low
        case .broadbandAbsorber5cm, .broadbandAbsorber10cm, .diffuser: return .medium
        case .broadbandAbsorber20cm, .cornerBassTrap: return .high
        }
    }
}

public enum CostTier: String, Sendable, Codable { case free, low, medium, high }
public enum EffortTier: String, Sendable, Codable { case low, medium, high }

/// Vendor product record — the data layer added in Phase 2. Fields for the
/// commission model exist now so the schema never has to change.
public struct Product: Sendable, Codable {
    public var id: String
    public var treatmentType: TreatmentType
    public var name: String
    public var vendor: String
    /// Overrides the generic class coefficients when the vendor publishes
    /// ISO 354 data for the SKU.
    public var absorption: Absorption.Coefficients?
    public var affiliateURL: String?
    /// Commission fraction (0…1) for the affiliate layer.
    public var commission: Double?

    public init(
        id: String,
        treatmentType: TreatmentType,
        name: String,
        vendor: String,
        absorption: Absorption.Coefficients? = nil,
        affiliateURL: String? = nil,
        commission: Double? = nil
    ) {
        self.id = id
        self.treatmentType = treatmentType
        self.name = name
        self.vendor = vendor
        self.absorption = absorption
        self.affiliateURL = affiliateURL
        self.commission = commission
    }
}
