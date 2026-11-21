//
//  HealthModels.swift
//  Disk Health
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import Foundation

/// Severity of an individual finding.
public enum Severity: Int, Codable, Sendable, Comparable, Hashable {
    case good = 0
    case info
    case watch
    case warning
    case critical
    case failed

    public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .good: return String(localized: "OK", comment: "Finding severity")
        case .info: return String(localized: "Info", comment: "Finding severity")
        case .watch: return String(localized: "Watch", comment: "Finding severity")
        case .warning: return String(localized: "Warning", comment: "Finding severity")
        case .critical: return String(localized: "Pre-Fail", comment: "Finding severity / drive status")
        case .failed: return String(localized: "Failed", comment: "Finding severity / drive status")
        }
    }
}

/// Overall drive state. Deliberately more than a binary OK / Failed.
public enum HealthStatus: Int, Codable, Sendable, Hashable {
    case excellent = 0
    case good
    case watch
    case degraded
    case failing
    case failed
    case unknown

    /// Ordering by how bad the state is (unknown sorts between good and watch).
    public var badness: Int {
        switch self {
        case .excellent: return 0
        case .good: return 1
        case .unknown: return 2
        case .watch: return 3
        case .degraded: return 4
        case .failing: return 5
        case .failed: return 6
        }
    }

    public func worse(_ other: HealthStatus) -> HealthStatus { other.badness > badness ? other : self }

    public var title: String {
        switch self {
        case .excellent: return String(localized: "Excellent", comment: "Drive status")
        case .good: return String(localized: "Good", comment: "Drive status")
        case .watch: return String(localized: "Needs Attention", comment: "Drive status")
        case .degraded: return String(localized: "Degraded", comment: "Drive status")
        case .failing: return String(localized: "Pre-Fail", comment: "Finding severity / drive status")
        case .failed: return String(localized: "Failed", comment: "Finding severity / drive status")
        case .unknown: return String(localized: "Unknown", comment: "Drive status")
        }
    }

    public var symbolName: String {
        switch self {
        case .excellent: return "checkmark.seal.fill"
        case .good: return "checkmark.circle.fill"
        case .watch: return "eye.circle.fill"
        case .degraded: return "exclamationmark.triangle.fill"
        case .failing: return "exclamationmark.octagon.fill"
        case .failed: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }
}

public enum Confidence: Int, Codable, Sendable, Comparable, Hashable {
    case none = 0, low, medium, high
    public static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .none: return String(localized: "No data")
        case .low: return String(localized: "Low confidence")
        case .medium: return String(localized: "Medium confidence")
        case .high: return String(localized: "High confidence")
        }
    }
}

public enum FindingCategory: String, Codable, Sendable, Hashable {
    case wear = "Wear"
    case media = "Media"
    case reliability = "Reliability"
    case errors = "Errors"
    case temperature = "Temperature"
    case interface = "Interface"
    case age = "Age"
    case power = "Power"
    case trend = "Trend"
    case test = "Self-Test"
    case data = "Data Source"

    /// Localized name for display (the raw value is a stable identifier).
    public var displayName: String {
        switch self {
        case .wear: return String(localized: "Wear", comment: "Finding category")
        case .media: return String(localized: "Media", comment: "Finding category")
        case .reliability: return String(localized: "Reliability", comment: "Finding category")
        case .errors: return String(localized: "Errors", comment: "Finding category")
        case .temperature: return String(localized: "Temperature", comment: "Finding category")
        case .interface: return String(localized: "Interface", comment: "Finding category")
        case .age: return String(localized: "Age", comment: "Finding category")
        case .power: return String(localized: "Power", comment: "Finding category")
        case .trend: return String(localized: "Trend", comment: "Finding category")
        case .test: return String(localized: "Self-Test", comment: "Finding category")
        case .data: return String(localized: "Data Source", comment: "Finding category")
        }
    }
}

public struct Finding: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var severity: Severity
    public var category: FindingCategory
    public var title: String
    public var detail: String
    public var recommendation: String?
    /// Upper bound this finding places on the health percentage.
    public var healthCap: Int?

    public init(id: String, severity: Severity, category: FindingCategory, title: String,
                detail: String, recommendation: String? = nil, healthCap: Int? = nil) {
        self.id = id
        self.severity = severity
        self.category = category
        self.title = title
        self.detail = detail
        self.recommendation = recommendation
        self.healthCap = healthCap
    }
}

public struct LifeEstimate: Codable, Sendable, Hashable {
    public var remainingDays: Double?
    public var label: String
    public var confidence: Confidence
    public var method: String
    /// Remaining rated endurance from the drive's own wear indicator (SSD).
    public var lifeRemainingPercent: Double?
    public var projectedEnduranceBytes: Double?
    public var remainingEnduranceBytes: Double?
    public var dutyHoursPerDay: Double?
    public var dutyCycleObserved: Bool

    public init(remainingDays: Double?, label: String, confidence: Confidence, method: String,
                lifeRemainingPercent: Double? = nil, projectedEnduranceBytes: Double? = nil,
                remainingEnduranceBytes: Double? = nil, dutyHoursPerDay: Double? = nil, dutyCycleObserved: Bool = false) {
        self.remainingDays = remainingDays
        self.label = label
        self.confidence = confidence
        self.method = method
        self.lifeRemainingPercent = lifeRemainingPercent
        self.projectedEnduranceBytes = projectedEnduranceBytes
        self.remainingEnduranceBytes = remainingEnduranceBytes
        self.dutyHoursPerDay = dutyHoursPerDay
        self.dutyCycleObserved = dutyCycleObserved
    }

    /// Approximate remaining time for display ("≈ 3 years", "10+ years").
    public static func label(forDays days: Double) -> String {
        if days < 1 { return String(localized: "< 1 day") }
        if days >= 3650 { return String(localized: "10+ years") }
        return String(localized: "≈ \(duration(days: days))", comment: "Approximate duration, e.g. ≈ 3 years")
    }

    /// Plain duration without the approximation sign ("3 years", "8 months", "1.5 years").
    public static func duration(days: Double) -> String {
        switch days {
        case ..<1: return String(localized: "less than a day")
        case ..<45: return String(localized: "\(Int(days.rounded())) days")
        case ..<365: return String(localized: "\(Int((days / 30.4).rounded())) months")
        default:
            let years = days / 365.25
            if years < 2 { return String(localized: "\(years.fixed(1)) years", comment: "Fractional years, e.g. 1.5 years") }
            return String(localized: "\(Int(years.rounded())) years")
        }
    }
}

public struct TemperatureAssessment: Codable, Sendable, Hashable {
    public var currentC: Double
    public var warningC: Double
    public var criticalC: Double
    public var lifetimeMinC: Double?
    public var lifetimeMaxC: Double?
}

public struct HealthReport: Codable, Sendable, Hashable {
    public var status: HealthStatus
    public var healthPercent: Int?
    public var confidence: Confidence
    public var headline: String
    public var summary: String
    public var findings: [Finding]
    public var life: LifeEstimate
    public var temperature: TemperatureAssessment?
    public var dataSources: [String]
    public var generatedAt: Date

    public var worstSeverity: Severity { findings.map(\.severity).max() ?? .good }
    public var problemCount: Int { findings.filter { $0.severity >= .watch }.count }
}
