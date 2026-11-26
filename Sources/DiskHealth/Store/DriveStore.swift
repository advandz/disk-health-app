//
//  DriveStore.swift
//  Disk Health
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import AppKit
import DiskHealthCore
import Foundation
import Observation

/// App state: discovered drives, their reports and history, background refresh,
/// surface scans and notifications.
@MainActor
@Observable
final class DriveStore {
    struct Entry: Identifiable, Hashable {
        var snapshot: DriveSnapshot
        var report: HealthReport
        var history: DriveHistory
        var id: String { snapshot.id }
        var metrics: DriveMetrics { DriveMetrics(snapshot) }
    }

    enum ScanPhase: Equatable {
        case authorizing
        case running(completed: Int, total: Int, errors: Int, slow: Int, mbps: Double)
        case finished
        /// Ended without changing the saved result (e.g. stopped early); the message says why.
        case discarded(String)
        case failed(String)
    }

    struct ScanState {
        var mode: SurfaceScanner.Mode
        var phase: ScanPhase
        var flag: CancelFlag
    }

    private(set) var entries: [Entry] = []
    var selectedID: String?
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    private(set) var scans: [String: ScanState] = [:]
    var selfTestMessages: [String: String] = [:]
    /// Presents the Settings sheet on the main window (⌘, or the Options menu).
    var isShowingSettings = false

    var showSamples: Bool = UserDefaults.standard.bool(forKey: "showSampleDrives") {
        didSet {
            UserDefaults.standard.set(showSamples, forKey: "showSampleDrives")
            Task { await refresh() }
        }
    }

    /// Seconds between automatic refreshes (0 = off).
    var refreshInterval: Double = UserDefaults.standard.object(forKey: "refreshInterval") as? Double ?? 300 {
        didSet {
            UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval")
            startTimer()
        }
    }

    var notificationsEnabled: Bool = UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: "notificationsEnabled") }
    }

    @ObservationIgnored let historyStore = HistoryStore()
    @ObservationIgnored private var watcher: DiskWatcher?
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var refreshQueued = false
    @ObservationIgnored private var queuedRefreshIsForced = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private let notifier = Notifier()

    var selectedEntry: Entry? { entries.first { $0.id == selectedID } }

    /// Exports the selected drive's report, or one report covering every listed drive
    /// (real drives first; sample drives only when nothing else is listed).
    func exportReport(allDrives: Bool) {
        let targets: [Entry]
        if allDrives {
            targets = realEntries.isEmpty ? entries : realEntries
        } else {
            targets = selectedEntry.map { [$0] } ?? []
        }
        guard !targets.isEmpty else { return }
        ReportExporter.export(targets, allDrives: allDrives)
    }
    var realEntries: [Entry] { entries.filter { !$0.snapshot.isSample } }

    func start() {
        guard !started else { return }
        started = true
        if !DemoMode.isActive {
            watcher = DiskWatcher { [weak self] in
                Task { await self?.refresh() }
            }
            notifier.requestAuthorizationIfPossible()
        }
        Task {
            await refresh()
            exportFromLaunchArguments()
        }
        startTimer()
    }

    /// Scripting: `-ExportReportPDF <path>` writes a report for every listed drive once the first scan
    /// finishes, then quits; `-ExportReportDrive <name or id>` limits it to matching drives. Read from
    /// launch arguments only, so a value saved in the app's settings can't make every launch quit.
    private func exportFromLaunchArguments() {
        guard let path = LaunchArguments.string("ExportReportPDF"), !path.isEmpty else { return }
        defer { NSApp.terminate(nil) }   // also on failure, so `open -W` scripts don't wait forever
        var targets = entries
        if let filter = LaunchArguments.string("ExportReportDrive"), !filter.isEmpty {
            targets = targets.filter { $0.id == filter || $0.snapshot.name.localizedCaseInsensitiveContains(filter) }
        }
        guard !targets.isEmpty else {
            NSLog("Disk Health: no drive matches the report filter; nothing exported")
            return
        }
        let unit = TemperatureUnit(rawValue: UserDefaults.standard.string(forKey: "temperatureUnit") ?? "") ?? .celsius
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        do {
            let start = Date()
            try ReportExporter.writePDF(targets, unit: unit, to: url)
            NSLog("Disk Health: exported %ld drive report(s) to %@ in %.2f s", targets.count, url.path,
                  Date().timeIntervalSince(start))
        } catch {
            NSLog("Disk Health: report export to %@ failed: %@", url.path, error.localizedDescription)
        }
    }

    private func startTimer() {
        timerTask?.cancel()
        guard refreshInterval > 0 else { return }
        let interval = refreshInterval
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { break }
                await self?.refresh()
            }
        }
    }

    /// Re-reads every drive. Timer and hot-plug refreshes may reuse an idle hard drive's last
    /// S.M.A.R.T. data instead of waking it (see `DriveDiscovery.scan(reusing:)`); `force` reads
    /// everything fresh, for when the user asks for a refresh.
    func refresh(force: Bool = false) async {
        if isRefreshing {
            refreshQueued = true
            queuedRefreshIsForced = queuedRefreshIsForced || force
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        // Demo mode (screenshots) lists only the sample drives: no real drives, no history writes.
        let demo = DemoMode.isActive
        let includeSamples = showSamples || demo
        let store = historyStore
        let previous = force ? [] : realEntries.map(\.snapshot)
        let fresh = await Task.detached(priority: .userInitiated) { () -> [Entry] in
            var result: [Entry] = []
            for snapshot in demo ? [] : DriveDiscovery.scan(reusing: previous) {
                let past = store.history(for: snapshot.id)
                let report = HealthAnalyzer.analyze(snapshot, history: past)
                var updated = past
                store.update(snapshot.id) { history in
                    history.append(HistoryPoint(metrics: DriveMetrics(snapshot), date: snapshot.capturedAt,
                                                healthPercent: report.healthPercent))
                    updated = history
                }
                result.append(Entry(snapshot: snapshot, report: report, history: updated))
            }
            if includeSamples {
                for sample in SampleDrives.all() {
                    result.append(Entry(snapshot: sample.snapshot,
                                        report: HealthAnalyzer.analyze(sample.snapshot, history: sample.history),
                                        history: sample.history))
                }
            }
            return result
        }.value

        entries = fresh
        lastRefresh = Date()
        if selectedID == nil || !entries.contains(where: { $0.id == selectedID }) {
            selectedID = demo
                ? (entries.first { $0.snapshot.name == DemoMode.selectedDriveName } ?? entries.first)?.id
                : entries.first?.id
        }
        if !demo { notifyIfWorse() }

        if refreshQueued {
            let forced = queuedRefreshIsForced
            refreshQueued = false
            queuedRefreshIsForced = false
            Task { await refresh(force: forced) }
        }
    }

    // MARK: - Notifications

    private func notifyIfWorse() {
        for entry in realEntries {
            let status = entry.report.status
            let last = entry.history.lastNotifiedStatus
            guard status != last else { continue }
            if notificationsEnabled, status.badness >= HealthStatus.degraded.badness,
               status.badness > (last?.badness ?? HealthStatus.good.badness) {
                notifier.post(title: "\(entry.snapshot.name): \(status.title)", body: entry.report.summary)
            }
            historyStore.update(entry.id) { $0.lastNotifiedStatus = status }
        }
    }

    // MARK: - Surface scan

    func startScan(_ entry: Entry, mode: SurfaceScanner.Mode) {
        guard !entry.snapshot.isSample, scans[entry.id].map({ isActive($0.phase) }) != true else { return }
        let id = entry.id
        let flag = CancelFlag()
        scans[id] = ScanState(mode: mode, phase: .authorizing, flag: flag)
        let snapshot = entry.snapshot
        let bsdName = snapshot.bsdName

        Task.detached(priority: .utility) { [self] in
            do {
                let fd = try SurfaceScanner.openRawDevice(bsdName: bsdName)
                defer { close(fd) }
                let result = try SurfaceScanner.scan(
                    fileDescriptor: fd, capacity: snapshot.capacityBytes,
                    blockSize: max(snapshot.logicalBlockSize, snapshot.physicalBlockSize ?? 0), mode: mode,
                    isCancelled: { flag.isCancelled },
                    isDevicePresent: { SurfaceScanner.deviceExists(bsdName: bsdName) },
                    progress: { p in
                        Task { @MainActor in
                            self.updateScanProgress(id: id, p)
                        }
                    })
                await self.finishScan(id: id, result: result)
            } catch {
                await self.failScan(id: id, message: error.localizedDescription)
            }
        }
    }

    private func updateScanProgress(id: String, _ p: SurfaceScanner.Progress) {
        guard let state = scans[id], isActive(state.phase) else { return }
        scans[id]?.phase = .running(completed: p.completed, total: p.total, errors: p.readErrors,
                                    slow: p.slowReads, mbps: p.currentMBps)
    }

    private func failScan(id: String, message: String) {
        scans[id]?.phase = .failed(message)
    }

    func cancelScan(_ entry: Entry) {
        scans[entry.id]?.flag.cancel()
    }

    func dismissScan(_ entry: Entry) {
        if let s = scans[entry.id], !isActive(s.phase) { scans[entry.id] = nil }
    }

    func isActive(_ phase: ScanPhase) -> Bool {
        switch phase {
        case .authorizing, .running: return true
        case .finished, .discarded, .failed: return false
        }
    }

    private func finishScan(id: String, result: SurfaceScanResult) {
        let previous = historyStore.history(for: id).lastSurfaceScan
        guard result.shouldReplace(previous) else {
            scans[id]?.phase = .discarded(previous != nil && result.completedSamples >= SurfaceScanResult.minimumUsefulSamples
                ? String(localized: "The test was stopped before it finished and found no problems, so the previous result is kept.")
                : String(localized: "The test was stopped too early to give a result."))
            return
        }
        scans[id]?.phase = .finished
        historyStore.update(id) { $0.lastSurfaceScan = result }
        if let index = entries.firstIndex(where: { $0.id == id }) {
            var entry = entries[index]
            entry.history.lastSurfaceScan = result
            entry.report = HealthAnalyzer.analyze(entry.snapshot, history: entry.history)
            entries[index] = entry
        }
    }

    // MARK: - ATA self-test

    func startSelfTest(_ entry: Entry, extended: Bool) {
        guard let serviceID = entry.snapshot.smartServiceEntryID, !entry.snapshot.isSample else { return }
        let id = entry.id
        selfTestMessages[id] = String(localized: "Starting…")
        Task.detached {
            let ok = DriveDiscovery.startSelfTest(serviceEntryID: serviceID, extended: extended)
            await MainActor.run { [weak self] in
                self?.selfTestMessages[id] = ok
                    ? (extended ? String(localized: "Extended self-test started. Progress appears here after each refresh.")
                                : String(localized: "Short self-test started. Progress appears here after each refresh."))
                    : String(localized: "The drive rejected the self-test command.")
            }
            try? await Task.sleep(for: .seconds(3))
            await self.refresh(force: true)
        }
    }
}

/// Thread-safe cancellation flag shared with the scan worker.
final class CancelFlag: @unchecked Sendable, Equatable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    static func == (lhs: CancelFlag, rhs: CancelFlag) -> Bool { lhs === rhs }
}
