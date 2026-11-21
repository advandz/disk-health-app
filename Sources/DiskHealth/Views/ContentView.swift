//
//  ContentView.swift
//  Disk Health
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import AppKit
import DiskHealthCore
import SwiftUI

struct ContentView: View {
    @Environment(DriveStore.self) private var store
    @AppStorage("temperatureUnit") private var unitRaw = TemperatureUnit.celsius.rawValue
    @State private var isFullScreen = false

    private var backdropColor: Color { store.selectedEntry?.report.status.color ?? .blue }

    /// In full screen the toolbar is hidden, so the floating sidebar would touch the top edge of the
    /// screen. Give it the same 8 pt margin it has on the other sides.
    private var fullScreenTopMargin: CGFloat { isFullScreen ? 8 : 0 }

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 250, ideal: 280, max: 360)
        } detail: {
            ZStack {
                StatusBackdrop(color: backdropColor)
                if let entry = store.selectedEntry {
                    DriveDetailView(entry: entry)
                        .id(entry.id)
                } else if store.isRefreshing && store.entries.isEmpty {
                    ProgressView("Scanning drives…")
                } else {
                    ContentUnavailableView("No Drive Selected", systemImage: "internaldrive",
                                           description: Text("Select a drive in the sidebar to see its health report."))
                }
            }
            .toolbar { toolbarContent }
            // Let the status gradient run up under the title bar instead of an opaque strip.
            // The detail scroll view fades its content out below the bar (see DriveDetailView).
            .toolbarBackground(.hidden, for: .windowToolbar)
        }
        .padding(.top, fullScreenTopMargin)
        .background {
            // Fills the margin strip so the gradient stays continuous.
            if fullScreenTopMargin > 0 { StatusBackdrop(color: backdropColor) }
        }
        .background(FullScreenObserver(isFullScreen: $isFullScreen))
        .toolbarHidesInFullScreen()
        .sheet(isPresented: $store.isShowingSettings) {
            SettingsView()
                .environment(store)
        }
        .navigationTitle(store.selectedEntry?.snapshot.name ?? String(localized: "Disk Health"))
        .navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        guard let last = store.lastRefresh else { return String(localized: "Scanning…") }
        return String(localized: "Updated \(last.formatted(date: .omitted, time: .shortened))")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                store.exportReport(allDrives: false)
            } label: {
                Label("Export PDF", systemImage: "arrow.down.doc")
            }
            .disabled(store.selectedEntry == nil)
            .help("Export this drive's health report as a PDF (⌘E)")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await store.refresh() }
            } label: {
                if store.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .help("Re-read health data from all drives (⌘R)")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Auto-Refresh", selection: Binding(get: { store.refreshInterval }, set: { store.refreshInterval = $0 })) {
                    Text("Off").tag(0.0)
                    Text("Every minute").tag(60.0)
                    Text("Every 5 minutes").tag(300.0)
                    Text("Every 15 minutes").tag(900.0)
                    Text("Every hour").tag(3600.0)
                }
                Picker("Temperature", selection: $unitRaw) {
                    ForEach(TemperatureUnit.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Divider()
                Toggle("Show Sample Drives", isOn: Binding(get: { store.showSamples }, set: { store.showSamples = $0 }))
                Divider()
                Button("Export Report for All Drives as PDF…") { store.exportReport(allDrives: true) }
                    .disabled(store.entries.isEmpty)
                Button("Settings…") { store.isShowingSettings = true }
            } label: {
                Label("Options", systemImage: "slider.horizontal.3")
            }
            .accessibilityLabel("Options")
            .help("Refresh interval, units and sample drives")
        }
    }
}

/// Reports whether the hosting window is in full screen (updated as it enters or leaves).
private struct FullScreenObserver: NSViewRepresentable {
    @Binding var isFullScreen: Bool

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = { isFullScreen = $0 }
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.onChange = { isFullScreen = $0 }
    }

    final class ObserverView: NSView {
        var onChange: ((Bool) -> Void)?
        private var tokens: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach { NotificationCenter.default.removeObserver($0) }
            tokens = []
            guard let window else { return }
            let initial = window.styleMask.contains(.fullScreen)
            DispatchQueue.main.async { [weak self] in self?.onChange?(initial) }
            let center = NotificationCenter.default
            tokens.append(center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window,
                                             queue: .main) { [weak self] _ in self?.onChange?(true) })
            tokens.append(center.addObserver(forName: NSWindow.willExitFullScreenNotification, object: window,
                                             queue: .main) { [weak self] _ in self?.onChange?(false) })
        }

        deinit {
            tokens.forEach { NotificationCenter.default.removeObserver($0) }
        }
    }
}
