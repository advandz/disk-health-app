//
//  DriveDiscovery.swift
//  Disk Health
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import CDiskKit
import Foundation
import IOKit

/// Enumerates physical storage devices through IOKit and collects everything
/// needed for analysis: identity, transport, SMART, I/O counters and volumes.
public enum DriveDiscovery {
    private static let nvmeCapableKey = "NVMe SMART Capable"
    private static let ataCapableKey = "SMART Capable"

    /// How long an idle hard drive's S.M.A.R.T. data may be reused before the drive is read again.
    static let idleReuseLimit: TimeInterval = 12 * 3600

    /// Reads every drive.
    ///
    /// `previous` holds the last snapshots. A hard drive whose host I/O counters haven't moved since
    /// its last S.M.A.R.T. read is idle and may be spun down; sending it S.M.A.R.T. commands would
    /// spin it up again, so its last data is reused for up to `idleReuseLimit`. Pass no snapshots
    /// to read every drive fresh.
    public static func scan(reusing previous: [DriveSnapshot] = []) -> [DriveSnapshot] {
        let mounted = VolumeScanner.mountedVolumes()
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDevice"),
                                           &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var drives: [DriveSnapshot] = []
        var seenBSD = Set<String>()
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            if let drive = snapshot(for: service, mounted: mounted, previous: previous), !seenBSD.contains(drive.bsdName) {
                seenBSD.insert(drive.bsdName)
                drives.append(drive)
            }
        }
        return drives.sorted { lhs, rhs in
            if lhs.isInternal != rhs.isInternal { return lhs.isInternal }
            return lhs.bsdName.localizedStandardCompare(rhs.bsdName) == .orderedAscending
        }
    }

    // MARK: - Per device

    static func snapshot(for service: io_service_t, mounted: [MountedVolume],
                         previous: [DriveSnapshot] = []) -> DriveSnapshot? {
        // Skip optical drives and virtual devices (disk images, RAM disks).
        if IORegistry.conforms(service, "IOCDBlockStorageDevice") { return nil }
        let props = IORegistry.properties(service)
        let protocolChars = props.dict("Protocol Characteristics") ?? [:]
        let interconnect = protocolChars.string("Physical Interconnect") ?? ""
        let location = protocolChars.string("Physical Interconnect Location") ?? props.string("Physical Interconnect Location") ?? ""
        if location == "File" || interconnect == "Virtual Interface" || interconnect == "RAM" { return nil }
        if IORegistry.className(service).contains("DiskImage") { return nil }

        guard let media = findMedia(of: service) else { return nil }   // e.g. empty card reader
        defer { IOObjectRelease(media.entry) }

        let deviceChars = props.dict("Device Characteristics") ?? [:]
        let ancestors = IORegistry.ancestors(service)
        defer { IORegistry.release(ancestors) }

        // USB bridge / reader information
        var usb: USBInfo?
        var usbLocationID: Int?
        if let usbDevice = ancestors.first(where: { IORegistry.conforms($0, "IOUSBHostDevice") || IORegistry.conforms($0, "IOUSBDevice") }) {
            let u = IORegistry.properties(usbDevice)
            usb = USBInfo(
                productName: u.string("USB Product Name") ?? u.string("kUSBProductString"),
                vendorName: u.string("USB Vendor Name") ?? u.string("kUSBVendorString"),
                serialNumber: u.string("USB Serial Number") ?? u.string("kUSBSerialNumberString"),
                vendorID: u.int("idVendor"),
                productID: u.int("idProduct"),
                linkSpeedBps: u.uint64("UsbLinkSpeed").map { Double($0) } ?? usbSpeed(fromDeviceSpeed: u.int("Device Speed")),
                bcdUSB: u.int("bcdUSB")
            )
            usbLocationID = u.int("locationID")
        }

        // SMART-capable service: the device itself or a close ancestor.
        let candidates = [service] + ancestors.prefix(4)
        let nvmeService = candidates.first { IORegistry.property($0, nvmeCapableKey) as? Bool == true }
        let ataService = candidates.first { IORegistry.property($0, ataCapableKey) as? Bool == true }

        // Interface classification
        var interface = classifyInterface(interconnect: interconnect, location: location, isNVMe: nvmeService != nil, usb: usb)
        let isInternal = location == "Internal" || (location.isEmpty && usb == nil && interface != .thunderbolt)

        let smart: SMARTData
        var smartEntryID: UInt64?
        var capturedAt = Date()
        if let s = nvmeService {
            smart = readNVMe(s)
            if interface == .pcie || interface == .unknown { interface = .nvme }
            smartEntryID = IORegistry.entryID(s)
        } else if let s = ataService {
            let entryID = IORegistry.entryID(s)
            if let idle = reusableIdleSnapshot(entryID: entryID, io: media.statistics, previous: previous) {
                // Keep the original capture time: the data is the same, so no new history point is added.
                smart = idle.smart
                capturedAt = idle.capturedAt
            } else {
                smart = readATA(s)
            }
            smartEntryID = entryID
        } else if interface == .usb || interface == .sdCard {
            smart = .unavailable(reason: bridgedSMARTUnavailableReason)
        } else {
            smart = .unavailable(reason: String(localized: "This device does not expose a S.M.A.R.T. interface to macOS."))
        }
        // Identity
        var model = deviceChars.string("Product Name")
        var vendor = deviceChars.string("Vendor Name")
        var serial = deviceChars.string("Serial Number")
        var firmware = deviceChars.string("Product Revision Level")
        var supportsTrim: Bool?
        var medium = mediumType(deviceChars.string("Medium Type"))
        var linkDescription: String?

        switch smart {
        case let .nvme(_, info):
            model = model ?? info?.model
            serial = serial ?? info?.serial
            firmware = firmware ?? info?.firmware
            medium = .solidState
            supportsTrim = (props.dict("IOStorageFeatures")?.bool("Unmap")) ?? true
        case let .ata(ata):
            if let id = ata.identify {
                model = id.model ?? model
                serial = id.serial ?? serial
                firmware = id.firmware ?? firmware
                supportsTrim = id.trimSupported
                if let ssd = id.isSolidState { medium = ssd ? .solidState : .rotational }
                if let gen = id.sataGenerationCurrent { linkDescription = ATAIdentify.sataSpeedName(gen) }
            }
        case .unavailable:
            if let unmap = props.dict("IOStorageFeatures")?.bool("Unmap") { supportsTrim = unmap }
        }
        if let usb {
            if model == nil || model?.isEmpty == true { model = usb.productName }
            if vendor == nil { vendor = usb.vendorName }
            if serial == nil { serial = usb.serialNumber }
            linkDescription = usb.speedDescription
        }
        if interface == .sdCard, medium == .unknown { medium = .flash }

        let isRemovable = media.props.bool("Removable") ?? false
        let isEjectable = media.props.bool("Ejectable") ?? false
        if medium == .unknown, interface == .usb, isRemovable { medium = .flash }

        let kind = classifyKind(interface: interface, isInternal: isInternal, medium: medium, removable: isRemovable)
        let bsdName = media.props.string("BSD Name") ?? "disk?"
        let capacity = media.props.uint64("Size") ?? 0
        let displayModel = (model?.isEmpty == false ? model : nil) ?? "\(vendor ?? "Unknown") Drive"
        let name = displayName(model: displayModel, vendor: vendor, kind: kind)

        // History is keyed by this identity. Drives with a serial number keep the key they always had.
        // Without one, model and capacity alone would make identical cards or sticks share history,
        // so a partition-table UUID (or failing that, the USB port) tells them apart.
        let identityKey: String
        if serial != nil || usb?.serialNumber != nil {
            identityKey = [displayModel, serial ?? usb?.serialNumber ?? "", serial == nil ? "\(capacity)" : ""]
                .filter { !$0.isEmpty }.joined(separator: "|")
        } else {
            let distinguisher = media.uuid.map { "uuid:\($0)" }
                ?? usbLocationID.map { "usb-location:\(String($0, radix: 16))" } ?? ""
            identityKey = [displayModel, "\(capacity)", distinguisher].filter { !$0.isEmpty }.joined(separator: "|")
        }

        let volumes = VolumeScanner.volumes(for: media.descendantBSDNames, from: mounted)

        return DriveSnapshot(
            id: identityKey,
            bsdName: bsdName,
            name: name,
            model: displayModel,
            vendor: vendor,
            serial: serial,
            firmware: firmware,
            interface: interface,
            isInternal: isInternal,
            medium: medium,
            kind: kind,
            capacityBytes: capacity,
            logicalBlockSize: media.props.int("Preferred Block Size") ?? props.int("Logical Block Size") ?? 512,
            physicalBlockSize: props.int("Physical Block Size"),
            isRemovable: isRemovable,
            isEjectable: isEjectable,
            supportsTrim: supportsTrim,
            usb: usb,
            linkDescription: linkDescription,
            smart: smart,
            io: media.statistics,
            volumes: volumes,
            capturedAt: capturedAt,
            isSample: false,
            smartServiceEntryID: smartEntryID
        )
    }

    // MARK: - Media & driver

    struct MediaInfo {
        var entry: io_registry_entry_t
        var props: [String: Any]
        var statistics: IOStatistics?
        var descendantBSDNames: Set<String>
        /// The disk's partition-table UUID, or its first partition's (GPT disks have them; MBR ones don't).
        var uuid: String?
    }

    /// The previous snapshot of an idle hard drive, if its S.M.A.R.T. data can be reused without
    /// sending the drive any command.
    static func reusableIdleSnapshot(entryID: UInt64?, io: IOStatistics?, previous: [DriveSnapshot],
                                     now: Date = Date()) -> DriveSnapshot? {
        guard let entryID, let io,
              let last = previous.first(where: { $0.smartServiceEntryID == entryID }),
              last.medium == .rotational,
              case let .ata(ata) = last.smart, !ata.selfTestInProgress,   // a self-test does no host I/O
              let lastIO = last.io, lastIO.totalOperations == io.totalOperations,
              now.timeIntervalSince(last.capturedAt) < idleReuseLimit
        else { return nil }
        return last
    }

    /// Device → IOBlockStorageDriver → whole-disk IOMedia.
    static func findMedia(of service: io_service_t) -> MediaInfo? {
        let children = IORegistry.children(service)
        defer { IORegistry.release(children) }
        for driver in children where IORegistry.conforms(driver, "IOBlockStorageDriver") {
            let driverProps = IORegistry.properties(driver)
            let mediaChildren = IORegistry.children(driver)
            var found: MediaInfo?
            for m in mediaChildren where found == nil && IORegistry.conforms(m, "IOMedia") {
                let mp = IORegistry.properties(m)
                guard mp.bool("Whole") == true, mp.string("BSD Name") != nil else { continue }
                IOObjectRetain(m)
                var names = Set<String>()
                if let own = mp.string("BSD Name") { names.insert(own) }
                var firstPartition: (id: Int, uuid: String)?
                let descendants = IORegistry.descendants(m)
                for d in descendants where IORegistry.conforms(d, "IOMedia") {
                    if let n = IORegistry.property(d, "BSD Name") as? String { names.insert(n) }
                    if let uuid = IORegistry.property(d, "UUID") as? String,
                       let partition = (IORegistry.property(d, "Partition ID") as? NSNumber)?.intValue,
                       partition < (firstPartition?.id ?? .max) {
                        firstPartition = (partition, uuid)
                    }
                }
                IORegistry.release(descendants)
                found = MediaInfo(entry: m, props: mp, statistics: statistics(driverProps.dict("Statistics")),
                                  descendantBSDNames: names, uuid: mp.string("UUID") ?? firstPartition?.uuid)
            }
            IORegistry.release(mediaChildren)
            if let found { return found }
        }
        return nil
    }

    static func statistics(_ d: [String: Any]?) -> IOStatistics? {
        guard let d else { return nil }
        var s = IOStatistics()
        s.bytesRead = d.uint64("Bytes (Read)") ?? 0
        s.bytesWritten = d.uint64("Bytes (Write)") ?? 0
        s.readOperations = d.uint64("Operations (Read)") ?? 0
        s.writeOperations = d.uint64("Operations (Write)") ?? 0
        s.readErrors = d.uint64("Errors (Read)") ?? 0
        s.writeErrors = d.uint64("Errors (Write)") ?? 0
        s.readRetries = d.uint64("Retries (Read)") ?? 0
        s.writeRetries = d.uint64("Retries (Write)") ?? 0
        s.totalReadTimeNs = d.uint64("Total Time (Read)") ?? 0
        s.totalWriteTimeNs = d.uint64("Total Time (Write)") ?? 0
        return s
    }

    // MARK: - SMART

    static func readNVMe(_ service: io_service_t) -> SMARTData {
        var log = [UInt8](repeating: 0, count: 512)
        var identify = [UInt8](repeating: 0, count: 4096)
        var identifyResult: Int32 = 0
        let result = log.withUnsafeMutableBufferPointer { logPtr in
            identify.withUnsafeMutableBufferPointer { idPtr in
                DKNVMeReadHealth(UInt32(service), logPtr.baseAddress, idPtr.baseAddress, &identifyResult)
            }
        }
        guard result == 0 else {
            let code = String(format: "0x%08x", UInt32(bitPattern: result))
            return .unavailable(reason: String(localized: "The NVMe health log could not be read (IOReturn \(code))."))
        }
        let info = identifyResult == 0 ? NVMeParser.parseIdentifyController(identify) : nil
        return .nvme(NVMeParser.parseHealthLog(log), info)
    }

    static func readATA(_ service: io_service_t) -> SMARTData {
        var data = [UInt8](repeating: 0, count: 512)
        var thresholds = [UInt8](repeating: 0, count: 512)
        var identify = [UInt8](repeating: 0, count: 512)
        var errorLog = [UInt8](repeating: 0, count: 512)
        var selfTestLog = [UInt8](repeating: 0, count: 512)
        var exceeded = false
        var availability: UInt32 = 0
        let result = data.withUnsafeMutableBufferPointer { d in
            thresholds.withUnsafeMutableBufferPointer { t in
                identify.withUnsafeMutableBufferPointer { i in
                    errorLog.withUnsafeMutableBufferPointer { e in
                        selfTestLog.withUnsafeMutableBufferPointer { s in
                            DKATAReadSMART(UInt32(service), d.baseAddress, t.baseAddress, i.baseAddress,
                                           e.baseAddress, s.baseAddress, &exceeded, &availability)
                        }
                    }
                }
            }
        }
        let has = { (flag: Int) in availability & UInt32(flag) != 0 }
        guard result == 0 || has(DKATAHasStatus) else {
            let code = String(format: "0x%08x", UInt32(bitPattern: result))
            return .unavailable(reason: String(localized: "S.M.A.R.T. data could not be read (IOReturn \(code)). S.M.A.R.T. may be turned off on this drive; Disk Health leaves that setting unchanged."))
        }
        return .ata(ATAParser.parse(
            data: has(DKATAHasData) ? data : [],
            thresholds: has(DKATAHasThresholds) ? thresholds : nil,
            identify: has(DKATAHasIdentify) ? identify : nil,
            errorLog: has(DKATAHasErrorLog) ? errorLog : nil,
            overallPassed: has(DKATAHasStatus) ? !exceeded : nil
        ))
    }

    /// Starts an ATA self-test on the drive's SMART service.
    public static func startSelfTest(serviceEntryID: UInt64, extended: Bool) -> Bool {
        let service = IORegistry.service(withEntryID: serviceEntryID)
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        return DKATAStartSelfTest(UInt32(service), extended) == 0
    }

    // MARK: - Classification

    static func classifyInterface(interconnect: String, location: String, isNVMe: Bool, usb: USBInfo?) -> DriveInterface {
        let product = (usb?.productName ?? "").lowercased()
        switch interconnect {
        case "Apple Fabric": return .appleFabric
        case "Secure Digital": return .sdCard
        case "USB":
            if ["card reader", "sd card", "sdxc", "sd/mmc", "mmc", "cardreader", "sd reader"].contains(where: product.contains) {
                return .sdCard
            }
            return .usb
        case "SATA", "ATA", "Serial ATA": return .sata
        case "PCI-Express", "PCI", "PCIe":
            if location == "External" { return .thunderbolt }
            return isNVMe ? .nvme : .pcie
        case "FireWire": return .firewire
        case "SAS": return .sas
        case "Thunderbolt": return .thunderbolt
        default:
            if usb != nil { return .usb }
            return isNVMe ? .nvme : .unknown
        }
    }

    static func mediumType(_ value: String?) -> MediumType {
        switch value {
        case "Solid State": return .solidState
        case "Rotational": return .rotational
        default: return .unknown
        }
    }

    static func classifyKind(interface: DriveInterface, isInternal: Bool, medium: MediumType, removable: Bool) -> DriveKind {
        if interface == .sdCard { return .sdCard }
        if isInternal { return medium == .rotational ? .internalHDD : .internalSSD }
        switch medium {
        case .rotational: return .externalHDD
        case .solidState: return .externalSSD
        case .flash: return interface == .usb && removable ? .usbFlash : .externalSSD
        case .unknown: return .externalDrive
        }
    }

    /// Shown for USB drives and card readers, whose bridges don't pass S.M.A.R.T. through.
    static var bridgedSMARTUnavailableReason: String {
        String(localized: "macOS does not pass S.M.A.R.T. commands through USB bridges and card readers without a third-party driver. If one (e.g. a SAT SMART driver) is installed, data appears here automatically.")
    }

    static func displayName(model: String, vendor: String?, kind: DriveKind) -> String {
        var name = model
        if let vendor, !vendor.isEmpty, !model.lowercased().contains(vendor.lowercased()),
           vendor.lowercased() != "generic" {
            name = "\(vendor) \(model)"
        }
        if ["external", "usb", "disk", "generic", "mass storage", "usb drive"].contains(model.lowercased()) {
            name = (vendor.map { "\($0) " } ?? "") + kind.displayName
        }
        return name
    }

    static func usbSpeed(fromDeviceSpeed speed: Int?) -> Double? {
        switch speed {
        case 0: return 1_500_000
        case 1: return 12_000_000
        case 2: return 480_000_000
        case 3: return 5_000_000_000
        case 4: return 10_000_000_000
        case 5: return 20_000_000_000
        default: return nil
        }
    }
}
