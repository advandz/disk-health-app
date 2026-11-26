//
//  SurfaceScanner.swift
//  Disk Health
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import CDiskKit
import Darwin
import Foundation

/// Result of a non-destructive sampled read test across the whole surface.
public struct SurfaceScanResult: Codable, Sendable, Hashable {
    public var date: Date
    public var mode: SurfaceScanner.Mode
    public var plannedSamples: Int
    public var completedSamples: Int
    public var chunkBytes: Int
    public var bytesRead: UInt64
    public var readErrors: Int
    public var errorOffsets: [UInt64]
    /// Reads well above the drive's own median latency.
    public var slowReads: Int
    /// Reads that took longer than one second (weak / retried sectors).
    public var verySlowReads: Int
    public var medianLatencyMs: Double
    public var p95LatencyMs: Double
    public var maxLatencyMs: Double
    public var throughputMBps: Double
    /// Counts per latency bucket, see `SurfaceScanner.bucketLimitsMs`.
    public var latencyBuckets: [Int]
    public var duration: TimeInterval
    public var cancelled: Bool

    public var isComplete: Bool { !cancelled && completedSamples >= plannedSamples }

    /// Unreadable or very slow regions were found.
    public var foundProblems: Bool { readErrors > 0 || verySlowReads > 0 }

    /// Results with fewer samples than this say too little to keep.
    public static let minimumUsefulSamples = 32

    /// Whether this result should become the drive's last scan in place of `previous`.
    ///
    /// A scan that was stopped early and found nothing must not replace an earlier result, or stopping
    /// a re-run would hide problems that a full scan found. Complete scans, and scans that found
    /// problems, always replace it.
    public func shouldReplace(_ previous: SurfaceScanResult?) -> Bool {
        guard completedSamples >= Self.minimumUsefulSamples else { return false }
        if isComplete || foundProblems { return true }
        guard let previous else { return true }
        return !previous.isComplete && !previous.foundProblems
    }
}

public enum SurfaceScanError: LocalizedError, Equatable {
    /// authopen ran but passed back no descriptor: authorization was cancelled or denied, or the
    /// device couldn't be opened (for example because it is busy).
    case notOpened
    /// The device node doesn't exist (the drive was disconnected).
    case deviceNotFound
    /// The drive went away while it was being read.
    case deviceDisconnected
    /// authopen couldn't be started.
    case helperFailed

    public var errorDescription: String? {
        switch self {
        case .notOpened:
            return String(localized: "The drive couldn't be opened for reading. Authorization was cancelled, or the drive is busy.")
        case .deviceNotFound:
            return String(localized: "The drive is no longer connected.")
        case .deviceDisconnected:
            return String(localized: "The drive was disconnected during the test, so no result was saved.")
        case .helperFailed:
            return String(localized: "The system's authorization helper (authopen) couldn't be started.")
        }
    }
}

/// Reads evenly distributed regions of the raw device and measures latency.
/// Read-only: it never writes to the drive.
public enum SurfaceScanner {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        case quick, extended

        public var sampleCount: Int { self == .quick ? 512 : 4096 }
        public var title: String { self == .quick ? String(localized: "Quick Scan") : String(localized: "Extended Scan") }
        public var detail: String {
            self == .quick ? String(localized: "\(512) regions · about 1 minute") : String(localized: "\(4096) regions · several minutes")
        }
    }

    public static let chunkBytes = 1 << 20
    /// Upper bounds (ms) of the latency histogram buckets; the last bucket is open-ended.
    public static let bucketLimitsMs: [Double] = [5, 20, 50, 150, 500, 1000]
    public static let bucketLabels = ["<5 ms", "5–20", "20–50", "50–150", "150–500", "0.5–1 s", ">1 s"]

    public struct Progress: Sendable {
        public var completed: Int
        public var total: Int
        public var readErrors: Int
        public var slowReads: Int
        public var currentMBps: Double
        public var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
    }

    /// The raw device node for a BSD name such as `disk4`.
    public static func rawDevicePath(bsdName: String) -> String { "/dev/r" + bsdName }

    /// True while the drive's device node exists.
    public static func deviceExists(bsdName: String) -> Bool {
        FileManager.default.fileExists(atPath: rawDevicePath(bsdName: bsdName))
    }

    /// Opens `/dev/rdiskN` through authopen (administrator authorization prompt).
    public static func openRawDevice(bsdName: String) throws -> Int32 {
        guard deviceExists(bsdName: bsdName) else { throw SurfaceScanError.deviceNotFound }
        let fd = rawDevicePath(bsdName: bsdName).withCString { DKAuthOpenReadOnly($0) }
        if fd >= 0 { return fd }
        if fd == Int32(DKAuthOpenLaunchFailed) { throw SurfaceScanError.helperFailed }
        throw deviceExists(bsdName: bsdName) ? SurfaceScanError.notOpened : SurfaceScanError.deviceNotFound
    }

    /// errno values that mean the device itself is gone, not that a region is unreadable.
    static func isDeviceLost(_ code: Int32) -> Bool {
        [ENXIO, ENODEV, EBADF, ENOENT].contains(code)
    }

    /// Runs the scan on an already open descriptor. The descriptor is not closed.
    ///
    /// A failed read counts as an unreadable region only while the device is still there. If the
    /// device disappears (the error says so, or `isDevicePresent` turns false), the scan throws
    /// `SurfaceScanError.deviceDisconnected` instead, so a disconnect is never recorded as bad media.
    public static func scan(fileDescriptor fd: Int32, capacity: UInt64, blockSize: Int, mode: Mode,
                            isCancelled: @Sendable () -> Bool,
                            isDevicePresent: @Sendable () -> Bool = { true },
                            progress: @Sendable (Progress) -> Void) throws -> SurfaceScanResult {
        let start = Date()
        let align = UInt64(max(512, blockSize))
        let chunk = UInt64(chunkBytes)
        let usable = capacity >= chunk ? capacity - chunk : 0
        let offsets = sampleOffsets(capacity: usable, samples: mode.sampleCount, align: align)

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkBytes, alignment: 4096)
        defer { buffer.deallocate() }

        var latencies: [Double] = []
        latencies.reserveCapacity(offsets.count)
        var errors: [UInt64] = []
        var bytes: UInt64 = 0
        var cancelled = false
        var lastReport = Date.distantPast

        for (index, offset) in offsets.enumerated() {
            if isCancelled() { cancelled = true; break }
            let t0 = DispatchTime.now().uptimeNanoseconds
            let n = pread(fd, buffer, chunkBytes, off_t(offset))
            let readError = n < 0 ? errno : 0
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
            if n < 0 {
                if isDeviceLost(readError) || !isDevicePresent() { throw SurfaceScanError.deviceDisconnected }
                errors.append(offset)
            } else {
                bytes += UInt64(n)
                latencies.append(ms)
            }
            if Date().timeIntervalSince(lastReport) > 0.15 || index == offsets.count - 1 {
                lastReport = Date()
                let elapsed = max(0.001, Date().timeIntervalSince(start))
                progress(Progress(completed: index + 1, total: offsets.count, readErrors: errors.count,
                                  slowReads: slowCount(latencies), currentMBps: Double(bytes) / 1_048_576 / elapsed))
            }
        }

        let sorted = latencies.sorted()
        let median = percentile(sorted, 0.5)
        var buckets = Array(repeating: 0, count: bucketLimitsMs.count + 1)
        for l in latencies {
            let index = bucketLimitsMs.firstIndex(where: { l < $0 }) ?? bucketLimitsMs.count
            buckets[index] += 1
        }
        let duration = Date().timeIntervalSince(start)
        return SurfaceScanResult(
            date: start, mode: mode, plannedSamples: offsets.count,
            completedSamples: latencies.count + errors.count, chunkBytes: chunkBytes, bytesRead: bytes,
            readErrors: errors.count, errorOffsets: Array(errors.prefix(32)),
            slowReads: slowCount(latencies), verySlowReads: latencies.filter { $0 >= 1000 }.count,
            medianLatencyMs: median, p95LatencyMs: percentile(sorted, 0.95), maxLatencyMs: sorted.last ?? 0,
            throughputMBps: duration > 0 ? Double(bytes) / 1_048_576 / duration : 0,
            latencyBuckets: buckets, duration: duration, cancelled: cancelled
        )
    }

    /// Stratified sampling: one aligned offset per equal stratum, jittered randomly,
    /// so repeated scans cover different parts of the surface. Always includes both ends.
    static func sampleOffsets(capacity: UInt64, samples: Int, align: UInt64) -> [UInt64] {
        guard capacity > 0, samples > 0 else { return [0] }
        let count = UInt64(samples)
        let stratum = max(align, capacity / count)
        var result: [UInt64] = []
        result.reserveCapacity(samples)
        var generator = SystemRandomNumberGenerator()
        for i in 0..<count {
            let base = i * stratum
            guard base <= capacity else { break }
            let span = min(stratum, capacity - base)
            let jitter = span > align ? UInt64.random(in: 0..<span, using: &generator) : 0
            let offset = (base + jitter) / align * align
            result.append(offset)
        }
        if let first = result.first, first != 0 { result[0] = 0 }
        let lastAligned = capacity / align * align
        if result.last != lastAligned { result.append(lastAligned) }
        return result
    }

    static func slowCount(_ latencies: [Double]) -> Int {
        guard latencies.count >= 8 else { return latencies.filter { $0 > 500 }.count }
        let median = percentile(latencies.sorted(), 0.5)
        let limit = max(150, median * 8)
        return latencies.filter { $0 > limit }.count
    }

    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[index]
    }
}
