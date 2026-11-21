import AppKit
import Foundation
import Observation

/// Disk cleanup: scans reclaimable space, lets the user pick items, removes them,
/// and offers a one-click "Like a fresh restart" cleanup.
///
/// Create one per app and inject it with `.environment(cleanup)` next to `MonitorStore`.
/// Nothing is scanned until `scan()` is called (for example when the Cleanup tab appears).
@MainActor
@Observable
public final class CleanupStore {
    /// One entry per `CleanupCategoryKind`, in display order.
    public private(set) var categories: [CleanupCategory]
    public private(set) var isScanning = false
    public private(set) var lastScan: Date?
    /// Free space on the startup disk (includes purgeable space macOS can reclaim).
    public private(set) var freeSpace: UInt64?
    /// IDs (`CleanupItem.id`) of the items the user picked.
    public var selection: Set<String> = []
    public private(set) var runState: CleanupRunState = .idle
    /// How Downloads, Large Files and iOS Backups are removed. Caches and temp files are always deleted.
    public var userDataMode: CleanupDeletionMode = .moveToTrash
    public let isPreview: Bool

    private var scanTask: Task<Void, Never>?
    private var directoryCache: [URL: [DirectoryEntry]] = [:]

    public init() {
        categories = CleanupCategoryKind.allCases.map { CleanupCategory(kind: $0) }
        isPreview = false
        freeSpace = DiskUsage.freeSpace()
    }

    /// Fixed data for SwiftUI previews; actions are no-ops.
    public init(preview categories: [CleanupCategory], freeSpace: UInt64?, selection: Set<String>? = nil,
                runState: CleanupRunState = .idle) {
        self.categories = categories
        self.isPreview = true
        self.freeSpace = freeSpace
        self.lastScan = Date()
        self.runState = runState
        self.selection = selection ?? Set(categories.flatMap(\.items).filter(\.selectedByDefault).map(\.id))
    }

    // MARK: Totals

    public func category(_ kind: CleanupCategoryKind) -> CleanupCategory? {
        categories.first { $0.kind == kind }
    }

    public var allItems: [CleanupItem] { categories.flatMap(\.items) }
    public var selectedItems: [CleanupItem] { allItems.filter { selection.contains($0.id) && $0.isRemovable } }
    public var selectedSize: UInt64 { selectedItems.reduce(0) { $0 + ($1.size ?? 0) } }
    /// Everything that could be removed (selected or not).
    public var reclaimableSize: UInt64 { categories.reduce(0) { $0 + $1.removableSize } }
    /// What the one-click restart cleanup would remove right now.
    public var restartCleanupSize: UInt64 {
        restartCleanupItems.reduce(0) { $0 + ($1.size ?? 0) }
    }
    /// True if any selected item needs the admin password.
    public var selectionNeedsAdmin: Bool { selectedItems.contains(where: \.requiresAdmin) }

    private var restartCleanupItems: [CleanupItem] {
        categories.filter(\.kind.isRestartEquivalent).flatMap(\.items).filter(\.selectedByDefault)
    }

    // MARK: Scanning

    /// Scans every category in parallel. Each category updates as soon as it finishes.
    public func scan() async {
        await scan(CleanupCategoryKind.allCases)
    }

    public func scan(_ kinds: [CleanupCategoryKind]) async {
        guard !isPreview, !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        for kind in kinds { update(kind) { $0.state = .scanning } }
        let context = CleanupContext.current(runningBundleIDs: runningBundleIDs())

        await withTaskGroup(of: CleanupCategory.self) { group in
            for kind in kinds {
                group.addTask { await CleanupScanner.scan(kind, context: context) }
            }
            for await result in group {
                let previouslyKnown = Set(category(result.kind)?.items.map(\.id) ?? [])
                update(result.kind) { $0 = result }
                // Select new safe items by default; keep the user's choices for known ones.
                for item in result.items where !previouslyKnown.contains(item.id) && item.selectedByDefault {
                    selection.insert(item.id)
                }
            }
        }
        let valid = Set(allItems.filter(\.isRemovable).map(\.id))
        selection.formIntersection(valid)
        directoryCache = [:]
        freeSpace = DiskUsage.freeSpace()
        lastScan = Date()
    }

    // MARK: Selection

    public func isSelected(_ item: CleanupItem) -> Bool { selection.contains(item.id) }

    public func toggle(_ item: CleanupItem) {
        guard item.isRemovable else { return }
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    public func selectAll(in kind: CleanupCategoryKind) {
        for item in category(kind)?.items ?? [] where item.isRemovable { selection.insert(item.id) }
    }

    public func deselectAll(in kind: CleanupCategoryKind) {
        for item in category(kind)?.items ?? [] { selection.remove(item.id) }
    }

    public func selectRecommended() {
        selection = Set(allItems.filter(\.selectedByDefault).map(\.id))
    }

    public func clearSelection() { selection = [] }

    public func selectedSize(in kind: CleanupCategoryKind) -> UInt64 {
        (category(kind)?.items ?? []).filter { selection.contains($0.id) && $0.isRemovable }
            .reduce(0) { $0 + ($1.size ?? 0) }
    }

    // MARK: Cleaning

    /// Removes the selected items. Shows one admin prompt if any need root.
    public func cleanSelected() async {
        await run(items: selectedItems, adminCommands: [], rescan: Array(Set(selectedItems.map(\.category))))
    }

    /// Does on disk (and in RAM) what a restart would, without closing any app:
    /// temp files, app and system caches that nothing has open, the Quick Look
    /// thumbnail cache, the file cache in RAM (`purge`), and the DNS cache.
    /// Shows one admin password prompt.
    public func restartCleanup() async {
        guard !isPreview, !isRunning else { return }
        let kinds = CleanupCategoryKind.allCases.filter(\.isRestartEquivalent)
        if kinds.contains(where: { category($0)?.state != .ready }) {
            runState = .running("Scanning…")
            await scan(kinds)
        }
        await run(items: restartCleanupItems,
                  adminCommands: ["/usr/sbin/purge", "/usr/bin/dscacheutil -flushcache", "/usr/bin/killall -HUP mDNSResponder"],
                  rescan: kinds, quickLook: true)
    }

    public func dismissResult() {
        if !isRunning { runState = .idle }
    }

    public var isRunning: Bool {
        if case .running = runState { return true }
        return false
    }

    private func run(items: [CleanupItem], adminCommands: [String], rescan kinds: [CleanupCategoryKind],
                     quickLook: Bool = false) async {
        guard !isPreview, !isRunning || runState == .running("Scanning…") else { return }
        guard !items.isEmpty || !adminCommands.isEmpty else { return }
        runState = .running("Preparing…")
        let context = CleanupContext.current(runningBundleIDs: runningBundleIDs())
        do {
            var report = try await CleanupExecutor.run(
                items: items, userDataMode: userDataMode, adminCommands: adminCommands, context: context,
                progress: { [weak self] message in await self?.setProgress(message) })
            if quickLook {
                _ = try? await Shell.runAsync("/usr/bin/qlmanage", ["-r", "cache"])
                report.actions.append("Reset the Quick Look thumbnail cache")
            }
            if adminCommands.contains(where: { $0.contains("purge") }) {
                report.actions.append("Freed cached files from memory")
            }
            if adminCommands.contains(where: { $0.contains("dscacheutil") }) {
                report.actions.append("Flushed the DNS cache")
            }
            runState = .finished(report)
        } catch AdminCommandError.cancelled {
            runState = .idle
        } catch {
            runState = .failed(error.localizedDescription)
        }
        selection.subtract(items.map(\.id))
        await scan(kinds)
    }

    private func setProgress(_ message: String) {
        runState = .running(message)
    }

    // MARK: Browsing

    /// Children of `url` with sizes, largest first. Cached until the next scan or deletion.
    public func contents(of url: URL, includeHidden: Bool = true) async -> [DirectoryEntry] {
        if let cached = directoryCache[url] { return cached }
        let entries = await DiskUsage.children(of: url, includeHidden: includeHidden)
        directoryCache[url] = entries
        return entries
    }

    /// True if the browser may offer "Move to Trash" / "Delete" for this entry.
    public func canDelete(_ entry: DirectoryEntry) -> Bool {
        CleanupGuard.isAllowed(entry.url, category: nil)
    }

    /// Deletes or trashes entries picked in the browser. Returns bytes affected.
    @discardableResult
    public func remove(_ entries: [DirectoryEntry], mode: CleanupDeletionMode = .moveToTrash) async throws -> UInt64 {
        guard !isPreview else { return 0 }
        let allowed = entries.filter(canDelete)
        let open = OpenFiles.snapshot()
        let blocked = allowed.filter { open.containsOpenFile(under: $0.url) }
        if let first = blocked.first {
            throw CleanupError.inUse(first.name)
        }
        let total = try await Task.detached(priority: .userInitiated) { () throws -> UInt64 in
            var total: UInt64 = 0
            for entry in allowed {
                if mode == .moveToTrash {
                    try FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
                } else {
                    try FileManager.default.removeItem(at: entry.url)
                }
                total += entry.size
            }
            return total
        }.value
        // Invalidate the parent listings and every ancestor (their sizes changed).
        directoryCache = directoryCache.filter { key, _ in
            !allowed.contains { $0.url.path.hasPrefix(key.path) }
        }
        freeSpace = DiskUsage.freeSpace()
        return total
    }

    public func revealInFinder(_ url: URL) {
        guard url.isFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public func open(_ url: URL) {
        guard url.isFileURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Opens System Settings › Privacy & Security › Full Disk Access.
    public func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Private

    private func update(_ kind: CleanupCategoryKind, _ change: (inout CleanupCategory) -> Void) {
        guard let index = categories.firstIndex(where: { $0.kind == kind }) else { return }
        change(&categories[index])
    }

    private func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }
}

public enum CleanupError: Error, LocalizedError, Sendable, Equatable {
    case inUse(String)

    public var errorDescription: String? {
        switch self {
        case .inUse(let name): "\(name) is in use by a running app. Quit the app first."
        }
    }
}
