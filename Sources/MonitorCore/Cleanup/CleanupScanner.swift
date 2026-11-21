import Darwin
import Foundation

/// Well-known locations used by the scanner, the executor and the safety guard.
enum CleanupPaths {
    static let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL

    static func darwinDir(_ name: Int32) -> URL? {
        let length = confstr(name, nil, 0)
        guard length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(name, &buffer, length) > 0 else { return nil }
        return URL(fileURLWithPath: String(cBuffer: buffer), isDirectory: true).standardizedFileURL
    }

    static let userTemp = darwinDir(_CS_DARWIN_USER_TEMP_DIR)
    static let userCache = darwinDir(_CS_DARWIN_USER_CACHE_DIR)
    static let tmp = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    static let userCaches = home.appendingPathComponent("Library/Caches", isDirectory: true)
    static let systemCaches = URL(fileURLWithPath: "/Library/Caches", isDirectory: true)
    static let userLogs = home.appendingPathComponent("Library/Logs", isDirectory: true)
    static let systemLogs = URL(fileURLWithPath: "/Library/Logs", isDirectory: true)
    static let varLog = URL(fileURLWithPath: "/private/var/log", isDirectory: true)
    static let trash = home.appendingPathComponent(".Trash", isDirectory: true)
    static let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
    static let iOSBackups = home.appendingPathComponent("Library/Application Support/MobileSync/Backup", isDirectory: true)
    static let sleepImage = URL(fileURLWithPath: "/private/var/vm/sleepimage")
    static let vm = URL(fileURLWithPath: "/private/var/vm", isDirectory: true)
}

/// Everything a scan needs to judge whether an item is safe to remove right now.
struct CleanupContext: Sendable {
    var openFiles: OpenFiles
    /// Lower-cased bundle identifiers of running apps.
    var runningBundleIDs: Set<String>
    var now: Date
    var uid: uid_t

    static func current(runningBundleIDs: Set<String>) -> CleanupContext {
        CleanupContext(openFiles: .snapshot(), runningBundleIDs: Set(runningBundleIDs.map { $0.lowercased() }),
                       now: Date(), uid: getuid())
    }

    /// Items touched more recently than this are treated as active.
    static let quietPeriod: TimeInterval = 3600
}

enum CleanupScanner {
    /// Cache folder names handled by the Developer category, so they aren't counted twice.
    static let developerCacheNames: Set<String> = [
        "Homebrew", "pip", "Yarn", "CocoaPods", "go-build", "node-gyp", "ms-playwright", "pnpm", "bun",
        "org.carthage.CarthageKit", "com.apple.dt.Xcode",
    ]

    /// Apple caches in DARWIN_USER_CACHE_DIR that are safe to drop (rebuilt on demand).
    static let safeAppleSystemCaches: Set<String> = ["com.apple.metal", "com.apple.Safari.SafeBrowsing"]

    static func scan(_ kind: CleanupCategoryKind, context: CleanupContext) async -> CleanupCategory {
        switch kind {
        case .temporaryFiles: await temporaryFiles(context)
        case .userCaches: await userCaches(context)
        case .systemCaches: await systemCaches(context)
        case .logs: await logs(context)
        case .developer: await developer(context)
        case .trash: await trash(context)
        case .downloads: await downloads(context)
        case .largeFiles: largeFiles(context)
        case .iOSBackups: await iOSBackups(context)
        case .localSnapshots: localSnapshots()
        case .sleepImage: sleepImage()
        case .swap: swap()
        }
    }

    // MARK: - Categories

    static func temporaryFiles(_ context: CleanupContext) async -> CleanupCategory {
        var items: [CleanupItem] = []
        for root in [CleanupPaths.userTemp, CleanupPaths.tmp].compactMap({ $0 }) {
            items += await children(of: root, kind: .temporaryFiles, context: context) { url, stats, owner in
                let name = url.lastPathComponent
                let reason: CleanupSkipReason? =
                    owner != context.uid ? .anotherUser
                    : name.hasPrefix("com.apple.") || name.hasPrefix(".s.") || name.hasSuffix(".lock") || name.hasSuffix(".pid") ? .protected
                    : stats.containsSockets ? .containsSockets
                    : context.openFiles.containsOpenFile(under: url) ? .inUse
                    : isRecent(stats, context) ? .recentlyModified
                    : nil
                return (reason, .removeItem, true, nil)
            }
        }
        return CleanupCategory(kind: .temporaryFiles, state: .ready, items: sorted(items), location: CleanupPaths.tmp)
    }

    static func userCaches(_ context: CleanupContext) async -> CleanupCategory {
        let items = await children(of: CleanupPaths.userCaches, kind: .userCaches, context: context,
                                   exclude: developerCacheNames) { url, stats, _ in
            let name = url.lastPathComponent
            let reason: CleanupSkipReason? =
                CacheCleaner.protectedPrefixes.contains(where: { name.hasPrefix($0) }) ? .protected
                : belongsToRunningApp(name, context) ? .runningApp
                : context.openFiles.containsOpenFile(under: url) ? .inUse
                : nil
            return (reason, isDirectory(url) ? .emptyFolder : .removeItem, true, nil)
        }
        return CleanupCategory(kind: .userCaches, state: .ready, items: sorted(items), location: CleanupPaths.userCaches)
    }

    static func systemCaches(_ context: CleanupContext) async -> CleanupCategory {
        var items: [CleanupItem] = []
        if let userCache = CleanupPaths.userCache {
            items += await children(of: userCache, kind: .systemCaches, context: context) { url, _, owner in
                let name = url.lastPathComponent
                let appleCritical = name.hasPrefix("com.apple.") && !safeAppleSystemCaches.contains(name)
                let reason: CleanupSkipReason? =
                    owner != context.uid ? .anotherUser
                    : appleCritical ? .protected
                    : belongsToRunningApp(name, context) ? .runningApp
                    : context.openFiles.containsOpenFile(under: url) ? .inUse
                    : nil
                return (reason, isDirectory(url) ? .emptyFolder : .removeItem, true,
                        name == "clang" ? "Compiler module cache" : nil)
            }
        }
        // Shared caches need root; Apple's own (icon services, ColorSync, wallpapers) stay.
        items += await children(of: CleanupPaths.systemCaches, kind: .systemCaches, context: context,
                                requiresAdmin: true) { url, _, _ in
            let name = url.lastPathComponent
            let protected = name.hasPrefix("com.apple.") || ["ColorSync", "Desktop Pictures"].contains(name)
            // Root daemons may have these open and a non-root lsof can't see them: review only.
            return (protected ? .protected : nil, isDirectory(url) ? .emptyFolder : .removeItem, false,
                    "Shared by all users")
        }
        return CleanupCategory(kind: .systemCaches, state: .ready, items: sorted(items), location: CleanupPaths.userCache)
    }

    static func logs(_ context: CleanupContext) async -> CleanupCategory {
        var items = await children(of: CleanupPaths.userLogs, kind: .logs, context: context) { url, _, _ in
            let reason: CleanupSkipReason? = context.openFiles.containsOpenFile(under: url) ? .inUse : nil
            return (reason, isDirectory(url) ? .emptyFolder : .removeItem, true,
                    url.lastPathComponent == "DiagnosticReports" ? "Crash and hang reports" : nil)
        }
        items += await children(of: CleanupPaths.systemLogs, kind: .logs, context: context, requiresAdmin: true) { url, _, _ in
            (nil, isDirectory(url) ? .emptyFolder : .removeItem, true, "System log")
        }
        // Only rotated archives in /var/log; live logs are held open by syslogd.
        items += await children(of: CleanupPaths.varLog, kind: .logs, context: context, requiresAdmin: true,
                                include: { name in
                                    name.hasSuffix(".gz") || name.hasSuffix(".bz2")
                                        || name.range(of: #"\.\d+$"#, options: .regularExpression) != nil
                                }) { _, _, _ in (nil, .removeItem, true, "Rotated system log") }
        return CleanupCategory(kind: .logs, state: .ready, items: sorted(items), location: CleanupPaths.userLogs)
    }

    static func developer(_ context: CleanupContext) async -> CleanupCategory {
        let home = CleanupPaths.home
        // (path, recommended, detail)
        var targets: [(URL, Bool, String)] = [
            (home.appendingPathComponent("Library/Developer/Xcode/DerivedData"), true, "Xcode build products"),
            (home.appendingPathComponent("Library/Developer/Xcode/Archives"), false, "Xcode archives (keep for crash symbolication)"),
            (home.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport"), false, "Re-copied when a device connects"),
            (home.appendingPathComponent("Library/Developer/Xcode/watchOS DeviceSupport"), false, "Re-copied when a device connects"),
            (home.appendingPathComponent("Library/Developer/CoreSimulator/Caches"), true, "Simulator caches"),
            (home.appendingPathComponent(".npm/_cacache"), true, "npm download cache"),
            (home.appendingPathComponent(".npm/_npx"), true, "npx package cache"),
            (home.appendingPathComponent(".gradle/caches"), true, "Gradle dependency cache"),
            (home.appendingPathComponent(".gradle/wrapper/dists"), false, "Gradle distributions"),
            (home.appendingPathComponent(".m2/repository"), false, "Maven repository"),
            (home.appendingPathComponent(".bun/install/cache"), true, "Bun package cache"),
            (home.appendingPathComponent("Library/pnpm/store"), false, "Hard-linked into projects; deleting frees little. Prefer `pnpm store prune`"),
        ]
        let costly = ["ms-playwright": "Playwright browsers", "huggingface": "Downloaded ML models",
                      "puppeteer": "Puppeteer browsers", "pnpm": "pnpm store"]
        for name in developerCacheNames.sorted() {
            targets.append((CleanupPaths.userCaches.appendingPathComponent(name), costly[name] == nil,
                            costly[name] ?? "\(name) cache"))
        }
        let dotCache = home.appendingPathComponent(".cache")
        for url in (try? FileManager.default.contentsOfDirectory(at: dotCache, includingPropertiesForKeys: nil)) ?? [] {
            let name = url.lastPathComponent
            guard !name.hasPrefix(".") else { continue }
            targets.append((url, costly[name] == nil, costly[name] ?? "~/.cache/\(name)"))
        }

        let fm = FileManager.default
        let existing = targets.filter { fm.fileExists(atPath: $0.0.path) }
        let items = await mapBounded(existing) { url, recommended, detail -> CleanupItem in
            let stats = DiskUsage.stats(of: url)
            let reason: CleanupSkipReason? = context.openFiles.containsOpenFile(under: url) ? .inUse : nil
            return CleanupItem(url: url, name: displayPath(url), category: .developer, size: stats.size,
                               fileCount: stats.fileCount, modified: stats.newestModification, isDirectory: true,
                               requiresAdmin: false, removal: .emptyFolder, skipReason: reason,
                               recommended: recommended, detail: detail)
        }
        return CleanupCategory(kind: .developer, state: .ready, items: sorted(items.filter { ($0.size ?? 0) > 0 }),
                               location: home.appendingPathComponent("Library/Developer"))
    }

    static func trash(_ context: CleanupContext) async -> CleanupCategory {
        guard canList(CleanupPaths.trash) else {
            return CleanupCategory(kind: .trash, state: .needsFullDiskAccess, location: CleanupPaths.trash)
        }
        let items = await children(of: CleanupPaths.trash, kind: .trash, context: context) { _, _, _ in
            (nil, .removeItem, true, nil)
        }
        return CleanupCategory(kind: .trash, state: .ready, items: sorted(items), location: CleanupPaths.trash)
    }

    static func downloads(_ context: CleanupContext) async -> CleanupCategory {
        guard canList(CleanupPaths.downloads) else {
            return CleanupCategory(kind: .downloads, state: .needsFullDiskAccess, location: CleanupPaths.downloads)
        }
        let installers: Set<String> = ["dmg", "pkg", "iso", "zip", "xip", "mpkg"]
        let items = await children(of: CleanupPaths.downloads, kind: .downloads, context: context) { url, _, _ in
            let reason: CleanupSkipReason? = context.openFiles.containsOpenFile(under: url) ? .inUse : nil
            let isInstaller = installers.contains(url.pathExtension.lowercased())
            return (reason, .removeItem, false, isInstaller ? "Installer or archive" : nil)
        }
        return CleanupCategory(kind: .downloads, state: .ready, items: sorted(items), location: CleanupPaths.downloads)
    }

    /// Files of 500 MB or more under the home folder, excluding ~/Library, hidden
    /// folders, app/package internals, Downloads and Trash (they have their own categories).
    static func largeFiles(_ context: CleanupContext, threshold: UInt64 = 500_000_000) -> CleanupCategory {
        let home = CleanupPaths.home
        let skipTopLevel: Set<String> = ["Library", "Downloads", ".Trash"]
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey, .contentModificationDateKey]
        var items: [CleanupItem] = []
        let tops = (try? FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles])) ?? []
        for top in tops where !skipTopLevel.contains(top.lastPathComponent) {
            let enumerator = FileManager.default.enumerator(at: top, includingPropertiesForKeys: keys,
                                                            options: [.skipsHiddenFiles, .skipsPackageDescendants]) { _, _ in true }
            while let url = enumerator?.nextObject() as? URL {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      let size = values.totalFileAllocatedSize, UInt64(size) >= threshold else { continue }
                let reason: CleanupSkipReason? = context.openFiles.containsOpenFile(under: url) ? .inUse : nil
                items.append(CleanupItem(url: url, name: url.lastPathComponent, category: .largeFiles,
                                         size: UInt64(size), fileCount: 1, modified: values.contentModificationDate,
                                         isDirectory: false, requiresAdmin: false, removal: .removeItem,
                                         skipReason: reason, recommended: false, detail: displayPath(url.deletingLastPathComponent())))
            }
        }
        return CleanupCategory(kind: .largeFiles, state: .ready, items: sorted(items), location: home)
    }

    static func iOSBackups(_ context: CleanupContext) async -> CleanupCategory {
        let fm = FileManager.default
        guard fm.fileExists(atPath: CleanupPaths.iOSBackups.path) else {
            return CleanupCategory(kind: .iOSBackups, state: .ready, location: CleanupPaths.iOSBackups)
        }
        guard canList(CleanupPaths.iOSBackups) else {
            return CleanupCategory(kind: .iOSBackups, state: .needsFullDiskAccess, location: CleanupPaths.iOSBackups)
        }
        let items = await children(of: CleanupPaths.iOSBackups, kind: .iOSBackups, context: context) { url, _, _ in
            (nil, .removeItem, false, backupDeviceName(url))
        }
        return CleanupCategory(kind: .iOSBackups, state: .ready, items: sorted(items), location: CleanupPaths.iOSBackups)
    }

    static func localSnapshots() -> CleanupCategory {
        guard let output = Shell.captureStdout("/usr/bin/tmutil", ["listlocalsnapshots", "/"]) else {
            return CleanupCategory(kind: .localSnapshots, state: .unavailable("tmutil failed"))
        }
        let items = parseSnapshots(output).map { name -> CleanupItem in
            let date = timeMachineSnapshotDate(name)
            return CleanupItem(url: URL(string: "snapshot:///\(name)")!, name: name, category: .localSnapshots,
                               size: nil, fileCount: 0, modified: nil, isDirectory: false, requiresAdmin: true,
                               removal: date.map { .snapshot(date: $0) } ?? .none,
                               skipReason: date == nil ? .snapshotUnremovable : nil, recommended: false,
                               detail: date == nil ? "Created by a macOS update" : "Time Machine")
        }
        return CleanupCategory(kind: .localSnapshots, state: .ready, items: items,
                               note: items.isEmpty ? nil : "APFS doesn't report snapshot sizes; free space is measured after deleting.")
    }

    static func sleepImage() -> CleanupCategory {
        let url = CleanupPaths.sleepImage
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value, size > 0 else {
            return CleanupCategory(kind: .sleepImage, state: .ready)
        }
        let item = CleanupItem(url: url, name: "sleepimage", category: .sleepImage, size: size, fileCount: 1,
                               modified: attributes[.modificationDate] as? Date, isDirectory: false, requiresAdmin: true,
                               removal: .removeItem, skipReason: nil, recommended: false,
                               detail: "Re-created at next sleep")
        return CleanupCategory(kind: .sleepImage, state: .ready, items: [item], location: CleanupPaths.vm)
    }

    static func swap() -> CleanupCategory {
        var usage = xsw_usage()
        usage = Sysctl.value("vm.swapusage", initial: usage) ?? usage
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: CleanupPaths.vm.path)) ?? [])
            .filter { $0.hasPrefix("swapfile") }
        let items = files.map { name -> CleanupItem in
            let url = CleanupPaths.vm.appendingPathComponent(name)
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value
            return CleanupItem(url: url, name: name, category: .swap, size: size, fileCount: 1, modified: nil,
                               isDirectory: false, requiresAdmin: true, removal: .none, skipReason: nil,
                               recommended: false, detail: "Released on restart")
        }
        let used = ByteCountFormatter.string(fromByteCount: Int64(usage.xsu_used), countStyle: .memory)
        return CleanupCategory(kind: .swap, state: .ready, items: items, location: CleanupPaths.vm,
                               note: "\(used) of swap in use. macOS removes swap files on restart.")
    }

    // MARK: - Helpers

    typealias Judge = @Sendable (URL, TreeStats, uid_t) -> (CleanupSkipReason?, CleanupItem.Removal, Bool, String?)

    /// One item per child of `root`, sized in parallel and judged by `judge`.
    static func children(of root: URL, kind: CleanupCategoryKind, context: CleanupContext, requiresAdmin: Bool = false,
                         exclude: Set<String> = [], include: @Sendable (String) -> Bool = { _ in true },
                         judge: @escaping Judge) async -> [CleanupItem] {
        let urls = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { url in
                let name = url.lastPathComponent
                return name != ".DS_Store" && name != ".localized" && !exclude.contains(name) && include(name)
            }
        return await mapBounded(urls) { url -> CleanupItem in
            let stats = DiskUsage.stats(of: url)
            let owner = ownerUID(url) ?? context.uid
            let (reason, removal, recommended, detail) = judge(url, stats, owner)
            return CleanupItem(url: url, name: url.lastPathComponent, category: kind, size: stats.size,
                               fileCount: stats.fileCount, modified: stats.newestModification,
                               isDirectory: isDirectory(url), requiresAdmin: requiresAdmin, removal: removal,
                               skipReason: reason, recommended: recommended, detail: detail)
        }
        .filter { ($0.size ?? 0) > 0 || $0.isDirectory }
    }

    static func mapBounded<T: Sendable, R: Sendable>(_ inputs: [T], width: Int = 8,
                                                      _ transform: @escaping @Sendable (T) -> R) async -> [R] {
        await withTaskGroup(of: R.self) { group in
            var results: [R] = []
            var iterator = inputs.makeIterator()
            for _ in 0..<width {
                guard let next = iterator.next() else { break }
                group.addTask { transform(next) }
            }
            while let result = await group.next() {
                results.append(result)
                if let next = iterator.next() { group.addTask { transform(next) } }
            }
            return results
        }
    }

    static func belongsToRunningApp(_ folder: String, _ context: CleanupContext) -> Bool {
        CacheCleaner.shouldSkip(folder: folder, runningBundleIDs: context.runningBundleIDs)
            && !CacheCleaner.protectedPrefixes.contains(where: { folder.hasPrefix($0) })
    }

    static func isRecent(_ stats: TreeStats, _ context: CleanupContext) -> Bool {
        guard let newest = stats.newestModification else { return false }
        return context.now.timeIntervalSince(newest) < CleanupContext.quietPeriod
    }

    static func isDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    static func ownerUID(_ url: URL) -> uid_t? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return info.st_uid
    }

    static func canList(_ url: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
    }

    static func sorted(_ items: [CleanupItem]) -> [CleanupItem] {
        items.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
    }

    static func displayPath(_ url: URL) -> String {
        let path = url.path
        let home = CleanupPaths.home.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    static func backupDeviceName(_ url: URL) -> String? {
        let info = url.appendingPathComponent("Info.plist")
        guard let dict = NSDictionary(contentsOf: info) else { return nil }
        return (dict["Device Name"] as? String) ?? (dict["Display Name"] as? String)
    }

    /// Snapshot names from `tmutil listlocalsnapshots /` output.
    static func parseSnapshots(_ output: String) -> [String] {
        output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("com.apple.") }
    }

    /// "com.apple.TimeMachine.2026-11-20-101010.local" -> "2026-11-20-101010". Other snapshots -> nil.
    static func timeMachineSnapshotDate(_ name: String) -> String? {
        guard name.hasPrefix("com.apple.TimeMachine.") else { return nil }
        let date = name.dropFirst("com.apple.TimeMachine.".count).replacingOccurrences(of: ".local", with: "")
        return date.range(of: #"^\d{4}-\d{2}-\d{2}-\d{6}$"#, options: .regularExpression) != nil ? date : nil
    }
}
