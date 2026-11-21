//
//  SampleDrives.swift
//  Disk Health
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import Foundation

/// Simulated drives covering every health state. They are built from raw
/// SMART byte buffers so they run through the same parsers as real hardware.
/// Shown in the app only when "Show Sample Drives" is enabled; also used by tests.
public enum SampleDrives {
    public struct Sample: Sendable {
        public var snapshot: DriveSnapshot
        public var history: DriveHistory
    }

    // MARK: - Raw buffer builders

    public struct ATAAttr {
        var id: Int, prefail: Bool, current: Int, worst: Int, threshold: Int, raw: UInt64
        public init(_ id: Int, prefail: Bool = false, _ current: Int, _ worst: Int? = nil, thr: Int = 0, raw: UInt64 = 0) {
            self.id = id; self.prefail = prefail; self.current = current
            self.worst = worst ?? current; self.threshold = thr; self.raw = raw
        }
    }

    public static func ataBuffers(_ attrs: [ATAAttr], selfTest: UInt8 = 0) -> (data: [UInt8], thresholds: [UInt8]) {
        var data = [UInt8](repeating: 0, count: 512)
        var thr = [UInt8](repeating: 0, count: 512)
        data[0] = 0x10; thr[0] = 0x10
        for (i, a) in attrs.prefix(30).enumerated() {
            let o = 2 + i * 12
            data[o] = UInt8(a.id)
            let flags: UInt16 = (a.prefail ? 0x1 : 0) | 0x2
            data[o + 1] = UInt8(flags & 0xFF)
            data[o + 2] = UInt8(flags >> 8)
            data[o + 3] = UInt8(a.current)
            data[o + 4] = UInt8(a.worst)
            for b in 0..<6 { data[o + 5 + b] = UInt8((a.raw >> (8 * UInt64(b))) & 0xFF) }
            thr[o] = UInt8(a.id)
            thr[o + 1] = UInt8(a.threshold)
        }
        data[363] = selfTest
        data[372] = 2
        data[373] = 0xFF
        data[375] = 0x2C; data[376] = 0x01   // 300 minutes
        return (data, thr)
    }

    public static func ataIdentify(model: String, serial: String, firmware: String, rpm: Int, sataGen: Int = 3) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 512)
        func put(_ s: String, _ first: Int, _ last: Int) {
            let chars = Array(s.utf8) + Array(repeating: UInt8(ascii: " "), count: (last - first + 1) * 2)
            for (k, w) in (first...last).enumerated() {
                b[w * 2] = chars[k * 2 + 1]      // low byte = second char
                b[w * 2 + 1] = chars[k * 2]      // high byte = first char
            }
        }
        put(serial, 10, 19); put(firmware, 23, 26); put(model, 27, 46)
        b[217 * 2] = UInt8(rpm & 0xFF); b[217 * 2 + 1] = UInt8(rpm >> 8)
        b[169 * 2] = rpm == 1 ? 1 : 0
        b[76 * 2] = UInt8(1 << sataGen | 0x6)
        b[77 * 2] = UInt8(sataGen << 1)
        return b
    }

    public static func nvmeLog(criticalWarning: UInt8 = 0, tempC: Int, spare: Int, spareThreshold: Int, used: Int,
                               dataUnitsRead: UInt64, dataUnitsWritten: UInt64, powerCycles: UInt64, powerOnHours: UInt64,
                               unsafe: UInt64, mediaErrors: UInt64, errorEntries: UInt64,
                               warnTempMinutes: UInt32 = 0, critTempMinutes: UInt32 = 0) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 512)
        func put64(_ v: UInt64, _ o: Int) { for i in 0..<8 { b[o + i] = UInt8((v >> (8 * UInt64(i))) & 0xFF) } }
        func put32(_ v: UInt32, _ o: Int) { for i in 0..<4 { b[o + i] = UInt8((v >> (8 * UInt32(i))) & 0xFF) } }
        b[0] = criticalWarning
        let k = tempC + 273
        b[1] = UInt8(k & 0xFF); b[2] = UInt8(k >> 8)
        b[3] = UInt8(spare); b[4] = UInt8(spareThreshold); b[5] = UInt8(used)
        put64(dataUnitsRead, 32); put64(dataUnitsWritten, 48)
        put64(dataUnitsRead * 12, 64); put64(dataUnitsWritten * 9, 80)
        put64(powerOnHours * 3, 96); put64(powerCycles, 112); put64(powerOnHours, 128)
        put64(unsafe, 144); put64(mediaErrors, 160); put64(errorEntries, 176)
        put32(warnTempMinutes, 192); put32(critTempMinutes, 196)
        return b
    }

    // MARK: - Samples

    public static func all(now: Date = Date()) -> [Sample] {
        [healthySATASSD(now), agingExternalHDD(now), wornSATASSD(now), degradedNVMe(now),
         failingHDD(now), failingSDCard(now), failedHDD(now)]
    }

    static func io(ops: UInt64, readErrors: UInt64 = 0, writeErrors: UInt64 = 0, retries: UInt64 = 0, latencyMs: Double = 0.4) -> IOStatistics {
        var s = IOStatistics()
        s.readOperations = ops * 3 / 4
        s.writeOperations = ops / 4
        s.bytesRead = s.readOperations * 65_536
        s.bytesWritten = s.writeOperations * 49_152
        s.readErrors = readErrors
        s.writeErrors = writeErrors
        s.readRetries = retries
        s.totalReadTimeNs = UInt64(Double(s.readOperations) * latencyMs * 1_000_000)
        s.totalWriteTimeNs = UInt64(Double(s.writeOperations) * latencyMs * 1.4 * 1_000_000)
        return s
    }

    static func volume(_ name: String, _ bsd: String, total: Double, used: Double, fs: String = "apfs") -> VolumeInfo {
        VolumeInfo(bsdName: bsd, name: name, mountPoint: "/Volumes/\(name)", fileSystem: fs,
                   fileSystemDescription: fs == "apfs" ? "APFS" : fs == "exfat" ? "ExFAT" : "Mac OS Extended (Journaled)",
                   totalBytes: Int64(total * 1e9), availableBytes: Int64((total - used) * 1e9),
                   containerKey: bsd, isReadOnly: false)
    }

    static func history(_ id: String, now: Date, days: Int, poh: (Double, Double),
                        temps: ClosedRange<Double>, build: (Double) -> HistoryPoint = { _ in HistoryPoint(date: .distantPast) }) -> DriveHistory {
        var points: [HistoryPoint] = []
        let steps = days * 6
        for i in 0...steps {
            let f = Double(i) / Double(steps)
            var p = build(f)
            p.date = now.addingTimeInterval(-Double(days) * 86_400 * (1 - f) - 600)
            p.powerOnHours = poh.0 + (poh.1 - poh.0) * f
            let wave = sin(f * Double(days) * 2 * .pi)
            p.temperatureC = (temps.lowerBound + temps.upperBound) / 2 + wave * (temps.upperBound - temps.lowerBound) / 2
            points.append(p)
        }
        return DriveHistory(driveID: id, points: points)
    }

    static func healthySATASSD(_ now: Date) -> Sample {
        let (data, thr) = ataBuffers([
            .init(1, prefail: false, 100, thr: 0, raw: 0), .init(5, prefail: true, 100, thr: 10, raw: 0),
            .init(9, 100, raw: 4_212), .init(12, 100, raw: 611), .init(171, 100, raw: 0), .init(172, 100, raw: 0),
            .init(173, 97, raw: 41), .init(174, 100, raw: 37), .init(180, prefail: true, 100, thr: 0, raw: 54),
            .init(183, 100, raw: 0), .init(184, 100, thr: 0, raw: 0), .init(187, 100, raw: 0), .init(194, 67, 51, raw: 0x0045_0012_0021),
            .init(196, 100, raw: 0), .init(197, 100, raw: 0), .init(198, 100, raw: 0), .init(199, 100, raw: 0),
            .init(202, 96, thr: 1, raw: 4), .init(206, 100, raw: 0), .init(246, 100, raw: 21_480_000_000),
        ])
        let id = ataIdentify(model: "CT1000MX500SSD1", serial: "2041E4A1B2C3", firmware: "M3CR046", rpm: 1)
        let ata = ATAParser.parse(data: data, thresholds: thr, identify: id, errorLog: [UInt8](repeating: 0, count: 512), overallPassed: true)
        let driveID = "sample-mx500"
        let snap = DriveSnapshot(id: driveID, bsdName: "disk10", name: "Crucial MX500 1TB", model: "CT1000MX500SSD1",
                                 vendor: "Crucial", serial: "2041E4A1B2C3", firmware: "M3CR046", interface: .sata, isInternal: true,
                                 medium: .solidState, kind: .internalSSD, capacityBytes: 1_000_204_886_016, supportsTrim: true,
                                 linkDescription: "SATA III (6 Gb/s)", smart: .ata(ata), io: io(ops: 8_400_000),
                                 volumes: [volume("Projects", "disk10s2", total: 999.8, used: 412.3)], isSample: true)
        let hist = history(driveID, now: now, days: 21, poh: (4_040, 4_212), temps: 29...36) { _ in
            HistoryPoint(date: .distantPast, wearUsedPercent: 4, reallocatedSectors: 0, pendingSectors: 0)
        }
        return Sample(snapshot: snap, history: hist)
    }

    static func agingExternalHDD(_ now: Date) -> Sample {
        let (data, thr) = ataBuffers([
            .init(1, prefail: true, 200, thr: 51, raw: 0), .init(3, prefail: true, 176, 172, thr: 21, raw: 6_183),
            .init(4, 98, raw: 2_301), .init(5, prefail: true, 200, thr: 140, raw: 0), .init(7, prefail: true, 200, thr: 0, raw: 0),
            .init(9, 28, raw: 52_870), .init(10, 100, thr: 0, raw: 0), .init(11, 100, thr: 0, raw: 0), .init(12, 98, raw: 2_284),
            .init(192, 200, raw: 410), .init(193, 133, raw: 201_557), .init(194, 112, 97, raw: 0x0037_0012_0026),
            .init(196, 200, raw: 0), .init(197, 200, raw: 0), .init(198, 100, thr: 0, raw: 0), .init(199, 200, raw: 23),
            .init(200, 200, thr: 0, raw: 0),
        ])
        let id = ataIdentify(model: "WDC WD40EDAZ-11SLVB0", serial: "WD-WX12D80H7KXY", firmware: "80.00A80", rpm: 5400)
        let ata = ATAParser.parse(data: data, thresholds: thr, identify: id, errorLog: nil, overallPassed: true)
        let driveID = "sample-wd-elements"
        let snap = DriveSnapshot(id: driveID, bsdName: "disk11", name: "WD Elements 4TB", model: "WDC WD40EDAZ-11SLVB0",
                                 vendor: "Western Digital", serial: "WD-WX12D80H7KXY", firmware: "80.00A80", interface: .usb,
                                 isInternal: false, medium: .rotational, kind: .externalHDD, capacityBytes: 4_000_787_030_016,
                                 isEjectable: true,
                                 usb: USBInfo(productName: "Elements 25A3", vendorName: "Western Digital", linkSpeedBps: 5e9, bcdUSB: 0x0320),
                                 linkDescription: "USB 3.2 Gen 1 (5 Gb/s)", smart: .ata(ata), io: io(ops: 1_210_000, latencyMs: 9.5),
                                 volumes: [volume("Time Machine", "disk11s2", total: 4000.6, used: 3105.2)], isSample: true)
        let hist = history(driveID, now: now, days: 30, poh: (52_640, 52_870), temps: 34...40) { _ in
            HistoryPoint(date: .distantPast, reallocatedSectors: 0, pendingSectors: 0)
        }
        return Sample(snapshot: snap, history: hist)
    }

    static func wornSATASSD(_ now: Date) -> Sample {
        let (data, thr) = ataBuffers([
            .init(5, prefail: true, 99, thr: 10, raw: 18), .init(9, 93, raw: 31_118), .init(12, 99, raw: 1_942),
            .init(177, prefail: true, 8, thr: 0, raw: 2_741), .init(179, prefail: true, 99, thr: 10, raw: 18),
            .init(181, 100, thr: 10, raw: 0), .init(182, 100, thr: 10, raw: 0), .init(183, 100, thr: 10, raw: 0),
            .init(187, 100, raw: 0), .init(190, 62, 41, raw: 38), .init(195, 200, raw: 0), .init(199, 100, raw: 0),
            .init(235, 99, raw: 214), .init(241, 99, raw: 615_284_772_112),
        ])
        let id = ataIdentify(model: "Samsung SSD 860 EVO 500GB", serial: "S3Z1NB0K412345X", firmware: "RVT02B6Q", rpm: 1)
        let ata = ATAParser.parse(data: data, thresholds: thr, identify: id, errorLog: [UInt8](repeating: 0, count: 512), overallPassed: true)
        let driveID = "sample-860evo"
        let snap = DriveSnapshot(id: driveID, bsdName: "disk12", name: "Samsung SSD 860 EVO 500GB", model: "Samsung SSD 860 EVO 500GB",
                                 vendor: "Samsung", serial: "S3Z1NB0K412345X", firmware: "RVT02B6Q", interface: .sata, isInternal: true,
                                 medium: .solidState, kind: .internalSSD, capacityBytes: 500_107_862_016, supportsTrim: true,
                                 linkDescription: "SATA III (6 Gb/s)", smart: .ata(ata), io: io(ops: 22_100_000),
                                 volumes: [volume("Scratch", "disk12s2", total: 499.9, used: 451.0)], isSample: true)
        let hist = history(driveID, now: now, days: 60, poh: (30_150, 31_118), temps: 33...41) { f in
            HistoryPoint(date: .distantPast, wearUsedPercent: (88 + 4 * f).rounded(.down), reallocatedSectors: 18, pendingSectors: 0)
        }
        return Sample(snapshot: snap, history: hist)
    }

    static func degradedNVMe(_ now: Date) -> Sample {
        let raw = nvmeLog(criticalWarning: 0, tempC: 61, spare: 64, spareThreshold: 10, used: 38,
                          dataUnitsRead: 210_000_000, dataUnitsWritten: 365_000_000, powerCycles: 1_204, powerOnHours: 9_870,
                          unsafe: 88, mediaErrors: 14, errorEntries: 1_830, warnTempMinutes: 312)
        var info = NVMeControllerInfo()
        info.model = "Samsung SSD 980 PRO 1TB"; info.serial = "S5GXNF0R123456"; info.firmware = "5B2QGXA7"
        info.warningTemperatureKelvin = 355; info.criticalTemperatureKelvin = 358
        let driveID = "sample-980pro"
        let snap = DriveSnapshot(id: driveID, bsdName: "disk13", name: "Samsung SSD 980 PRO 1TB", model: "Samsung SSD 980 PRO 1TB",
                                 vendor: "Samsung", serial: "S5GXNF0R123456", firmware: "5B2QGXA7", interface: .thunderbolt,
                                 isInternal: false, medium: .solidState, kind: .externalSSD, capacityBytes: 1_000_204_886_016,
                                 supportsTrim: true, linkDescription: "Thunderbolt 3 (40 Gb/s)",
                                 smart: .nvme(NVMeParser.parseHealthLog(raw), info), io: io(ops: 14_800_000, retries: 3),
                                 volumes: [volume("Media", "disk13s2", total: 1000.2, used: 702.4)], isSample: true)
        let hist = history(driveID, now: now, days: 14, poh: (9_700, 9_870), temps: 48...63) { f in
            HistoryPoint(date: .distantPast, wearUsedPercent: 38, mediaErrors: 14, availableSpare: f < 0.5 ? 66 : 65)
        }
        return Sample(snapshot: snap, history: hist)
    }

    static func failingHDD(_ now: Date) -> Sample {
        let (data, thr) = ataBuffers([
            .init(1, prefail: true, 188, 180, thr: 51, raw: 2_317), .init(3, prefail: true, 172, 170, thr: 21, raw: 6_383),
            .init(4, 99, raw: 1_472), .init(5, prefail: true, 171, thr: 140, raw: 184), .init(7, prefail: true, 200, thr: 0, raw: 0),
            .init(9, 48, raw: 38_512), .init(10, 100, thr: 0, raw: 0), .init(12, 99, raw: 1_431), .init(187, 100, raw: 12),
            .init(193, 196, raw: 14_225), .init(194, 104, 98, raw: 46), .init(196, 151, raw: 49), .init(197, 200, thr: 0, raw: 16),
            .init(198, 100, thr: 0, raw: 16), .init(199, 200, raw: 0), .init(200, 196, thr: 0, raw: 418),
        ], selfTest: 0x73)
        let id = ataIdentify(model: "WDC WD20EZRZ-00Z5HB0", serial: "WD-WCC4M1KT2ABC", firmware: "80.00A80", rpm: 5400)
        var errLog = [UInt8](repeating: 0, count: 512)
        errLog[0] = 1; errLog[452] = 27
        let ata = ATAParser.parse(data: data, thresholds: thr, identify: id, errorLog: errLog, overallPassed: true)
        let driveID = "sample-wd-blue"
        let snap = DriveSnapshot(id: driveID, bsdName: "disk14", name: "WD Blue 2TB", model: "WDC WD20EZRZ-00Z5HB0",
                                 vendor: "Western Digital", serial: "WD-WCC4M1KT2ABC", firmware: "80.00A80", interface: .sata,
                                 isInternal: true, medium: .rotational, kind: .internalHDD, capacityBytes: 2_000_398_934_016,
                                 linkDescription: "SATA III (6 Gb/s)", smart: .ata(ata),
                                 io: io(ops: 3_400_000, readErrors: 4, retries: 37, latencyMs: 14),
                                 volumes: [volume("Photos Archive", "disk14s2", total: 2000.1, used: 1688.5, fs: "hfs")], isSample: true)
        let hist = history(driveID, now: now, days: 18, poh: (38_180, 38_512), temps: 41...47) { f in
            HistoryPoint(date: .distantPast, reallocatedSectors: f < 0.4 ? 120 : f < 0.8 ? 152 : 184,
                         pendingSectors: f < 0.5 ? 4 : 9, offlineUncorrectable: f < 0.5 ? 4 : 9, reportedUncorrectable: f < 0.6 ? 5 : 9)
        }
        return Sample(snapshot: snap, history: hist)
    }

    static func failingSDCard(_ now: Date) -> Sample {
        let driveID = "sample-sdcard"
        let snap = DriveSnapshot(id: driveID, bsdName: "disk15", name: "SanDisk Extreme 128GB", model: "SDXC Card",
                                 vendor: "SanDisk", serial: nil, firmware: "1.00", interface: .sdCard, isInternal: false,
                                 medium: .flash, kind: .sdCard, capacityBytes: 127_865_454_592, isRemovable: true, isEjectable: true,
                                 linkDescription: "UHS-I", smart: .unavailable(reason: DriveDiscovery.bridgedSMARTUnavailableReason),
                                 io: io(ops: 412_000, readErrors: 3, retries: 41, latencyMs: 6.1),
                                 volumes: [volume("EOS_DIGITAL", "disk15s1", total: 127.8, used: 88.1, fs: "exfat")], isSample: true)
        var hist = DriveHistory(driveID: driveID)
        hist.lastSurfaceScan = SurfaceScanResult(
            date: now.addingTimeInterval(-3_600), mode: .quick, plannedSamples: 513, completedSamples: 513,
            chunkBytes: SurfaceScanner.chunkBytes, bytesRead: 511 * 1_048_576, readErrors: 2,
            errorOffsets: [41_943_040_000, 41_944_088_576], slowReads: 19, verySlowReads: 5,
            medianLatencyMs: 11.8, p95LatencyMs: 96, maxLatencyMs: 2_840, throughputMBps: 61.4,
            latencyBuckets: [12, 401, 63, 18, 9, 3, 5], duration: 8.3, cancelled: false)
        return Sample(snapshot: snap, history: hist)
    }

    static func failedHDD(_ now: Date) -> Sample {
        let (data, thr) = ataBuffers([
            .init(1, prefail: true, 62, 44, thr: 6, raw: 176_327_412), .init(3, prefail: true, 92, 91, thr: 0, raw: 0),
            .init(5, prefail: true, 3, 3, thr: 10, raw: 31_416), .init(7, prefail: true, 78, 60, thr: 45, raw: 61_904_221),
            .init(9, 51, raw: 43_210), .init(10, prefail: true, 100, thr: 97, raw: 0), .init(12, 99, raw: 1_088),
            .init(184, 100, thr: 99, raw: 0), .init(187, 1, raw: 2_013), .init(188, 100, thr: 0, raw: 4_295_032_833),
            .init(190, 57, 41, thr: 40, raw: 43), .init(194, 43, raw: 43), .init(197, 100, raw: 1_128), .init(198, 100, raw: 1_128),
            .init(199, 200, raw: 0),
        ], selfTest: 0x74)
        let id = ataIdentify(model: "ST4000DM004-2CV104", serial: "ZFN0ABCD", firmware: "0001", rpm: 5425)
        let ata = ATAParser.parse(data: data, thresholds: thr, identify: id, errorLog: nil, overallPassed: false)
        let snap = DriveSnapshot(id: "sample-barracuda", bsdName: "disk16", name: "Seagate BarraCuda 4TB", model: "ST4000DM004-2CV104",
                                 vendor: "Seagate", serial: "ZFN0ABCD", firmware: "0001", interface: .sata, isInternal: true,
                                 medium: .rotational, kind: .internalHDD, capacityBytes: 4_000_787_030_016,
                                 linkDescription: "SATA III (6 Gb/s)", smart: .ata(ata),
                                 io: io(ops: 2_100_000, readErrors: 211, retries: 1_904, latencyMs: 180),
                                 volumes: [volume("Backup", "disk16s2", total: 4000.6, used: 3550.0, fs: "hfs")], isSample: true)
        return Sample(snapshot: snap, history: DriveHistory(driveID: "sample-barracuda"))
    }
}
