//
//  UpdateVerification.swift
//  Disk Health
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import CryptoKit
import Foundation

/// When the app looks for a new version on its own.
///
/// It checks every time it starts, and while it keeps running, again once a day. A check that fails
/// (offline, GitHub unreachable) doesn't count, so it's retried at the next hourly tick.
public enum UpdateSchedule {
    /// Time between automatic checks while the app runs.
    public static let interval: TimeInterval = 24 * 3600
    /// How often a running app looks at whether a check is due.
    public static let tick: TimeInterval = 3600

    /// Whether a periodic check is due, given the last successful one.
    /// A last-check date in the future (the clock was set back) counts as due.
    public static func isDue(lastCheck: Date?, now: Date = Date()) -> Bool {
        guard let lastCheck, lastCheck <= now else { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }
}

/// Ed25519 signatures on release disk images (made by `scripts/update-signing.swift`).
///
/// An update is installed only if its `.dmg.sig` is a valid signature of the exact disk-image bytes
/// under the publisher's public key built into the app. A replaced, modified or re-signed image, a
/// signature made with another key, or a missing or malformed signature file is rejected.
public enum UpdateSignature {
    /// Signature files are one base64 line; anything much larger isn't one.
    public static let maximumFileSize = 1024

    /// Checks `image` against the contents of a `.sig` file and a base64 raw Ed25519 public key.
    public static func isValid(signatureFile: Data, for image: Data, publicKey: String) -> Bool {
        guard signatureFile.count <= maximumFileSize,
              let text = String(data: signatureFile, encoding: .utf8),
              let signature = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              signature.count == 64,
              let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else { return false }
        return key.isValidSignature(signature, for: image)
    }
}
