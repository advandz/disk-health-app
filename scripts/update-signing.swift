//
//  update-signing.swift
//  Disk Health
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

// Signs release disk images so the in-app updater can tell they came from the publisher.
//
//   swift scripts/update-signing.swift generate          creates the key pair (once) and prints the public key
//   swift scripts/update-signing.swift public-key        prints the public key for Updater.signingPublicKey
//   swift scripts/update-signing.swift sign <file.dmg>   writes <file.dmg>.sig next to it
//   swift scripts/update-signing.swift verify <file.dmg> <public key>
//                                                        checks <file.dmg>.sig the way the app will
//
// The private key (Ed25519) lives outside the repository, in ~/.config/disk-health/update-signing.key
// (or the path in DISK_HEALTH_SIGNING_KEY), readable only by you. Back it up: without it, new
// releases can't be installed automatically by existing copies of the app.
import CryptoKit
import Foundation

let keyURL: URL = {
    if let path = ProcessInfo.processInfo.environment["DISK_HEALTH_SIGNING_KEY"], !path.isEmpty {
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/disk-health/update-signing.key")
}()

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func loadKey() -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOf: keyURL, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else { fail("No signing key at \(keyURL.path). Run: swift scripts/update-signing.swift generate") }
    return key
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "generate":
    guard !FileManager.default.fileExists(atPath: keyURL.path) else {
        fail("A signing key already exists at \(keyURL.path); not replacing it.")
    }
    let key = Curve25519.Signing.PrivateKey()
    let directory = keyURL.deletingLastPathComponent()
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Create the file with owner-only permissions before any key bytes are written.
        guard FileManager.default.createFile(atPath: keyURL.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            fail("Couldn't create \(keyURL.path)")
        }
        try Data((key.rawRepresentation.base64EncodedString() + "\n").utf8).write(to: keyURL)
    } catch {
        fail("Couldn't save the key: \(error.localizedDescription)")
    }
    print("Saved the private key to \(keyURL.path) (owner-only). Back it up somewhere safe.")
    print("Public key: \(key.publicKey.rawRepresentation.base64EncodedString())")

case "public-key":
    print(loadKey().publicKey.rawRepresentation.base64EncodedString())

case "sign":
    guard arguments.count == 2 else { fail("usage: update-signing.swift sign <file.dmg>") }
    let file = URL(fileURLWithPath: arguments[1])
    guard let data = try? Data(contentsOf: file) else { fail("Couldn't read \(file.path)") }
    let signature = try loadKey().signature(for: data)
    let output = file.appendingPathExtension("sig")
    try Data((signature.base64EncodedString() + "\n").utf8).write(to: output)
    print("Signed \(file.lastPathComponent) → \(output.lastPathComponent)")

case "verify":
    guard arguments.count == 3 else { fail("usage: update-signing.swift verify <file.dmg> <public key>") }
    let file = URL(fileURLWithPath: arguments[1])
    guard let image = try? Data(contentsOf: file),
          let text = try? String(contentsOf: file.appendingPathExtension("sig"), encoding: .utf8),
          let signature = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let keyData = Data(base64Encoded: arguments[2]),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    else { fail("Couldn't read \(file.lastPathComponent), its .sig or the public key") }
    guard key.isValidSignature(signature, for: image) else {
        fail("\(file.lastPathComponent).sig doesn't verify with the public key built into the app")
    }
    print("Verified \(file.lastPathComponent).sig")

default:
    fail("usage: update-signing.swift generate | public-key | sign <file.dmg> | verify <file.dmg> <public key>")
}
