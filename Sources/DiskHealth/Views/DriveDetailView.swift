//
//  DriveDetailView.swift
//  Disk Health
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import DiskHealthCore
import SwiftUI

struct DriveDetailView: View {
    let entry: DriveStore.Entry
    @AppStorage("temperatureUnit") private var unitRaw = TemperatureUnit.celsius.rawValue
    private var unit: TemperatureUnit { TemperatureUnit(rawValue: unitRaw) ?? .celsius }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if entry.snapshot.isSample {
                    SampleBanner()
                }
                HeroCard(entry: entry, unit: unit)
                MetricsGrid(entry: entry, unit: unit)
                FindingsSection(report: entry.report)
                HStack(alignment: .top, spacing: 18) {
                    LifeSection(entry: entry).frame(maxHeight: .infinity, alignment: .top)
                    UsageSection(snapshot: entry.snapshot).frame(maxHeight: .infinity, alignment: .top)
                }
                .fixedSize(horizontal: false, vertical: true)
                TemperatureHistorySection(entry: entry, unit: unit)
                SurfaceScanSection(entry: entry)
                switch entry.snapshot.smart {
                case let .ata(ata): ATAAttributesSection(entry: entry, ata: ata)
                case let .nvme(log, info): NVMeLogSection(log: log, info: info, unit: unit)
                case .unavailable: EmptyView()
                }
                HStack(alignment: .top, spacing: 18) {
                    IOStatsSection(io: entry.snapshot.io).frame(maxHeight: .infinity, alignment: .top)
                    DeviceInfoSection(entry: entry).frame(maxHeight: .infinity, alignment: .top)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        // The title bar is transparent, so content must not scroll underneath the window title.
        // Clip it at the bar's lower edge with a short fade instead.
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: 18)
                Rectangle()
            }
        }
    }
}

struct SampleBanner: View {
    var body: some View {
        Label("Simulated sample drive — data is synthetic and shown to preview how each health state is reported.",
              systemImage: "flask.fill")
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassCapsule(tint: .purple)
    }
}

// MARK: - Hero

struct HeroCard: View {
    let entry: DriveStore.Entry
    let unit: TemperatureUnit

    var body: some View {
        let report = entry.report
        let status = report.status
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 28) {
                HealthRing(percent: report.healthPercent, status: status)
                    .frame(width: 168, height: 168)
                identity
                Spacer(minLength: 0)
                heroStats
                    .frame(width: 230)
            }
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 24) {
                    HealthRing(percent: report.healthPercent, status: status)
                        .frame(width: 140, height: 140)
                    identity
                }
                heroStats
            }
        }
        .padding(24)
        .glassSurface(cornerRadius: 30, tint: status.color)
    }

    private var identity: some View {
        let report = entry.report
        let s = entry.snapshot
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: s.kind.symbolName)
                    .font(.title)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name)
                        .font(.title2.weight(.bold))
                        .lineLimit(2)
                    Text(verbatim: [s.kind.displayName, s.subtitle].joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Label(report.status.title, systemImage: report.status.symbolName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(report.status.color)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassCapsule(tint: report.status.color)
                Label(report.confidence.label, systemImage: "gauge.with.dots.needle.67percent")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .glassCapsule()
                    .help(report.dataSources.joined(separator: "\n"))
            }
            Text(report.headline)
                .font(.title3.weight(.semibold))
            Text(report.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minWidth: 280, idealWidth: 340, maxWidth: 520, alignment: .leading)
    }

    private var heroStats: some View {
        let report = entry.report
        let m = entry.metrics
        return VStack(spacing: 10) {
            HeroStat(symbol: "hourglass", title: "Estimated Life Remaining", value: report.life.label,
                     detail: report.life.confidence == .none ? String(localized: "Not enough data") : report.life.confidence.label,
                     tint: report.status == .failing || report.status == .failed ? report.status.color : .accentColor)
            HeroStat(symbol: "thermometer.medium", title: "Temperature",
                     value: Format.temperature(m.temperatureC, unit: unit),
                     detail: report.temperature.map { String(localized: "Warning at \(Format.temperature($0.warningC, unit: unit))") }
                        ?? String(localized: "Not reported"),
                     tint: temperatureTint)
            HeroStat(symbol: "power", title: "Powered On", value: Format.hours(m.powerOnHours),
                     detail: m.powerOnHours.map { Format.duration(hours: $0) } ?? String(localized: "Not reported"), tint: .indigo)
        }
    }

    private var temperatureTint: Color {
        guard let t = entry.report.temperature else { return .gray }
        if t.currentC >= t.criticalC { return HealthStatus.failing.color }
        if t.currentC >= t.warningC { return HealthStatus.degraded.color }
        return .teal
    }
}

struct HeroStat: View {
    let symbol: String
    let title: LocalizedStringKey
    let value: String
    let detail: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
                Text(verbatim: value).font(.headline.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
                Text(verbatim: detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassSurface(cornerRadius: 16)
    }
}

struct HealthRing: View {
    let percent: Int?
    let status: HealthStatus
    @State private var animated: Double = 0

    var body: some View {
        let fraction = Double(percent ?? 0) / 100
        ZStack {
            Circle()
                .stroke(status.color.opacity(0.16), style: StrokeStyle(lineWidth: 16, lineCap: .round))
            Circle()
                .trim(from: 0, to: animated)
                .stroke(
                    AngularGradient(colors: [status.color.opacity(0.55), status.color, status.color.opacity(0.9)],
                                    center: .center, startAngle: .degrees(-90), endAngle: .degrees(270)),
                    style: StrokeStyle(lineWidth: 16, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: status.color.opacity(0.45), radius: 8)
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(verbatim: percent.map { "\($0)" } ?? "—")
                        .font(.system(size: 46, weight: .bold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                    if percent != nil {
                        Text(verbatim: "%")
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Health")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .onAppear {
            withAnimation(.spring(response: 1.0, dampingFraction: 0.85)) { animated = fraction }
        }
        .onChange(of: fraction) { _, new in
            withAnimation(.spring(response: 0.8, dampingFraction: 0.85)) { animated = new }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(percent.map { String(localized: "Health \($0) percent, \(status.title)") }
                            ?? String(localized: "Health unknown, \(status.title)"))
    }
}

// MARK: - Metric tiles

struct MetricsGrid: View {
    let entry: DriveStore.Entry
    let unit: TemperatureUnit

    var body: some View {
        let tiles = Self.makeTiles(entry: entry, unit: unit)
        GlassGroup(spacing: 14) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 172), spacing: 14)], spacing: 14) {
                ForEach(tiles) { MetricTileView(tile: $0) }
            }
        }
    }

    struct Tile: Identifiable {
        var id: String { symbol }
        let symbol: String
        let title: LocalizedStringKey
        let value: String
        let detail: String
        var severity: Severity = .good
        var neutral = true
    }

    static func makeTiles(entry: DriveStore.Entry, unit: TemperatureUnit) -> [Tile] {
        let s = entry.snapshot
        let m = entry.metrics
        let report = entry.report
        var tiles: [Tile] = []

        if let life = m.lifeRemainingPercent {
            let sev: Severity = life <= 0 ? .critical : life < 10 ? .warning : life < 25 ? .watch : .good
            tiles.append(Tile(symbol: "battery.75percent", title: "Endurance Left", value: Format.percent(life),
                              detail: String(localized: "\(Format.percent(m.wearUsedPercent)) of rated writes used"), severity: sev, neutral: false))
        }
        if let spare = m.availableSpare {
            let sev: Severity = spare <= (m.availableSpareThreshold ?? 0) ? .critical : spare < 50 ? .warning : spare < 90 ? .watch : .good
            tiles.append(Tile(symbol: "square.stack.3d.up.fill", title: "Available Spare", value: "\(spare)%",
                              detail: m.availableSpareThreshold.map { String(localized: "Threshold \($0)%") } ?? String(localized: "Reserve blocks"),
                              severity: sev, neutral: false))
        }
        if let written = m.bytesWritten {
            tiles.append(Tile(symbol: "square.and.pencil", title: "Data Written", value: Format.bytes(written), detail: String(localized: "Lifetime host writes")))
        } else if let io = s.io {
            tiles.append(Tile(symbol: "square.and.pencil", title: "Data Written", value: Format.bytes(io.bytesWritten), detail: String(localized: "Since connected")))
        }
        if let read = m.bytesRead {
            tiles.append(Tile(symbol: "book.pages", title: "Data Read", value: Format.bytes(read), detail: String(localized: "Lifetime host reads")))
        } else if let io = s.io {
            tiles.append(Tile(symbol: "book.pages", title: "Data Read", value: Format.bytes(io.bytesRead), detail: String(localized: "Since connected")))
        }
        if let cycles = m.powerCycles {
            tiles.append(Tile(symbol: "arrow.triangle.2.circlepath", title: "Power Cycles", value: Format.number(cycles),
                              detail: m.unsafeShutdowns.map { String(localized: "\($0.clampedInt) unsafe shutdowns") } ?? String(localized: "On/off cycles")))
        }
        if case .nvme = s.smart, let media = m.mediaErrors {
            tiles.append(Tile(symbol: "exclamationmark.shield.fill", title: "Media Errors", value: Format.number(media),
                              detail: String(localized: "Data integrity errors"), severity: media > 0 ? (media >= 50 ? .critical : .warning) : .good, neutral: false))
        }
        if let n = m.reallocatedSectors {
            tiles.append(Tile(symbol: "arrow.left.arrow.right.square.fill", title: s.medium == .rotational ? "Reallocated Sectors" : "Retired Blocks",
                              value: Format.number(n), detail: String(localized: "Remapped to spare area"),
                              severity: n == 0 ? .good : n >= 100 ? .critical : n >= 10 ? .warning : .watch, neutral: false))
        }
        if let n = m.pendingSectors {
            tiles.append(Tile(symbol: "hourglass.badge.plus", title: "Pending Sectors", value: Format.number(n), detail: String(localized: "Unstable, awaiting remap"),
                              severity: n == 0 ? .good : n >= 5 ? .critical : .warning, neutral: false))
        }
        if let n = m.offlineUncorrectable ?? m.reportedUncorrectable {
            tiles.append(Tile(symbol: "xmark.bin.fill", title: "Uncorrectable", value: Format.number(n), detail: String(localized: "Unrecoverable sectors"),
                              severity: n == 0 ? .good : n >= 5 ? .critical : .warning, neutral: false))
        }
        if let io = s.io {
            tiles.append(Tile(symbol: "bolt.horizontal.circle.fill", title: "I/O Errors", value: Format.number(Int(io.totalErrors)),
                              detail: io.totalRetries > 0 ? String(localized: "\(io.totalRetries.clampedInt) retries since connected")
                                                          : String(localized: "Since connected"),
                              severity: io.totalErrors == 0 ? (io.totalRetries > 0 ? .watch : .good) : io.totalErrors >= 10 ? .critical : .warning,
                              neutral: false))
            let lat = [io.averageReadLatencyMs, io.averageWriteLatencyMs].compactMap { $0 }
            if !lat.isEmpty {
                tiles.append(Tile(symbol: "stopwatch", title: "Avg. Response",
                                  value: Format.latency(io.averageReadLatencyMs ?? io.averageWriteLatencyMs),
                                  detail: String(localized: "Write \(Format.latency(io.averageWriteLatencyMs))")))
            }
        }
        if let usage = s.usage {
            let fraction = usage.total > 0 ? Double(usage.used) / Double(usage.total) : 0
            tiles.append(Tile(symbol: "chart.pie.fill", title: "Disk Usage", value: Format.percent(fraction * 100),
                              detail: String(localized: "\(Format.bytes(usage.total - usage.used)) free"),
                              severity: fraction > 0.95 ? .warning : fraction > 0.9 ? .watch : .good, neutral: fraction <= 0.9))
        }
        if let t = report.temperature, let maxC = t.lifetimeMaxC {
            tiles.append(Tile(symbol: "thermometer.high", title: "Lifetime Max Temp", value: Format.temperature(maxC, unit: unit),
                              detail: t.lifetimeMinC.map { String(localized: "Min \(Format.temperature($0, unit: unit))") }
                                  ?? String(localized: "Recorded by drive"),
                              severity: maxC >= t.criticalC ? .watch : .good, neutral: maxC < t.criticalC))
        }
        return tiles
    }
}

struct MetricTileView: View {
    let tile: MetricsGrid.Tile

    var body: some View {
        let accent: Color = tile.neutral ? .accentColor : tile.severity.color
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: tile.symbol)
                    .foregroundStyle(accent)
                Text(tile.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 0)
                if !tile.neutral && tile.severity >= .watch {
                    Image(systemName: tile.severity.symbolName)
                        .font(.caption)
                        .foregroundStyle(tile.severity.color)
                }
            }
            Text(verbatim: tile.value)
                .font(.system(.title2, design: .rounded).weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(verbatim: tile.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .glassSurface(cornerRadius: 18, tint: !tile.neutral && tile.severity >= .watch ? tile.severity.color : nil)
    }
}
