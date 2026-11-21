import AppKit
import ClipboardCore

@MainActor
final class AgentDelegate: NSObject, NSApplicationDelegate {
    private let history = ClipboardHistory()
    private var watcher: PasteboardWatcher?
    private var hotKey: GlobalHotKey?
    private var panel: ClipboardPanelController?
    private var pruneTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination("Records clipboard history")
        ProcessInfo.processInfo.disableSuddenTermination()

        let watcher = PasteboardWatcher { [history] text, app in
            history.add(text, sourceAppName: app?.localizedName, sourceBundleID: app?.bundleIdentifier)
        }
        watcher.start()
        self.watcher = watcher

        let panel = ClipboardPanelController(history: history) { [weak self] entry, targetApp in
            self?.pick(entry, pasteInto: targetApp)
        }
        self.panel = panel

        do {
            hotKey = try GlobalHotKey(keyCode: GlobalHotKey.keyV, modifiers: .option) { [weak panel] in
                panel?.toggle()
            }
        } catch {
            print("Could not register ⌥V: \(error.localizedDescription)")
        }

        // Expire entries even when nothing is being copied.
        let timer = Timer(timeInterval: 60, repeats: true) { [history] _ in
            MainActor.assumeIsolated { _ = history.prune() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        pruneTimer = timer

        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: ClipboardMessages.showPanel, object: nil, queue: .main) { [weak panel] _ in
            MainActor.assumeIsolated { panel?.show() }
        }
        center.addObserver(forName: ClipboardMessages.clear, object: nil, queue: .main) { [history] _ in
            MainActor.assumeIsolated { history.clear() }
        }
        print("Clipboard helper started with \(history.entries.count) saved entries.")
    }

    /// Refuse polite quit requests (Swift Quit, "Quit" from other apps) so history
    /// keeps recording. Logout, restart and shutdown are allowed. `launchctl bootout`
    /// (the Disable button) sends SIGTERM, which doesn't go through here.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let reason = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
        let systemReasons: Set<OSType> = [
            OSType(kAELogOut), OSType(kAEReallyLogOut), OSType(kAEShowRestartDialog), OSType(kAERestart),
            OSType(kAEShowShutdownDialog), OSType(kAEShutDown),
        ]
        if let reason, systemReasons.contains(reason) { return .terminateNow }
        return .terminateCancel
    }

    private func pick(_ entry: ClipboardEntry, pasteInto app: NSRunningApplication?) {
        watcher?.write(entry.text)
        // Move it to the top: it's the most recently used text now.
        history.add(entry.text, sourceAppName: entry.sourceAppName, sourceBundleID: entry.sourceBundleID)
        Paster.paste(into: app)
    }
}
