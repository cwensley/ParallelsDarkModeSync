// darkmode-watcher.swift
//
// Watches the macOS interface appearance and publishes it to a small state file
// that Parallels guests read over the \\Mac\Home shared folder.
//
// The file contains exactly one line: "dark" or "light".
//
// Build:  swiftc -O -o darkmode-watcher darkmode-watcher.swift

import Foundation

let stateDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".darkmode-sync", isDirectory: true)
let stateURL = stateDir.appendingPathComponent("state")
let tmpURL = stateDir.appendingPathComponent(".state.tmp")

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("\(stamp) \(message)\n".utf8))
}

/// Reads the appearance straight from the global preferences domain.
/// AppleInterfaceStyle is absent in light mode and "Dark" in dark mode.
func currentMode() -> String {
    CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
    let value = CFPreferencesCopyAppValue("AppleInterfaceStyle" as CFString,
                                          kCFPreferencesAnyApplication) as? String
    return value?.lowercased() == "dark" ? "dark" : "light"
}

var lastPublished: String?

func publish(reason: String) {
    let mode = currentMode()
    guard mode != lastPublished else { return }

    do {
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try Data("\(mode)\n".utf8).write(to: tmpURL, options: .atomic)
        // rename(2) is atomic, so a guest polling the file never sees a partial write.
        guard rename(tmpURL.path, stateURL.path) == 0 else {
            log("rename failed: \(String(cString: strerror(errno)))")
            return
        }
        lastPublished = mode
        log("published \(mode) (\(reason))")
    } catch {
        log("write failed: \(error.localizedDescription)")
    }
}

DistributedNotificationCenter.default().addObserver(
    forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
    object: nil,
    queue: .main
) { _ in
    // The notification can land marginally before the preference is readable.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { publish(reason: "theme notification") }
}

publish(reason: "startup")

// Safety net: catches an appearance change if a notification is ever missed
// (for example while the session is locked). publish() is a no-op when nothing
// changed, so this costs a preference read every 10 seconds and nothing else.
Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { _ in publish(reason: "periodic check") }

log("watching for appearance changes; state file: \(stateURL.path)")
RunLoop.main.run()
