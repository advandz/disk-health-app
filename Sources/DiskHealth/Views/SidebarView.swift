//
//  SidebarView.swift
//  Disk Health
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import DiskHealthCore
import SwiftUI

struct SidebarView: View {
    @Environment(DriveStore.self) private var store

    var body: some View {
        @Bindable var store = store
        let internalDrives = store.entries.filter { !$0.snapshot.isSample && $0.snapshot.isInternal }
        let externalDrives = store.entries.filter { !$0.snapshot.isSample && !$0.snapshot.isInternal }
        let samples = store.entries.filter { $0.snapshot.isSample }

        List(selection: $store.selectedID) {
            if !store.realEntries.isEmpty {
                OverviewHeader(entries: store.realEntries)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .selectionDisabled()
            }
            if !internalDrives.isEmpty {
                Section("Internal") { ForEach(internalDrives) { DriveRow(entry: $0).tag($0.id) } }
            }
            if !externalDrives.isEmpty {
                Section("External") { ForEach(externalDrives) { DriveRow(entry: $0).tag($0.id) } }
            }
            if !samples.isEmpty {
                Section("Sample Drives (simulated)") { ForEach(samples) { DriveRow(entry: $0).tag($0.id) } }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if store.entries.isEmpty && !store.isRefreshing {
                ContentUnavailableView("No Drives Found", systemImage: "externaldrive.badge.questionmark")
            }
        }
    }
}

private struct OverviewHeader: View {
    let entries: [DriveStore.Entry]

    var body: some View {
        let problems = entries.filter { $0.report.status.badness >= HealthStatus.watch.badness }
        let worst = entries.map(\.report.status).max { $0.badness < $1.badness } ?? .unknown
        HStack(spacing: 12) {
            Image(systemName: problems.isEmpty ? "checkmark.shield.fill" : worst.symbolName)
                .font(.title2)
                .foregroundStyle(problems.isEmpty ? HealthStatus.excellent.color : worst.color)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(problems.isEmpty ? String(localized: "All drives healthy") : String(localized: "\(problems.count) drives need attention"))
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(entries.count) drives monitored")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .glassSurface(cornerRadius: 16, tint: problems.isEmpty ? nil : worst.color)
        .padding(.vertical, 4)
    }
}

struct DriveRow: View {
    let entry: DriveStore.Entry

    var body: some View {
        let status = entry.report.status
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: entry.snapshot.kind.symbolName)
                    .font(.title2)
                    .foregroundStyle(.primary.opacity(0.85))
                    .frame(width: 30, height: 30)
                Circle()
                    .fill(status.color)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                    .offset(x: 2, y: 2)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.snapshot.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(entry.snapshot.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            HealthPill(percent: entry.report.healthPercent, status: status)
        }
        .padding(.vertical, 4)
        .help(Text(verbatim: "\(status.title) — \(entry.report.headline)"))
    }
}

struct HealthPill: View {
    let percent: Int?
    let status: HealthStatus

    var body: some View {
        Text(verbatim: percent.map { "\($0)%" } ?? "—")
            .font(.caption.weight(.bold).monospacedDigit())
            .foregroundStyle(status == .unknown ? Color.secondary : status.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(status.color.opacity(0.16), in: Capsule())
    }
}
