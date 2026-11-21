//
//  HealthAnalyzer.swift
//  Disk Health
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import Foundation

/// Turns raw drive data into a graded health assessment.
///
/// The model is multi-signal rather than a pass/fail check:
/// - a base score from the drive's own wear indicator (SSD) or 100 (HDD),
/// - multiplicative penalties for every error / defect counter,
/// - per-finding caps (a failing indicator can never coexist with a high score),
/// - trend analysis against stored history (growth of defects ⇒ Pre-Fail),
/// - and the worst finding severity, which can only make the status worse.
public enum HealthAnalyzer {
    public static func analyze(_ s: DriveSnapshot, history: DriveHistory? = nil, now: Date = Date()) -> HealthReport {
        var b = Builder()
        let m = DriveMetrics(s)
        var base = 100.0
        var hasReliabilityData = false
        var dataSources: [String] = []

        switch s.smart {
        case let .nvme(log, info):
            hasReliabilityData = true
            dataSources.append(String(localized: "NVMe SMART / Health Information log"))
            if info != nil { dataSources.append(String(localized: "NVMe Identify Controller")) }
            base = analyzeNVMe(log, into: &b)
        case let .ata(ata):
            hasReliabilityData = !ata.attributes.isEmpty || ata.overallPassed != nil
            dataSources.append(String(localized: "ATA S.M.A.R.T. attributes & thresholds"))
            base = analyzeATA(ata, snapshot: s, metrics: m, into: &b)
        case let .unavailable(reason):
            b.append("smart.unavailable", .info, .data, String(localized: "S.M.A.R.T. data not available"), reason,
                     rec: String(localized: "Health is inferred from I/O error counters and the optional surface read test."))
        }

        if let io = s.io {
            dataSources.append(String(localized: "I/O error & latency counters (since connected)"))
            analyzeIO(io, snapshot: s, into: &b)
        }

        var scanConsidered = false
        if let scan = history?.lastSurfaceScan, now.timeIntervalSince(scan.date) < 45 * 86_400, scan.completedSamples > 0 {
            scanConsidered = true
            let scanDate = scan.date.formatted(date: .abbreviated, time: .shortened)
            dataSources.append(String(localized: "Surface read test (\(scanDate))"))
            analyzeScan(scan, into: &b)
        }

        let temperature = analyzeTemperature(s, metrics: m, into: &b)
        analyzeInterface(s, into: &b)

        if let history, history.points.count > 1 {
            let days = history.span / 86_400
            let samples = String(localized: "\(history.points.count) samples")
            let span = days < 1 ? String(localized: "less than a day") : String(localized: "\(Int(days.rounded())) days")
            dataSources.append(String(localized: "History: \(samples) over \(span)"))
            analyzeTrends(current: m, history: history, now: now, into: &b)
        }

        // Health score
        var score = base
        for f in b.factors { score *= f }
        for cap in b.findings.compactMap(\.healthCap) { score = min(score, Double(cap)) }
        score = max(0, min(100, score))
        let healthPercent: Int? = (hasReliabilityData || s.io != nil || scanConsidered) ? Int(score.rounded()) : nil

        // Status: worst of finding severity and score band
        var status: HealthStatus
        switch b.findings.map(\.severity).max() ?? .good {
        case .failed: status = .failed
        case .critical: status = .failing
        case .warning: status = .degraded
        case .watch: status = .watch
        case .good, .info: status = .excellent
        }
        if let hp = healthPercent {
            let band: HealthStatus
            switch hp {
            case 85...: band = .excellent
            case 45..<85: band = .good
            case 20..<45: band = .watch
            default: band = .degraded
            }
            // A low score alone (e.g. heavy but orderly SSD wear) means Degraded;
            // Pre-Fail / Failed require an explicit critical indicator.
            status = status.worse(band)
        } else {
            status = .unknown
        }
        // Without S.M.A.R.T., "no errors seen" is not evidence of excellent health.
        if !hasReliabilityData, status == .excellent { status = .good }

        let confidence: Confidence
        if hasReliabilityData {
            confidence = .high
        } else if scanConsidered {
            confidence = .medium
        } else if s.io != nil {
            confidence = .low
        } else {
            confidence = .none
        }

        let life = LifeEstimator.estimate(snapshot: s, metrics: m, history: history,
                                          healthPercent: healthPercent, status: status)

        let findings = b.findings.sorted {
            $0.severity != $1.severity ? $0.severity > $1.severity : $0.category.rawValue < $1.category.rawValue
        }

        return HealthReport(
            status: status,
            healthPercent: healthPercent,
            confidence: confidence,
            headline: headline(for: status, limited: !hasReliabilityData),
            summary: summary(for: status, findings: findings, limited: !hasReliabilityData),
            findings: findings,
            life: life,
            temperature: temperature,
            dataSources: dataSources,
            generatedAt: now
        )
    }

    // MARK: - NVMe

    static func analyzeNVMe(_ log: NVMeHealthLog, into b: inout Builder) -> Double {
        let w = log.warnings
        if w.contains(.readOnly) {
            b.add("nvme.cw.readonly", .failed, .reliability, "Drive has switched to read-only mode",
                  "The controller placed the media in read-only mode to protect data. Writes will fail.",
                  rec: "Copy your data to another drive immediately and replace this drive.", cap: 5)
        }
        if w.contains(.reliabilityDegraded) {
            b.add("nvme.cw.reliability", .critical, .reliability, "NVM subsystem reliability degraded",
                  "The controller reports reliability degraded due to excessive media or internal errors.",
                  rec: "Back up now and plan a replacement.", cap: 25)
        }
        if w.contains(.spareBelowThreshold) {
            b.add("nvme.cw.spare", .critical, .media, "Spare capacity below threshold",
                  "Available spare (\(log.availableSpare)%) has fallen below the drive's threshold (\(log.availableSpareThreshold)%). The drive is running out of replacement blocks.",
                  rec: "Back up now and plan a replacement.", cap: 20)
        }
        if w.contains(.persistentMemoryReadOnly) {
            b.add("nvme.cw.pmr", .critical, .reliability, "Persistent memory region is read-only",
                  "The controller's persistent memory region became read-only or unreliable.", cap: 30)
        }
        if w.contains(.volatileBackupFailed) {
            b.add("nvme.cw.backup", .warning, .power, "Power-loss protection failed",
                  "The volatile memory backup device has failed. Data in flight may be lost on power failure.", cap: 70)
        }
        if w.contains(.temperature) {
            b.add("nvme.cw.temp", .warning, .temperature, "Temperature threshold exceeded",
                  "The controller reports a temperature outside its operating range.",
                  rec: "Improve cooling and avoid sustained heavy writes until temperatures drop.")
        }

        // Wear / endurance
        let used = Double(log.percentageUsed)
        let remaining = max(0, 100 - used)
        addWearFinding(used: used, into: &b)

        // Spare blocks
        if !w.contains(.spareBelowThreshold) {
            let spare = log.availableSpare, threshold = log.availableSpareThreshold
            if threshold > 0, threshold <= 100, spare < threshold {
                b.add("nvme.spare.below", .critical, .media, "Spare capacity below threshold",
                      "Available spare is \(spare)% against a threshold of \(threshold)%.", cap: 20)
            } else if spare < 100 {
                if threshold < 100, spare - threshold <= 5 {
                    b.add("nvme.spare.near", .warning, .media, "Spare blocks nearly exhausted",
                          "Available spare is \(spare)%, close to the \(threshold)% threshold.",
                          rec: "Back up regularly and plan a replacement.", cap: 60)
                } else if spare <= 50 {
                    b.add("nvme.spare.low", .warning, .media, "Low spare capacity",
                          "Only \(spare)% of the reserved spare blocks remain.", cap: 70)
                } else if spare < 90 {
                    b.add("nvme.spare.used", .watch, .media, "Spare blocks in use",
                          "Available spare is \(spare)%. The drive has started retiring worn blocks.")
                }
            }
        }

        // Media & data integrity errors
        if log.mediaErrors > 0 {
            let n = log.mediaErrors
            let severe = n >= 50
            // Conditional literals passed to an Optional parameter are not picked up by string
            // extraction, so resolve the choice into a non-optional value first.
            let mediaRec: String.LocalizationValue = severe ? "Back up now; this drive is losing data integrity."
                                                           : "Back up important data and monitor for growth."
            b.add("nvme.media", severe ? .critical : .warning, .media,
                  "\(n.clampedInt) media & data integrity errors",
                  "The controller detected unrecovered data integrity errors (ECC/CRC failures, LBA tag mismatches). Healthy drives report 0.",
                  rec: mediaRec,
                  cap: severe ? 35 : 75)
            b.penalize(n, scale: 20)
        } else {
            b.add("nvme.media.ok", .good, .media, "No media errors", "No unrecovered data integrity errors have been recorded.")
        }

        if log.errorLogEntries > 0 {
            b.add("nvme.errlog", .info, .errors, "\(log.errorLogEntries.clampedInt) error log entries",
                  "Entries in the controller's error information log. Often caused by benign command errors (e.g. unsupported requests) rather than media problems.")
        }

        // Unsafe shutdowns
        if log.unsafeShutdowns > 0 {
            let ratio = log.powerCycles > 0 ? log.unsafeShutdowns / log.powerCycles : 0
            let frequent = log.unsafeShutdowns >= 50 && ratio >= 0.25
            let percent = Int((ratio * 100).rounded()), cycles = log.powerCycles.clampedInt
            b.add("nvme.unsafe", frequent ? .watch : .info, .power, "\(log.unsafeShutdowns.clampedInt) unsafe shutdowns",
                  log.powerCycles > 0
                      ? "Power was lost without a clean shutdown notification (\(percent)% of \(cycles) power cycles)."
                      : "Power was lost without a clean shutdown notification.",
                  rec: frequent ? "Avoid force-restarts and unplugging without ejecting; frequent power loss risks file-system corruption." : nil)
        }

        if log.criticalTemperatureMinutes > 0 {
            b.add("nvme.temp.crittime", .watch, .temperature, "Time spent above critical temperature",
                  "The drive has operated above its critical temperature for \(log.criticalTemperatureMinutes) minutes in its lifetime.")
        } else if log.warningTemperatureMinutes > 60 {
            b.add("nvme.temp.warntime", .info, .temperature, "Time spent above warning temperature",
                  "The drive has operated above its warning temperature for \(log.warningTemperatureMinutes) minutes in its lifetime.")
        }
        if log.thermalThrottle1Transitions + log.thermalThrottle2Transitions > 0 {
            b.add("nvme.throttle", .info, .temperature, "Thermal throttling has occurred",
                  "The controller has throttled performance \(log.thermalThrottle1Transitions + log.thermalThrottle2Transitions) times to manage heat.")
        }

        let spareFactor = log.availableSpare < 100 ? Double(max(1, log.availableSpare)) : 100
        return min(max(remaining, used >= 100 ? 1 : 0), spareFactor)
    }

    static func addWearFinding(used: Double, into b: inout Builder) {
        let percent = Int(used.rounded())
        let usedText: String.LocalizationValue = "\(percent)% of rated write endurance used."
        switch used {
        case 100...:
            b.add("wear.exceeded", .critical, .wear, "Rated endurance exhausted",
                  "\(percent)% of rated write endurance used. The NAND has exceeded its manufacturer-rated life; failure risk rises sharply from here.",
                  rec: "Back up now and replace the drive soon.")
        case 90..<100:
            b.add("wear.high", .warning, .wear, "Nearing end of rated endurance",
                  usedText, rec: "Plan a replacement and keep backups current.")
        case 75..<90:
            b.add("wear.significant", .watch, .wear, "Significant wear", usedText)
        case 50..<75:
            b.add("wear.moderate", .info, .wear, "Moderate wear", usedText)
        default:
            b.add("wear.low", .good, .wear, "Low wear", usedText)
        }
    }

    // MARK: - ATA

    static func analyzeATA(_ ata: ATAHealthData, snapshot s: DriveSnapshot, metrics m: DriveMetrics, into b: inout Builder) -> Double {
        let isSSD = s.medium.isSolidState || ata.identify?.isSolidState == true
        var base = 100.0

        if ata.overallPassed == false {
            b.add("ata.status", .failed, .reliability, "S.M.A.R.T. overall-health self-assessment: FAILED",
                  "The drive's own firmware has determined that it is failing or about to fail.",
                  rec: "Copy your data off immediately and replace the drive.", cap: 5)
        }

        // Normalized-vs-threshold analysis for every attribute
        for a in ata.attributes {
            guard let t = a.threshold, t > 0 else { continue }
            if a.isFailingNow {
                if a.isPrefail {
                    b.add("ata.thr.now.\(a.id)", .failed, .reliability, "\(a.name) has crossed its failure threshold",
                          "Pre-failure attribute #\(a.id) is at \(a.current) (threshold \(t)). The drive predicts failure on this parameter.",
                          rec: "Copy your data off immediately and replace the drive.", cap: 10)
                } else {
                    b.add("ata.thr.now.\(a.id)", .warning, .age, "\(a.name) is below threshold",
                          "Old-age attribute #\(a.id) is at \(a.current) (threshold \(t)). The drive is past its design life on this parameter.",
                          cap: 60)
                }
            } else if a.hasFailedInPast, a.isPrefail {
                b.add("ata.thr.past.\(a.id)", .warning, .reliability, "\(a.name) crossed its threshold in the past",
                      "Worst recorded value \(a.worst) reached the threshold \(t) at some point.", cap: 65)
            } else if a.isPrefail, a.current < 100, a.current - t <= 10, !ATAAttributeCatalog.wearIndicatorIDs.contains(a.id) {
                b.add("ata.thr.near.\(a.id)", .watch, .reliability, "\(a.name) approaching threshold",
                      "Normalized value \(a.current) is within \(a.current - t) points of the failure threshold \(t).")
            }
        }

        // Sector-level defects
        if let n = m.reallocatedSectors, n > 0 {
            let (sev, cap): (Severity, Int?) = isSSD
                ? (n >= 500 ? (.critical, 35) : n >= 50 ? (.warning, 70) : (.watch, nil))
                : (n >= 100 ? (.critical, 35) : n >= 10 ? (.warning, 70) : (.watch, nil))
            let reallocRec: String.LocalizationValue = sev >= .warning
                ? "Back up important data and watch whether this number keeps growing." : "Monitor for growth."
            b.add("ata.realloc", sev, .media, isSSD ? "\(n) reallocated blocks" : "\(n) reallocated sectors",
                  isSSD ? "Worn or defective NAND blocks have been retired and replaced with spares."
                        : "Bad sectors were found and remapped to the spare area. Drives with reallocated sectors fail far more often than drives without.",
                  rec: reallocRec,
                  cap: cap)
            b.penalize(Double(n), scale: isSSD ? 200 : 40)
        } else if m.reallocatedSectors != nil {
            b.add("ata.realloc.ok", .good, .media, isSSD ? "No reallocated blocks" : "No reallocated sectors", "No defects have been remapped.")
        }

        if let n = m.pendingSectors, n > 0 {
            b.add("ata.pending", n >= 5 ? .critical : .warning, .media, "\(n) pending unstable sectors",
                  "Sectors that could not be read reliably and are waiting to be remapped. This is one of the strongest predictors of imminent failure.",
                  rec: "Back up now. Data in these sectors may already be unreadable.", cap: n >= 5 ? 35 : 60)
            b.penalize(Double(n), scale: 10)
        }
        if let n = m.offlineUncorrectable, n > 0 {
            b.add("ata.offline", n >= 5 ? .critical : .warning, .media, "\(n) offline uncorrectable sectors",
                  "Sectors that could not be read during the drive's background scan.",
                  rec: "Back up now and run an extended self-test.", cap: n >= 5 ? 35 : 60)
            b.penalize(Double(n), scale: 10)
        }
        if let n = m.reportedUncorrectable, n > 0 {
            b.add("ata.reported", n >= 20 ? .critical : .warning, .errors, "\(n) uncorrectable read errors",
                  "Errors that could not be recovered using ECC were reported to the host.",
                  rec: "Back up important data.", cap: n >= 20 ? 40 : 75)
            b.penalize(Double(n), scale: 20)
        }
        if let n = m.endToEndErrors, n > 0 {
            b.add("ata.e2e", n >= 5 ? .critical : .warning, .errors, "\(n) end-to-end data path errors",
                  "Parity mismatches inside the drive's internal data path (cache/controller).", cap: n >= 5 ? 40 : 70)
            b.penalize(Double(n), scale: 5)
        }
        if let n = m.spinRetries, n > 0, !isSSD {
            b.add("ata.spin", .warning, .reliability, "\(n) spin-up retries",
                  "The motor needed more than one attempt to reach operating speed — a mechanical or power-supply problem.",
                  rec: "Check power supply / enclosure; back up data.", cap: 70)
            b.penalize(Double(n), scale: 5)
        }
        if let n = m.commandTimeouts, n > 0 {
            b.add("ata.timeout", n >= 20 ? .warning : .watch, .errors, "\(n) command timeouts",
                  "Operations were aborted because the drive did not respond in time. Often caused by power or cable problems, sometimes by a failing drive.")
            b.penalize(Double(n), scale: 200)
        }
        if let n = m.crcErrors, n > 0 {
            b.add("ata.crc", n >= 100 ? .warning : .watch, .interface, "\(n) interface CRC errors",
                  "Data was corrupted in transit between drive and computer. This points to the cable, connector or enclosure rather than the drive itself.",
                  rec: "Replace or reseat the cable / try another port or enclosure.")
            b.penalize(Double(n), scale: 1000)
        }
        if let n = m.runtimeBadBlocks, n > 0, isSSD {
            b.add("ata.runtimebad", n >= 50 ? .warning : .watch, .media, "\(n) runtime bad blocks",
                  "NAND blocks that failed during operation.")
            b.penalize(Double(n), scale: 100)
        }
        let flashFailures = (m.programFailures ?? 0) + (m.eraseFailures ?? 0)
        if flashFailures > 0 {
            b.add("ata.flashfail", flashFailures >= 10 ? .warning : .watch, .media,
                  "\(flashFailures) NAND program/erase failures",
                  "Flash blocks failed to program or erase and were retired.", cap: flashFailures >= 10 ? 75 : nil)
            b.penalize(Double(flashFailures), scale: 50)
        }
        if let n = m.loadCycles, n > 300_000, !isSSD {
            b.add("ata.loadcycles", n > 600_000 ? .warning : .watch, .age, "\(n) head load/unload cycles",
                  "Typical drives are rated for 300,000–600,000 load cycles. Aggressive head parking accelerates mechanical wear.")
        }
        if let n = ata.errorLogCount, n > 0 {
            b.add("ata.errorlog", n > 50 ? .warning : .watch, .errors, "\(n) ATA errors logged",
                  "The drive recorded command errors in its SMART error log.")
            b.penalize(Double(n), scale: 200)
        }

        if let status = ata.selfTestStatus {
            let d = ATAParser.selfTestDescription(status)
            if status >> 4 != 0 || d.severity > .good {
                b.append("ata.selftest", d.severity, .test, d.text,
                         d.severity >= .warning ? String(localized: "The drive's built-in diagnostic found a problem.")
                                                : String(localized: "Result of the drive's built-in diagnostic."),
                         rec: d.severity >= .warning ? String(localized: "Back up now.") : nil, cap: d.severity >= .critical ? 30 : nil)
            }
        }

        if isSSD {
            if let used = m.wearUsedPercent {
                addWearFinding(used: used, into: &b)
                base = max(0, 100 - used)
            } else {
                b.add("wear.unknown", .info, .wear, "Wear indicator not reported",
                      "This SSD does not expose a recognized remaining-life attribute.")
            }
        } else if let hours = m.powerOnHours {
            // Age: HDD failure rates climb noticeably after ~4–5 years of operation.
            let years = hours / 8766
            if hours > 61_000 {
                b.add("age.old", .warning, .age, "Very old drive (\(years.fixed(1)) years powered on)",
                      "Most hard drives are designed for about 5 years of service; failure rates rise steeply beyond that.",
                      rec: "Plan a replacement and keep backups current.")
            } else if hours > 43_800 {
                b.add("age.aging", .watch, .age, "Aging drive (\(years.fixed(1)) years powered on)",
                      "Beyond the typical 5-year design life of hard drives, failure rates rise.")
            }
            if hours > 35_000 { b.factors.append(max(0.6, 1 - (hours - 35_000) / 100_000)) }
        }
        return base
    }

    // MARK: - I/O counters

    static func analyzeIO(_ io: IOStatistics, snapshot s: DriveSnapshot, into b: inout Builder) {
        let errors = io.totalErrors
        if errors > 0 {
            let severe = errors >= 10
            let ioRec: String.LocalizationValue = severe
                ? "Back up now; the drive is failing requests."
                : "Back up important data. If errors keep increasing the drive or its connection is failing."
            b.add("io.errors", severe ? .critical : .warning, .errors,
                  "\(errors.clampedInt) I/O errors since connected",
                  "macOS recorded failed requests on this drive after all retries were exhausted (reads: \(io.readErrors.clampedInt), writes: \(io.writeErrors.clampedInt)).",
                  rec: ioRec,
                  cap: severe ? 40 : 70)
            b.penalize(Double(errors), scale: 10)
        } else if io.totalOperations > 0 {
            b.add("io.ok", .good, .errors, "No I/O errors since connected",
                  "\(io.totalOperations.clampedInt) operations completed without a failed request.")
        }
        let retries = io.totalRetries
        if retries > 0 {
            b.add("io.retries", retries >= 100 ? .warning : .watch, .errors, "\(retries.clampedInt) I/O retries since connected",
                  "Requests had to be retried before they succeeded — a sign of marginal sectors, a weak connection or power issues.")
            b.penalize(Double(retries), scale: 500)
        }
        let latencies = [io.averageReadLatencyMs, io.averageWriteLatencyMs].compactMap { $0 }
        if let worst = latencies.max(), worst > (s.medium == .rotational ? 120 : 100), io.totalOperations > 1000 {
            b.add("io.latency", .watch, .errors, "Unusually slow I/O responses",
                  "Average response time is \(Int(worst.rounded())) ms per operation. Very slow responses can indicate internal retries on weak sectors.")
        }
    }

    // MARK: - Surface scan

    static func analyzeScan(_ scan: SurfaceScanResult, into b: inout Builder) {
        let when = scan.date.formatted(date: .abbreviated, time: .omitted)
        if scan.readErrors > 0 {
            b.add("scan.errors", .critical, .test, "\(scan.readErrors) unreadable regions found",
                  "The surface read test (\(when)) could not read \(scan.readErrors) of \(scan.completedSamples) sampled regions.",
                  rec: "Back up now. Unreadable areas indicate failing media.", cap: 30)
            b.penalize(Double(scan.readErrors), scale: 2)
        }
        if scan.verySlowReads > 0 {
            b.add("scan.veryslow", .warning, .test, "\(scan.verySlowReads) very slow regions (> 1 s)",
                  "Regions that took over a second to read usually needed many internal retries — typical of weak or degrading sectors.",
                  rec: "Back up important data and re-run the test to see whether the count grows.", cap: 75)
            b.penalize(Double(scan.verySlowReads), scale: 20)
        }
        let slowShare = scan.completedSamples > 0 ? Double(scan.slowReads) / Double(scan.completedSamples) : 0
        if scan.slowReads > 0, slowShare >= 0.01, scan.verySlowReads == 0 {
            b.add("scan.slow", .watch, .test, "\(scan.slowReads) slow regions",
                  "\((slowShare * 100).fixed(1))% of sampled regions were much slower than the drive's median (\(Int(scan.medianLatencyMs.rounded())) ms).")
        }
        if scan.readErrors == 0, scan.verySlowReads == 0, slowShare < 0.01 {
            b.add("scan.ok", .good, .test, "Surface read test passed",
                  "\(scan.completedSamples) regions read on \(when) with no errors (median \(scan.medianLatencyMs.fixed(1)) ms, \(Int(scan.throughputMBps.rounded())) MB/s).")
        }
    }

    // MARK: - Temperature

    public static func temperatureLimits(for s: DriveSnapshot) -> (warning: Double, critical: Double, low: Double?) {
        if case let .nvme(_, info?) = s.smart {
            let w = Double(info.warningTemperatureKelvin) - 273.15
            let c = Double(info.criticalTemperatureKelvin) - 273.15
            let warning = (50...100).contains(w) ? w : 70
            let critical = (warning + 1...110).contains(c) ? c : warning + 10
            return (warning, critical, nil)
        }
        if case .nvme = s.smart { return (70, 80, nil) }
        switch s.medium {
        case .rotational: return (50, 60, 5)
        case .solidState: return (65, 75, nil)
        case .flash: return (60, 70, nil)
        case .unknown: return (55, 65, 5)
        }
    }

    static func analyzeTemperature(_ s: DriveSnapshot, metrics m: DriveMetrics, into b: inout Builder) -> TemperatureAssessment? {
        guard let t = m.temperatureC else { return nil }
        let limits = temperatureLimits(for: s)
        let text = "\(Int(t.rounded())) °C"
        let criticalLimit = Int(limits.critical.rounded()), warningLimit = Int(limits.warning.rounded())
        if t >= limits.critical {
            b.add("temp.critical", .warning, .temperature, "Critical temperature (\(text))",
                  "Above the \(criticalLimit) °C critical limit. Sustained heat accelerates wear and can cause data errors or throttling.",
                  rec: "Improve airflow, reduce load, or move the drive away from heat sources.")
        } else if t >= limits.warning {
            b.add("temp.high", .watch, .temperature, "Running hot (\(text))",
                  "Above the recommended \(warningLimit) °C.",
                  rec: "Improve airflow around the drive.")
        } else if let low = limits.low, t < low {
            b.add("temp.low", .watch, .temperature, "Very cold (\(text))", "Operating hard drives below 5 °C increases mechanical stress.")
        } else {
            b.add("temp.ok", .good, .temperature, "Temperature normal (\(text))",
                  "Within the safe range (below \(warningLimit) °C).")
        }
        return TemperatureAssessment(currentC: t, warningC: limits.warning, criticalC: limits.critical,
                                     lifetimeMinC: m.temperatureMinC, lifetimeMaxC: m.temperatureMaxC)
    }

    // MARK: - Interface

    static func analyzeInterface(_ s: DriveSnapshot, into b: inout Builder) {
        if let usb = s.usb, usb.isRunningBelowCapability {
            b.add("usb.slowlink", .info, .interface, "Connected at USB 2.0 speed",
                  "This USB 3 device negotiated only \(usb.speedDescription ?? "USB 2.0"). Transfers will be slow.",
                  rec: "Use a USB 3 port and cable directly on the Mac.")
        }
        if case let .ata(ata) = s.smart, let id = ata.identify,
           let supported = id.sataGenerationSupported, let current = id.sataGenerationCurrent, current < supported {
            b.add("sata.slowlink", .info, .interface, "SATA link below maximum speed",
                  "Running at \(ATAIdentify.sataSpeedName(current)) although the drive supports \(ATAIdentify.sataSpeedName(supported)).")
        }
    }

    // MARK: - Trends

    static func analyzeTrends(current m: DriveMetrics, history: DriveHistory, now: Date, into b: inout Builder) {
        let windowStart = now.addingTimeInterval(-30 * 86_400)
        let window = history.points.filter { $0.date >= windowStart && $0.date < now }
        guard let baseline = window.first ?? history.points.first(where: { $0.date < now }) else { return }
        let since = baseline.date.formatted(date: .abbreviated, time: .omitted)

        func growth(_ current: Int?, _ past: Int?) -> Int? {
            guard let c = current, let p = past, c > p else { return nil }
            return c - p
        }

        if let d = growth(m.reallocatedSectors, baseline.reallocatedSectors) {
            let severe = d >= 5
            b.add("trend.realloc", severe ? .critical : .warning, .trend, "Reallocated sectors increasing (+\(d))",
                  "Grew from \(baseline.reallocatedSectors ?? 0) to \(m.reallocatedSectors ?? 0) since \(since). Actively growing defects indicate progressive media failure.",
                  rec: "Back up now and plan a replacement.", cap: severe ? 35 : 65)
        }
        if let d = growth(m.pendingSectors, baseline.pendingSectors) {
            b.add("trend.pending", .critical, .trend, "Pending sectors increasing (+\(d))",
                  "Grew from \(baseline.pendingSectors ?? 0) to \(m.pendingSectors ?? 0) since \(since).",
                  rec: "Back up now — the drive is developing unreadable areas.", cap: 30)
        }
        if let d = growth(m.offlineUncorrectable, baseline.offlineUncorrectable) {
            b.add("trend.offline", .critical, .trend, "Uncorrectable sectors increasing (+\(d))",
                  "Grew from \(baseline.offlineUncorrectable ?? 0) to \(m.offlineUncorrectable ?? 0) since \(since).",
                  rec: "Back up now.", cap: 30)
        }
        if let d = growth(m.reportedUncorrectable, baseline.reportedUncorrectable) {
            b.add("trend.reported", d >= 5 ? .critical : .warning, .trend, "Uncorrectable read errors increasing (+\(d))",
                  "Grew since \(since).", rec: "Back up important data.", cap: d >= 5 ? 40 : 70)
        }
        if let c = m.mediaErrors, let p = baseline.mediaErrors, c > p {
            b.add("trend.media", .critical, .trend, "Media errors increasing (+\((c - p).clampedInt))",
                  "NVMe media & data integrity errors grew from \(p.clampedInt) to \(c.clampedInt) since \(since).",
                  rec: "Back up now and plan a replacement.", cap: 35)
        }
        if let c = m.availableSpare, let p = baseline.availableSpare, p - c >= 3 {
            b.add("trend.spare", .warning, .trend, "Spare capacity dropping (−\(p - c)%)",
                  "Available spare fell from \(p)% to \(c)% since \(since).", rec: "Plan a replacement.", cap: 70)
        }
        if let c = m.wearUsedPercent, let p = baseline.wearUsedPercent, c - p >= 2 {
            let days = now.timeIntervalSince(baseline.date) / 86_400
            if days >= 7 {
                let perDay = (c - p) / days
                let remainingDays = max(0, 100 - c) / perDay
                if remainingDays < 365 {
                    let increase = Int((c - p).rounded()), span = Int(days.rounded())
                    let remaining = LifeEstimate.duration(days: remainingDays)
                    b.add("trend.wear", .warning, .trend, "Wearing out quickly",
                          "Wear increased \(increase)% in \(span) days; at this rate rated endurance is exhausted in about \(remaining).",
                          rec: "Reduce write-heavy workloads (swap, caches, video editing scratch) or plan a replacement.")
                }
            }
        }
    }

    // MARK: - Text

    static func headline(for status: HealthStatus, limited: Bool) -> String {
        switch status {
        case .excellent: return limited ? String(localized: "No problems detected") : String(localized: "Excellent condition")
        case .good: return limited ? String(localized: "No problems detected") : String(localized: "Healthy")
        case .watch: return String(localized: "Minor issues — keep an eye on it")
        case .degraded: return String(localized: "Degraded — back up your data")
        case .failing: return String(localized: "Pre-failure — may fail soon")
        case .failed: return String(localized: "Failed — copy data off now")
        case .unknown: return String(localized: "Health unknown")
        }
    }

    static func summary(for status: HealthStatus, findings: [Finding], limited: Bool) -> String {
        let problems = findings.filter { $0.severity >= .watch }
        var text: String
        switch status {
        case .excellent, .good:
            text = problems.isEmpty ? String(localized: "All monitored health indicators are within normal ranges.")
                                    : String(localized: "The drive is healthy overall; \(problems.count) minor items noted.")
        case .watch:
            text = String(localized: "Minor issues were detected. The drive is usable, but monitor it and keep backups current.")
        case .degraded:
            text = String(localized: "The drive shows signs of degradation. Back up important data and monitor it closely.")
        case .failing:
            text = String(localized: "Pre-failure indicators detected. This drive is at high risk of failing soon — back up now and plan a replacement.")
        case .failed:
            text = String(localized: "The drive reports a failure condition. Copy your data to another drive immediately.")
        case .unknown:
            text = String(localized: "Not enough information to assess this drive.")
        }
        if limited, status != .unknown {
            text += " " + String(localized: "S.M.A.R.T. is not accessible for this drive, so the assessment is based on I/O counters and tests only.")
        }
        return text
    }

    // MARK: - Builder

    struct Builder {
        var findings: [Finding] = []
        var factors: [Double] = []

        /// Text arguments are localization keys (English source text); they are resolved here.
        mutating func add(_ id: String, _ severity: Severity, _ category: FindingCategory,
                          _ title: String.LocalizationValue, _ detail: String.LocalizationValue,
                          rec: String.LocalizationValue? = nil, cap: Int? = nil) {
            append(id, severity, category, String(localized: title), String(localized: detail),
                   rec: rec.map { String(localized: $0) }, cap: cap)
        }

        /// For text that is already localized (e.g. produced by another component).
        mutating func append(_ id: String, _ severity: Severity, _ category: FindingCategory,
                             _ title: String, _ detail: String, rec: String? = nil, cap: Int? = nil) {
            findings.removeAll { $0.id == id }
            findings.append(Finding(id: id, severity: severity, category: category, title: title,
                                    detail: detail, recommendation: rec, healthCap: cap))
        }

        mutating func penalize(_ count: Double, scale: Double) {
            guard count > 0, scale > 0 else { return }
            factors.append(1 / (1 + count / scale))
        }
    }
}
