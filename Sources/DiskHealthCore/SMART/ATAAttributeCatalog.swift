//
//  ATAAttributeCatalog.swift
//  Disk Health
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import Foundation

/// Names and meaning of common ATA S.M.A.R.T. attributes.
public enum ATAAttributeCatalog {
    public static func name(for id: Int) -> String {
        names[id].map { String(localized: $0) } ?? String(localized: "Vendor Specific (\(id))")
    }

    /// Short explanation of what an attribute measures, used in the UI.
    public static func explanation(for id: Int) -> String? {
        explanations[id].map { String(localized: $0) }
    }

    /// Attributes that carry an SSD's remaining-life percentage in their
    /// normalized value, in priority order.
    public static let wearIndicatorIDs: [Int] = [231, 233, 177, 202, 169, 248, 230, 173]

    /// Attributes whose raw value most strongly predicts failure (Backblaze et al.).
    public static let criticalIDs: Set<Int> = [5, 10, 184, 187, 188, 196, 197, 198, 199]

    private static let names: [Int: LocalizedStringResource] = [
        1: "Raw Read Error Rate",
        2: "Throughput Performance",
        3: "Spin-Up Time",
        4: "Start/Stop Count",
        5: "Reallocated Sectors Count",
        6: "Read Channel Margin",
        7: "Seek Error Rate",
        8: "Seek Time Performance",
        9: "Power-On Hours",
        10: "Spin Retry Count",
        11: "Calibration Retry Count",
        12: "Power Cycle Count",
        13: "Soft Read Error Rate",
        22: "Current Helium Level",
        160: "Uncorrectable Sector Count",
        161: "Valid Spare Blocks",
        163: "Initial Bad Blocks",
        164: "Total Erase Count",
        165: "Max Erase Count",
        166: "Min Erase Count",
        167: "Average Erase Count",
        168: "SATA PHY Error Count",
        169: "Remaining Life Percentage",
        170: "Available Reserved Space",
        171: "Program Fail Count",
        172: "Erase Fail Count",
        173: "Wear Leveling Count",
        174: "Unexpected Power Loss Count",
        175: "Power Loss Protection Failure",
        176: "Erase Fail Count (Chip)",
        177: "Wear Leveling Count",
        178: "Used Reserved Block Count (Chip)",
        179: "Used Reserved Block Count",
        180: "Unused Reserved Block Count",
        181: "Program Fail Count",
        182: "Erase Fail Count",
        183: "Runtime Bad Blocks / SATA Downshift",
        184: "End-to-End Error",
        187: "Reported Uncorrectable Errors",
        188: "Command Timeout",
        189: "High Fly Writes",
        190: "Airflow Temperature",
        191: "G-Sense Error Rate",
        192: "Power-Off Retract Count",
        193: "Load/Unload Cycle Count",
        194: "Temperature",
        195: "Hardware ECC Recovered",
        196: "Reallocation Event Count",
        197: "Current Pending Sectors",
        198: "Offline Uncorrectable Sectors",
        199: "UltraDMA CRC Error Count",
        200: "Multi-Zone Error Rate",
        201: "Soft Read Error Rate",
        202: "Percent Lifetime Remaining",
        203: "Run Out Cancel",
        204: "Soft ECC Correction",
        205: "Thermal Asperity Rate",
        206: "Flying Height",
        207: "Spin High Current",
        208: "Spin Buzz",
        209: "Offline Seek Performance",
        210: "Vibration During Write",
        211: "Vibration During Read",
        212: "Shock During Write",
        220: "Disk Shift",
        221: "G-Sense Error Rate",
        222: "Loaded Hours",
        223: "Load/Unload Retry Count",
        224: "Load Friction",
        225: "Load/Unload Cycle Count",
        226: "Load-in Time",
        227: "Torque Amplification Count",
        228: "Power-Off Retract Cycle",
        230: "Media Wearout / GMR Head Amplitude",
        231: "SSD Life Left",
        232: "Available Reserved Space",
        233: "Media Wearout Indicator",
        234: "Average / Max Erase Count",
        235: "Good Block Count / System Free Blocks",
        240: "Head Flying Hours",
        241: "Total Host Writes",
        242: "Total Host Reads",
        243: "Total LBAs Written (Expanded)",
        244: "Total LBAs Read (Expanded)",
        245: "Remaining Rated Write Endurance",
        246: "Cumulative Host Sectors Written",
        247: "Host Program Page Count",
        248: "Background Program Page Count / Life Remaining",
        249: "NAND Writes (1 GiB)",
        250: "Read Error Retry Rate",
        251: "Minimum Spares Remaining",
        252: "Newly Added Bad Flash Block",
        254: "Free Fall Protection",
    ]

    private static let explanations: [Int: LocalizedStringResource] = [
        1: "Rate of hardware read errors. Vendor-specific raw encoding; judge by normalized value.",
        5: "Sectors found bad and remapped to spares. Any growth is a strong failure predictor.",
        9: "Total hours the drive has been powered on.",
        10: "Retries needed to spin the platters up to speed. Indicates motor or power problems.",
        12: "Number of complete power on/off cycles.",
        177: "Remaining program/erase endurance of the NAND (normalized value = percent of life left).",
        184: "Parity errors between host and media inside the drive's data path.",
        187: "Errors that could not be recovered using hardware ECC.",
        188: "Operations aborted because of a drive timeout. Often power or cable related.",
        190: "Airflow temperature in °C.",
        194: "Drive temperature in °C.",
        196: "Number of remap operations performed.",
        197: "Unstable sectors waiting to be remapped. A strong predictor of imminent failure.",
        198: "Sectors that could not be read during off-line scan.",
        199: "Interface data-transfer CRC errors, usually a bad cable or enclosure.",
        202: "Remaining rated endurance (normalized value = percent of life left).",
        231: "Remaining SSD life (normalized value = percent of life left).",
        233: "NAND wear (normalized value = percent of life left).",
        241: "Total data written by the host.",
        242: "Total data read by the host.",
    ]
}
