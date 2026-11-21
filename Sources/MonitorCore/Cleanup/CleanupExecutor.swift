import Darwin
import Foundation

/// Last line of defense: every path the app deletes must pass this check,
/// whatever the scanner or UI handed over.
enum CleanupGuard {
    /// Roots whose *contents* may be deleted (never the root itself).
    static var allowedRoots: [String] {
        let home = CleanupPaths.home
        var roots = [
            CleanupPaths.userCaches, CleanupPaths.systemCaches, CleanupPaths.userLogs, CleanupPaths.systemLogs,
            CleanupPaths.varLog, CleanupPaths.trash, CleanupPaths.downloads, CleanupPaths.iOSBackups, CleanupPaths.tmp,
            home.appendingPathComponent("Library/Developer"), home.appendingPathComponent("Library/pnpm"),
            home.appendingPathComponent(".npm"), home.appendingPathComponent(".gradle"),
            home.appendingPathComponent(".cache"), home.appendingPathComponent(".m2"), home.appendingPathComponent(".bun"),
        ]
        roots += [CleanupPaths.userTemp, CleanupPaths.userCache].compactMap { $0 }
        return roots.map { normalize($0.path) }
    }

    /// Folders that must never be deleted themselves, even though they're inside the home folder.
    static var protectedExact: Set<String> {
        let home = CleanupPaths.home
        let names = ["", "Library", "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music",
                     "Applications", "Public", "Library/Mobile Documents", "Library/CloudStorage"]
        return Set(names.map { normalize(home.appendingPathComponent($0).path) })
    }

    static func normalize(_ path: String) -> String {
        var result = OpenFiles.normalize((path as NSString).standardizingPath)
        while result.count > 1 && result.hasSuffix("/") { result.removeLast() }
        return result
    }

    /// True if `url` may be removed by the cleanup feature.
    static func isAllowed(_ url: URL, category: CleanupCategoryKind?) -> Bool {
        guard url.isFileURL else { return false }
        let path = normalize(url.path)
        guard !path.contains("/../"), !protectedExact.contains(path) else { return false }
        if path == normalize(CleanupPaths.sleepImage.path) { return category == .sleepImage }
        if allowedRoots.contains(where: { path.hasPrefix($0 + "/") }) { return true }
        // Large files and the in-app browser may target anything in the home folder
        // except ~/Library (app data, iCloud) and the protected folders themselves.
        let home = normalize(CleanupPaths.home.path)
        let library = home + "/Library/"
        if category == .largeFiles || category == nil {
            return path.hasPrefix(home + "/") && !path.hasPrefix(library) && !(path + "/").hasPrefix(library)
        }
        return false
    }
}

enum CleanupExecutor {
    struct Outcome {
        var report = CleanupReport()
    }

    /// Removes `items` and returns what happened. `adminCommands` are extra root
    /// commands (purge, DNS flush) that share the single password prompt.
    static func run(items: [CleanupItem], userDataMode: CleanupDeletionMode, adminCommands: [String] = [],
                    context: CleanupContext, progress: @Sendable (String) async -> Void) async throws -> CleanupReport {
        let start = Date()
        var report = CleanupReport(freeSpaceBefore: DiskUsage.freeSpace())

        // Re-check safety now: the scan may be minutes old.
        var userItems: [CleanupItem] = []
        var adminItems: [CleanupItem] = []
        for item in items {
            if let reason = recheck(item, context: context) {
                report.skipped.append(.init(name: item.name, reason: reason))
                continue
            }
            if item.requiresAdmin { adminItems.append(item) } else { userItems.append(item) }
        }

        // User-level deletions, grouped by category for progress messages.
        let grouped = Dictionary(grouping: userItems, by: \.category)
        for kind in CleanupCategoryKind.allCases {
            guard let group = grouped[kind], !group.isEmpty else { continue }
            await progress("Cleaning \(kind.title)…")
            let mode: CleanupDeletionMode = (kind == .downloads || kind == .largeFiles || kind == .iOSBackups)
                ? userDataMode : .delete
            let result = await Task.detached(priority: .userInitiated) {
                removeUserItems(group, mode: mode, context: context)
            }.value
            report.bytesDeleted += result.bytesDeleted
            report.bytesMovedToTrash += result.bytesMovedToTrash
            report.itemsRemoved += result.itemsRemoved
            report.skipped += result.skipped
            report.failures += result.failures
        }

        // Everything that needs root, in one password prompt.
        let script = adminScript(for: adminItems) + adminCommands
        if !script.isEmpty {
            await progress("Waiting for administrator password…")
            let memoryBefore = MemorySampler.sample().cachedFiles
            let result = try await Shell.runAsAdministrator(script.joined(separator: "; "))
            let failed = Set(result.stdout.split(separator: "\n").compactMap { line -> String? in
                line.hasPrefix("FAILED:") ? String(line.dropFirst("FAILED:".count)) : nil
            })
            for item in adminItems {
                let key = adminKey(item)
                if failed.contains(key) {
                    report.failures.append("\(item.name): could not be removed")
                } else {
                    report.itemsRemoved += 1
                    report.bytesDeleted += item.size ?? 0
                }
            }
            if adminCommands.contains(where: { $0.contains("purge") }) {
                let after = MemorySampler.sample().cachedFiles
                report.memoryFreed = memoryBefore > after ? memoryBefore - after : 0
            }
        }

        report.freeSpaceAfter = DiskUsage.freeSpace()
        report.duration = Date().timeIntervalSince(start)
        return report
    }

    /// nil if the item may still be removed; otherwise the reason it can't.
    static func recheck(_ item: CleanupItem, context: CleanupContext) -> String? {
        if case .snapshot = item.removal { return nil }
        guard item.removal != .none else { return "Not removable" }
        guard CleanupGuard.isAllowed(item.url, category: item.category) else { return "Outside cleanup locations" }
        guard FileManager.default.fileExists(atPath: item.url.path) || isBrokenSymlink(item.url) else {
            return "Already gone"
        }
        if !item.requiresAdmin, context.openFiles.containsOpenFile(under: item.url) {
            return CleanupSkipReason.inUse.description
        }
        if [.userCaches, .systemCaches].contains(item.category),
           CleanupScanner.belongsToRunningApp(item.url.lastPathComponent, context) {
            return CleanupSkipReason.runningApp.description
        }
        return nil
    }

    static func removeUserItems(_ items: [CleanupItem], mode: CleanupDeletionMode, context: CleanupContext) -> CleanupReport {
        let fm = FileManager.default
        var report = CleanupReport()
        for item in items {
            switch item.removal {
            case .removeItem:
                do {
                    if mode == .moveToTrash && item.category != .trash {
                        try fm.trashItem(at: item.url, resultingItemURL: nil)
                        report.bytesMovedToTrash += item.size ?? 0
                    } else {
                        try fm.removeItem(at: item.url)
                        report.bytesDeleted += item.size ?? 0
                    }
                    report.itemsRemoved += 1
                } catch {
                    report.failures.append("\(item.name): \(error.localizedDescription)")
                }
            case .emptyFolder:
                let children = (try? fm.contentsOfDirectory(at: item.url, includingPropertiesForKeys: nil)) ?? []
                var freed: UInt64 = 0, failures = 0, kept = 0
                for child in children {
                    // A file inside may have been opened since the scan.
                    if context.openFiles.containsOpenFile(under: child) {
                        kept += 1
                        continue
                    }
                    let size = DiskUsage.stats(of: child).size
                    do {
                        try fm.removeItem(at: child)
                        freed += size
                    } catch {
                        failures += 1
                    }
                }
                report.bytesDeleted += freed
                if freed > 0 || children.isEmpty { report.itemsRemoved += 1 }
                if failures > 0 { report.failures.append("\(item.name): \(failures) item(s) could not be removed") }
                if kept > 0 { report.skipped.append(.init(name: item.name, reason: "\(kept) item(s) in use were kept")) }
            case .snapshot, .none:
                break
            }
        }
        return report
    }

    /// Shell lines that remove admin items and print FAILED:<key> for each failure.
    static func adminScript(for items: [CleanupItem]) -> [String] {
        items.compactMap { item in
            let key = adminKey(item)
            switch item.removal {
            case .removeItem:
                return "/bin/rm -rf -- \(quote(item.url.path)) || echo \(quote("FAILED:" + key))"
            case .emptyFolder:
                return "/usr/bin/find \(quote(item.url.path)) -mindepth 1 -maxdepth 1 -exec /bin/rm -rf -- {} + || echo \(quote("FAILED:" + key))"
            case .snapshot(let date):
                return "/usr/bin/tmutil deletelocalsnapshots \(quote(date)) >/dev/null || echo \(quote("FAILED:" + key))"
            case .none:
                return nil
            }
        }
    }

    static func adminKey(_ item: CleanupItem) -> String {
        item.url.absoluteString.replacingOccurrences(of: "\n", with: "")
    }

    /// POSIX single-quote escaping: 'it'\''s'.
    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func isBrokenSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}
