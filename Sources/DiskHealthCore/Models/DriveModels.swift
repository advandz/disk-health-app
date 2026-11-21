//
//  DriveModels.swift
//  Disk Health
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import Foundation

// MARK: - Classification

public enum DriveInterface: String, Codable, Sendable, Hashable {
    case nvme = "NVMe"
    case sata = "SATA"
    case usb = "USB"
    case thunderbolt = "Thunderbolt"
    case sdCard = "SD Card"
    case appleFabric = "Apple Fabric (NVMe)"
    case pcie = "PCIe"
    case firewire = "FireWire"
    case sas = "SAS"
    case unknown = "Unknown"

    /// Localized name for display (the raw value is a stable identifier).
    public var displayName: String {
        switch self {
        case .sdCard: return String(localized: "SD Card")
        case .appleFabric: return String(localized: "Apple Fabric (NVMe)")
        case .unknown: return String(localized: "Unknown", comment: "Drive interface")
        default: return rawValue
        }
    }
}

public enum MediumType: String, Codable, Sendable, Hashable {
    case solidState = "SSD"
    case rotational = "HDD"
    case flash = "Flash"
    case unknown = "Unknown"

    public var isSolidState: Bool { self == .solidState || self == .flash }

    /// Localized name for display (the raw value is a stable identifier).
    public var displayName: String {
        switch self {
        case .solidState: return String(localized: "SSD")
        case .rotational: return String(localized: "HDD")
        case .flash: return String(localized: "Flash", comment: "Storage medium")
        case .unknown: return String(localized: "Unknown", comment: "Storage medium")
        }
    }
}

public enum DriveKind: String, Codable, Sendable, Hashable {
    case internalSSD, internalHDD, externalSSD, externalHDD, usbFlash, sdCard, externalDrive

    public var displayName: String {
        switch self {
        case .internalSSD: return String(localized: "Internal SSD")
        case .internalHDD: return String(localized: "Internal Hard Drive")
        case .externalSSD: return String(localized: "External SSD")
        case .externalHDD: return String(localized: "External Hard Drive")
        case .usbFlash: return String(localized: "USB Flash Drive")
        case .sdCard: return String(localized: "SD Card")
        case .externalDrive: return String(localized: "External Drive")
        }
    }

    public var symbolName: String {
        switch self {
        case .internalSSD, .internalHDD: return "internaldrive.fill"
        case .externalSSD, .externalHDD, .externalDrive: return "externaldrive.fill"
        case .usbFlash: return "mediastick"
        case .sdCard: return "sdcard.fill"
        }
    }
}

// MARK: - Transport details

public struct USBInfo: Codable, Sendable, Hashable {
    public var productName: String?
    public var vendorName: String?
    public var serialNumber: String?
    public var vendorID: Int?
    public var productID: Int?
    /// Negotiated link speed in bits per second.
    public var linkSpeedBps: Double?
    /// USB spec the device declares (bcdUSB), e.g. 0x0300 for USB 3.0.
    public var bcdUSB: Int?

    public init(productName: String? = nil, vendorName: String? = nil, serialNumber: String? = nil,
                vendorID: Int? = nil, productID: Int? = nil, linkSpeedBps: Double? = nil, bcdUSB: Int? = nil) {
        self.productName = productName
        self.vendorName = vendorName
        self.serialNumber = serialNumber
        self.vendorID = vendorID
        self.productID = productID
        self.linkSpeedBps = linkSpeedBps
        self.bcdUSB = bcdUSB
    }

    public var speedDescription: String? {
        guard let bps = linkSpeedBps, bps > 0 else { return nil }
        switch bps {
        case ..<2_000_000: return "USB 1.1 Low Speed (1.5 Mb/s)"
        case ..<20_000_000: return "USB 1.1 Full Speed (12 Mb/s)"
        case ..<1_000_000_000: return "USB 2.0 High Speed (480 Mb/s)"
        case ..<6_000_000_000: return "USB 3.2 Gen 1 (5 Gb/s)"
        case ..<15_000_000_000: return "USB 3.2 Gen 2 (10 Gb/s)"
        case ..<30_000_000_000: return "USB 3.2 Gen 2x2 (20 Gb/s)"
        default: return "USB4 (\(Int(bps / 1_000_000_000)) Gb/s)"
        }
    }

    /// True when a USB 3 capable device is negotiated at USB 2 (or slower) speed.
    public var isRunningBelowCapability: Bool {
        guard let bcd = bcdUSB, let bps = linkSpeedBps else { return false }
        return bcd >= 0x0300 && bps < 1_000_000_000
    }
}

/// I/O counters published by IOBlockStorageDriver since the device was attached.
public struct IOStatistics: Codable, Sendable, Hashable {
    public var bytesRead: UInt64 = 0
    public var bytesWritten: UInt64 = 0
    public var readOperations: UInt64 = 0
    public var writeOperations: UInt64 = 0
    public var readErrors: UInt64 = 0
    public var writeErrors: UInt64 = 0
    public var readRetries: UInt64 = 0
    public var writeRetries: UInt64 = 0
    public var totalReadTimeNs: UInt64 = 0
    public var totalWriteTimeNs: UInt64 = 0

    public init() {}

    public var totalErrors: UInt64 { readErrors + writeErrors }
    public var totalRetries: UInt64 { readRetries + writeRetries }
    public var totalOperations: UInt64 { readOperations + writeOperations }

    public var averageReadLatencyMs: Double? {
        guard readOperations > 0, totalReadTimeNs > 0 else { return nil }
        return Double(totalReadTimeNs) / Double(readOperations) / 1_000_000
    }

    public var averageWriteLatencyMs: Double? {
        guard writeOperations > 0, totalWriteTimeNs > 0 else { return nil }
        return Double(totalWriteTimeNs) / Double(writeOperations) / 1_000_000
    }
}

public struct VolumeInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: String { bsdName + mountPoint }
    public var bsdName: String
    public var name: String
    public var mountPoint: String
    public var fileSystem: String
    public var fileSystemDescription: String?
    public var totalBytes: Int64
    public var availableBytes: Int64
    /// Volumes that share storage (APFS volumes in one container) share this key.
    public var containerKey: String
    public var isReadOnly: Bool

    public init(bsdName: String, name: String, mountPoint: String, fileSystem: String,
                fileSystemDescription: String?, totalBytes: Int64, availableBytes: Int64,
                containerKey: String, isReadOnly: Bool) {
        self.bsdName = bsdName
        self.name = name
        self.mountPoint = mountPoint
        self.fileSystem = fileSystem
        self.fileSystemDescription = fileSystemDescription
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.containerKey = containerKey
        self.isReadOnly = isReadOnly
    }

    public var usedBytes: Int64 { max(0, totalBytes - availableBytes) }
    public var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
}

// MARK: - NVMe

/// Parsed NVMe SMART / Health Information log (Log Page 02h).
public struct NVMeHealthLog: Codable, Sendable, Hashable {
    public var criticalWarning: UInt8 = 0
    public var temperatureKelvin: Int = 0
    public var availableSpare: Int = 100
    public var availableSpareThreshold: Int = 10
    public var percentageUsed: Int = 0
    public var enduranceGroupCriticalWarning: UInt8 = 0
    public var dataUnitsRead: Double = 0
    public var dataUnitsWritten: Double = 0
    public var hostReadCommands: Double = 0
    public var hostWriteCommands: Double = 0
    public var controllerBusyMinutes: Double = 0
    public var powerCycles: Double = 0
    public var powerOnHours: Double = 0
    public var unsafeShutdowns: Double = 0
    public var mediaErrors: Double = 0
    public var errorLogEntries: Double = 0
    public var warningTemperatureMinutes: Int = 0
    public var criticalTemperatureMinutes: Int = 0
    public var temperatureSensorsKelvin: [Int] = []
    public var thermalThrottle1Transitions: Int = 0
    public var thermalThrottle2Transitions: Int = 0
    public var thermalThrottle1Seconds: Int = 0
    public var thermalThrottle2Seconds: Int = 0

    public init() {}

    /// One NVMe data unit is 1000 × 512 bytes.
    public static let dataUnitBytes: Double = 512_000

    public var bytesRead: Double { dataUnitsRead * Self.dataUnitBytes }
    public var bytesWritten: Double { dataUnitsWritten * Self.dataUnitBytes }
    public var temperatureCelsius: Double? { temperatureKelvin > 0 ? Double(temperatureKelvin) - 273.15 : nil }

    public struct CriticalWarning: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let spareBelowThreshold = CriticalWarning(rawValue: 1 << 0)
        public static let temperature = CriticalWarning(rawValue: 1 << 1)
        public static let reliabilityDegraded = CriticalWarning(rawValue: 1 << 2)
        public static let readOnly = CriticalWarning(rawValue: 1 << 3)
        public static let volatileBackupFailed = CriticalWarning(rawValue: 1 << 4)
        public static let persistentMemoryReadOnly = CriticalWarning(rawValue: 1 << 5)
    }

    public var warnings: CriticalWarning { CriticalWarning(rawValue: criticalWarning) }
}

public struct NVMeControllerInfo: Codable, Sendable, Hashable {
    public var model: String?
    public var serial: String?
    public var firmware: String?
    public var pciVendorID: Int?
    /// Warning Composite Temperature Threshold (WCTEMP), Kelvin; 0 if not reported.
    public var warningTemperatureKelvin: Int = 0
    /// Critical Composite Temperature Threshold (CCTEMP), Kelvin; 0 if not reported.
    public var criticalTemperatureKelvin: Int = 0
    public var totalCapacityBytes: Double?

    public init() {}
}

// MARK: - ATA

public struct ATAAttribute: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var flags: UInt16
    public var current: Int
    public var worst: Int
    public var threshold: Int?
    public var rawBytes: [UInt8]

    public init(id: Int, flags: UInt16, current: Int, worst: Int, threshold: Int?, rawBytes: [UInt8]) {
        self.id = id
        self.flags = flags
        self.current = current
        self.worst = worst
        self.threshold = threshold
        self.rawBytes = rawBytes
    }

    public var name: String { ATAAttributeCatalog.name(for: id) }
    /// Pre-failure attribute (bit 0). Otherwise "old age" / advisory.
    public var isPrefail: Bool { flags & 0x1 != 0 }
    public var isOnline: Bool { flags & 0x2 != 0 }

    /// Full 48-bit little-endian raw value.
    public var raw: UInt64 {
        var value: UInt64 = 0
        for (index, byte) in rawBytes.prefix(6).enumerated() { value |= UInt64(byte) << (8 * UInt64(index)) }
        return value
    }
    public var raw32: UInt64 { raw & 0xFFFF_FFFF }
    public var raw16: UInt64 { raw & 0xFFFF }

    /// Normalized value is at or below the vendor threshold right now.
    public var isFailingNow: Bool {
        guard let t = threshold, t > 0, t < 0xFE else { return false }
        return current <= t
    }

    /// Worst-ever value dropped to or below threshold at some point.
    public var hasFailedInPast: Bool {
        guard let t = threshold, t > 0, t < 0xFE else { return false }
        return worst <= t && current > t
    }

    /// Value suitable for display, decoding attributes with packed raw formats.
    public var displayRaw: String {
        switch id {
        case 194, 190:
            let current = Int(rawBytes.first ?? 0)
            let low = rawBytes.count > 2 ? Int(rawBytes[2]) : 0
            let high = rawBytes.count > 4 ? Int(rawBytes[4]) : 0
            if low > 0, high > 0, high >= low, high < 150 { return "\(current) (min \(low) / max \(high))" }
            return "\(current)"
        case 9:
            return "\(raw32)"
        case 188:
            return "\(raw16)"
        default:
            return "\(raw)"
        }
    }
}

public struct ATAIdentify: Codable, Sendable, Hashable {
    public var model: String?
    public var serial: String?
    public var firmware: String?
    /// 1 = non-rotating (SSD); >1 = nominal RPM; nil = not reported.
    public var rotationRate: Int?
    public var trimSupported: Bool = false
    public var sectorCount: UInt64 = 0
    public var logicalSectorSize: Int = 512
    /// Highest SATA generation supported (1 = 1.5 Gb/s, 2 = 3 Gb/s, 3 = 6 Gb/s).
    public var sataGenerationSupported: Int?
    /// Currently negotiated SATA generation.
    public var sataGenerationCurrent: Int?

    public init() {}

    public var isSolidState: Bool? {
        guard let rate = rotationRate else { return nil }
        return rate == 1
    }

    public static func sataSpeedName(_ gen: Int) -> String {
        switch gen {
        case 1: return "SATA I (1.5 Gb/s)"
        case 2: return "SATA II (3 Gb/s)"
        case 3: return "SATA III (6 Gb/s)"
        default: return "SATA"
        }
    }
}

public struct ATAHealthData: Codable, Sendable, Hashable {
    public var attributes: [ATAAttribute]
    /// SMART RETURN STATUS: true = passed, false = threshold exceeded, nil = not available.
    public var overallPassed: Bool?
    /// Self-test execution status byte (offset 363 of SMART data).
    public var selfTestStatus: Int?
    /// Error count from the SMART summary error log.
    public var errorLogCount: Int?
    public var identify: ATAIdentify?
    public var shortTestMinutes: Int?
    public var extendedTestMinutes: Int?

    public init(attributes: [ATAAttribute], overallPassed: Bool?, selfTestStatus: Int?,
                errorLogCount: Int?, identify: ATAIdentify?, shortTestMinutes: Int? = nil, extendedTestMinutes: Int? = nil) {
        self.attributes = attributes
        self.overallPassed = overallPassed
        self.selfTestStatus = selfTestStatus
        self.errorLogCount = errorLogCount
        self.identify = identify
        self.shortTestMinutes = shortTestMinutes
        self.extendedTestMinutes = extendedTestMinutes
    }

    public func attribute(_ id: Int) -> ATAAttribute? { attributes.first { $0.id == id } }

    public var selfTestInProgress: Bool { (selfTestStatus ?? 0) >> 4 == 0xF }
    /// Percent of self-test remaining when in progress.
    public var selfTestRemainingPercent: Int? {
        guard selfTestInProgress, let s = selfTestStatus else { return nil }
        return (s & 0x0F) * 10
    }
}

// MARK: - SMART container

public enum SMARTData: Codable, Sendable, Hashable {
    case nvme(NVMeHealthLog, NVMeControllerInfo?)
    case ata(ATAHealthData)
    case unavailable(reason: String)

    public var isAvailable: Bool {
        if case .unavailable = self { return false }
        return true
    }

    public var protocolName: String {
        switch self {
        case .nvme: return String(localized: "NVMe Health Log")
        case .ata: return "ATA S.M.A.R.T."
        case .unavailable: return String(localized: "Not available")
        }
    }
}

// MARK: - Snapshot

/// Everything known about one physical drive at a moment in time.
public struct DriveSnapshot: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var bsdName: String
    public var name: String
    public var model: String
    public var vendor: String?
    public var serial: String?
    public var firmware: String?
    public var interface: DriveInterface
    public var isInternal: Bool
    public var medium: MediumType
    public var kind: DriveKind
    public var capacityBytes: UInt64
    public var logicalBlockSize: Int
    public var physicalBlockSize: Int?
    public var isRemovable: Bool
    public var isEjectable: Bool
    public var supportsTrim: Bool?
    public var usb: USBInfo?
    public var linkDescription: String?
    public var smart: SMARTData
    public var io: IOStatistics?
    public var volumes: [VolumeInfo]
    public var capturedAt: Date
    public var isSample: Bool
    /// IORegistry entry ID of the service that exposes SMART (for self-tests).
    public var smartServiceEntryID: UInt64?

    public init(id: String, bsdName: String, name: String, model: String, vendor: String? = nil,
                serial: String? = nil, firmware: String? = nil, interface: DriveInterface, isInternal: Bool,
                medium: MediumType, kind: DriveKind, capacityBytes: UInt64, logicalBlockSize: Int = 512,
                physicalBlockSize: Int? = nil, isRemovable: Bool = false, isEjectable: Bool = false,
                supportsTrim: Bool? = nil, usb: USBInfo? = nil, linkDescription: String? = nil,
                smart: SMARTData, io: IOStatistics? = nil, volumes: [VolumeInfo] = [],
                capturedAt: Date = Date(), isSample: Bool = false, smartServiceEntryID: UInt64? = nil) {
        self.id = id
        self.bsdName = bsdName
        self.name = name
        self.model = model
        self.vendor = vendor
        self.serial = serial
        self.firmware = firmware
        self.interface = interface
        self.isInternal = isInternal
        self.medium = medium
        self.kind = kind
        self.capacityBytes = capacityBytes
        self.logicalBlockSize = logicalBlockSize
        self.physicalBlockSize = physicalBlockSize
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.supportsTrim = supportsTrim
        self.usb = usb
        self.linkDescription = linkDescription
        self.smart = smart
        self.io = io
        self.volumes = volumes
        self.capturedAt = capturedAt
        self.isSample = isSample
        self.smartServiceEntryID = smartServiceEntryID
    }

    /// Volumes that share storage are counted once.
    public var usage: (total: Int64, used: Int64)? {
        guard !volumes.isEmpty else { return nil }
        var seen = Set<String>()
        var total: Int64 = 0
        var used: Int64 = 0
        for v in volumes where !seen.contains(v.containerKey) {
            seen.insert(v.containerKey)
            total += v.totalBytes
            used += v.usedBytes
        }
        return (total, used)
    }

    public var supportsSelfTest: Bool {
        if case .ata = smart, smartServiceEntryID != nil { return true }
        return false
    }
}
