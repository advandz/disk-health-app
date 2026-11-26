//
//  DiskHealthApp.swift
//  Disk Health
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import AppKit
import SwiftUI

@main
struct DiskHealthApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = DriveStore()

    var body: some Scene {
        // A single main window: Settings and the PDF export are sheets on it.
        Window("Disk Health", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 980, minHeight: 660)
                .task { store.start() }
        }
        .defaultSize(width: 1240, height: 860)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Updater.shared.check(userInitiated: true) }
                    .disabled(!Updater.isAvailable)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { store.isShowingSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .importExport) {
                Button("Export Report as PDF…") { store.exportReport(allDrives: false) }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(store.selectedEntry == nil)
                Button("Export Report for All Drives as PDF…") { store.exportReport(allDrives: true) }
                    .keyboardShortcut("e", modifiers: [.command, .option])
                    .disabled(store.entries.isEmpty)
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh Drives") { Task { await store.refresh(force: true) } }
                    .keyboardShortcut("r", modifiers: .command)
                Toggle("Show Sample Drives", isOn: Binding(get: { store.showSamples }, set: { store.showSamples = $0 }))
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Divider()
            }
        }

    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run); harmless inside the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DemoMode.applyAppearance()
        // Checks this repository's GitHub releases about once a day (Settings › Updates).
        if Updater.isAvailable { Updater.shared.start() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
