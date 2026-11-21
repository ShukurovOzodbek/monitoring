import AppKit
import ClipboardCore

// Background helper: records copied text for 24 hours and shows it on ⌥V.
// launchd keeps it running (see ClipboardAgentInstaller).

setvbuf(stdout, nil, _IOLBF, 0) // launchd sends stdout to a log file; flush per line
SingleInstance.waitForLock()

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AgentDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // no Dock icon, no menu bar, not a "regular" app
    withExtendedLifetime(delegate) { app.run() }
}

/// Only one helper may record at a time (for example a dev build and the installed one).
/// A second copy waits for the lock instead of exiting, so launchd doesn't restart it in a loop.
enum SingleInstance {
    nonisolated(unsafe) private static var fd: Int32 = -1

    static func waitForLock() {
        let folder = ClipboardStorage.default.url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        fd = open(folder.appendingPathComponent("clipboard-agent.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return }
        var announced = false
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if !announced {
                print("Another clipboard helper is running; waiting.")
                announced = true
            }
            sleep(5)
        }
    }
}
