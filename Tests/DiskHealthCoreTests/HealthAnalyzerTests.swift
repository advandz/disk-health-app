//
//  HealthAnalyzerTests.swift
//  Disk Health
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import CryptoKit
import XCTest
@testable import DiskHealthCore

final class ParserTests: XCTestCase {
    func testNVMeLogParsing() {
        let raw = SampleDrives.nvmeLog(criticalWarning: 0x05, tempC: 44, spare: 97, spareThreshold: 10, used: 13,
                                       dataUnitsRead: 1_000, dataUnitsWritten: 334_795_795, powerCycles: 2_173,
                                       powerOnHours: 6_628, unsafe: 200, mediaErrors: 0, errorEntries: 0,
                                       warnTempMinutes: 7, critTempMinutes: 1)
        let log = NVMeParser.parseHealthLog(raw)
        XCTAssertEqual(log.criticalWarning, 0x05)
        XCTAssertTrue(log.warnings.contains(.spareBelowThreshold))
        XCTAssertTrue(log.warnings.contains(.reliabilityDegraded))
        XCTAssertFalse(log.warnings.contains(.readOnly))
        XCTAssertEqual(log.temperatureCelsius!, 44 - 0.15, accuracy: 0.01)
        XCTAssertEqual(log.availableSpare, 97)
        XCTAssertEqual(log.percentageUsed, 13)
        XCTAssertEqual(log.powerOnHours, 6_628)
        XCTAssertEqual(log.powerCycles, 2_173)
        XCTAssertEqual(log.unsafeShutdowns, 200)
        XCTAssertEqual(log.bytesWritten, 334_795_795 * 512_000, accuracy: 1)
        XCTAssertEqual(log.warningTemperatureMinutes, 7)
        XCTAssertEqual(log.criticalTemperatureMinutes, 1)
    }

    func testATAAttributeAndIdentifyParsing() {
        let (data, thr) = SampleDrives.ataBuffers([
            .init(5, prefail: true, 171, thr: 140, raw: 184),
            .init(194, 104, 98, raw: 0x0037_0012_0026),
            .init(9, 48, raw: 38_512),
        ], selfTest: 0x73)
        let identify = SampleDrives.ataIdentify(model: "WDC WD20EZRZ-00Z5HB0", serial: "WD-ABC", firmware: "80.00A80", rpm: 5400)
        let ata = ATAParser.parse(data: data, thresholds: thr, identify: identify, errorLog: nil, overallPassed: true)

        XCTAssertEqual(ata.attributes.count, 3)
        let realloc = ata.attribute(5)!
        XCTAssertTrue(realloc.isPrefail)
        XCTAssertEqual(realloc.current, 171)
        XCTAssertEqual(realloc.threshold, 140)
        XCTAssertEqual(realloc.raw, 184)
        XCTAssertFalse(realloc.isFailingNow)
        XCTAssertEqual(ata.attribute(194)!.rawBytes.first, 0x26)
        XCTAssertEqual(ata.selfTestStatus, 0x73)
        XCTAssertEqual(ata.identify?.model, "WDC WD20EZRZ-00Z5HB0")
        XCTAssertEqual(ata.identify?.serial, "WD-ABC")
        XCTAssertEqual(ata.identify?.rotationRate, 5400)
        XCTAssertEqual(ata.identify?.isSolidState, false)
        XCTAssertEqual(ata.identify?.sataGenerationSupported, 3)
    }

    func testTemperatureDecodingUsesLowByte() {
        let sample = SampleDrives.all().first { $0.snapshot.id == "sample-wd-elements" }!
        let m = DriveMetrics(sample.snapshot)
        XCTAssertEqual(m.temperatureC, 38)          // 0x26
        XCTAssertEqual(m.temperatureMinC, 18)       // 0x12
        XCTAssertEqual(m.temperatureMaxC, 55)       // 0x37
        XCTAssertEqual(m.powerOnHours, 52_870)
        XCTAssertEqual(m.powerCycles, 2_284)        // regression: must not be Double(bitPattern:)
    }

    func testCommandTimeoutUsesLow16Bits() {
        let sample = SampleDrives.all().first { $0.snapshot.id == "sample-barracuda" }!
        XCTAssertEqual(DriveMetrics(sample.snapshot).commandTimeouts, 1)   // 4295032833 = 0x1_0001_0001
    }
}

final class HealthAnalyzerTests: XCTestCase {
    private func report(_ id: String) -> HealthReport {
        let sample = SampleDrives.all().first { $0.snapshot.id == id }!
        return HealthAnalyzer.analyze(sample.snapshot, history: sample.history)
    }

    func testEverySampleLandsInExpectedState() {
        XCTAssertEqual(report("sample-mx500").status, .excellent)
        XCTAssertEqual(report("sample-wd-elements").status, .watch)
        XCTAssertEqual(report("sample-860evo").status, .degraded)
        XCTAssertEqual(report("sample-980pro").status, .degraded)
        XCTAssertEqual(report("sample-wd-blue").status, .failing)
        XCTAssertEqual(report("sample-sdcard").status, .failing)
        XCTAssertEqual(report("sample-barracuda").status, .failed)
    }

    func testHealthyAppleStyleNVMeIsNotFlaggedBySpareThreshold() {
        // Apple SSDs report available spare 100 % with a threshold of 99 %.
        let raw = SampleDrives.nvmeLog(tempC: 43, spare: 100, spareThreshold: 99, used: 13, dataUnitsRead: 900_000_000,
                                       dataUnitsWritten: 334_795_795, powerCycles: 2_173, powerOnHours: 6_628,
                                       unsafe: 200, mediaErrors: 0, errorEntries: 0)
        let snap = DriveSnapshot(id: "apple", bsdName: "disk0", name: "APPLE SSD", model: "APPLE SSD AP0256Q",
                                 interface: .appleFabric, isInternal: true, medium: .solidState, kind: .internalSSD,
                                 capacityBytes: 251_000_193_024, smart: .nvme(NVMeParser.parseHealthLog(raw), nil),
                                 io: IOStatistics())
        let r = HealthAnalyzer.analyze(snap)
        XCTAssertEqual(r.status, .excellent)
        XCTAssertEqual(r.healthPercent, 87)
        XCTAssertFalse(r.findings.contains { $0.severity >= .watch }, "\(r.findings.filter { $0.severity >= .watch })")
        // Wear 13 % over 6,628 h at 8 h/day ⇒ far beyond 10 years; projected endurance ~1.3 PB.
        XCTAssertEqual(r.life.label, "10+ years")
        XCTAssertEqual(r.life.projectedEnduranceBytes! / 1e15, 1.318, accuracy: 0.01)
    }

    func testNVMeCriticalWarningBits() {
        func status(_ bits: UInt8, media: UInt64 = 0) -> HealthStatus {
            let raw = SampleDrives.nvmeLog(criticalWarning: bits, tempC: 40, spare: 100, spareThreshold: 10, used: 5,
                                           dataUnitsRead: 1, dataUnitsWritten: 1, powerCycles: 10, powerOnHours: 100,
                                           unsafe: 0, mediaErrors: media, errorEntries: 0)
            let snap = DriveSnapshot(id: "x", bsdName: "disk9", name: "x", model: "x", interface: .nvme, isInternal: true,
                                     medium: .solidState, kind: .internalSSD, capacityBytes: 1,
                                     smart: .nvme(NVMeParser.parseHealthLog(raw), nil))
            return HealthAnalyzer.analyze(snap).status
        }
        XCTAssertEqual(status(0), .excellent)
        XCTAssertEqual(status(0x08), .failed)          // read-only
        XCTAssertEqual(status(0x04), .failing)         // reliability degraded
        XCTAssertEqual(status(0x01), .failing)         // spare below threshold
        XCTAssertEqual(status(0x02), .degraded)        // temperature
        XCTAssertEqual(status(0, media: 3), .degraded) // media errors present
        XCTAssertEqual(status(0, media: 80), .failing) // many media errors
    }

    func testPrefailAttributeAtThresholdFails() {
        let (data, thr) = SampleDrives.ataBuffers([.init(5, prefail: true, 10, thr: 10, raw: 2_000)])
        let ata = ATAParser.parse(data: data, thresholds: thr, identify: nil, errorLog: nil, overallPassed: true)
        let snap = DriveSnapshot(id: "y", bsdName: "disk9", name: "y", model: "y", interface: .sata, isInternal: true,
                                 medium: .rotational, kind: .internalHDD, capacityBytes: 1, smart: .ata(ata))
        let r = HealthAnalyzer.analyze(snap)
        XCTAssertEqual(r.status, .failed)
        XCTAssertLessThanOrEqual(r.healthPercent!, 10)
    }

    func testPendingSectorsAndGrowthArePreFail() {
        let (data, thr) = SampleDrives.ataBuffers([
            .init(5, prefail: true, 200, thr: 140, raw: 3), .init(197, 200, raw: 2), .init(9, 90, raw: 9_000),
        ])
        let ata = ATAParser.parse(data: data, thresholds: thr, identify: nil, errorLog: nil, overallPassed: true)
        let snap = DriveSnapshot(id: "z", bsdName: "disk9", name: "z", model: "z", interface: .sata, isInternal: true,
                                 medium: .rotational, kind: .internalHDD, capacityBytes: 1, smart: .ata(ata))

        // Without history: 2 pending sectors is a warning (Degraded), not yet Pre-Fail.
        XCTAssertEqual(HealthAnalyzer.analyze(snap).status, .degraded)

        // With history showing pending sectors appearing, it becomes Pre-Fail.
        let now = Date()
        let history = DriveHistory(driveID: "z", points: [
            HistoryPoint(date: now.addingTimeInterval(-5 * 86_400), powerOnHours: 8_900, reallocatedSectors: 3, pendingSectors: 0),
            HistoryPoint(date: now.addingTimeInterval(-86_400), powerOnHours: 8_980, reallocatedSectors: 3, pendingSectors: 1),
        ])
        let r = HealthAnalyzer.analyze(snap, history: history, now: now)
        XCTAssertEqual(r.status, .failing)
        XCTAssertTrue(r.findings.contains { $0.id == "trend.pending" })
    }

    func testNoSMARTDriveIsLowConfidenceAndHasNoLifeEstimate() {
        var io = IOStatistics()
        io.readOperations = 10_000
        let snap = DriveSnapshot(id: "usb", bsdName: "disk6", name: "USB", model: "External", interface: .usb,
                                 isInternal: false, medium: .unknown, kind: .externalDrive, capacityBytes: 1,
                                 smart: .unavailable(reason: "n/a"), io: io)
        let r = HealthAnalyzer.analyze(snap)
        XCTAssertEqual(r.confidence, .low)
        XCTAssertEqual(r.status, .good, "No SMART data: never rated Excellent")
        XCTAssertNil(r.life.remainingDays)
        XCTAssertEqual(r.life.label, "Not available")

        io.readErrors = 2
        let failing = HealthAnalyzer.analyze(DriveSnapshot(id: "usb", bsdName: "disk6", name: "USB", model: "External",
                                                           interface: .usb, isInternal: false, medium: .unknown,
                                                           kind: .externalDrive, capacityBytes: 1,
                                                           smart: .unavailable(reason: "n/a"), io: io))
        XCTAssertEqual(failing.status, .degraded)
    }

    func testSSDWearLifeUsesHistoryTrend() {
        let r = report("sample-860evo")
        XCTAssertNotNil(r.life.remainingDays)
        XCTAssertLessThan(r.life.remainingDays!, 200)
        XCTAssertGreaterThan(r.life.remainingDays!, 60)
        XCTAssertTrue(r.findings.contains { $0.id == "wear.high" })
    }

    func testHDDLifeEstimateIsLowConfidence() {
        let r = report("sample-wd-elements")
        XCTAssertEqual(r.life.confidence, .low)
        XCTAssertNotNil(r.life.remainingDays)
    }
}

final class HistoryTests: XCTestCase {
    func testAppendThrottlesUnchangedSamples() {
        var h = DriveHistory(driveID: "a")
        let t0 = Date()
        h.append(HistoryPoint(date: t0, temperatureC: 40, reallocatedSectors: 0))
        h.append(HistoryPoint(date: t0.addingTimeInterval(60), temperatureC: 41, reallocatedSectors: 0))
        XCTAssertEqual(h.points.count, 1)
        h.append(HistoryPoint(date: t0.addingTimeInterval(120), temperatureC: 41, reallocatedSectors: 1))
        XCTAssertEqual(h.points.count, 2, "Counter changes are always recorded")
        h.append(HistoryPoint(date: t0.addingTimeInterval(600), temperatureC: 42, reallocatedSectors: 1))
        XCTAssertEqual(h.points.count, 3)
    }

    func testStoreRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(directory: dir)
        store.update("drive-1") { $0.append(HistoryPoint(date: Date(), temperatureC: 39)) }
        let reloaded = HistoryStore(directory: dir).history(for: "drive-1")
        XCTAssertEqual(reloaded.points.count, 1)
        XCTAssertEqual(reloaded.points.first?.temperatureC, 39)
    }

    func testUnchangedHistoryIsNotRewritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(directory: dir)
        store.update("drive-2") { _ in }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty,
                      "A no-op update must not write a file")

        let t0 = Date()
        store.update("drive-2") { $0.append(HistoryPoint(date: t0, temperatureC: 40)) }
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first)
        let written = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        Thread.sleep(forTimeInterval: 1.1)
        // Within the sampling interval and with unchanged counters, append keeps nothing new.
        store.update("drive-2") { $0.append(HistoryPoint(date: t0.addingTimeInterval(60), temperatureC: 41)) }
        let after = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        XCTAssertEqual(written, after, "History that didn't change must not be rewritten")
    }

    func testObservedDutyCycle() {
        let now = Date()
        let h = DriveHistory(driveID: "d", points: [
            HistoryPoint(date: now.addingTimeInterval(-10 * 86_400), powerOnHours: 1_000),
            HistoryPoint(date: now, powerOnHours: 1_060),
        ])
        XCTAssertEqual(h.observedDutyHoursPerDay!, 6, accuracy: 0.01)
    }
}

final class SurfaceScannerTests: XCTestCase {
    func testScanReadsFileWithoutErrors() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dh-scan-\(UUID().uuidString)")
        let size = 64 * 1_048_576
        FileManager.default.createFile(atPath: url.path, contents: Data(count: size))
        defer { try? FileManager.default.removeItem(at: url) }
        let fd = open(url.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        let result = try SurfaceScanner.scan(fileDescriptor: fd, capacity: UInt64(size), blockSize: 4096, mode: .quick,
                                             isCancelled: { false }, progress: { _ in })
        XCTAssertEqual(result.readErrors, 0)
        XCTAssertGreaterThan(result.completedSamples, 0)
        XCTAssertEqual(result.latencyBuckets.reduce(0, +), result.completedSamples)
        XCTAssertTrue(result.isComplete)
    }

    /// A device that goes away mid-scan must end the scan, not be recorded as unreadable regions.
    func testLostDeviceThrowsInsteadOfCountingErrors() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dh-scan-\(UUID().uuidString)")
        let size = 64 * 1_048_576
        FileManager.default.createFile(atPath: url.path, contents: Data(count: size))
        defer { try? FileManager.default.removeItem(at: url) }
        let fd = open(url.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        let reads = Counter()
        XCTAssertThrowsError(try SurfaceScanner.scan(
            fileDescriptor: fd, capacity: UInt64(size), blockSize: 4096, mode: .quick,
            isCancelled: {
                reads.value += 1
                if reads.value == 5 { close(fd) }   // the next read fails with EBADF
                return false
            },
            progress: { _ in })) { error in
            XCTAssertEqual(error as? SurfaceScanError, .deviceDisconnected)
        }
    }

    func testDeviceLossErrorsAreToldApartFromMediaErrors() {
        XCTAssertTrue(SurfaceScanner.isDeviceLost(ENXIO))
        XCTAssertTrue(SurfaceScanner.isDeviceLost(ENODEV))
        XCTAssertFalse(SurfaceScanner.isDeviceLost(EIO), "EIO is a media error while the device is present")
    }

    func testStoppedCleanScanKeepsPreviousResult() {
        let complete = Self.result(completed: 512, planned: 512, errors: 0)
        let completeWithErrors = Self.result(completed: 512, planned: 512, errors: 7)
        let stoppedClean = Self.result(completed: 40, planned: 512, errors: 0, cancelled: true)
        let stoppedWithErrors = Self.result(completed: 40, planned: 512, errors: 2, cancelled: true)
        let tooShort = Self.result(completed: 10, planned: 512, errors: 0, cancelled: true)

        XCTAssertFalse(stoppedClean.shouldReplace(completeWithErrors), "Stopping a re-run must not hide errors")
        XCTAssertFalse(stoppedClean.shouldReplace(complete))
        XCTAssertTrue(stoppedClean.shouldReplace(nil))
        XCTAssertTrue(stoppedWithErrors.shouldReplace(complete), "New problems are always kept")
        XCTAssertTrue(complete.shouldReplace(completeWithErrors), "A complete scan supersedes the last one")
        XCTAssertFalse(tooShort.shouldReplace(nil))
    }

    static func result(completed: Int, planned: Int, errors: Int, cancelled: Bool = false) -> SurfaceScanResult {
        SurfaceScanResult(date: Date(), mode: .quick, plannedSamples: planned, completedSamples: completed,
                          chunkBytes: SurfaceScanner.chunkBytes, bytesRead: 0, readErrors: errors, errorOffsets: [],
                          slowReads: 0, verySlowReads: 0, medianLatencyMs: 1, p95LatencyMs: 1, maxLatencyMs: 1,
                          throughputMBps: 100, latencyBuckets: [], duration: 1, cancelled: cancelled)
    }

    func testSampleOffsetsAreAlignedAndCoverBothEnds() {
        let capacity: UInt64 = 1_000_000_000_000
        let offsets = SurfaceScanner.sampleOffsets(capacity: capacity, samples: 512, align: 4096)
        XCTAssertEqual(offsets.first, 0)
        XCTAssertEqual(offsets.last, capacity / 4096 * 4096)
        XCTAssertTrue(offsets.allSatisfy { $0 % 4096 == 0 && $0 <= capacity })
        XCTAssertGreaterThanOrEqual(offsets.count, 512)
    }
}

final class IdleDriveTests: XCTestCase {
    static func hdd(operations: UInt64, capturedAt: Date, selfTest: Int? = nil) -> DriveSnapshot {
        var io = IOStatistics()
        io.readOperations = operations
        let ata = ATAHealthData(attributes: [], overallPassed: true, selfTestStatus: selfTest, errorLogCount: nil,
                                identify: nil, shortTestMinutes: nil, extendedTestMinutes: nil)
        return DriveSnapshot(id: "hdd", bsdName: "disk9", name: "HDD", model: "HDD", interface: .sata,
                             isInternal: false, medium: .rotational, kind: .externalHDD, capacityBytes: 1,
                             smart: .ata(ata), io: io, capturedAt: capturedAt, smartServiceEntryID: 42)
    }

    func testIdleHardDriveReusesLastReading() {
        let now = Date()
        let last = Self.hdd(operations: 100, capturedAt: now.addingTimeInterval(-600))
        var io = IOStatistics(); io.readOperations = 100
        XCTAssertNotNil(DriveDiscovery.reusableIdleSnapshot(entryID: 42, io: io, previous: [last], now: now))
    }

    func testActiveOrStaleOrTestingDriveIsReadAgain() {
        let now = Date()
        var io = IOStatistics(); io.readOperations = 100
        var busy = IOStatistics(); busy.readOperations = 101
        let last = Self.hdd(operations: 100, capturedAt: now.addingTimeInterval(-600))
        XCTAssertNil(DriveDiscovery.reusableIdleSnapshot(entryID: 42, io: busy, previous: [last], now: now),
                     "Host I/O since the last read means the drive is spinning")
        XCTAssertNil(DriveDiscovery.reusableIdleSnapshot(entryID: 7, io: io, previous: [last], now: now),
                     "A different (re-attached) device is read fresh")
        let old = Self.hdd(operations: 100, capturedAt: now.addingTimeInterval(-13 * 3600))
        XCTAssertNil(DriveDiscovery.reusableIdleSnapshot(entryID: 42, io: io, previous: [old], now: now))
        let testing = Self.hdd(operations: 100, capturedAt: now.addingTimeInterval(-600), selfTest: 0xF5)
        XCTAssertNil(DriveDiscovery.reusableIdleSnapshot(entryID: 42, io: io, previous: [testing], now: now),
                     "A running self-test does no host I/O but its progress must update")
        XCTAssertNil(DriveDiscovery.reusableIdleSnapshot(entryID: 42, io: io, previous: [], now: now))
    }
}

/// A mutable counter for @Sendable test closures.
final class Counter: @unchecked Sendable {
    var value = 0
}

final class UpdateScheduleTests: XCTestCase {
    func testChecksOncePerDay() {
        let now = Date()
        XCTAssertTrue(UpdateSchedule.isDue(lastCheck: nil, now: now), "Never checked")
        XCTAssertFalse(UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(-3600), now: now))
        XCTAssertFalse(UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(-(24 * 3600 - 60)), now: now))
        XCTAssertTrue(UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(-24 * 3600), now: now))
        XCTAssertTrue(UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(-3 * 24 * 3600), now: now))
        XCTAssertTrue(UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(3600), now: now),
                      "A last check in the future (clock set back) must not block checks")
    }
}

final class UpdateSignatureTests: XCTestCase {
    let key = Curve25519.Signing.PrivateKey()
    let image = Data((0..<100_000).map { UInt8($0 % 251) })

    var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }

    func signatureFile(for data: Data, with signer: Curve25519.Signing.PrivateKey? = nil) throws -> Data {
        Data(((try (signer ?? key).signature(for: data)).base64EncodedString() + "\n").utf8)
    }

    func testGenuineImageIsAccepted() throws {
        XCTAssertTrue(UpdateSignature.isValid(signatureFile: try signatureFile(for: image), for: image, publicKey: publicKey))
    }

    func testModifiedImageIsRejected() throws {
        var forged = image
        forged[50_000] ^= 0x01
        XCTAssertFalse(UpdateSignature.isValid(signatureFile: try signatureFile(for: image), for: forged, publicKey: publicKey))
        XCTAssertFalse(UpdateSignature.isValid(signatureFile: try signatureFile(for: image), for: image + Data([0]),
                                               publicKey: publicKey), "Appended bytes")
    }

    func testImageSignedWithAnotherKeyIsRejected() throws {
        let attacker = Curve25519.Signing.PrivateKey()
        XCTAssertFalse(UpdateSignature.isValid(signatureFile: try signatureFile(for: image, with: attacker), for: image,
                                               publicKey: publicKey))
    }

    func testSignatureForAnotherFileIsRejected() throws {
        let other = Data("another release".utf8)
        XCTAssertFalse(UpdateSignature.isValid(signatureFile: try signatureFile(for: other), for: image, publicKey: publicKey))
    }

    func testMalformedSignatureFilesAreRejected() throws {
        let genuine = try signatureFile(for: image)
        XCTAssertFalse(UpdateSignature.isValid(signatureFile: Data(), for: image, publicKey: publicKey), "Empty")
        XCTAssertFalse(UpdateSignature.isValid(signatureFile: Data("not base64!".utf8), for: image, publicKey: publicKey))
        XCTAssertFalse(UpdateSignature.isValid(signatureFile: Data(Data(repeating: 7, count: 32).base64EncodedString().utf8),
                                               for: image, publicKey: publicKey), "Wrong length")
        XCTAssertFalse(UpdateSignature.isValid(signatureFile: genuine + Data(repeating: 0x20, count: 2048), for: image,
                                               publicKey: publicKey), "Oversized file")
        XCTAssertFalse(UpdateSignature.isValid(signatureFile: genuine, for: image, publicKey: "not a key"), "Bad public key")
    }
}
