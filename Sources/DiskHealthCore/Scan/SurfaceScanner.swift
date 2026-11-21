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
}

public enum SurfaceScanError: LocalizedError {
    case authorizationDenied
    case invalidDevice

    public var errorDescription: String? {
        switch self {
        case .authorizationDenied: return String(localized: "Read access to the device was not authorized.")
        case .invalidDevice: return String(localized: "The device could not be opened for reading.")
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

    /// Opens `/dev/rdiskN` through authopen (administrator authorization prompt).
    public static func openRawDevice(bsdName: String) throws -> Int32 {
        let path = "/dev/r" + bsdName
        let fd = path.withCString { DKAuthOpenReadOnly($0) }
        guard fd >= 0 else { throw SurfaceScanError.authorizationDenied }
        return fd
    }

    /// Runs the scan on an already open descriptor. The descriptor is not closed.
    public static func scan(fileDescriptor fd: Int32, capacity: UInt64, blockSize: Int, mode: Mode,
                            isCancelled: @Sendable () -> Bool,
                            progress: @Sendable (Progress) -> Void) -> SurfaceScanResult {
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
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
            if n < 0 {
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
