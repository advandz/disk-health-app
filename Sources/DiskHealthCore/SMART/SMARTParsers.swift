//
//  SMARTParsers.swift
//  Disk Health
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import Foundation

// MARK: - Byte helpers

@inline(__always) func le16(_ b: [UInt8], _ o: Int) -> Int {
    guard o + 1 < b.count else { return 0 }
    return Int(b[o]) | (Int(b[o + 1]) << 8)
}

@inline(__always) func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
    guard o + 3 < b.count else { return 0 }
    var v: UInt32 = 0
    for i in 0..<4 { v |= UInt32(b[o + i]) << (8 * UInt32(i)) }
    return v
}

@inline(__always) func le64(_ b: [UInt8], _ o: Int) -> UInt64 {
    guard o + 7 < b.count else { return 0 }
    var v: UInt64 = 0
    for i in 0..<8 { v |= UInt64(b[o + i]) << (8 * UInt64(i)) }
    return v
}

/// 128-bit little-endian counter as Double (NVMe counters are 16 bytes).
@inline(__always) func le128(_ b: [UInt8], _ o: Int) -> Double {
    Double(le64(b, o)) + Double(le64(b, o + 8)) * 18_446_744_073_709_551_616.0
}

func asciiField(_ b: [UInt8], _ range: Range<Int>) -> String? {
    guard range.upperBound <= b.count else { return nil }
    let bytes = b[range].map { $0 == 0 ? UInt8(ascii: " ") : $0 }
    let s = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return s.isEmpty ? nil : s
}

// MARK: - NVMe

public enum NVMeParser {
    /// Parses the 512-byte SMART / Health Information log page (NVMe 1.4 §5.14.1.2).
    public static func parseHealthLog(_ b: [UInt8]) -> NVMeHealthLog {
        var log = NVMeHealthLog()
        guard b.count >= 512 else { return log }
        log.criticalWarning = b[0]
        log.temperatureKelvin = le16(b, 1)
        log.availableSpare = Int(b[3])
        log.availableSpareThreshold = Int(b[4])
        log.percentageUsed = Int(b[5])
        log.enduranceGroupCriticalWarning = b[6]
        log.dataUnitsRead = le128(b, 32)
        log.dataUnitsWritten = le128(b, 48)
        log.hostReadCommands = le128(b, 64)
        log.hostWriteCommands = le128(b, 80)
        log.controllerBusyMinutes = le128(b, 96)
        log.powerCycles = le128(b, 112)
        log.powerOnHours = le128(b, 128)
        log.unsafeShutdowns = le128(b, 144)
        log.mediaErrors = le128(b, 160)
        log.errorLogEntries = le128(b, 176)
        log.warningTemperatureMinutes = Int(le32(b, 192))
        log.criticalTemperatureMinutes = Int(le32(b, 196))
        log.temperatureSensorsKelvin = (0..<8).map { le16(b, 200 + $0 * 2) }.filter { $0 > 0 }
        log.thermalThrottle1Transitions = Int(le32(b, 216))
        log.thermalThrottle2Transitions = Int(le32(b, 220))
        log.thermalThrottle1Seconds = Int(le32(b, 224))
        log.thermalThrottle2Seconds = Int(le32(b, 228))
        return log
    }

    /// Parses the 4096-byte Identify Controller data structure.
    public static func parseIdentifyController(_ b: [UInt8]) -> NVMeControllerInfo {
        var info = NVMeControllerInfo()
        guard b.count >= 4096 else { return info }
        info.pciVendorID = le16(b, 0)
        info.serial = asciiField(b, 4..<24)
        info.model = asciiField(b, 24..<64)
        info.firmware = asciiField(b, 64..<72)
        info.warningTemperatureKelvin = le16(b, 266)
        info.criticalTemperatureKelvin = le16(b, 268)
        let capacity = le128(b, 280)
        info.totalCapacityBytes = capacity > 0 ? capacity : nil
        return info
    }
}

// MARK: - ATA

public enum ATAParser {
    /// Parses the 30 attribute entries of the SMART READ DATA / READ THRESHOLDS
    /// structures (2-byte revision, then 30 × 12-byte entries).
    public static func parseAttributes(data: [UInt8], thresholds: [UInt8]?) -> [ATAAttribute] {
        guard data.count >= 362 else { return [] }
        var thresholdMap: [Int: Int] = [:]
        if let t = thresholds, t.count >= 362 {
            for i in 0..<30 {
                let o = 2 + i * 12
                let id = Int(t[o])
                if id != 0 { thresholdMap[id] = Int(t[o + 1]) }
            }
        }
        var attributes: [ATAAttribute] = []
        for i in 0..<30 {
            let o = 2 + i * 12
            let id = Int(data[o])
            guard id != 0, id != 0xFF else { continue }
            let flags = UInt16(data[o + 1]) | (UInt16(data[o + 2]) << 8)
            attributes.append(ATAAttribute(
                id: id,
                flags: flags,
                current: Int(data[o + 3]),
                worst: Int(data[o + 4]),
                threshold: thresholdMap[id],
                rawBytes: Array(data[(o + 5)..<(o + 11)])
            ))
        }
        return attributes
    }

    /// Parses IDENTIFY DEVICE (512 bytes, 256 native-endian 16-bit words).
    public static func parseIdentify(_ b: [UInt8]) -> ATAIdentify {
        var id = ATAIdentify()
        guard b.count >= 512 else { return id }
        func word(_ n: Int) -> Int { le16(b, n * 2) }
        func string(_ first: Int, _ last: Int) -> String? {
            var bytes: [UInt8] = []
            for w in first...last {
                let v = word(w)
                bytes.append(UInt8((v >> 8) & 0xFF))
                bytes.append(UInt8(v & 0xFF))
            }
            return asciiField(bytes, 0..<bytes.count)
        }
        id.serial = string(10, 19)
        id.firmware = string(23, 26)
        id.model = string(27, 46)
        let rotation = word(217)
        if rotation == 1 || (rotation >= 0x0401 && rotation < 0xFFFF) { id.rotationRate = rotation }
        id.trimSupported = word(169) & 0x1 != 0
        let lba48 = UInt64(word(100)) | (UInt64(word(101)) << 16) | (UInt64(word(102)) << 32) | (UInt64(word(103)) << 48)
        let lba28 = UInt64(word(60)) | (UInt64(word(61)) << 16)
        id.sectorCount = lba48 > 0 ? lba48 : lba28
        let w106 = word(106)
        if w106 & 0xC000 == 0x4000, w106 & 0x1000 != 0 {
            id.logicalSectorSize = (word(117) | (word(118) << 16)) * 2
        }
        let sataCaps = word(76)
        if sataCaps != 0, sataCaps != 0xFFFF {
            if sataCaps & (1 << 3) != 0 { id.sataGenerationSupported = 3 }
            else if sataCaps & (1 << 2) != 0 { id.sataGenerationSupported = 2 }
            else if sataCaps & (1 << 1) != 0 { id.sataGenerationSupported = 1 }
            let current = (word(77) >> 1) & 0x7
            if (1...3).contains(current) { id.sataGenerationCurrent = current }
        }
        return id
    }

    /// Error count from the SMART summary error log (bytes 452–453).
    public static func parseErrorLogCount(_ b: [UInt8]) -> Int? {
        guard b.count >= 454 else { return nil }
        return le16(b, 452)
    }

    public static func parse(data: [UInt8], thresholds: [UInt8]?, identify: [UInt8]?,
                             errorLog: [UInt8]?, overallPassed: Bool?) -> ATAHealthData {
        let attributes = parseAttributes(data: data, thresholds: thresholds)
        let selfTest = data.count > 363 ? Int(data[363]) : nil
        let shortMinutes = data.count > 372 ? Int(data[372]) : nil
        var extendedMinutes = data.count > 373 ? Int(data[373]) : nil
        if extendedMinutes == 0xFF, data.count > 376 { extendedMinutes = le16(data, 375) }
        return ATAHealthData(
            attributes: attributes,
            overallPassed: overallPassed,
            selfTestStatus: selfTest,
            errorLogCount: errorLog.flatMap(parseErrorLogCount),
            identify: identify.map(parseIdentify),
            shortTestMinutes: shortMinutes,
            extendedTestMinutes: extendedMinutes
        )
    }

    /// Describes the high nibble of the self-test execution status byte.
    public static func selfTestDescription(_ status: Int) -> (text: String, severity: Severity) {
        switch status >> 4 {
        case 0x0: return (String(localized: "Last self-test completed without error"), .good)
        case 0x1: return (String(localized: "Last self-test was aborted by the host"), .info)
        case 0x2: return (String(localized: "Last self-test was interrupted by a reset"), .info)
        case 0x3: return (String(localized: "Last self-test could not complete due to a fatal error"), .critical)
        case 0x4: return (String(localized: "Last self-test failed (unknown test element)"), .warning)
        case 0x5: return (String(localized: "Last self-test failed: electrical element"), .critical)
        case 0x6: return (String(localized: "Last self-test failed: servo / seek element"), .critical)
        case 0x7: return (String(localized: "Last self-test failed: read element"), .critical)
        case 0x8: return (String(localized: "Last self-test failed: suspected handling damage"), .critical)
        case 0xF: return (String(localized: "Self-test in progress (\((status & 0xF) * 10)% remaining)"), .info)
        default: return (String(localized: "Self-test status unknown (0x\(String(status, radix: 16)))"), .info)
        }
    }
}
