//
//  SettingsView.swift
//  Disk Health
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import SwiftUI

/// Presented as a sheet on the main window.
struct SettingsView: View {
    @Environment(DriveStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("temperatureUnit") private var unitRaw = TemperatureUnit.celsius.rawValue
    @AppStorage(Updater.Keys.checkAutomatically) private var checksForUpdates = true
    @AppStorage(Updater.Keys.lastCheck) private var lastUpdateCheck = 0.0

    var body: some View {
        VStack(spacing: 0) {
            Text("Settings")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.top, 18)
            Form {
                Section("Monitoring") {
                    Picker("Refresh automatically", selection: Binding(get: { store.refreshInterval }, set: { store.refreshInterval = $0 })) {
                        Text("Off").tag(0.0)
                        Text("Every minute").tag(60.0)
                        Text("Every 5 minutes").tag(300.0)
                        Text("Every 15 minutes").tag(900.0)
                        Text("Every hour").tag(3600.0)
                    }
                    Toggle("Notify when a drive's health gets worse",
                           isOn: Binding(get: { store.notificationsEnabled }, set: { store.notificationsEnabled = $0 }))
                }
                Section("Display") {
                    Picker("Temperature unit", selection: $unitRaw) {
                        ForEach(TemperatureUnit.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    Toggle("Show sample drives (simulated failure states)",
                           isOn: Binding(get: { store.showSamples }, set: { store.showSamples = $0 }))
                }
                Section("Updates") {
                    Toggle("Check for updates automatically", isOn: $checksForUpdates)
                    LabeledContent {
                        Button("Check Now") { Updater.shared.check(userInitiated: true) }
                            .disabled(!Updater.isAvailable)
                    } label: {
                        Text(verbatim: "Disk Health \(AppVersion.current)")
                        Text(lastCheckedDescription)
                    }
                }
                Section {
                    Text("Health history is stored locally in ~/Library/Application Support/DiskHealth. Nothing leaves this Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .glassButton(prominent: true)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .onExitCommand { dismiss() }
    }

    private var lastCheckedDescription: String {
        guard lastUpdateCheck > 0 else { return String(localized: "Not checked yet") }
        let date = Date(timeIntervalSince1970: lastUpdateCheck)
        return String(localized: "Last checked \(date.formatted(.relative(presentation: .named)))")
    }
}
