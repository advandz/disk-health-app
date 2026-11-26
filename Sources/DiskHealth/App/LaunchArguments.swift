//
//  LaunchArguments.swift
//  Disk Health
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import Foundation

/// Values passed on the command line as `-Key value` (for example
/// `open "Disk Health.app" --args -ExportReportPDF ~/report.pdf`).
///
/// Unlike `UserDefaults.standard`, this never returns a value saved in the app's settings, so an
/// option meant for a single launch (scripted export, a test update feed) can't be made permanent
/// with `defaults write`.
enum LaunchArguments {
    static func string(_ key: String) -> String? {
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[key] as? String
    }
}
