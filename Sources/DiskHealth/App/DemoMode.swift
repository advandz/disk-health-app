//
//  DemoMode.swift
//  Disk Health
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import AppKit

/// Screenshots: `open "build/Disk Health.app" --args --demo [--light | --dark]` lists only the simulated
/// sample drives (never this Mac's real ones), and doesn't save history, send notifications or check
/// for updates. `-DemoDrive <name>` picks the selected drive.
enum DemoMode {
    static let isActive = CommandLine.arguments.contains("--demo")

    /// The sample drive selected at launch; defaults to one whose report shows most of the app.
    static var selectedDriveName: String {
        UserDefaults.standard.string(forKey: "DemoDrive") ?? "Samsung SSD 860 EVO 500GB"
    }

    /// Applies `--light` or `--dark`; without either, the app follows the system appearance.
    @MainActor static func applyAppearance() {
        guard isActive else { return }
        if CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if CommandLine.arguments.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
    }
}
