//
//  LifeEstimator.swift
//  Disk Health
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import Foundation

/// Estimates remaining useful life.
///
/// SSDs: from the drive's own wear indicator. The wear rate comes from history
/// (calendar time) when available, otherwise from wear per power-on hour and a
/// duty cycle (observed from history, or an assumed 8 h/day).
/// HDDs: from power-on age against a typical service life, scaled by health.
public enum LifeEstimator {
    public static let assumedDutyHoursPerDay = 8.0
    public static let hddServiceLifeHours = 45_000.0

    public static func estimate(snapshot s: DriveSnapshot, metrics m: DriveMetrics, history: DriveHistory?,
                                healthPercent: Int?, status: HealthStatus) -> LifeEstimate {
        if status == .failed {
            return LifeEstimate(remainingDays: 0, label: String(localized: "End of life"), confidence: .high,
                                method: String(localized: "The drive reports a failure condition."))
        }

        let observedDuty = history?.observedDutyHoursPerDay
        let duty = observedDuty ?? assumedDutyHoursPerDay
        // Full sentences are built at each call site (word order differs between languages).
        let dutyText = observedDuty != nil ? duty.fixed(1) : "\(Int(duty.rounded()))"

        if let used = m.wearUsedPercent {
            return ssdEstimate(used: used, metrics: m, history: history, healthPercent: healthPercent,
                               status: status, duty: duty, dutyObserved: observedDuty != nil, dutyText: dutyText)
        }

        if s.medium == .rotational || (s.medium == .unknown && m.powerOnHours != nil && m.reallocatedSectors != nil) {
            guard let poh = m.powerOnHours else {
                return LifeEstimate(remainingDays: nil, label: String(localized: "Not available"), confidence: .none,
                                    method: String(localized: "The drive does not report its power-on time."))
            }
            let health = Double(healthPercent ?? 100) / 100
            let remainingHours = max(0, hddServiceLifeHours - poh) * health
            var days = remainingHours / duty
            var label = LifeEstimate.label(forDays: days)
            if status == .failing {
                days = min(days, 30)
                label = String(localized: "At risk now")
            } else if remainingHours < 500 {
                label = String(localized: "Past typical service life")
            }
            let hours = poh.clampedInt, serviceLife = hddServiceLifeHours.clampedInt, healthPct = healthPercent ?? 100
            let method = observedDuty != nil
                ? String(localized: "Hard drives have no wear meter. Estimated from \(hours) power-on hours against a typical \(serviceLife)-hour service life, scaled by current health (\(healthPct)%), at the observed usage of \(dutyText) powered-on hours per day.")
                : String(localized: "Hard drives have no wear meter. Estimated from \(hours) power-on hours against a typical \(serviceLife)-hour service life, scaled by current health (\(healthPct)%), at an assumed \(dutyText) powered-on hours per day (refines as history accumulates).")
            return LifeEstimate(
                remainingDays: days, label: label, confidence: .low,
                method: method,
                dutyHoursPerDay: duty, dutyCycleObserved: observedDuty != nil)
        }

        let reason: String
        if case .unavailable = s.smart {
            reason = String(localized: "This drive does not expose wear or age data to macOS (no S.M.A.R.T. access), so remaining life cannot be estimated.")
        } else {
            reason = String(localized: "The drive does not report a wear indicator.")
        }
        return LifeEstimate(remainingDays: nil, label: status == .failing ? String(localized: "At risk now") : String(localized: "Not available"),
                            confidence: .none, method: reason)
    }

    static func ssdEstimate(used: Double, metrics m: DriveMetrics, history: DriveHistory?, healthPercent: Int?,
                            status: HealthStatus, duty: Double, dutyObserved: Bool, dutyText: String) -> LifeEstimate {
        let remaining = max(0, 100 - used)

        // Endurance projection in bytes written
        var projected: Double?
        var remainingBytes: Double?
        if let written = m.bytesWritten, written > 0, used >= 1 {
            projected = written / (used / 100)
            remainingBytes = max(0, projected! - written)
        }

        var days: Double?
        var confidence: Confidence = .low
        var method: String

        // 1. Calendar trend from history
        if let trend = wearTrend(history), trend.perDay > 0 {
            days = remaining / trend.perDay
            confidence = trend.spanDays >= 30 ? .high : .medium
            let delta = Int(trend.delta.rounded()), span = Int(trend.spanDays.rounded())
            method = String(localized: "Based on \(delta)% wear observed over the last \(span) days.")
        } else if let poh = m.powerOnHours, poh > 0, used >= 1 {
            // 2. Wear per power-on hour × duty cycle
            let perHour = used / poh
            days = remaining / perHour / duty
            confidence = dutyObserved ? .medium : .low
            let percent = Int(used.rounded()), hours = poh.clampedInt
            method = dutyObserved
                ? String(localized: "Extrapolated from \(percent)% wear over \(hours) power-on hours, at the observed usage of \(dutyText) powered-on hours per day.")
                : String(localized: "Extrapolated from \(percent)% wear over \(hours) power-on hours, at an assumed \(dutyText) powered-on hours per day (refines as history accumulates).")
        } else if let poh = m.powerOnHours, poh > 24 {
            // 3. Less than 1% used: only a lower bound is known.
            days = 99 * poh / duty
            confidence = .low
            let hours = poh.clampedInt
            method = dutyObserved
                ? String(localized: "Less than 1% of rated endurance used after \(hours) power-on hours; this is a lower bound at the observed usage of \(dutyText) powered-on hours per day.")
                : String(localized: "Less than 1% of rated endurance used after \(hours) power-on hours; this is a lower bound at an assumed \(dutyText) powered-on hours per day (refines as history accumulates).")
        } else {
            method = String(localized: "Insufficient wear data to extrapolate yet.")
        }

        // Non-wear problems shorten life independently of NAND endurance.
        if let d = days, let hp = healthPercent, remaining > 0, Double(hp) < remaining {
            days = d * max(0.05, Double(hp) / remaining)
            method += " " + String(localized: "Reduced to account for detected errors.")
        }

        var label = days.map(LifeEstimate.label(forDays:))
            ?? (remaining > 0 ? String(localized: "\(Int(remaining))% remaining") : String(localized: "Exhausted"))
        if used >= 100 {
            label = String(localized: "Rated life exceeded")
            days = 0
        }
        if status == .failing {
            label = String(localized: "At risk now")
            days = min(days ?? 30, 30)
            confidence = min(confidence, .medium)
        }

        return LifeEstimate(remainingDays: days, label: label, confidence: confidence, method: method,
                            lifeRemainingPercent: remaining, projectedEnduranceBytes: projected,
                            remainingEnduranceBytes: remainingBytes, dutyHoursPerDay: duty, dutyCycleObserved: dutyObserved)
    }

    /// Wear increase per calendar day from stored history. The wear indicator has
    /// 1 % resolution, so a meaningful rate needs either ≥ 30 days or ≥ 3 % of change.
    static func wearTrend(_ history: DriveHistory?) -> (perDay: Double, delta: Double, spanDays: Double)? {
        guard let points = history?.points.filter({ $0.wearUsedPercent != nil }),
              let first = points.first, let last = points.last,
              let a = first.wearUsedPercent, let b = last.wearUsedPercent else { return nil }
        let spanDays = last.date.timeIntervalSince(first.date) / 86_400
        let delta = b - a
        guard delta >= 1, (spanDays >= 30 || (spanDays >= 7 && delta >= 3)) else { return nil }
        return ((b - a) / spanDays, b - a, spanDays)
    }
}
