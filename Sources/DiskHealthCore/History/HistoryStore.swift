//
//  HistoryStore.swift
//  Disk Health
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import CryptoKit
import Foundation

/// One persisted observation of a drive, used for trends and life estimation.
public struct HistoryPoint: Codable, Sendable, Hashable {
    public var date: Date
    public var temperatureC: Double?
    public var powerOnHours: Double?
    public var wearUsedPercent: Double?
    public var bytesWritten: Double?
    public var reallocatedSectors: Int?
    public var pendingSectors: Int?
    public var offlineUncorrectable: Int?
    public var reportedUncorrectable: Int?
    public var mediaErrors: Double?
    public var availableSpare: Int?
    public var healthPercent: Int?

    public init(date: Date, temperatureC: Double? = nil, powerOnHours: Double? = nil, wearUsedPercent: Double? = nil,
                bytesWritten: Double? = nil, reallocatedSectors: Int? = nil, pendingSectors: Int? = nil,
                offlineUncorrectable: Int? = nil, reportedUncorrectable: Int? = nil, mediaErrors: Double? = nil,
                availableSpare: Int? = nil, healthPercent: Int? = nil) {
        self.date = date
        self.temperatureC = temperatureC
        self.powerOnHours = powerOnHours
        self.wearUsedPercent = wearUsedPercent
        self.bytesWritten = bytesWritten
        self.reallocatedSectors = reallocatedSectors
        self.pendingSectors = pendingSectors
        self.offlineUncorrectable = offlineUncorrectable
        self.reportedUncorrectable = reportedUncorrectable
        self.mediaErrors = mediaErrors
        self.availableSpare = availableSpare
        self.healthPercent = healthPercent
    }

    public init(metrics m: DriveMetrics, date: Date, healthPercent: Int?) {
        self.init(date: date, temperatureC: m.temperatureC, powerOnHours: m.powerOnHours,
                  wearUsedPercent: m.wearUsedPercent, bytesWritten: m.bytesWritten,
                  reallocatedSectors: m.reallocatedSectors, pendingSectors: m.pendingSectors,
                  offlineUncorrectable: m.offlineUncorrectable, reportedUncorrectable: m.reportedUncorrectable,
                  mediaErrors: m.mediaErrors, availableSpare: m.availableSpare, healthPercent: healthPercent)
    }

    /// True if any failure-relevant counter differs from another point.
    func countersDiffer(from other: HistoryPoint) -> Bool {
        reallocatedSectors != other.reallocatedSectors || pendingSectors != other.pendingSectors
            || offlineUncorrectable != other.offlineUncorrectable || reportedUncorrectable != other.reportedUncorrectable
            || mediaErrors != other.mediaErrors || availableSpare != other.availableSpare
            || wearUsedPercent != other.wearUsedPercent
    }
}

public struct DriveHistory: Codable, Sendable, Hashable {
    public var driveID: String
    public var points: [HistoryPoint]
    public var lastSurfaceScan: SurfaceScanResult?
    public var lastNotifiedStatus: HealthStatus?

    public init(driveID: String, points: [HistoryPoint] = [], lastSurfaceScan: SurfaceScanResult? = nil,
                lastNotifiedStatus: HealthStatus? = nil) {
        self.driveID = driveID
        self.points = points
        self.lastSurfaceScan = lastSurfaceScan
        self.lastNotifiedStatus = lastNotifiedStatus
    }

    public var firstDate: Date? { points.first?.date }
    public var span: TimeInterval { (points.last?.date ?? .distantPast).timeIntervalSince(points.first?.date ?? .distantPast) }

    /// Appends a point, sampling at most every `minimumInterval` unless counters changed,
    /// and thins out data older than a week to one point per day.
    public mutating func append(_ point: HistoryPoint, minimumInterval: TimeInterval = 300) {
        if let last = points.last {
            let elapsed = point.date.timeIntervalSince(last.date)
            if elapsed < minimumInterval && !point.countersDiffer(from: last) { return }
        }
        points.append(point)
        compact(now: point.date)
    }

    mutating func compact(now: Date) {
        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        guard let firstRecent = points.firstIndex(where: { $0.date >= weekAgo }), firstRecent > 1 else {
            if points.count > 6_000 { points.removeFirst(points.count - 6_000) }
            return
        }
        var kept: [HistoryPoint] = []
        var lastDay: Int?
        let calendar = Calendar(identifier: .gregorian)
        for (index, p) in points[..<firstRecent].enumerated() {
            let day = calendar.ordinality(of: .day, in: .era, for: p.date) ?? 0
            let changed = kept.last.map { p.countersDiffer(from: $0) } ?? true
            if index == 0 || day != lastDay || changed {
                kept.append(p)
                lastDay = day
            }
        }
        points = kept + points[firstRecent...]
        if points.count > 6_000 { points.removeFirst(points.count - 6_000) }
    }

    /// Observed power-on hours per calendar day, if enough history exists.
    public var observedDutyHoursPerDay: Double? {
        let withPOH = points.filter { $0.powerOnHours != nil }
        guard let first = withPOH.first, let last = withPOH.last,
              let a = first.powerOnHours, let b = last.powerOnHours else { return nil }
        let days = last.date.timeIntervalSince(first.date) / 86_400
        guard days >= 1, b >= a else { return nil }
        return min(24, max(0.25, (b - a) / days))
    }
}

/// Persists per-drive history as JSON in Application Support.
public final class HistoryStore: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private var cache: [String: DriveHistory] = [:]

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.directory = base.appendingPathComponent("DiskHealth/History", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    private func fileURL(for driveID: String) -> URL {
        let digest = SHA256.hash(data: Data(driveID.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(digest).json")
    }

    public func history(for driveID: String) -> DriveHistory {
        lock.lock(); defer { lock.unlock() }
        return loadLocked(driveID)
    }

    private func loadLocked(_ driveID: String) -> DriveHistory {
        if let cached = cache[driveID] { return cached }
        let url = fileURL(for: driveID)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let data = try? Data(contentsOf: url), let history = try? decoder.decode(DriveHistory.self, from: data) {
            cache[driveID] = history
            return history
        }
        let fresh = DriveHistory(driveID: driveID)
        cache[driveID] = fresh
        return fresh
    }

    public func update(_ driveID: String, _ body: (inout DriveHistory) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var history = loadLocked(driveID)
        body(&history)
        cache[driveID] = history
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(history) {
            try? data.write(to: fileURL(for: driveID), options: .atomic)
        }
    }
}
