// swift-tools-version: 6.2
//
//  Package.swift
//  Disk Health
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import PackageDescription

// Disk Health — advanced drive health monitoring for macOS.
// No third-party dependencies: only Apple system frameworks
// (IOKit, DiskArbitration, SwiftUI, Charts, UserNotifications).
let package = Package(
    name: "DiskHealth",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "DiskHealth", targets: ["DiskHealth"])
    ],
    targets: [
        // Thin C shim around the IOKit COM-style SMART plug-ins and authopen(1).
        .target(
            name: "CDiskKit",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        // Drive discovery, SMART parsing, health analysis, history, surface scan.
        .target(
            name: "DiskHealthCore",
            dependencies: ["CDiskKit"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("DiskArbitration"),
            ]
        ),
        // SwiftUI application (Liquid Glass).
        .executableTarget(
            name: "DiskHealth",
            dependencies: ["DiskHealthCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DiskHealthCoreTests",
            dependencies: ["DiskHealthCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
