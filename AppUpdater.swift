import Cocoa

// MARK: - App Updates & Installation

enum AppUpdater {
    private static let githubRepo = "Drozes/ClaudeMeter"

    private static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
    }

    static var isAppBundle: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
    }

    static var isRunningFromApplications: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") ||
               path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    // MARK: - Move to Applications

    static func promptMoveToApplicationsIfNeeded() {
        guard isAppBundle, !isRunningFromApplications else { return }
        guard !UserDefaults.standard.bool(forKey: "declinedMoveToApplications") else { return }

        let alert = NSAlert()
        alert.messageText = "Move to Applications?"
        alert.informativeText = "ClaudeMeter works best from your Applications folder. Would you like to move it there?"
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Don\u{2019}t Ask Again")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            moveToApplications()
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(true, forKey: "declinedMoveToApplications")
        default:
            break
        }
    }

    private static func moveToApplications() {
        let source = Bundle.main.bundlePath
        let destination = "/Applications/" + (source as NSString).lastPathComponent
        let fm = FileManager.default

        do {
            if fm.fileExists(atPath: destination) {
                try fm.removeItem(atPath: destination)
            }
            try fm.copyItem(atPath: source, toPath: destination)
        } catch {
            NSLog("ClaudeMeter: Direct copy failed (%@), requesting privileges", error.localizedDescription)
            let src = source.replacingOccurrences(of: "'", with: "'\\''")
            let dst = destination.replacingOccurrences(of: "'", with: "'\\''")
            let script = "do shell script \"rm -rf '\(dst)'; cp -R '\(src)' '\(dst)'\" with administrator privileges"
            guard let appleScript = NSAppleScript(source: script) else {
                showError("Move Failed", "Could not prepare the authorization request.")
                return
            }
            var err: NSDictionary?
            appleScript.executeAndReturnError(&err)
            if err != nil {
                showError("Move Failed", "Could not copy ClaudeMeter to Applications.\nYou can drag it there manually.")
                return
            }
        }

        // Launch the new copy and quit
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: destination),
            configuration: .init()
        ) { _, _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.quitAfterRelaunchDelay) {
            NSApp.terminate(nil)
        }
    }

    // MARK: - Check for Updates

    static func checkForUpdates(silent: Bool = false) {
        let url = URL(string: "https://api.github.com/repos/\(githubRepo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                guard let data = data, error == nil,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tagName = json["tag_name"] as? String else {
                    if !silent {
                        showError("Update Check Failed",
                                  "Could not reach GitHub. Check your internet connection.")
                    }
                    return
                }

                let remote = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

                guard isNewer(remote, than: currentVersion) else {
                    if !silent {
                        showInfo("You\u{2019}re Up to Date",
                                 "ClaudeMeter \(currentVersion) is the latest version.")
                    }
                    return
                }

                let assets = json["assets"] as? [[String: Any]] ?? []
                let zipURL = assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
                    .flatMap { $0["browser_download_url"] as? String }
                let notes = json["body"] as? String ?? ""

                promptUpdate(version: remote, notes: notes, zipURL: zipURL)
            }
        }.resume()
    }

    private static func promptUpdate(version: String, notes: String, zipURL: String?) {
        let alert = NSAlert()
        alert.messageText = "ClaudeMeter \(version) Available"
        let trimmed = notes.count > 500 ? String(notes.prefix(500)) + "\u{2026}" : notes
        alert.informativeText = "You\u{2019}re running \(currentVersion).\n\n\(trimmed)"

        if zipURL != nil, isAppBundle {
            alert.addButton(withTitle: "Update & Restart")
            alert.addButton(withTitle: "Later")
        } else {
            alert.addButton(withTitle: "Open Download Page")
            alert.addButton(withTitle: "Later")
        }

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if let zipURL = zipURL, isAppBundle {
            downloadAndInstall(zipURL)
        } else {
            NSWorkspace.shared.open(URL(string: "https://github.com/\(githubRepo)/releases/latest")!)
        }
    }

    // MARK: - Download & Install

    private static func downloadAndInstall(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }

        URLSession.shared.downloadTask(with: url) { tempFile, _, error in
            DispatchQueue.main.async {
                guard let tempFile = tempFile, error == nil else {
                    showError("Download Failed",
                              "Could not download the update. Try again later.")
                    return
                }
                install(from: tempFile)
            }
        }.resume()
    }

    private static func install(from zipFile: URL) {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("ClaudeMeter-update-\(UUID().uuidString)")

        do {
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)

            // Move the downloaded zip before the system cleans it up
            let zipDest = workDir.appendingPathComponent("update.zip")
            try fm.moveItem(at: zipFile, to: zipDest)

            // Unzip
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzip.arguments = ["-o", zipDest.path, "-d", workDir.path]
            unzip.standardOutput = nil
            unzip.standardError = nil
            try unzip.run()
            unzip.waitUntilExit()
            guard unzip.terminationStatus == 0 else {
                throw NSError(domain: "AppUpdater", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Could not extract the update archive."])
            }

            // Find the .app in the extracted contents
            let items = try fm.contentsOfDirectory(atPath: workDir.path)
            guard let appName = items.first(where: { $0.hasSuffix(".app") }) else {
                throw NSError(domain: "AppUpdater", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "No app bundle found in the update archive."])
            }
            let newAppPath = workDir.appendingPathComponent(appName).path

            // Verify code signature before replacing
            let codesign = Process()
            codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            codesign.arguments = ["--verify", "--deep", "--strict", newAppPath]
            let signPipe = Pipe()
            codesign.standardOutput = signPipe
            codesign.standardError = signPipe
            try codesign.run()
            codesign.waitUntilExit()
            if codesign.terminationStatus != 0 {
                let signOutput = String(data: signPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                NSLog("ClaudeMeter: Code signature verification failed: %@", signOutput)
                showError("Update Failed",
                          "The downloaded app failed code signature verification and cannot be installed.")
                try? fm.removeItem(at: workDir)
                return
            }

            let currentAppPath = Bundle.main.bundlePath
            let pid = ProcessInfo.processInfo.processIdentifier

            // Updater script: waits for quit, replaces app, relaunches
            let scriptPath = fm.temporaryDirectory.appendingPathComponent("claudemeter-update.sh").path
            let script = """
            #!/bin/bash
            while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
            rm -rf "$2"
            mv "$3" "$2"
            xattr -dr com.apple.quarantine "$2" 2>/dev/null
            open "$2"
            rm -rf "$4"
            rm -f "$0"
            """
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)

            let updater = Process()
            updater.executableURL = URL(fileURLWithPath: "/bin/bash")
            updater.arguments = [scriptPath, "\(pid)", currentAppPath, newAppPath, workDir.path]
            try updater.run()

            NSApp.terminate(nil)
        } catch {
            showError("Update Failed", error.localizedDescription)
            try? fm.removeItem(at: workDir)
        }
    }

    // MARK: - Silent Update Check (returns version string if newer, nil otherwise)

    static func checkAvailableUpdate(completion: @escaping (String?) -> Void) {
        let url = URL(string: "https://api.github.com/repos/\(githubRepo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                guard let data = data, error == nil,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tagName = json["tag_name"] as? String else {
                    completion(nil)
                    return
                }
                let remote = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
                completion(isNewer(remote, than: currentVersion) ? remote : nil)
            }
        }.resume()
    }

    // MARK: - Version Comparison

    // Visible for testing
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv != lv { return rv > lv }
        }
        return false
    }

    // MARK: - Alerts

    private static func showError(_ title: String, _ message: String) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = title
        a.informativeText = message
        a.runModal()
    }

    private static func showInfo(_ title: String, _ message: String) {
        let a = NSAlert()
        a.alertStyle = .informational
        a.messageText = title
        a.informativeText = message
        a.runModal()
    }
}
