# Monitoring: agent guide

A personal macOS activity monitor: every running process plus CPU, memory, network,
disk, battery, storage capacity, website/server checks, and a cache cleaner. It runs
only on the owner's Mac (no App Store, no notarization).

Two coding agents work in this repo. The owner decides who writes what.

## Ownership (do not edit outside your area)

| Area | Owner | Path |
|---|---|---|
| Sampling, models, store, actions | Claude | `Sources/MonitorCore/**`, `Tests/**` |
| SwiftUI views, preview fixtures, design | Codex | `Sources/MonitorUI/**` |
| App entry point, menu bar scene, settings scene | Codex | `Sources/MonitoringApp/**` |
| Build/bundle scripts, app icon, README | Codex | `scripts/**`, `Resources/**`, `README.md` |
| Clipboard history logic and background helper | Claude | `Sources/ClipboardCore/**`, `Sources/ClipboardAgent/**` |
| Clipboard panel UI (⌥V) | Codex | `Sources/ClipboardUI/**` |

If the UI needs something MonitorCore doesn't provide, don't work around it in the
UI. Write the request in `docs/CORE_REQUESTS.md` (what and why), and the owner
passes it to Claude.

## Stack and rules

- Swift 6 language mode, macOS 14+, SwiftUI with Observation (`@Observable`), and Swift Charts.
- No third-party dependencies.
- `MonitorStore` is `@MainActor @Observable`. Inject it with `.environment(store)` and
  read it with `@Environment(MonitorStore.self)`.
- Every view in MonitorUI has a `#Preview` that uses fixture data. It must never
  start live sampling. Use `MonitorStore(preview:systemInfo:history:…)`.
- Build: `swift build`. Run: `swift run MonitoringApp`.
- Xcode: open `Package.swift`. Live previews work for the `MonitorUI` target.
- `swift test` needs full Xcode (the Command Line Tools ship an incomplete Testing framework).

## MonitorCore API (read the source for details)

`MonitorStore` (create one per app, call `start()` once):

- Live values: `systemInfo`, `cpu`, `memory`, `network`, `disk`, `battery` (nil without
  a battery), `hasBattery`, `volumes`, `processes`, `lastUpdated`.
- History for charts: `history` (`MetricHistory`: cpu, cpuUser, cpuSystem, memoryUsed, networkIn/Out,
  diskRead/Write, batteryLevel; 300 points), `processHistory[pid]` (120 points), and
  `watchedHistory[name]`.
- Processes: `sortedProcesses(by:matching:)`, `processGroups` (an app plus its
  helpers), `topProcesses(by:limit:)`, `process(pid:)`, and
  `terminate(pid:force:asAdministrator:) async throws`. It throws
  `ProcessActionError.permissionDenied` for system processes. Offer an "Enter
  password" retry with `asAdministrator: true`.
- Watched ("specific") processes: `watchedProcessNames`, `watch(_:)`, `unwatch(_:)`,
  `isWatched(_:)`, `processes(named:)`.
- Websites and servers: `endpoints`, `endpointStatuses[id]`, `addEndpoint(_:)`,
  `updateEndpoint(_:)`, `removeEndpoint(id:)`, and `checkNow(id:) async`.
  `Endpoint.parse("https://…" | "host:port" | "host")` builds one from a single text field.
- Cache: `cleanCaches(_ options: CacheCleanOptions = .all) async`, `cacheCleanState`
  (`.idle/.running/.finished(report)/.failed(msg)`), and `dismissCacheCleanResult()`.
- Settings: `sampleInterval` and `setSampleInterval(_:)` (0.5 to 10 s).
- `isPreview`: true for the fixture store. Actions are no-ops there, so use it instead of comparing against `PreviewData.store`.

Units: bytes, bytes per second, percent 0 to 100. `ProcessSample.cpuPercent` uses
100 = one core, so it can exceed 100. `ProcessSample.quality == .limited` means a
root/system process: CPU and memory are known, but threads and disk I/O are nil.
Show "—" for those, not 0.

## Disk cleanup API (`CleanupStore`, separate from `MonitorStore`)

Create one per app (`@State private var cleanup = CleanupStore()`), inject it with
`.environment(cleanup)`, and read it with `@Environment(CleanupStore.self)`. Nothing scans
until `await cleanup.scan()`. Call it when the Cleanup tab first appears, plus a Rescan button.

- `categories: [CleanupCategory]`, one per `CleanupCategoryKind` in display order. Each
  category has `kind` (with `title`, `summary`, `symbol`, `safety`, `isRestartEquivalent`),
  `state` (`.notScanned/.scanning/.ready/.needsFullDiskAccess/.unavailable(msg)`),
  `items`, `location` (folder to open), `note`, `totalSize`, and `removableSize`.
  Categories update one by one while scanning; show each as it arrives.
- `CleanupItem` has `name`, `detail`, `size` (nil = unknown, for snapshots), `fileCount`,
  `modified`, `url`, `requiresAdmin`, `recommended`, `skipReason` (non-nil = shown but not
  selectable; show `skipReason.description`), and `isRemovable`.
- Selection: `selection` (`Set<item.id>`), `isSelected`, `toggle`, `selectAll(in:)`,
  `deselectAll(in:)`, `selectRecommended()`, `clearSelection()`, `selectedSize`,
  `selectedSize(in:)`, and `selectionNeedsAdmin`. After a scan, recommended items are pre-selected.
- Totals: `freeSpace`, `reclaimableSize`, `restartCleanupSize`, `isScanning`, `lastScan`.
- Actions:
  - `await cleanSelected()` removes the selected items.
  - `await restartCleanup()` is the one-click "Like a fresh restart": temp files, app and
    system caches that nothing has open, the Quick Look cache, purge of RAM file cache,
    and a DNS flush. It shows one admin password prompt.
  - `userDataMode` (`.moveToTrash` default or `.delete`) applies to Downloads, Large
    Files and iOS Backups only.
  - Progress and result: `runState` (`.idle/.running(step)/.finished(CleanupReport)/.failed`)
    and `dismissResult()`. `CleanupReport` has `bytesDeleted`, `bytesMovedToTrash`,
    `itemsRemoved`, `skipped`, `failures`, `memoryFreed`, `actions`, `measuredFreed`
    (the real change in free disk space), and `duration`.
- Navigation:
  - `await contents(of: url)` lists `[DirectoryEntry]` (size, fileCount, `canBrowse`), largest first.
  - `canDelete(entry)` and `try await remove([entry], mode:)` delete from the browser. They
    throw `CleanupError.inUse`.
  - `revealInFinder(url)`, `open(url)`, and `openFullDiskAccessSettings()` (for
    `.needsFullDiskAccess` categories).
- Previews: `CleanupStore(preview:freeSpace:selection:runState:)` takes fixture categories. `isPreview` is true there.

## Clipboard history (`ClipboardCore`, separate helper process)

A background helper (`ClipboardAgent`, bundled as `Monitoring Clipboard.app`) records copied
text for 24 hours and shows a panel on ⌥V. launchd keeps it alive (RunAtLoad + KeepAlive). It
runs even when Monitoring is closed and refuses polite quits such as Swift Quit's. It's
installed as `~/Library/LaunchAgents/com.ozodbek.monitoring.clipboard.plist`.

- `ClipboardHistory` (`@MainActor @Observable`): `entries` (newest first, at most 24 h old),
  `search(_:)`, `remove(id:)`, `clear()`. `ClipboardEntry` has `text`, `title` (first
  non-empty line), `lineCount`, `date`, `sourceAppName`, and `sourceBundleID`. Previews:
  `ClipboardHistory(preview: [ClipboardEntry])`.
- `ClipboardPanelView(history:canAutoPaste:onPick:onDelete:onClose:onEnableAutoPaste:)` in
  ClipboardUI is the panel content. The helper hosts it in a floating panel. Keep this
  initializer signature.
- In the Monitoring app:
  - `ClipboardAgentInstaller.ensureInstalled()` at launch (no-op when unbundled).
  - `status()` returns `.notInstalled/.installedNotRunning/.running(pid:)`.
  - `setEnabled(_:)` and `isDisabledByUser`.
  - Post `ClipboardMessages.showPanel` or `ClipboardMessages.clear` with
    `DistributedNotificationCenter.default().postNotificationName(_:object:deliverImmediately: true)`
    to open the panel or clear history in the helper.
