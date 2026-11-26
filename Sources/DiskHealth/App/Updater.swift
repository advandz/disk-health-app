//
//  Updater.swift
//  Disk Health
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import AppKit
import DiskHealthCore
import SwiftUI

// MARK: - Versions

/// A release version such as 1.2.3, parsed from a tag like "v1.2.3".
/// Pre-release tags ("1.2.0-beta") and anything that isn't numeric are ignored.
struct AppVersion: Comparable, CustomStringConvertible {
    let components: [Int]

    init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        guard !text.isEmpty, !text.contains("-"), !text.contains("+") else { return nil }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let number = Int(part), number >= 0 else { return nil }
            numbers.append(number)
        }
        components = numbers
    }

    private func padded(to count: Int) -> [Int] {
        components + Array(repeating: 0, count: max(0, count - components.count))
    }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        let n = max(a.components.count, b.components.count)
        return a.padded(to: n).lexicographicallyPrecedes(b.padded(to: n))
    }

    static func == (a: AppVersion, b: AppVersion) -> Bool {
        let n = max(a.components.count, b.components.count)
        return a.padded(to: n) == b.padded(to: n)
    }

    var description: String { padded(to: 3).map(String.init).joined(separator: ".") }

    /// The version of the running app.
    static var current: AppVersion {
        AppVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") ?? AppVersion("0")!
    }

    /// The newest release version among tag names, with the tag it came from.
    static func newest(in tags: [String]) -> (tag: String, version: AppVersion)? {
        tags.compactMap { tag in AppVersion(tag).map { (tag, $0) } }.max { $0.1 < $1.1 }
    }
}

// MARK: - GitHub

struct AvailableUpdate {
    let version: AppVersion
    let tag: String
    let notes: String
    /// The disk image attached to the tag's GitHub release, if there is one.
    let downloadURL: URL?
    /// Its Ed25519 signature (`<image>.dmg.sig`), attached to the same release.
    let signatureURL: URL?
    let pageURL: URL
}

enum UpdateError: LocalizedError {
    case server(Int)
    case invalidDownload(String)
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .server(let status): String(localized: "GitHub responded with an error (HTTP \(status)).")
        case .invalidDownload(let reason), .installFailed(let reason): reason
        }
    }
}

private struct GitHubTag: Decodable { let name: String }

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL
        enum CodingKeys: String, CodingKey { case name, browserDownloadURL = "browser_download_url" }
    }
    let body: String?
    let htmlURL: URL?
    let assets: [Asset]
    enum CodingKeys: String, CodingKey { case body, assets, htmlURL = "html_url" }
}

// MARK: - Updater

/// Checks the GitHub repository's tags for a newer version and offers to
/// install it, remind later, or skip that version.
@MainActor
final class Updater: NSObject {
    static let shared = Updater()
    static let repository = "advandz/disk-health-app"

    /// Public half of the release signing key (`scripts/update-signing.swift`). A downloaded disk image
    /// is installed only if its `.sig` verifies against this key, so a release file swapped on GitHub,
    /// or re-signed ad hoc, is refused.
    nonisolated static let signingPublicKey = "tUoX1JHmJqcB3GGcgxLj5ia1PqV+rMQNQlRRVejIqdw="

    /// Updating needs the app bundle (not `swift run`), and is off for demo runs and scripted exports.
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && !DemoMode.isActive
            && LaunchArguments.string("ExportReportPDF") == nil
    }

    /// Settings keys. Automatic checks are on unless turned off in Settings › Updates.
    enum Keys {
        static let checkAutomatically = "checkForUpdates"
        static let lastCheck = "lastUpdateCheck"
        static let skippedVersion = "skippedVersion"
    }

    private var isChecking = false
    private var pendingUpdate: AvailableUpdate?
    private var installer: UpdateInstaller?
    private var timer: Timer?

    /// The API base URL. For testing, `-UpdateFeedURL http://127.0.0.1:<port>` on the command line
    /// points it at a local copy of the API. It's read from launch arguments only and must be on this
    /// Mac, so a value written into the app's settings can't redirect updates.
    private var feedBase: String {
        if let override = LaunchArguments.string("UpdateFeedURL"), let url = URL(string: override),
           Self.isLocal(url) {
            return override
        }
        return "https://api.github.com/repos/\(Self.repository)"
    }

    nonisolated static func isLocal(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme ?? "") && ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "")
    }

    // MARK: Scheduling

    /// Automatic checks (on unless turned off in Settings › Updates): every time the app starts, then
    /// once a day while it runs (see `UpdateSchedule`). A failed check is retried at the next hourly tick.
    func start() {
        UserDefaults.standard.register(defaults: [Keys.checkAutomatically: true])
        // On startup: always, a moment after launch so the window is up first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.checkAutomatically(onStartup: true) }
        // While running: once a day. The hourly tick also catches up after sleep or time offline.
        timer = Timer.scheduledTimer(withTimeInterval: UpdateSchedule.tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAutomatically(onStartup: false) }
        }
        timer?.tolerance = 60
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // An update found while the app was in the background waits until it's in front.
                guard let self, let update = self.pendingUpdate else { return }
                self.pendingUpdate = nil
                self.present(update)
            }
        }
    }

    private func checkAutomatically(onStartup: Bool) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Keys.checkAutomatically) else { return }
        if !onStartup {
            let last = defaults.double(forKey: Keys.lastCheck)
            guard UpdateSchedule.isDue(lastCheck: last > 0 ? Date(timeIntervalSince1970: last) : nil) else { return }
        }
        check(userInitiated: false)
    }

    // MARK: Checking

    @objc func checkForUpdates(_ sender: Any?) {
        check(userInitiated: true)
    }

    func check(userInitiated: Bool) {
        if let installer {
            installer.bringToFront()
            return
        }
        guard !isChecking else { return }
        isChecking = true

        Task {
            defer { isChecking = false }
            do {
                let update = try await fetchNewestUpdate()
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Keys.lastCheck)

                guard let update, update.version > .current else {
                    if userInitiated { showUpToDate() }
                    return
                }
                // Automatic checks respect "Skip This Version"; asking explicitly always shows it.
                let skipped = UserDefaults.standard.string(forKey: Keys.skippedVersion)
                if !userInitiated, skipped == update.version.description { return }

                if userInitiated || NSApp.isActive {
                    present(update)
                } else {
                    pendingUpdate = update
                }
            } catch {
                if userInitiated { showCheckFailed(error) }
            }
        }
    }

    private func fetchNewestUpdate() async throws -> AvailableUpdate? {
        let tags: [GitHubTag] = try await get("tags?per_page=100")
        guard let newest = AppVersion.newest(in: tags.map(\.name)) else { return nil }

        let encodedTag = newest.tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? newest.tag
        let release: GitHubRelease? = try? await get("releases/tags/\(encodedTag)")
        let dmgAsset = release?.assets.first { $0.name.lowercased().hasSuffix(".dmg") }
        let dmg = dmgAsset?.browserDownloadURL
        let signature = dmgAsset.flatMap { image in
            release?.assets.first { $0.name.lowercased() == image.name.lowercased() + ".sig" }?.browserDownloadURL
        }
        let page = release?.htmlURL
            ?? URL(string: "https://github.com/\(Self.repository)/releases/tag/\(encodedTag)")!

        return AvailableUpdate(
            version: newest.version,
            tag: newest.tag,
            notes: release?.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            downloadURL: dmg.map(Self.isTrusted) == true ? dmg : nil,
            signatureURL: signature.map(Self.isTrusted) == true ? signature : nil,
            pageURL: page
        )
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        guard let url = URL(string: "\(feedBase)/\(path)") else { throw UpdateError.server(0) }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("DiskHealth/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.server(status) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Downloads must come over HTTPS (or from this Mac, when testing).
    nonisolated static func isTrusted(_ url: URL) -> Bool {
        url.scheme == "https" || isLocal(url)
    }

    // MARK: Prompts

    /// "Install Update", "Later" or "Skip This Version".
    private func present(_ update: AvailableUpdate) {
        NSApp.activate()
        // Without a signature there's no way to check the download, so it can only be opened on GitHub.
        let canInstall = update.downloadURL != nil && update.signatureURL != nil && UpdateInstaller.canReplaceRunningApp

        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        let newVersion = update.version.description, currentVersion = AppVersion.current.description
        alert.messageText = String(localized: "A new version of Disk Health is available")
        alert.informativeText = canInstall
            ? String(localized: "Disk Health \(newVersion) is available. You have \(currentVersion). Would you like to install it now? Disk Health will restart when it's done.")
            : String(localized: "Disk Health \(newVersion) is available. You have \(currentVersion).")
        if !update.notes.isEmpty {
            alert.accessoryView = Self.notesView(update.notes)
        }
        alert.addButton(withTitle: canInstall ? String(localized: "Install Update") : String(localized: "View Release"))
        let later = alert.addButton(withTitle: String(localized: "Later"))
        later.keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: String(localized: "Skip This Version"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if canInstall {
                install(update)
            } else {
                NSWorkspace.shared.open(update.pageURL)
            }
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(update.version.description, forKey: Keys.skippedVersion)
        default:
            break   // Later: ask again at the next check
        }
    }

    private func install(_ update: AvailableUpdate) {
        let installer = UpdateInstaller(update: update)
        installer.onFailure = { [weak self] error in
            self?.installer = nil
            self?.showInstallFailed(error, update: update)
        }
        installer.onCancel = { [weak self] in self?.installer = nil }
        self.installer = installer
        installer.start()
    }

    private func showUpToDate() {
        NSApp.activate()
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        let version = AppVersion.current.description
        alert.messageText = String(localized: "You're up to date")
        alert.informativeText = String(localized: "Disk Health \(version) is the newest version available.")
        alert.runModal()
    }

    private func showCheckFailed(_ error: Error) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Couldn't check for updates")
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private func showInstallFailed(_ error: Error, update: AvailableUpdate) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Couldn't install the update")
        let version = update.version.description
        alert.informativeText = error.localizedDescription + "\n\n"
            + String(localized: "You can download Disk Health \(version) from GitHub instead.")
        alert.addButton(withTitle: String(localized: "Open GitHub"))
        alert.addButton(withTitle: String(localized: "Close"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(update.pageURL)
        }
    }

    /// Release notes from GitHub, shown under the alert text.
    private static func notesView(_ notes: String) -> NSView {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let attributed = (try? NSMutableAttributedString(AttributedString(markdown: notes, options: options)))
            ?? NSMutableAttributedString(string: notes)
        let range = NSRange(location: 0, length: attributed.length)
        attributed.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
        attributed.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let base = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            let font = (value as? NSFont).map { NSFontManager.shared.convert($0, toSize: base.pointSize) } ?? base
            attributed.addAttribute(.font, value: font, range: subrange)
        }

        // Fit short notes; scroll long ones.
        let width: CGFloat = 360
        let fitted = attributed.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
        let height = min(max(ceil(fitted) + 12, 28), 160)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 0, height: 4)
        text.autoresizingMask = [.width]
        text.textStorage?.setAttributedString(attributed)
        scroll.documentView = text
        return scroll
    }
}

// MARK: - Installer

@MainActor
@Observable
private final class InstallProgress {
    var message = ""
    var fraction: Double? = 0
    var canCancel = true
}

/// Downloads the release's disk image, checks the app inside it, and swaps it
/// in for the running copy once Disk Health quits, then relaunches.
@MainActor
final class UpdateInstaller: NSObject {
    let update: AvailableUpdate
    var onFailure: ((Error) -> Void)?
    var onCancel: (() -> Void)?

    private let progress = InstallProgress()
    private var window: NSWindow?
    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?
    private let workDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DiskHealthUpdate-\(UUID().uuidString)", isDirectory: true)

    init(update: AvailableUpdate) {
        self.update = update
    }

    /// Updating replaces the app in place, so its folder must be writable and
    /// it mustn't be running from a disk image or a translocated copy.
    static var canReplaceRunningApp: Bool {
        let app = Bundle.main.bundleURL
        let path = app.path
        guard !path.contains("/AppTranslocation/") else { return false }
        let fm = FileManager.default
        return fm.isWritableFile(atPath: app.deletingLastPathComponent().path) && fm.isWritableFile(atPath: path)
    }

    func start() {
        guard let url = update.downloadURL else { return }
        showWindow()
        let version = update.version.description
        progress.message = String(localized: "Downloading Disk Health \(version)…")

        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let destination = workDirectory.appendingPathComponent("Disk-Health-\(update.version).dmg")

        let task = URLSession.shared.downloadTask(with: url) { [weak self] location, response, error in
            // Move the file before this handler returns; URLSession deletes it afterwards.
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            var outcome: Result<URL, Error>
            if let error {
                outcome = .failure(error)
            } else if let location, status == 200 || status == 0 {
                do {
                    try FileManager.default.moveItem(at: location, to: destination)
                    outcome = .success(destination)
                } catch {
                    outcome = .failure(error)
                }
            } else {
                outcome = .failure(UpdateError.server(status))
            }
            let result = outcome
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.downloadFinished(result) } }
        }
        observation = task.progress.observe(\.fractionCompleted) { [weak self] value, _ in
            let fraction = value.fractionCompleted
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.progress.fraction = fraction } }
        }
        self.task = task
        task.resume()
    }

    func bringToFront() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func cancel() {
        task?.cancel()
        finish()
        onCancel?()
    }

    private func downloadFinished(_ result: Result<URL, Error>) {
        observation = nil
        switch result {
        case .failure(let error):
            if (error as? URLError)?.code == .cancelled { return }
            fail(error)
        case .success(let dmg):
            let versionText = update.version.description
            progress.message = String(localized: "Installing Disk Health \(versionText)…")
            progress.fraction = nil
            progress.canCancel = false
            let target = Bundle.main.bundleURL
            let bundleID = Bundle.main.bundleIdentifier ?? ""
            let version = update.version
            let work = workDirectory
            let signatureURL = update.signatureURL
            Task.detached {
                do {
                    // Check the signature before mounting: an unverified disk image is never attached.
                    try await Self.verifySignature(of: dmg, signatureURL: signatureURL)
                    let staged = try Self.stage(dmg: dmg, work: work, version: version, bundleID: bundleID, target: target)
                    await MainActor.run { self.relaunch(replacing: target, with: staged) }
                } catch {
                    await MainActor.run { self.fail(error) }
                }
            }
        }
    }

    /// Checks the downloaded image against its Ed25519 signature and the app's built-in public key.
    nonisolated private static func verifySignature(of file: URL, signatureURL: URL?) async throws {
        let refused = UpdateError.invalidDownload(
            String(localized: "The download's signature doesn't match Disk Health's publisher, so it wasn't installed."))
        guard let signatureURL, Updater.isTrusted(signatureURL) else { throw refused }
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: signatureURL, timeoutInterval: 30))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let image = try? Data(contentsOf: file, options: .mappedIfSafe),
              UpdateSignature.isValid(signatureFile: data, for: image, publicKey: Updater.signingPublicKey)
        else { throw refused }
    }

    /// Mounts the image, checks the app inside and copies it next to the
    /// running app (same volume, so the final swap is a quick rename).
    nonisolated private static func stage(dmg: URL, work: URL, version: AppVersion,
                                          bundleID: String, target: URL) throws -> URL {
        let mountPoint = work.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mountPoint.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"]) }

        let apps = (try FileManager.default.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil))
            .filter { $0.pathExtension == "app" }
        guard let app = apps.first, let bundle = Bundle(url: app), bundle.bundleIdentifier == bundleID else {
            throw UpdateError.invalidDownload(String(localized: "The downloaded disk image doesn't contain Disk Health."))
        }
        let found = AppVersion(bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
        guard let found, found == version else {
            let foundVersion = found?.description ?? String(localized: "unknown")
            let expected = version.description
            throw UpdateError.invalidDownload(String(localized: "The downloaded app is version \(foundVersion), not \(expected)."))
        }
        do {
            try run("/usr/bin/codesign", ["--verify", "--strict", app.path])
        } catch {
            throw UpdateError.invalidDownload(String(localized: "The downloaded app's code signature isn't valid."))
        }

        let staged = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.deletingPathExtension().lastPathComponent)-update.app")
        try? FileManager.default.removeItem(at: staged)
        try run("/usr/bin/ditto", [app.path, staged.path])
        return staged
    }

    /// Hands the swap to a small script that waits for Disk Health to quit.
    private func relaunch(replacing target: URL, with staged: URL) {
        let script = workDirectory.appendingPathComponent("install.sh")
        do {
            try Self.installScript.write(to: script, atomically: true, encoding: .utf8)
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/bin/sh")
            helper.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), target.path, staged.path]
            try helper.run()
        } catch {
            let reason = error.localizedDescription
            fail(UpdateError.installFailed(String(localized: "Couldn't start the installer: \(reason)")))
            return
        }
        progress.message = String(localized: "Restarting Disk Health…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
    }

    private static let installScript = """
    #!/bin/sh
    # Replaces Disk Health.app once the running copy has quit, then relaunches it.
    PID="$1"; TARGET="$2"; STAGED="$3"
    [ -n "$PID" ] && [ -d "$TARGET" ] && [ -d "$STAGED" ] || exit 1
    # This script's own folder holds the downloaded disk image; remove it when done.
    WORK="$(cd "$(dirname "$0")" && pwd)"
    cleanup() { case "$WORK" in */DiskHealthUpdate-*) rm -rf "$WORK" ;; esac; }
    waited=0
    while kill -0 "$PID" 2>/dev/null; do
      waited=$((waited + 1))
      if [ "$waited" -gt 600 ]; then rm -rf "${STAGED:?}"; cleanup; exit 1; fi
      sleep 0.5
    done
    BACKUP="${TARGET:?}.previous"
    rm -rf "$BACKUP"
    if mv "$TARGET" "$BACKUP" && mv "$STAGED" "$TARGET"; then
      rm -rf "$BACKUP"
    else
      [ -d "$TARGET" ] || mv "$BACKUP" "$TARGET"
      rm -rf "${STAGED:?}"
    fi
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET" >/dev/null 2>&1
    open "$TARGET"
    cleanup
    """

    nonisolated private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let name = URL(fileURLWithPath: tool).lastPathComponent
            let status = Int(process.terminationStatus)
            throw UpdateError.installFailed(String(localized: "\(name) failed (\(status))."))
        }
    }

    private func fail(_ error: Error) {
        finish()
        onFailure?(error)
    }

    private func finish() {
        observation = nil
        window?.close()
        window = nil
        try? FileManager.default.removeItem(at: workDirectory)
    }

    // MARK: Window

    private func showWindow() {
        let view = UpdateProgressView(progress: progress) { [weak self] in self?.cancel() }
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = String(localized: "Updating Disk Health")
        window.styleMask = [.titled]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

private struct UpdateProgressView: View {
    let progress: InstallProgress
    let cancel: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 12) {
                Text(progress.message)
                    .font(.headline)
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
                HStack {
                    Spacer()
                    Button("Cancel", action: cancel)
                        .keyboardShortcut(.cancelAction)
                        .disabled(!progress.canCancel)
                }
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
