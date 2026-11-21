//
//  DriveMetrics.swift
//  Disk Health
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import Foundation

/// Normalized view over NVMe / ATA data so the analyzer, history and UI
/// can treat every drive the same way.
public struct DriveMetrics: Sendable, Hashable {
    public var temperatureC: Double?
    public var temperatureMinC: Double?
    public var temperatureMaxC: Double?
    public var powerOnHours: Double?
    public var powerCycles: Double?
    public var unsafeShutdowns: Double?
    public var bytesRead: Double?
    public var bytesWritten: Double?
    /// Percent of rated endurance consumed (SSD). May exceed 100.
    public var wearUsedPercent: Double?
    public var availableSpare: Int?
    public var availableSpareThreshold: Int?
    public var mediaErrors: Double?
    public var errorLogEntries: Double?
    public var reallocatedSectors: Int?
    public var reallocationEvents: Int?
    public var pendingSectors: Int?
    public var offlineUncorrectable: Int?
    public var reportedUncorrectable: Int?
    public var commandTimeouts: Int?
    public var crcErrors: Int?
    public var spinRetries: Int?
    public var loadCycles: Int?
    public var programFailures: Int?
    public var eraseFailures: Int?
    public var endToEndErrors: Int?
    public var runtimeBadBlocks: Int?

    public init(_ snapshot: DriveSnapshot) {
        switch snapshot.smart {
        case let .nvme(log, _):
            temperatureC = log.temperatureCelsius
            powerOnHours = log.powerOnHours
            powerCycles = log.powerCycles
            unsafeShutdowns = log.unsafeShutdowns
            bytesRead = log.bytesRead
            bytesWritten = log.bytesWritten
            wearUsedPercent = Double(log.percentageUsed)
            availableSpare = log.availableSpare
            availableSpareThreshold = log.availableSpareThreshold
            mediaErrors = log.mediaErrors
            errorLogEntries = log.errorLogEntries
        case let .ata(ata):
            Self.fillATA(&self, ata: ata, snapshot: snapshot)
        case .unavailable:
            break
        }
    }

    private static func fillATA(_ m: inout DriveMetrics, ata: ATAHealthData, snapshot: DriveSnapshot) {
        func raw(_ id: Int) -> UInt64? { ata.attribute(id)?.raw }
        func int(_ id: Int, mask: UInt64 = 0xFFFF_FFFF) -> Int? { raw(id).map { Int($0 & mask) } }

        if let t = ata.attribute(194) ?? ata.attribute(190) {
            let c = Int(t.rawBytes.first ?? 0)
            if c > 0, c < 120 { m.temperatureC = Double(c) }
            if t.rawBytes.count >= 6 {
                let low = Int(t.rawBytes[2]), high = Int(t.rawBytes[4])
                if low > 0, high >= low, high < 120 {
                    m.temperatureMinC = Double(low)
                    m.temperatureMaxC = Double(high)
                }
            }
        }
        m.powerOnHours = raw(9).map { Double($0 & 0xFFFF_FFFF) }
        m.powerCycles = raw(12).map { Double($0) }
        m.unsafeShutdowns = (raw(174) ?? raw(192)).map { Double($0) }
        m.reallocatedSectors = int(5)
        m.reallocationEvents = int(196)
        m.pendingSectors = int(197)
        m.offlineUncorrectable = int(198)
        m.reportedUncorrectable = int(187)
        m.commandTimeouts = int(188, mask: 0xFFFF)
        m.crcErrors = int(199)
        m.spinRetries = int(10)
        m.loadCycles = int(193)
        m.endToEndErrors = int(184)
        m.runtimeBadBlocks = int(183)
        let programFail = [int(171), int(181)].compactMap { $0 }
        m.programFailures = programFail.isEmpty ? nil : programFail.max()
        let eraseFail = [int(172), int(182)].compactMap { $0 }
        m.eraseFailures = eraseFail.isEmpty ? nil : eraseFail.max()
        m.errorLogEntries = ata.errorLogCount.map { Double($0) }

        let isSSD = snapshot.medium.isSolidState || ata.identify?.isSolidState == true
        if isSSD {
            for id in ATAAttributeCatalog.wearIndicatorIDs {
                if let a = ata.attribute(id), a.current > 0, a.current <= 100 {
                    m.wearUsedPercent = Double(100 - a.current)
                    break
                }
            }
            if let reserve = ata.attribute(232) ?? ata.attribute(170), reserve.current <= 100 {
                m.availableSpare = reserve.current
                m.availableSpareThreshold = reserve.threshold
            }
        }

        let model = (snapshot.model + " " + (snapshot.vendor ?? "")).lowercased()
        if let written = raw(241) ?? raw(246) {
            m.bytesWritten = Self.hostBytes(raw: written, model: model, powerOnHours: m.powerOnHours)
        }
        if let read = raw(242) {
            m.bytesRead = Self.hostBytes(raw: read, model: model, powerOnHours: m.powerOnHours)
        }
    }

    /// Interprets the "Total LBAs written/read" raw value, whose unit varies by vendor.
    static func hostBytes(raw: UInt64, model: String, powerOnHours: Double?) -> Double {
        let gib = 1_073_741_824.0
        if model.contains("intel") { return Double(raw) * 32 * 1_048_576 }
        if ["sandisk", "kingston", "sa400", "patriot", "adata", "transcend", "pny"].contains(where: model.contains) {
            return Double(raw) * gib
        }
        let asLBA = Double(raw) * 512
        // A drive with real usage that reports < 1 GB in LBAs is almost certainly counting GiB.
        if asLBA < 1_000_000_000, raw > 0, (powerOnHours ?? 0) > 200 { return Double(raw) * gib }
        return asLBA
    }

    public var lifeRemainingPercent: Double? { wearUsedPercent.map { max(0, 100 - $0) } }
}
