//
//  DetailSections.swift
//  Disk Health
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import Charts
import DiskHealthCore
import SwiftUI

// MARK: - Findings

struct FindingsSection: View {
    let report: HealthReport
    @State private var showPassed = false

    var body: some View {
        let problems = report.findings.filter { $0.severity >= .watch }
        let notes = report.findings.filter { $0.severity == .info }
        let passed = report.findings.filter { $0.severity == .good }

        GlassSection(title: "Health Assessment", symbol: "stethoscope", tint: report.status.color) {
            Text(verbatim: String(localized: "\(problems.count) issues") + " · " + String(localized: "\(passed.count) passed"))
                .font(.caption)
                .foregroundStyle(.secondary)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                if problems.isEmpty {
                    Label("No problems found across \(report.findings.count) health checks.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(HealthStatus.excellent.color)
                        .font(.callout.weight(.medium))
                }
                ForEach(problems) { FindingRow(finding: $0) }
                ForEach(notes) { FindingRow(finding: $0) }
                if !passed.isEmpty {
                    DisclosureGroup(isExpanded: $showPassed) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(passed) { FindingRow(finding: $0, compact: true) }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text("\(passed.count) checks passed")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct FindingRow: View {
    let finding: Finding
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: finding.severity.symbolName)
                .font(compact ? .body : .title3)
                .foregroundStyle(finding.severity.color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(finding.title)
                        .font(compact ? .callout : .callout.weight(.semibold))
                    Spacer(minLength: 8)
                    if !compact {
                        Text(verbatim: finding.severity == .info ? finding.category.displayName
                                                                 : "\(finding.severity.label) · \(finding.category.displayName)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(finding.severity.color)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(finding.severity.color.opacity(0.14), in: Capsule())
                    }
                }
                Text(finding.detail)
                    .font(compact ? .caption : .callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let rec = finding.recommendation, !compact {
                    Label(rec, systemImage: "lightbulb.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(finding.severity >= .warning ? finding.severity.color : .secondary)
                        .padding(.top, 2)
                }
            }
        }
        .padding(compact ? 0 : 12)
        .background {
            if !compact {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(finding.severity.color.opacity(finding.severity >= .watch ? 0.09 : 0.04))
            }
        }
    }
}

// MARK: - Life

struct LifeSection: View {
    let entry: DriveStore.Entry

    var body: some View {
        let life = entry.report.life
        let m = entry.metrics
        GlassSection(title: "Remaining Life", symbol: "hourglass") {
            Text(life.confidence.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(life.confidence.color)
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                Text(life.label)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                if let pct = life.lifeRemainingPercent {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressBar(fraction: pct / 100, color: barColor(pct))
                        Text("\(Format.percent(pct)) of rated write endurance remaining")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(life.method)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if life.projectedEnduranceBytes != nil || m.bytesWritten != nil {
                    Divider()
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        if let w = m.bytesWritten { KVRow("Written so far", Format.bytes(w)) }
                        if let p = life.projectedEnduranceBytes { KVRow("Projected endurance", Format.bytes(p)) }
                        if let r = life.remainingEnduranceBytes { KVRow("Remaining writes", Format.bytes(r)) }
                        if let d = life.dutyHoursPerDay {
                            KVRow("Usage", life.dutyCycleObserved ? String(localized: "\(d.fixed(1)) h/day (observed)")
                                                                  : String(localized: "\(d.fixed(1)) h/day (assumed)"))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func barColor(_ pct: Double) -> Color {
        pct < 10 ? HealthStatus.failing.color : pct < 25 ? HealthStatus.degraded.color : pct < 50 ? HealthStatus.watch.color : HealthStatus.excellent.color
    }
}

struct ProgressBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.75), color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
    }
}

struct KVRow: View {
    let key: LocalizedStringKey
    let value: String
    var monospaced = false

    init(_ key: LocalizedStringKey, _ value: String, monospaced: Bool = false) {
        self.key = key
        self.value = value
        self.monospaced = monospaced
    }

    var body: some View {
        GridRow {
            Text(key)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(verbatim: value)
                .font(monospaced ? .callout.monospaced() : .callout.monospacedDigit())
                .textSelection(.enabled)
                .gridColumnAlignment(.leading)
        }
        .font(.callout)
    }
}

// MARK: - Usage

struct UsageSection: View {
    let snapshot: DriveSnapshot

    var body: some View {
        GlassSection(title: "Disk Usage", symbol: "chart.pie") {
            VStack(alignment: .leading, spacing: 14) {
                if let usage = snapshot.usage {
                    let fraction = usage.total > 0 ? Double(usage.used) / Double(usage.total) : 0
                    HStack(alignment: .firstTextBaseline) {
                        Text(Format.bytes(usage.used))
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                        Text("of \(Format.bytes(usage.total)) used")
                            .foregroundStyle(.secondary)
                    }
                    ProgressBar(fraction: fraction, color: fraction > 0.9 ? HealthStatus.degraded.color : .accentColor)
                    ForEach(snapshot.volumes) { volume in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: volume.mountPoint == "/" ? "laptopcomputer" : "folder.fill")
                                    .foregroundStyle(.secondary)
                                Text(volume.name).font(.callout.weight(.medium))
                                Text(volume.fileSystemDescription ?? volume.fileSystem.uppercased())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(Format.bytes(volume.availableBytes)) free")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            ProgressBar(fraction: volume.usedFraction,
                                        color: volume.usedFraction > 0.9 ? HealthStatus.degraded.color : .accentColor.opacity(0.8),
                                        height: 6)
                        }
                    }
                    if fraction > 0.9 {
                        Label("Keeping at least 10–15% free helps SSD wear-leveling and file-system performance.",
                              systemImage: "lightbulb")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No mounted volumes on this drive.")
                        .foregroundStyle(.secondary)
                    Text("Capacity: \(Format.capacity(snapshot.capacityBytes))")
                        .font(.callout)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Temperature history

struct TemperatureHistorySection: View {
    let entry: DriveStore.Entry
    let unit: TemperatureUnit
    @Environment(\.isReportRendering) private var isReport

    var body: some View {
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        let points = entry.history.points.filter { $0.temperatureC != nil && $0.date >= cutoff }
        if points.count >= 2 {
            let values = points.compactMap(\.temperatureC)
            let convert: (Double) -> Double = { unit == .celsius ? $0 : $0 * 9 / 5 + 32 }
            let warning = entry.report.temperature?.warningC
            GlassSection(title: "Temperature History", symbol: "chart.xyaxis.line") {
                Text("min \(Format.temperature(values.min(), unit: unit)) · avg \(Format.temperature(values.reduce(0, +) / Double(values.count), unit: unit)) · max \(Format.temperature(values.max(), unit: unit))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } content: {
                Chart {
                    ForEach(points, id: \.date) { p in
                        AreaMark(x: .value("Time", p.date), y: .value("Temperature", convert(p.temperatureC ?? 0)))
                            // Gradients with transparency don't survive PDF rendering; print a flat tint.
                            .foregroundStyle(isReport ? AnyShapeStyle(Color.orange.opacity(0.14))
                                                      : AnyShapeStyle(LinearGradient(colors: [.orange.opacity(0.35), .orange.opacity(0.02)],
                                                                                     startPoint: .top, endPoint: .bottom)))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Time", p.date), y: .value("Temperature", convert(p.temperatureC ?? 0)))
                            .foregroundStyle(.orange)
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    if let warning, (values.max() ?? 0) > warning - 15 {
                        RuleMark(y: .value("Warning", convert(warning)))
                            .foregroundStyle(HealthStatus.degraded.color.opacity(0.8))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                            .annotation(position: .top, alignment: .trailing) {
                                Text("Warning").font(.caption2).foregroundStyle(HealthStatus.degraded.color)
                            }
                    }
                }
                .chartYAxisLabel { Text(verbatim: unit == .celsius ? "°C" : "°F") }
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 180)
            }
        }
    }
}

// MARK: - Surface scan

struct SurfaceScanSection: View {
    @Environment(DriveStore.self) private var store
    let entry: DriveStore.Entry

    var body: some View {
        let scan = store.scans[entry.id]
        let last = entry.history.lastSurfaceScan
        let busy = scan.map { store.isActive($0.phase) } ?? false

        GlassSection(title: "Surface Read Test", symbol: "waveform.path.ecg") {
            if busy {
                Button("Stop", role: .cancel) { store.cancelScan(entry) }
                    .glassButton()
            } else {
                HStack(spacing: 8) {
                    ForEach(SurfaceScanner.Mode.allCases, id: \.self) { mode in
                        Button {
                            store.startScan(entry, mode: mode)
                        } label: {
                            Label(mode.title, systemImage: mode == .quick ? "bolt.fill" : "scope")
                        }
                        .glassButton(prominent: mode == .quick)
                        .help(mode.detail)
                        .disabled(entry.snapshot.isSample)
                    }
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                Text("Reads evenly distributed regions across the entire drive and times each read to find unreadable or weak areas. Read-only and safe for mounted drives; macOS asks for administrator authorization to open the raw device.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let scan {
                    switch scan.phase {
                    case .authorizing:
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Waiting for authorization…").foregroundStyle(.secondary)
                        }
                    case let .running(completed, total, errors, slow, mbps):
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: Double(completed), total: Double(max(total, 1)))
                            Text("\(scan.mode.title): \(completed) of \(total) regions · errors: \(errors) · slow: \(slow) · \(Int(mbps)) MB/s")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(errors > 0 ? HealthStatus.failing.color : .secondary)
                        }
                    case let .failed(message):
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(HealthStatus.degraded.color)
                    case let .discarded(message):
                        Label(message, systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    case .finished:
                        EmptyView()
                    }
                }

                if let last {
                    ScanResultView(result: last)
                } else if !busy {
                    Text(entry.snapshot.smart.isAvailable
                         ? "No test has been run yet. S.M.A.R.T. already covers most media problems; the test adds a direct check of read performance."
                         : "No test has been run yet. Because S.M.A.R.T. is unavailable for this drive, a surface test is the best way to check its media.")
                        .font(.callout.weight(.medium))
                }
            }
        }
    }
}

struct ScanResultView: View {
    let result: SurfaceScanResult

    private var resultLine: String {
        let date = result.date.formatted(date: .abbreviated, time: .shortened)
        var line = String(localized: "\(result.mode.title) on \(date)")
        if result.cancelled { line += " " + String(localized: "(stopped early)") }
        return line + " · " + String(localized: "\(result.completedSamples) regions in \(Int(result.duration)) s")
    }

    var body: some View {
        let ok = result.readErrors == 0 && result.verySlowReads == 0
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: ok ? "checkmark.seal.fill" : "exclamationmark.octagon.fill")
                    .font(.title2)
                    .foregroundStyle(ok ? HealthStatus.excellent.color : HealthStatus.failing.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ok ? String(localized: "No unreadable or weak regions found")
                            : String(localized: "Unreadable regions: \(result.readErrors) · very slow: \(result.verySlowReads)"))
                        .font(.callout.weight(.semibold))
                    Text(verbatim: resultLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top, spacing: 24) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    KVRow("Median latency", Format.latency(result.medianLatencyMs))
                    KVRow("95th percentile", Format.latency(result.p95LatencyMs))
                    KVRow("Slowest read", Format.latency(result.maxLatencyMs))
                    KVRow("Throughput", "\(Int(result.throughputMBps.rounded()).formatted()) MB/s")
                    KVRow("Slow regions", result.slowReads.formatted())
                }
                .fixedSize()
                Chart {
                    ForEach(Array(result.latencyBuckets.enumerated()), id: \.offset) { index, count in
                        BarMark(x: .value("Latency", SurfaceScanner.bucketLabels[index]), y: .value("Regions", count))
                            .foregroundStyle(index >= 5 ? HealthStatus.failing.color : index >= 4 ? HealthStatus.degraded.color : Color.accentColor)
                            .cornerRadius(4)
                    }
                }
                .chartYScale(type: .symmetricLog)
                .chartXAxisLabel("Read latency per 1 MiB region")
                .frame(height: 130)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.primary.opacity(0.04)))
    }
}

// MARK: - ATA attributes

struct ATAAttributesSection: View {
    @Environment(DriveStore.self) private var store
    let entry: DriveStore.Entry
    let ata: ATAHealthData

    var body: some View {
        GlassSection(title: "S.M.A.R.T. Attributes", symbol: "list.bullet.rectangle") {
            if entry.snapshot.supportsSelfTest {
                Menu {
                    Button(ata.shortTestMinutes.map { String(localized: "Short Self-Test (~\($0) min)") } ?? String(localized: "Short Self-Test")) {
                        store.startSelfTest(entry, extended: false)
                    }
                    Button(ata.extendedTestMinutes.map { String(localized: "Extended Self-Test (~\($0) min)") } ?? String(localized: "Extended Self-Test")) {
                        store.startSelfTest(entry, extended: true)
                    }
                } label: {
                    Label("Run Self-Test", systemImage: "play.circle")
                }
                .fixedSize()
                .disabled(entry.snapshot.isSample || ata.selfTestInProgress)
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 16) {
                    overall
                    if let status = ata.selfTestStatus {
                        let d = ATAParser.selfTestDescription(status)
                        Label(d.text, systemImage: d.severity.symbolName)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(d.severity >= .watch ? d.severity.color : .secondary)
                    }
                }
                if let message = store.selfTestMessages[entry.id] {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                VStack(spacing: 0) {
                    AttributeHeader()
                    ForEach(ata.attributes) { attribute in
                        AttributeRow(attribute: attribute)
                        Divider().opacity(0.4)
                    }
                }
                .font(.callout)
            }
        }
    }

    private var overall: some View {
        let passed = ata.overallPassed
        let text = passed == nil ? String(localized: "Overall status: not reported")
            : passed! ? String(localized: "Overall self-assessment: PASSED") : String(localized: "Overall self-assessment: FAILED")
        return Label(text,
                     systemImage: passed == false ? "xmark.octagon.fill" : "checkmark.shield")
            .font(.caption.weight(.semibold))
            .foregroundStyle(passed == false ? HealthStatus.failed.color : .secondary)
    }
}

struct AttributeHeader: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("ID").frame(width: 34, alignment: .leading)
            Text("Attribute").frame(maxWidth: .infinity, alignment: .leading)
            Text("Value").frame(width: 50, alignment: .trailing)
            Text("Worst").frame(width: 50, alignment: .trailing)
            Text("Thresh").frame(width: 54, alignment: .trailing)
            Text("Raw").frame(width: 170, alignment: .trailing)
            Text("Type").frame(width: 66, alignment: .center)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
    }
}

struct AttributeRow: View {
    let attribute: ATAAttribute

    var body: some View {
        let state = attribute.displaySeverity
        HStack(spacing: 8) {
            Text(verbatim: "\(attribute.id)").monospacedDigit().frame(width: 34, alignment: .leading).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if state > .good {
                    Image(systemName: state.symbolName).foregroundStyle(state.color).font(.caption)
                }
                Text(attribute.name).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(ATAAttributeCatalog.explanation(for: attribute.id) ?? attribute.name)
            Text(verbatim: "\(attribute.current)").monospacedDigit().frame(width: 50, alignment: .trailing)
            Text(verbatim: "\(attribute.worst)").monospacedDigit().frame(width: 50, alignment: .trailing).foregroundStyle(.secondary)
            Text(verbatim: attribute.threshold.map(String.init) ?? "—").monospacedDigit().frame(width: 54, alignment: .trailing).foregroundStyle(.secondary)
            Text(attribute.displayRaw).monospacedDigit().lineLimit(1).frame(width: 170, alignment: .trailing)
                .foregroundStyle(state >= .watch ? state.color : .primary)
            Text(attribute.isPrefail ? "Pre-fail" : "Old-age")
                .font(.caption2.weight(.medium))
                .foregroundStyle(attribute.isPrefail ? .primary : .secondary)
                .frame(width: 66, alignment: .center)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(state >= .watch ? state.color.opacity(0.08) : .clear)
    }

}

extension ATAAttribute {
    /// How strongly a row in the attribute table is highlighted (app and PDF report).
    var displaySeverity: Severity {
        if isFailingNow { return isPrefail ? .failed : .warning }
        if hasFailedInPast { return .warning }
        let counters: Set<Int> = [5, 10, 184, 187, 196, 197, 198]
        if counters.contains(id), raw32 > 0 { return [197, 198].contains(id) ? .critical : .warning }
        if [188, 199].contains(id), raw16 > 0 { return .watch }
        return .good
    }
}

// MARK: - NVMe log

struct NVMeLogSection: View {
    let log: NVMeHealthLog
    let info: NVMeControllerInfo?
    let unit: TemperatureUnit

    var body: some View {
        GlassSection(title: "NVMe Health Information Log", symbol: "list.bullet.rectangle") {
            Text("Log page 02h").font(.caption).foregroundStyle(.secondary)
        } content: {
            let columns = [GridItem(.flexible(), spacing: 24, alignment: .topLeading), GridItem(.flexible(), spacing: 24, alignment: .topLeading)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                    KVRow("Critical warning", criticalWarningText)
                    KVRow("Composite temperature", Format.temperature(log.temperatureCelsius, unit: unit))
                    KVRow("Available spare", "\(log.availableSpare)%")
                    KVRow("Spare threshold", "\(log.availableSpareThreshold)%")
                    KVRow("Percentage used", "\(log.percentageUsed)%")
                    KVRow("Data units read", "\(Format.number(log.dataUnitsRead)) (\(Format.bytes(log.bytesRead)))")
                    KVRow("Data units written", "\(Format.number(log.dataUnitsWritten)) (\(Format.bytes(log.bytesWritten)))")
                    KVRow("Host read commands", Format.number(log.hostReadCommands))
                    KVRow("Host write commands", Format.number(log.hostWriteCommands))
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                    KVRow("Controller busy time", Format.minutes(log.controllerBusyMinutes))
                    KVRow("Power cycles", Format.number(log.powerCycles))
                    KVRow("Power-on hours", Format.number(log.powerOnHours))
                    KVRow("Unsafe shutdowns", Format.number(log.unsafeShutdowns))
                    KVRow("Media & data integrity errors", Format.number(log.mediaErrors))
                    KVRow("Error log entries", Format.number(log.errorLogEntries))
                    KVRow("Warning temp. time", Format.minutes(Double(log.warningTemperatureMinutes)))
                    KVRow("Critical temp. time", Format.minutes(Double(log.criticalTemperatureMinutes)))
                    if !log.temperatureSensorsKelvin.isEmpty {
                        KVRow("Sensors", log.temperatureSensorsKelvin.map { Format.temperature(Double($0) - 273.15, unit: unit) }.joined(separator: ", "))
                    }
                    if let info, info.warningTemperatureKelvin > 0 {
                        KVRow("Temp. thresholds", "\(Format.temperature(Double(info.warningTemperatureKelvin) - 273.15, unit: unit)) / \(Format.temperature(Double(info.criticalTemperatureKelvin) - 273.15, unit: unit))")
                    }
                }
            }
        }
    }

    private var criticalWarningText: String {
        let w = log.warnings
        guard log.criticalWarning != 0 else { return String(localized: "None (0x00)") }
        var parts: [String] = []
        if w.contains(.spareBelowThreshold) { parts.append(String(localized: "spare", comment: "NVMe critical warning bit")) }
        if w.contains(.temperature) { parts.append(String(localized: "temperature", comment: "NVMe critical warning bit")) }
        if w.contains(.reliabilityDegraded) { parts.append(String(localized: "reliability", comment: "NVMe critical warning bit")) }
        if w.contains(.readOnly) { parts.append(String(localized: "read-only", comment: "NVMe critical warning bit")) }
        if w.contains(.volatileBackupFailed) { parts.append(String(localized: "backup", comment: "NVMe critical warning bit")) }
        if w.contains(.persistentMemoryReadOnly) { parts.append("PMR") }
        return String(format: "0x%02X (%@)", log.criticalWarning, parts.joined(separator: ", "))
    }
}

// MARK: - I/O statistics

struct IOStatsSection: View {
    let io: IOStatistics?

    var body: some View {
        GlassSection(title: "I/O Statistics", symbol: "arrow.up.arrow.down.circle") {
            Text("since connected").font(.caption).foregroundStyle(.secondary)
        } content: {
            if let io {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                    KVRow("Read", String(localized: "\(Format.bytes(io.bytesRead)) in \(io.readOperations.clampedInt) ops"))
                    KVRow("Written", String(localized: "\(Format.bytes(io.bytesWritten)) in \(io.writeOperations.clampedInt) ops"))
                    KVRow("Read errors", Format.number(Int(io.readErrors)))
                    KVRow("Write errors", Format.number(Int(io.writeErrors)))
                    KVRow("Retries", String(localized: "\(io.readRetries.clampedInt) read · \(io.writeRetries.clampedInt) write"))
                    KVRow("Avg. read response", Format.latency(io.averageReadLatencyMs))
                    KVRow("Avg. write response", Format.latency(io.averageWriteLatencyMs))
                }
            } else {
                Text("Not available").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Device information

struct DeviceInfoSection: View {
    let entry: DriveStore.Entry

    var body: some View {
        let s = entry.snapshot
        GlassSection(title: "Device", symbol: "info.circle") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                KVRow("Model", s.model)
                if let v = s.vendor { KVRow("Vendor", v) }
                if let serial = s.serial { KVRow("Serial number", serial, monospaced: true) }
                if let fw = s.firmware { KVRow("Firmware", fw, monospaced: true) }
                KVRow("Capacity", String(localized: "\(Format.capacity(s.capacityBytes)) (\(s.capacityBytes.clampedInt) bytes)"))
                KVRow("Interface", s.interface.displayName)
                if let link = s.linkDescription { KVRow("Link", link) }
                KVRow("Media", s.medium.displayName)
                KVRow("Device", String(localized: "/dev/\(s.bsdName) · \(s.logicalBlockSize)-byte blocks"))
                if let trim = s.supportsTrim, s.medium.isSolidState {
                    KVRow("TRIM / Unmap", trim ? String(localized: "Supported") : String(localized: "Not supported"))
                }
                KVRow("Health data", s.smart.protocolName)
                if let usb = s.usb, let vid = usb.vendorID, let pid = usb.productID {
                    KVRow("USB ID", String(format: "%04X:%04X", vid, pid), monospaced: true)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}
