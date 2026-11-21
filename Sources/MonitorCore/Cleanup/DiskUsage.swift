import Darwin
import Foundation

/// Size and safety facts about a file or folder tree, gathered in one walk.
struct TreeStats: Sendable {
    var size: UInt64 = 0
    var fileCount = 0
    /// Most recent modification anywhere in the tree.
    var newestModification: Date?
    /// Sockets/FIFOs mean a live process is using the folder for IPC.
    var containsSockets = false
    var accessDenied = false
}

enum DiskUsage {
    private static let keys: [URLResourceKey] = [
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey, .isRegularFileKey,
        .isSymbolicLinkKey, .contentModificationDateKey, .fileResourceTypeKey,
    ]

    /// Walks `url` without following symlinks. Cheap enough for caches and temp
    /// folders; large trees (npm, gradle) take a few seconds.
    static func stats(of url: URL) -> TreeStats {
        var stats = TreeStats()
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
            stats.accessDenied = true
            return stats
        }
        record(values, into: &stats)
        guard values.isDirectory == true, values.isSymbolicLink != true else { return stats }

        var denied = false
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: []) { _, _ in
            denied = true
            return true
        }
        while let child = enumerator?.nextObject() as? URL {
            guard let childValues = try? child.resourceValues(forKeys: Set(keys)) else { continue }
            record(childValues, into: &stats)
        }
        stats.accessDenied = denied && stats.fileCount == 0
        return stats
    }

    private static func record(_ values: URLResourceValues, into stats: inout TreeStats) {
        if let modified = values.contentModificationDate,
           stats.newestModification.map({ modified > $0 }) ?? true {
            stats.newestModification = modified
        }
        switch values.fileResourceType {
        case .socket?, .namedPipe?: stats.containsSockets = true
        default: break
        }
        if values.isRegularFile == true || values.isSymbolicLink == true {
            stats.fileCount += 1
            stats.size += UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
    }

    /// Immediate children of `url`, each with its full tree size, largest first.
    static func children(of url: URL, includeHidden: Bool = true) async -> [DirectoryEntry] {
        let fm = FileManager.default
        let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
        guard let urls = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys + [.isPackageKey, .isHiddenKey],
                                                     options: options) else { return [] }
        let entries = await withTaskGroup(of: DirectoryEntry?.self) { group in
            var results: [DirectoryEntry] = []
            var iterator = urls.makeIterator()
            func addNext() -> Bool {
                guard let child = iterator.next() else { return false }
                group.addTask { entry(for: child) }
                return true
            }
            // Bounded parallelism: enough to hide disk latency without thrashing.
            for _ in 0..<8 where addNext() {}
            while let result = await group.next() {
                if let result { results.append(result) }
                _ = addNext()
            }
            return results
        }
        return entries.sorted { $0.size > $1.size }
    }

    static func entry(for url: URL) -> DirectoryEntry? {
        guard let values = try? url.resourceValues(forKeys: Set(keys + [.isPackageKey, .isHiddenKey])) else { return nil }
        let stats = stats(of: url)
        return DirectoryEntry(url: url, size: stats.size, fileCount: stats.fileCount,
                              isDirectory: values.isDirectory == true && values.isSymbolicLink != true,
                              isPackage: values.isPackage == true, isHidden: values.isHidden == true,
                              modified: stats.newestModification ?? values.contentModificationDate,
                              accessDenied: stats.accessDenied)
    }

    static func freeSpace() -> UInt64? {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return UInt64(max(0, capacity))
    }
}

/// Paths currently open by any process of this user (from `lsof`, about 0.3 s).
/// Used to skip files a running app still needs.
struct OpenFiles: Sendable {
    private let paths: [String]   // sorted for prefix search
    /// False when lsof failed or its output looks truncated. Then every path counts
    /// as open, so nothing gets deleted on bad information (fail closed).
    let isReliable: Bool

    init(paths: [String], isReliable: Bool = true) {
        self.paths = paths.map(OpenFiles.normalize).sorted()
        self.isReliable = isReliable
    }

    static func snapshot() -> OpenFiles {
        for _ in 0..<2 {
            let files = read()
            if files.isReliable { return files }
        }
        return OpenFiles(paths: [], isReliable: false)
    }

    private static func read() -> OpenFiles {
        let output = Shell.captureStdout("/usr/sbin/lsof", ["-nPw", "-Fn", "-u", String(getuid())]) ?? ""
        // This process always has files open, so a complete listing must include it.
        let reliable = output.contains("p\(getpid())\n")
        var result: [String] = []
        for line in output.split(separator: "\n") where line.hasPrefix("n/") {
            var path = String(line.dropFirst())
            // lsof appends " (deleted)" or socket peer info on some entries.
            if let space = path.range(of: " (") { path = String(path[..<space.lowerBound]) }
            result.append(path)
        }
        return OpenFiles(paths: result, isReliable: reliable)
    }

    /// /tmp and /var are symlinks into /private; lsof reports either form.
    static func normalize(_ path: String) -> String {
        for dir in ["/tmp", "/var", "/etc"] where path == dir || path.hasPrefix(dir + "/") {
            return "/private" + path
        }
        return path
    }

    /// True if `url` itself, or anything inside it, is open.
    func containsOpenFile(under url: URL) -> Bool {
        guard isReliable else { return true }
        let base = OpenFiles.normalize(url.standardizedFileURL.path)
        let prefix = base.hasSuffix("/") ? base : base + "/"
        // Binary search for the first path >= base.
        var low = 0, high = paths.count
        while low < high {
            let mid = (low + high) / 2
            if paths[mid] < base { low = mid + 1 } else { high = mid }
        }
        var index = low
        while index < paths.count {
            let path = paths[index]
            if path == base || path.hasPrefix(prefix) { return true }
            if !path.hasPrefix(base) { break }
            index += 1
        }
        return false
    }

    var count: Int { paths.count }
}
