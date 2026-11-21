import Foundation

/// Installs the clipboard helper as a per-user launchd agent:
/// starts at login (`RunAtLoad`) and is restarted by launchd whenever it exits
/// (`KeepAlive`), so quitting the Monitoring app or tools like Swift Quit can't stop it.
/// Only `uninstall()` stops it for good.
public enum ClipboardAgentInstaller {
    public static let label = "com.ozodbek.monitoring.clipboard"

    public static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// Where bundle.sh puts the helper inside the installed app.
    public static let defaultExecutable = URL(fileURLWithPath:
        "/Applications/Monitoring.app/Contents/Library/LoginItems/Monitoring Clipboard.app/Contents/MacOS/Monitoring Clipboard")

    /// The helper bundled next to the running Monitoring app, if present.
    public static var bundledExecutable: URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LoginItems/Monitoring Clipboard.app/Contents/MacOS/Monitoring Clipboard")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    public enum Status: Sendable, Equatable {
        case notInstalled
        /// Plist exists but launchd hasn't loaded it.
        case installedNotRunning
        case running(pid: Int32)
    }

    static func plist(executable: URL) -> [String: Any] {
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Monitoring")
        return [
            "Label": label,
            "ProgramArguments": [executable.path],
            "RunAtLoad": true,
            // Always restart, including after a clean quit (Swift Quit sends a normal quit).
            "KeepAlive": true,
            // Don't spin if the binary is missing or crashes at launch.
            "ThrottleInterval": 5,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": logs.appendingPathComponent("clipboard.log").path,
            "StandardErrorPath": logs.appendingPathComponent("clipboard.log").path,
        ]
    }

    /// Writes the plist and (re)loads it, so the helper starts now and at every login.
    public static func install(executable: URL = bundledExecutable ?? defaultExecutable) throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw InstallerError.executableMissing(executable.path)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Monitoring"),
                               withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist(executable: executable), format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
        // bootout first so an updated plist or binary takes effect; ignore "not loaded".
        _ = launchctl(["bootout", domain + "/" + label])
        let result = launchctl(["bootstrap", domain, plistURL.path])
        guard result.status == 0 else { throw InstallerError.launchctl(result.output) }
    }

    private static let disabledKey = "clipboardAgentDisabled"

    /// The user turned the helper off in Monitoring; don't reinstall it automatically.
    public static var isDisabledByUser: Bool {
        get { UserDefaults.standard.bool(forKey: disabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: disabledKey) }
    }

    /// Call at every Monitoring launch. Installs the helper bundled in this app unless
    /// the user disabled it, and re-points launchd when the app moved or was updated.
    /// Does nothing when running unbundled (swift run), so dev builds never register themselves.
    public static func ensureInstalled() {
        guard !isDisabledByUser, let executable = bundledExecutable else { return }
        let current = (NSDictionary(contentsOf: plistURL)?["ProgramArguments"] as? [String])?.first
        if current == executable.path, case .running = status() { return }
        try? install(executable: executable)
    }

    /// User-facing switch: on installs and starts it now; off stops it and keeps it off.
    public static func setEnabled(_ enabled: Bool) throws {
        isDisabledByUser = !enabled
        if enabled {
            try install()
        } else {
            try uninstall()
        }
    }

    /// Stops the helper and removes it from login. The saved history file is kept.
    public static func uninstall() throws {
        _ = launchctl(["bootout", domain + "/" + label])
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    public static func status() -> Status {
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return .notInstalled }
        let result = launchctl(["print", domain + "/" + label])
        guard result.status == 0 else { return .installedNotRunning }
        if let line = result.output.split(separator: "\n").first(where: { $0.contains("pid = ") }),
           let pid = Int32(line.split(separator: "=").last?.trimmingCharacters(in: .whitespaces) ?? "") {
            return .running(pid: pid)
        }
        return .installedNotRunning
    }

    static var domain: String { "gui/\(getuid())" }

    @discardableResult
    static func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

public enum InstallerError: Error, LocalizedError {
    case executableMissing(String)
    case launchctl(String)

    public var errorDescription: String? {
        switch self {
        case .executableMissing(let path): "Clipboard helper not found at \(path). Run scripts/bundle.sh --install first."
        case .launchctl(let output): "launchctl failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}

/// Cross-process messages between the Monitoring app and the helper.
public enum ClipboardMessages {
    /// Posted by the main app; the helper opens its panel.
    public static let showPanel = Notification.Name("com.ozodbek.monitoring.clipboard.show")
    /// Posted by the main app after clearing; the helper clears its memory too.
    public static let clear = Notification.Name("com.ozodbek.monitoring.clipboard.clear")
}
