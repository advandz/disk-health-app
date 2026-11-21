//
//  ReportContent.swift
//  Disk Health
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import Charts
import DiskHealthCore
import SwiftUI

/// One unbreakable piece of the PDF report. The paginator never splits a block across pages, so
/// long content (findings, attribute tables) is emitted as several blocks.
struct ReportBlock {
    let view: AnyView
    /// Keeps a heading on the same page as the block that follows it.
    var keepWithNext = false

    init(_ view: some View, keepWithNext: Bool = false) {
        self.view = AnyView(view)
        self.keepWithNext = keepWithNext
    }
}

/// Builds the report for one drive out of the same views the app shows, rendered flat and light.
@MainActor
enum ReportContent {
    static func blocks(for entry: DriveStore.Entry, unit: TemperatureUnit) -> [ReportBlock] {
        let s = entry.snapshot
        let report = entry.report
        var blocks: [ReportBlock] = []

        if s.isSample { blocks.append(ReportBlock(SampleBanner())) }
        blocks.append(ReportBlock(ReportDriveHeader(entry: entry, unit: unit)))
        blocks.append(ReportBlock(ReportTileGrid(tiles: MetricsGrid.makeTiles(entry: entry, unit: unit))))

        // Findings: one block each, so a long list flows across pages.
        let problems = report.findings.filter { $0.severity >= .watch }
        let notes = report.findings.filter { $0.severity == .info }
        let passed = report.findings.filter { $0.severity == .good }
        blocks.append(ReportBlock(
            ReportHeading(title: "Health Assessment", symbol: "stethoscope", tint: report.status.color,
                          trailing: String(localized: "\(problems.count) issues") + " · " + String(localized: "\(passed.count) passed")),
            keepWithNext: true))
        if problems.isEmpty {
            blocks.append(ReportBlock(
                Label("No problems found across \(report.findings.count) health checks.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(HealthStatus.excellent.color)
                    .font(.callout.weight(.medium))))
        }
        for finding in problems + notes {
            blocks.append(ReportBlock(FindingRow(finding: finding)))
        }
        if !passed.isEmpty {
            blocks.append(ReportBlock(
                Text("\(passed.count) checks passed")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12),
                keepWithNext: true))
            for finding in passed {
                blocks.append(ReportBlock(FindingRow(finding: finding, compact: true).padding(.horizontal, 12)))
            }
        }

        blocks.append(ReportBlock(LifeSection(entry: entry)))
        blocks.append(ReportBlock(UsageSection(snapshot: s)))
        blocks.append(ReportBlock(TemperatureHistorySection(entry: entry, unit: unit)))
        if let scan = entry.history.lastSurfaceScan {
            blocks.append(ReportBlock(GlassSection(title: "Surface Read Test", symbol: "waveform.path.ecg") {
                ScanResultView(result: scan)
            }))
        }

        switch s.smart {
        case let .ata(ata):
            blocks.append(ReportBlock(
                ReportHeading(title: "S.M.A.R.T. Attributes", symbol: "list.bullet.rectangle", tint: nil,
                              trailing: overallText(ata.overallPassed)),
                keepWithNext: true))
            if let status = ata.selfTestStatus {
                let d = ATAParser.selfTestDescription(status)
                blocks.append(ReportBlock(
                    Label(d.text, systemImage: d.severity.symbolName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(d.severity >= .watch ? d.severity.color : .secondary),
                    keepWithNext: true))
            }
            // Repeat the column header on every chunk so each page's table reads on its own.
            let chunkSize = 12
            for start in stride(from: 0, to: ata.attributes.count, by: chunkSize) {
                let rows = Array(ata.attributes[start..<min(start + chunkSize, ata.attributes.count)])
                blocks.append(ReportBlock(ReportAttributeTable(attributes: rows)))
            }
        case let .nvme(log, info):
            blocks.append(ReportBlock(NVMeLogSection(log: log, info: info, unit: unit)))
        case .unavailable:
            break
        }

        blocks.append(ReportBlock(IOStatsSection(io: s.io)))
        blocks.append(ReportBlock(DeviceInfoSection(entry: entry)))
        if !report.dataSources.isEmpty {
            blocks.append(ReportBlock(ReportDataSources(sources: report.dataSources)))
        }
        return blocks
    }

    private static func overallText(_ passed: Bool?) -> String {
        switch passed {
        case nil: return String(localized: "Overall status: not reported")
        case true?: return String(localized: "Overall self-assessment: PASSED")
        case false?: return String(localized: "Overall self-assessment: FAILED")
        }
    }
}

// MARK: - Report-only views

/// Drive identity, status and the three headline numbers.
struct ReportDriveHeader: View {
    let entry: DriveStore.Entry
    let unit: TemperatureUnit

    var body: some View {
        let s = entry.snapshot
        let report = entry.report
        let m = entry.metrics
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 22) {
                ReportHealthGauge(percent: report.healthPercent, status: report.status)
                    .frame(width: 112, height: 112)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: s.kind.symbolName)
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name).font(.title2.weight(.bold))
                            Text(verbatim: [s.kind.displayName, s.subtitle].joined(separator: " · "))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 8) {
                        Label(report.status.title, systemImage: report.status.symbolName)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(report.status.color)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .glassCapsule(tint: report.status.color)
                        Label(report.confidence.label, systemImage: "gauge.with.dots.needle.67percent")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .glassCapsule()
                    }
                    Text(report.headline).font(.title3.weight(.semibold))
                    Text(report.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                HeroStat(symbol: "hourglass", title: "Estimated Life Remaining", value: report.life.label,
                         detail: report.life.confidence == .none ? String(localized: "Not enough data") : report.life.confidence.label,
                         tint: report.status == .failing || report.status == .failed ? report.status.color : .accentColor)
                HeroStat(symbol: "thermometer.medium", title: "Temperature",
                         value: Format.temperature(m.temperatureC, unit: unit),
                         detail: report.temperature.map { String(localized: "Warning at \(Format.temperature($0.warningC, unit: unit))") }
                            ?? String(localized: "Not reported"),
                         tint: .teal)
                HeroStat(symbol: "power", title: "Powered On", value: Format.hours(m.powerOnHours),
                         detail: m.powerOnHours.map { Format.duration(hours: $0) } ?? String(localized: "Not reported"),
                         tint: .indigo)
            }
        }
        .padding(18)
        .glassSurface(cornerRadius: 20, tint: report.status.color)
    }
}

/// A static version of the app's health ring (the app's ring animates in on appear, which an
/// offscreen render never runs).
struct ReportHealthGauge: View {
    let percent: Int?
    let status: HealthStatus

    var body: some View {
        ZStack {
            Circle().stroke(status.color.opacity(0.16), lineWidth: 12)
            Circle()
                .trim(from: 0, to: Double(percent ?? 0) / 100)
                .stroke(status.color, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(verbatim: percent.map { "\($0)" } ?? "—")
                        .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                    if percent != nil {
                        Text(verbatim: "%").font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                    }
                }
                Text("Health").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
        }
        .padding(6)
    }
}

/// Metric tiles in a fixed three-column grid (lazy grids don't render offscreen).
struct ReportTileGrid: View {
    let tiles: [MetricsGrid.Tile]

    var body: some View {
        let rows = stride(from: 0, to: tiles.count, by: 3).map { Array(tiles[$0..<min($0 + 3, tiles.count)]) }
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            ForEach(rows.indices, id: \.self) { index in
                GridRow {
                    ForEach(rows[index]) { MetricTileView(tile: $0) }
                    ForEach(0..<(3 - rows[index].count), id: \.self) { _ in Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                }
            }
        }
    }
}

struct ReportHeading: View {
    let title: LocalizedStringKey
    let symbol: String
    let tint: Color?
    var trailing: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.headline).foregroundStyle(tint ?? .secondary)
            Text(title).font(.headline)
            Spacer(minLength: 8)
            if let trailing {
                Text(verbatim: trailing).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 6)
    }
}

/// Compact S.M.A.R.T. attribute table sized for a printed page.
struct ReportAttributeTable: View {
    let attributes: [ATAAttribute]

    var body: some View {
        VStack(spacing: 0) {
            row(id: Text("ID"), name: Text("Attribute"), value: Text("Value"), worst: Text("Worst"),
                threshold: Text("Thresh"), raw: Text("Raw"), type: Text("Type"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
            ForEach(attributes) { a in
                Divider().opacity(0.5)
                let severity = a.displaySeverity
                row(id: Text(verbatim: "\(a.id)"), name: Text(a.name), value: Text(verbatim: "\(a.current)"),
                    worst: Text(verbatim: "\(a.worst)"), threshold: Text(verbatim: a.threshold.map(String.init) ?? "—"),
                    raw: Text(a.displayRaw), type: Text(a.isPrefail ? "Pre-fail" : "Old-age"))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(severity >= .warning ? severity.color : .primary)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 4)
                    .background(severity >= .watch ? severity.color.opacity(0.08) : .clear)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassSurface(cornerRadius: 14)
    }

    private func row(id: Text, name: Text, value: Text, worst: Text, threshold: Text, raw: Text, type: Text) -> some View {
        HStack(spacing: 8) {
            id.frame(width: 30, alignment: .leading)
            name.lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            value.frame(width: 44, alignment: .trailing)
            worst.frame(width: 44, alignment: .trailing)
            threshold.frame(width: 50, alignment: .trailing)
            raw.lineLimit(1).frame(width: 130, alignment: .trailing)
            type.lineLimit(1).frame(width: 70, alignment: .trailing)
        }
    }
}

struct ReportDataSources: View {
    let sources: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Data Sources").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(sources, id: \.self) { source in
                Text(verbatim: "• " + source).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}

/// Running header and footer drawn on every page.
struct ReportPageChrome: View {
    let driveName: String
    let generated: Date
    let page: Int
    let pageCount: Int
    let size: CGSize

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Disk Health Report", systemImage: "internaldrive")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(verbatim: driveName).font(.caption).foregroundStyle(.secondary)
            }
            Divider().padding(.top, 6)
            Spacer()
            Divider().padding(.bottom, 6)
            HStack {
                Text("Generated \(generated.formatted(date: .long, time: .shortened))")
                Spacer()
                Text("Page \(page) of \(pageCount)")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(width: size.width, height: size.height)
    }
}
