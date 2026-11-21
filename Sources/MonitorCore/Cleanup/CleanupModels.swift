import Foundation

/// Kinds of reclaimable space, in the order the UI should list them.
public enum CleanupCategoryKind: String, CaseIterable, Codable, Sendable, Hashable, Identifiable {
    /// $TMPDIR and /private/tmp: what macOS itself wipes at reboot.
    case temporaryFiles
    /// ~/Library/Caches.
    case userCaches
    /// Per-user system cache (DARWIN_USER_CACHE_DIR) and /Library/Caches.
    case systemCaches
    /// ~/Library/Logs, diagnostic reports, and old system logs.
    case logs
    /// Xcode DerivedData, simulator caches, npm/yarn/gradle/pip caches.
    case developer
    case trash
    case downloads
    /// Files of 500 MB or more in your home folder (outside ~/Library).
    case largeFiles
    case iOSBackups
    /// Time Machine local snapshots on the startup disk.
    case localSnapshots
    /// /private/var/vm/sleepimage (RAM saved for safe sleep).
    case sleepImage
    /// Swap files. Only a reboot removes them, so this is informational.
    case swap

    public var id: Self { self }

    public var title: String {
        switch self {
        case .temporaryFiles: "Temporary Files"
        case .userCaches: "App Caches"
        case .systemCaches: "System Caches"
        case .logs: "Logs & Crash Reports"
        case .developer: "Developer Caches"
        case .trash: "Trash"
        case .downloads: "Downloads"
        case .largeFiles: "Large Files"
        case .iOSBackups: "iPhone & iPad Backups"
        case .localSnapshots: "Time Machine Snapshots"
        case .sleepImage: "Sleep Image"
        case .swap: "Swap"
        }
    }

    public var summary: String {
        switch self {
        case .temporaryFiles: "Leftover temp files that macOS deletes on restart. Files that apps still have open are kept."
        case .userCaches: "Data apps re-create on demand. Caches of running apps are kept."
        case .systemCaches: "Per-user and shared system caches. In-use and Apple-critical items are kept."
        case .logs: "Old app logs, crash reports, and rotated system logs."
        case .developer: "Build products and package-manager caches. They re-download or rebuild when needed."
        case .trash: "Files you already deleted."
        case .downloads: "Review before deleting. Installers (.dmg, .pkg, .zip, .iso) are usually safe to remove."
        case .largeFiles: "Files of 500 MB or more. Review each one."
        case .iOSBackups: "Device backups. Delete only if you have newer ones or use iCloud Backup."
        case .localSnapshots: "Local Time Machine snapshots. macOS keeps them as purgeable space."
        case .sleepImage: "Copy of RAM used for safe sleep. macOS re-creates it the next time the Mac sleeps."
        case .swap: "Virtual memory on disk. It's released on restart or when memory pressure drops."
        }
    }

    public var symbol: String {
        switch self {
        case .temporaryFiles: "clock.arrow.circlepath"
        case .userCaches: "archivebox"
        case .systemCaches: "gearshape.2"
        case .logs: "doc.text.magnifyingglass"
        case .developer: "hammer"
        case .trash: "trash"
        case .downloads: "arrow.down.circle"
        case .largeFiles: "doc.badge.ellipsis"
        case .iOSBackups: "iphone"
        case .localSnapshots: "clock.badge.checkmark"
        case .sleepImage: "moon.zzz"
        case .swap: "memorychip"
        }
    }

    public var safety: CleanupSafety {
        switch self {
        case .temporaryFiles, .userCaches, .systemCaches, .logs, .developer, .trash: .safe
        case .downloads, .largeFiles, .iOSBackups, .localSnapshots, .sleepImage: .review
        case .swap: .informational
        }
    }

    /// Part of the "Like a fresh restart" one-click cleanup.
    public var isRestartEquivalent: Bool {
        switch self {
        case .temporaryFiles, .userCaches, .systemCaches: true
        default: false
        }
    }

    /// How items in this category are removed by default.
    public var defaultMode: CleanupDeletionMode {
        switch self {
        case .downloads, .largeFiles: .moveToTrash
        default: .delete
        }
    }
}

public enum CleanupSafety: String, Sendable, Hashable {
    /// Regenerated automatically; selected by default.
    case safe
    /// User data or costly to rebuild; never selected by default.
    case review
    /// Shown for information; cannot be deleted from the app.
    case informational
}

public enum CleanupDeletionMode: String, Sendable, Hashable, CaseIterable {
    /// Gone immediately; space is freed now.
    case delete
    /// Recoverable from the Trash; space is freed when the Trash is emptied.
    case moveToTrash
}

/// Why an item is shown but cannot be selected.
public enum CleanupSkipReason: String, Sendable, Hashable {
    case inUse              // a running process has a file inside open
    case runningApp         // cache of an app that is running
    case recentlyModified   // changed in the last hour; probably still active
    case containsSockets    // live IPC endpoint (database, agent, daemon)
    case protected          // Apple-critical or tooling we never touch
    case anotherUser        // owned by root or another user
    case snapshotUnremovable // OS update snapshots; macOS manages them

    public var description: String {
        switch self {
        case .inUse: "In use by a running process"
        case .runningApp: "App is running"
        case .recentlyModified: "Changed in the last hour"
        case .containsSockets: "Used by a running service"
        case .protected: "Protected system data"
        case .anotherUser: "Owned by another user"
        case .snapshotUnremovable: "Managed by macOS updates"
        }
    }
}

public struct CleanupItem: Sendable, Hashable, Identifiable {
    public enum Removal: Sendable, Hashable {
        /// Remove the file or folder itself.
        case removeItem
        /// Delete everything inside, keep the folder (apps expect cache folders to exist).
        case emptyFolder
        /// `tmutil deletelocalsnapshots <date>`.
        case snapshot(date: String)
        /// Cannot be removed by the app.
        case none
    }

    public var url: URL
    public var name: String
    public var category: CleanupCategoryKind
    /// nil when unknown (snapshots: APFS doesn't report their size).
    public var size: UInt64?
    public var fileCount: Int
    public var modified: Date?
    public var isDirectory: Bool
    public var requiresAdmin: Bool
    public var removal: Removal
    public var skipReason: CleanupSkipReason?
    /// Safe to remove without thinking (caches that rebuild themselves cheaply).
    /// False for user data and for caches that are expensive to rebuild (ML models, browsers).
    public var recommended: Bool
    /// Short explanation shown under the name, e.g. "Xcode build products".
    public var detail: String?
    public var id: String { url.absoluteString }

    public var isRemovable: Bool { skipReason == nil && removal != .none }
    public var selectedByDefault: Bool { isRemovable && recommended }

    public init(url: URL, name: String, category: CleanupCategoryKind, size: UInt64?, fileCount: Int, modified: Date?,
                isDirectory: Bool, requiresAdmin: Bool, removal: Removal, skipReason: CleanupSkipReason?,
                recommended: Bool, detail: String? = nil) {
        self.url = url
        self.name = name
        self.category = category
        self.size = size
        self.fileCount = fileCount
        self.modified = modified
        self.isDirectory = isDirectory
        self.requiresAdmin = requiresAdmin
        self.removal = removal
        self.skipReason = skipReason
        self.recommended = recommended
        self.detail = detail
    }
}

public struct CleanupCategory: Sendable, Hashable, Identifiable {
    public enum State: Sendable, Hashable {
        case notScanned
        case scanning
        case ready
        /// macOS privacy blocks this folder. Grant Full Disk Access to see it.
        case needsFullDiskAccess
        case unavailable(String)
    }

    public var kind: CleanupCategoryKind
    public var state: State
    public var items: [CleanupItem]
    /// Folder to open when navigating ("Show in Finder" / in-app browser).
    public var location: URL?
    /// Extra context, e.g. "Swap: 2 GB in use (cleared on restart)".
    public var note: String?
    public var id: CleanupCategoryKind { kind }

    public var totalSize: UInt64 { items.reduce(0) { $0 + ($1.size ?? 0) } }
    public var removableSize: UInt64 { items.filter(\.isRemovable).reduce(0) { $0 + ($1.size ?? 0) } }

    public init(kind: CleanupCategoryKind, state: State = .notScanned, items: [CleanupItem] = [],
                location: URL? = nil, note: String? = nil) {
        self.kind = kind
        self.state = state
        self.items = items
        self.location = location
        self.note = note
    }
}

/// A row in the in-app folder browser.
public struct DirectoryEntry: Sendable, Hashable, Identifiable {
    public var url: URL
    public var size: UInt64
    public var fileCount: Int
    public var isDirectory: Bool
    public var isPackage: Bool
    public var isHidden: Bool
    public var modified: Date?
    public var accessDenied: Bool
    public var id: String { url.path }
    public var name: String { url.lastPathComponent }
    /// Folders (not app bundles or other packages) can be opened in the browser.
    public var canBrowse: Bool { isDirectory && !isPackage && !accessDenied }

    public init(url: URL, size: UInt64, fileCount: Int, isDirectory: Bool, isPackage: Bool, isHidden: Bool,
                modified: Date?, accessDenied: Bool) {
        self.url = url
        self.size = size
        self.fileCount = fileCount
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isHidden = isHidden
        self.modified = modified
        self.accessDenied = accessDenied
    }
}

public struct CleanupReport: Sendable, Hashable {
    public struct Skipped: Sendable, Hashable {
        public var name: String
        public var reason: String
        public init(name: String, reason: String) {
            self.name = name
            self.reason = reason
        }
    }

    /// Space freed right away (deleted items).
    public var bytesDeleted: UInt64
    /// Space that frees once the Trash is emptied.
    public var bytesMovedToTrash: UInt64
    public var itemsRemoved: Int
    /// Items found in use at deletion time (the situation changed since the scan), or failed.
    public var skipped: [Skipped]
    public var failures: [String]
    /// RAM moved from cache to free by purge (fresh-restart cleanup only).
    public var memoryFreed: UInt64
    /// Extra actions performed, e.g. "Flushed DNS cache", "Reset Quick Look cache".
    public var actions: [String]
    public var freeSpaceBefore: UInt64?
    public var freeSpaceAfter: UInt64?
    public var duration: TimeInterval

    /// Measured change in free disk space (can differ from bytesDeleted due to APFS).
    public var measuredFreed: Int64? {
        guard let before = freeSpaceBefore, let after = freeSpaceAfter else { return nil }
        return Int64(after) - Int64(before)
    }

    public init(bytesDeleted: UInt64 = 0, bytesMovedToTrash: UInt64 = 0, itemsRemoved: Int = 0, skipped: [Skipped] = [],
                failures: [String] = [], memoryFreed: UInt64 = 0, actions: [String] = [], freeSpaceBefore: UInt64? = nil,
                freeSpaceAfter: UInt64? = nil, duration: TimeInterval = 0) {
        self.bytesDeleted = bytesDeleted
        self.bytesMovedToTrash = bytesMovedToTrash
        self.itemsRemoved = itemsRemoved
        self.skipped = skipped
        self.failures = failures
        self.memoryFreed = memoryFreed
        self.actions = actions
        self.freeSpaceBefore = freeSpaceBefore
        self.freeSpaceAfter = freeSpaceAfter
        self.duration = duration
    }
}

public enum CleanupRunState: Sendable, Hashable {
    case idle
    /// Step description, e.g. "Deleting App Caches…".
    case running(String)
    case finished(CleanupReport)
    case failed(String)
}
