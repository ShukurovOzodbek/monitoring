import Foundation

/// What "Clean Cache" does. All of it is safe while apps keep running.
public struct CacheCleanOptions: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// `purge`: drops the file cache and inactive memory, like right after boot.
    /// Needs the admin password.
    public static let memory = CacheCleanOptions(rawValue: 1 << 0)
    /// Flushes the DNS resolver cache. Needs the admin password (shared prompt with `.memory`).
    public static let dns = CacheCleanOptions(rawValue: 1 << 1)
    /// Deletes the contents of ~/Library/Caches for apps that are not running.
    public static let userCaches = CacheCleanOptions(rawValue: 1 << 2)

    public static let all: CacheCleanOptions = [.memory, .dns, .userCaches]
}

public struct CacheCleanReport: Sendable, Hashable {
    /// RAM moved from "Cached Files" to "Free" by purge.
    public var memoryFreed: UInt64
    public var userCacheBytesFreed: UInt64
    public var userCacheFoldersCleaned: Int
    /// Cache folders left alone because their app is running or they are protected.
    public var skipped: [String]
    public var dnsFlushed: Bool
    /// Non-fatal problems (individual files that could not be removed, ...).
    public var warnings: [String]
    public var duration: TimeInterval

    public var totalFreed: UInt64 { memoryFreed + userCacheBytesFreed }

    public init(memoryFreed: UInt64, userCacheBytesFreed: UInt64, userCacheFoldersCleaned: Int, skipped: [String],
                dnsFlushed: Bool, warnings: [String], duration: TimeInterval) {
        self.memoryFreed = memoryFreed
        self.userCacheBytesFreed = userCacheBytesFreed
        self.userCacheFoldersCleaned = userCacheFoldersCleaned
        self.skipped = skipped
        self.dnsFlushed = dnsFlushed
        self.warnings = warnings
        self.duration = duration
    }
}

public enum CacheCleanState: Sendable, Hashable {
    case idle
    case running
    case finished(CacheCleanReport)
    case failed(String)
}

enum CacheCleaner {
    /// Cache folders never touched: Apple system caches (often SIP/TCC protected
    /// and used by background daemons), and caches that hold downloaded tooling
    /// rather than disposable data.
    static let protectedPrefixes = ["com.apple.", "CloudKit", "FamilyCircle", "ms-playwright", "GeoServices"]

    static func run(options: CacheCleanOptions, runningBundleIDs: Set<String>) async throws -> CacheCleanReport {
        let start = Date()
        var report = CacheCleanReport(memoryFreed: 0, userCacheBytesFreed: 0, userCacheFoldersCleaned: 0,
                                      skipped: [], dnsFlushed: false, warnings: [], duration: 0)

        var adminCommands: [String] = []
        if options.contains(.memory) { adminCommands.append("/usr/sbin/purge") }
        if options.contains(.dns) {
            adminCommands.append("/usr/bin/dscacheutil -flushcache")
            adminCommands.append("/usr/bin/killall -HUP mDNSResponder")
        }
        if !adminCommands.isEmpty {
            let before = MemorySampler.sample().cachedFiles
            // One password prompt for everything that needs root.
            _ = try await Shell.runAsAdministrator(adminCommands.joined(separator: "; "))
            let after = MemorySampler.sample().cachedFiles
            report.memoryFreed = before > after ? before - after : 0
            report.dnsFlushed = options.contains(.dns)
        }

        if options.contains(.userCaches) {
            let result = await Task.detached(priority: .userInitiated) {
                cleanUserCaches(runningBundleIDs: runningBundleIDs)
            }.value
            report.userCacheBytesFreed = result.freed
            report.userCacheFoldersCleaned = result.cleaned
            report.skipped = result.skipped
            report.warnings = result.warnings
        }

        report.duration = Date().timeIntervalSince(start)
        return report
    }

    struct UserCacheResult {
        var freed: UInt64 = 0
        var cleaned = 0
        var skipped: [String] = []
        var warnings: [String] = []
    }

    /// Empties each folder in ~/Library/Caches (keeping the folder itself) unless
    /// it belongs to a running app or is protected.
    static func cleanUserCaches(runningBundleIDs: Set<String>,
                                cachesURL: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]) -> UserCacheResult {
        let fm = FileManager.default
        var result = UserCacheResult()
        let running = Set(runningBundleIDs.map { $0.lowercased() })
        guard let entries = try? fm.contentsOfDirectory(at: cachesURL, includingPropertiesForKeys: [.isDirectoryKey]) else {
            result.warnings.append("Could not read \(cachesURL.path)")
            return result
        }

        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasPrefix(".") { continue }
            if shouldSkip(folder: name, runningBundleIDs: running) {
                result.skipped.append(name)
                continue
            }
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let targets = isDirectory
                ? ((try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? [])
                : [entry]
            var freedHere: UInt64 = 0
            var failures = 0
            for target in targets {
                let size = allocatedSize(of: target)
                do {
                    try fm.removeItem(at: target)
                    freedHere += size
                } catch {
                    failures += 1
                }
            }
            if freedHere > 0 { result.cleaned += 1 }
            result.freed += freedHere
            if failures > 0 { result.warnings.append("\(name): \(failures) item(s) could not be removed") }
        }
        return result
    }

    static func shouldSkip(folder name: String, runningBundleIDs: Set<String>) -> Bool {
        if protectedPrefixes.contains(where: { name.hasPrefix($0) }) { return true }
        let lower = name.lowercased()
        // "com.google.Chrome" also covers "com.google.Chrome.helper" caches.
        return runningBundleIDs.contains { id in lower == id || lower.hasPrefix(id + ".") || id.hasPrefix(lower + ".") }
    }

    static func allocatedSize(of url: URL) -> UInt64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isDirectory != true { return UInt64(values.totalFileAllocatedSize ?? 0) }
        var total: UInt64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        while let file = enumerator?.nextObject() as? URL {
            total += UInt64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
