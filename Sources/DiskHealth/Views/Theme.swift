//
//  Theme.swift
//  Disk Health
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import DiskHealthCore
import SwiftUI

extension HealthStatus {
    var color: Color {
        switch self {
        case .excellent: return Color(red: 0.16, green: 0.78, blue: 0.47)
        case .good: return Color(red: 0.30, green: 0.75, blue: 0.35)
        case .watch: return Color(red: 0.96, green: 0.74, blue: 0.10)
        case .degraded: return Color(red: 0.98, green: 0.52, blue: 0.12)
        case .failing: return Color(red: 0.93, green: 0.23, blue: 0.20)
        case .failed: return Color(red: 0.72, green: 0.09, blue: 0.28)
        case .unknown: return .gray
        }
    }
}

extension Severity {
    var color: Color {
        switch self {
        case .good: return HealthStatus.excellent.color
        case .info: return .blue
        case .watch: return HealthStatus.watch.color
        case .warning: return HealthStatus.degraded.color
        case .critical: return HealthStatus.failing.color
        case .failed: return HealthStatus.failed.color
        }
    }

    var symbolName: String {
        switch self {
        case .good: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .watch: return "eye.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }
}

extension Confidence {
    var color: Color {
        switch self {
        case .high: return .green
        case .medium: return .blue
        case .low: return .orange
        case .none: return .gray
        }
    }
}

enum TemperatureUnit: String, CaseIterable, Identifiable {
    case celsius = "C", fahrenheit = "F"
    var id: String { rawValue }
    var label: String { self == .celsius ? String(localized: "Celsius (°C)") : String(localized: "Fahrenheit (°F)") }
}

enum Format {
    static func bytes(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        if value >= 1e15 { return "\((value / 1e15).fixed(2)) PB" }
        return ByteCountFormatter.string(fromByteCount: Int64(min(value, 9.0e18)), countStyle: .file)
    }

    static func bytes(_ value: UInt64) -> String { bytes(Double(value)) }
    static func bytes(_ value: Int64) -> String { bytes(Double(value)) }

    static func number(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(0)))
    }

    static func number(_ value: Int?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number)
    }

    static func temperature(_ celsius: Double?, unit: TemperatureUnit) -> String {
        guard let c = celsius else { return "—" }
        switch unit {
        case .celsius: return "\(Int(c.rounded())) °C"
        case .fahrenheit: return "\(Int((c * 9 / 5 + 32).rounded())) °F"
        }
    }

    static func hours(_ hours: Double?) -> String {
        guard let h = hours else { return "—" }
        return "\(number(h)) h"
    }

    static func duration(hours: Double?) -> String {
        guard let h = hours else { return "" }
        let days = h / 24
        if days < 1 { return LifeEstimate.duration(days: days) }
        return String(localized: "≈ \(LifeEstimate.duration(days: days))", comment: "Approximate duration, e.g. ≈ 3 years")
    }

    static func minutes(_ minutes: Double) -> String {
        String(localized: "\(number(minutes)) min", comment: "Duration in minutes")
    }

    static func percent(_ value: Double?) -> String {
        guard let v = value else { return "—" }
        return "\(Int(v.rounded()))%"
    }

    static func latency(_ ms: Double?) -> String {
        guard let ms else { return "—" }
        if ms < 1 { return "\(ms.fixed(2)) ms" }
        if ms < 10 { return "\(ms.fixed(1)) ms" }
        return "\(ms.fixed(0)) ms"
    }

    static func capacity(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .decimal)
    }
}

extension DriveSnapshot {
    var subtitle: String {
        var parts = [Format.capacity(capacityBytes)]
        parts.append(interface == .appleFabric ? "NVMe" : interface.displayName)
        if medium != .unknown { parts.append(medium.displayName) }
        return parts.joined(separator: " · ")
    }
}
