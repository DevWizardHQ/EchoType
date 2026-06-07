import AppKit

/// Checks GitHub Releases for new versions and self-updates in place.
///
/// Flow: query /releases/latest → compare semver tags → download the .zip asset →
/// verify its SHA-256 against the .sha256 asset → swap the app bundle → relaunch.
final class UpdateManager {
    static let shared = UpdateManager()

    private static let repo = "DevWizardHQ/EchoType"
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    struct Release {
        let version: String
        let zipURL: URL
        let checksumURL: URL?
        let notes: String
    }

    private(set) var availableRelease: Release?
    var onUpdateAvailable: ((Release) -> Void)?

    private var timer: Timer?
    private var isUpdating = false

    private init() {}

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    // MARK: - Scheduling

    func startAutomaticChecks() {
        guard Settings.autoCheckUpdates else { return }
        // First check shortly after launch, then daily.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.checkForUpdates(userInitiated: false)
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            guard Settings.autoCheckUpdates else { return }
            self?.checkForUpdates(userInitiated: false)
        }
    }

    func stopAutomaticChecks() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Check

    func checkForUpdates(userInitiated: Bool) {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest") else { return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self else { return }
            guard error == nil, let data,
                  let release = Self.parseRelease(data) else {
                if userInitiated {
                    DispatchQueue.main.async {
                        self.alert(title: "Update check failed",
                                   text: "Could not reach GitHub. Check your internet connection and try again.")
                    }
                }
                return
            }

            DispatchQueue.main.async {
                if Self.isNewer(release.version, than: Self.currentVersion) {
                    Log.write("update: \(release.version) available (current \(Self.currentVersion))")
                    self.availableRelease = release
                    self.onUpdateAvailable?(release)
                    self.promptToInstall(release)
                } else if userInitiated {
                    self.alert(title: "You're up to date",
                               text: "EchoType \(Self.currentVersion) is the latest version.")
                }
            }
        }.resume()
    }

    private static func parseRelease(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]] else { return nil }

        var zipURL: URL?
        var checksumURL: URL?
        for asset in assets {
            guard let name = asset["name"] as? String,
                  let urlString = asset["browser_download_url"] as? String,
                  let url = URL(string: urlString) else { continue }
            if name.hasSuffix(".zip") { zipURL = url }
            if name.hasSuffix(".sha256") { checksumURL = url }
        }
        guard let zipURL else { return nil }

        return Release(
            version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
            zipURL: zipURL,
            checksumURL: checksumURL,
            notes: json["body"] as? String ?? ""
        )
    }

    /// Semver-ish compare: "1.2.10" > "1.2.9".
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Install

    private func promptToInstall(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = "EchoType \(release.version) is available"
        alert.informativeText = "You have \(Self.currentVersion). Download and install now? EchoType will relaunch automatically."
        alert.addButton(withTitle: "Install Update")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        install(release)
    }

    func install(_ release: Release) {
        guard !isUpdating else { return }
        isUpdating = true
        Log.write("update: downloading \(release.version)")

        URLSession.shared.downloadTask(with: release.zipURL) { [weak self] tempURL, _, error in
            guard let self else { return }
            guard error == nil, let tempURL else {
                self.finishWithError("Download failed. Try again later.")
                return
            }
            do {
                try self.verifyAndSwap(zipAt: tempURL, release: release)
            } catch {
                self.finishWithError(error.localizedDescription)
            }
        }.resume()
    }

    private func verifyAndSwap(zipAt zipURL: URL, release: Release) throws {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("echotype-update-\(UUID().uuidString)")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        // Verify checksum when the release ships one.
        if let checksumURL = release.checksumURL,
           let expectedLine = try? String(contentsOf: checksumURL, encoding: .utf8),
           let expected = expectedLine.split(separator: " ").first {
            let actual = try Self.sha256(of: zipURL)
            guard actual == expected.lowercased() else {
                throw NSError(domain: "EchoType", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Checksum verification failed — update aborted."
                ])
            }
        }

        // Unpack with ditto (preserves signatures and resource forks).
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zipURL.path, workDir.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else {
            throw NSError(domain: "EchoType", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Could not unpack the update."
            ])
        }

        guard let newApp = try fm.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw NSError(domain: "EchoType", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Update archive did not contain an app."
            ])
        }

        // Swap: move the running bundle aside, move the new one in.
        let installedURL = Bundle.main.bundleURL
        let backupURL = fm.temporaryDirectory.appendingPathComponent("EchoType-old-\(UUID().uuidString).app")
        try fm.moveItem(at: installedURL, to: backupURL)
        do {
            try fm.moveItem(at: newApp, to: installedURL)
        } catch {
            try? fm.moveItem(at: backupURL, to: installedURL) // roll back
            throw error
        }
        try? fm.removeItem(at: backupURL)
        Log.write("update: installed \(release.version), relaunching")

        DispatchQueue.main.async {
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"\(installedURL.path)\""]
            try? relaunch.run()
            NSApp.terminate(nil)
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let hash = String(data: data, encoding: .utf8)?.split(separator: " ").first else {
            throw NSError(domain: "EchoType", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Could not compute checksum."
            ])
        }
        return String(hash).lowercased()
    }

    private func finishWithError(_ message: String) {
        isUpdating = false
        Log.write("update: failed — \(message)")
        DispatchQueue.main.async {
            self.alert(title: "Update failed", text: message)
        }
    }

    private func alert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
