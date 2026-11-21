//
//  VolumeScanner.swift
//  Disk Health
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import Darwin
import Foundation

/// A mounted file system backed by a /dev/disk node.
public struct MountedVolume: Sendable, Hashable {
    public var bsdName: String
    public var name: String
    public var mountPoint: String
    public var fileSystem: String
    public var fileSystemDescription: String?
    public var totalBytes: Int64
    public var availableBytes: Int64
    public var isReadOnly: Bool
}

enum VolumeScanner {
    static func mountedVolumes() -> [MountedVolume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeIsReadOnlyKey, .volumeLocalizedFormatDescriptionKey,
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: []) else {
            return []
        }
        var result: [MountedVolume] = []
        for url in urls {
            var fs = statfs()
            guard statfs(url.path, &fs) == 0 else { continue }
            let from = withUnsafePointer(to: &fs.f_mntfromname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            let type = withUnsafePointer(to: &fs.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
            }
            guard from.hasPrefix("/dev/disk") else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let blockSize = Int64(fs.f_bsize)
            let total = Int64(values?.volumeTotalCapacity ?? Int(Int64(fs.f_blocks) * blockSize))
            let available = values?.volumeAvailableCapacityForImportantUsage
                ?? Int64(values?.volumeAvailableCapacity ?? Int(Int64(fs.f_bavail) * blockSize))
            result.append(MountedVolume(
                bsdName: String(from.dropFirst("/dev/".count)),
                name: values?.volumeLocalizedName ?? values?.volumeName ?? url.lastPathComponent,
                mountPoint: url.path,
                fileSystem: type,
                fileSystemDescription: values?.volumeLocalizedFormatDescription,
                totalBytes: total,
                availableBytes: max(0, available),
                isReadOnly: values?.volumeIsReadOnly ?? false
            ))
        }
        return result
    }

    /// Whole-disk BSD name ("disk3s1s1" → "disk3").
    static func wholeDisk(_ bsd: String) -> String {
        guard bsd.hasPrefix("disk") else { return bsd }
        let digits = bsd.dropFirst(4).prefix { $0.isNumber }
        return "disk" + digits
    }

    /// Volumes that live on a physical disk, given the BSD names of all its descendants.
    static func volumes(for descendantBSDNames: Set<String>, from mounted: [MountedVolume]) -> [VolumeInfo] {
        var result: [VolumeInfo] = []
        for v in mounted {
            guard belongs(v.bsdName, to: descendantBSDNames) else { continue }
            // Hide APFS system helper volumes (Preboot, VM, Update, Recovery…); "/" represents the container.
            if v.mountPoint.hasPrefix("/System/Volumes/") { continue }
            let isAPFS = v.fileSystem == "apfs"
            result.append(VolumeInfo(
                bsdName: v.bsdName,
                name: v.mountPoint == "/" ? (v.name.isEmpty ? "Macintosh HD" : v.name) : v.name,
                mountPoint: v.mountPoint,
                fileSystem: v.fileSystem,
                fileSystemDescription: v.fileSystemDescription,
                totalBytes: v.totalBytes,
                availableBytes: v.availableBytes,
                containerKey: isAPFS ? wholeDisk(v.bsdName) : v.bsdName,
                isReadOnly: v.isReadOnly && v.mountPoint != "/"
            ))
        }
        return result.sorted { ($0.mountPoint == "/" ? 0 : 1, $0.name) < ($1.mountPoint == "/" ? 0 : 1, $1.name) }
    }

    /// Matches a volume BSD name against a disk's descendants; APFS snapshots
    /// ("disk3s1s1") are not IOMedia objects, so strip slice suffixes until one matches.
    static func belongs(_ bsd: String, to names: Set<String>) -> Bool {
        var candidate = bsd
        while true {
            if names.contains(candidate) { return true }
            guard let range = candidate.range(of: "s[0-9]+$", options: .regularExpression),
                  range.lowerBound > candidate.index(candidate.startIndex, offsetBy: 4) else { return false }
            candidate.removeSubrange(range)
        }
    }
}
