//
//  IORegistry.swift
//  Disk Health
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import Foundation
import IOKit

/// Small helpers around the IORegistry C API.
enum IORegistry {
    static func properties(_ entry: io_registry_entry_t) -> [String: Any] {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = unmanaged?.takeRetainedValue() as? [String: Any] else { return [:] }
        return dict
    }

    static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func className(_ entry: io_registry_entry_t) -> String {
        guard let name = IOObjectCopyClass(entry)?.takeRetainedValue() else { return "" }
        return name as String
    }

    static func conforms(_ entry: io_registry_entry_t, _ className: String) -> Bool {
        IOObjectConformsTo(entry, className) != 0
    }

    static func entryID(_ entry: io_registry_entry_t) -> UInt64? {
        var id: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS ? id : nil
    }

    /// Direct children in the IOService plane. Caller owns the returned objects.
    static func children(_ entry: io_registry_entry_t) -> [io_registry_entry_t] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        return drain(iterator)
    }

    /// All descendants (recursive). Caller owns the returned objects.
    static func descendants(_ entry: io_registry_entry_t) -> [io_registry_entry_t] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(entry, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively),
                                            &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        return drain(iterator)
    }

    /// All ancestors, nearest first. Caller owns the returned objects.
    static func ancestors(_ entry: io_registry_entry_t) -> [io_registry_entry_t] {
        var iterator: io_iterator_t = 0
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        guard IORegistryEntryCreateIterator(entry, kIOServicePlane, options, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        return drain(iterator)
    }

    static func service(withEntryID id: UInt64) -> io_service_t {
        IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(id))
    }

    private static func drain(_ iterator: io_iterator_t) -> [io_registry_entry_t] {
        var result: [io_registry_entry_t] = []
        while true {
            let next = IOIteratorNext(iterator)
            if next == 0 { break }
            result.append(next)
        }
        return result
    }

    static func release(_ entries: [io_registry_entry_t]) {
        entries.forEach { IOObjectRelease($0) }
    }
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? {
        guard let s = self[key] as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    func uint64(_ key: String) -> UInt64? {
        if let n = self[key] as? NSNumber { return n.uint64Value }
        return nil
    }

    func int(_ key: String) -> Int? {
        if let n = self[key] as? NSNumber { return n.intValue }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        if let b = self[key] as? Bool { return b }
        if let n = self[key] as? NSNumber { return n.boolValue }
        return nil
    }

    func dict(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
}
