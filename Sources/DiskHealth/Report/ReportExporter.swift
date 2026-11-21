//
//  ReportExporter.swift
//  Disk Health
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import AppKit
import DiskHealthCore
import SwiftUI
import UniformTypeIdentifiers

/// Asks where to save, renders the PDF and writes it.
@MainActor
enum ReportExporter {
    static func export(_ entries: [DriveStore.Entry], allDrives: Bool) {
        let unit = TemperatureUnit(rawValue: UserDefaults.standard.string(forKey: "temperatureUnit") ?? "") ?? .celsius
        let day = Date().formatted(.iso8601.year().month().day())
        let title = String(localized: "Disk Health Report")
        let subject = allDrives || entries.count > 1 ? String(localized: "All Drives") : entries[0].snapshot.name

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = sanitized("\(title) – \(subject) – \(day).pdf")

        let write: (URL) -> Void = { url in
            do {
                try writePDF(entries, unit: unit, to: url)
            } catch {
                let alert = NSAlert(error: error)
                alert.messageText = String(localized: "The report could not be saved.")
                alert.runModal()
            }
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                write(url)
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            write(url)
        }
    }

    /// Renders and writes the report without any UI (also used by the `-ExportReportPDF` launch argument).
    static func writePDF(_ entries: [DriveStore.Entry], unit: TemperatureUnit, to url: URL) throws {
        let drives = entries.map { ReportPDF.Drive(name: $0.snapshot.name, blocks: ReportContent.blocks(for: $0, unit: unit)) }
        try ReportPDF.render(drives).write(to: url, options: .atomic)
    }

    /// File names can't contain "/" or ":".
    private static func sanitized(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }
}
