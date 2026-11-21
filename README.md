# Monitoring

Monitoring is a personal macOS activity monitor with a live dashboard and a menu bar panel. It tracks CPU, memory, network, disk, battery, and storage capacity. Search and sort running processes, group helpers by app, inspect a PID, or pin a process name to track its resource use. Add websites and servers to follow response times and recent uptime.

## Run and preview

Monitoring requires macOS 14 or later and a Swift 6 toolchain. Run it from the repository root.

```sh
swift run MonitoringApp
```

Open `Package.swift` in Xcode for live SwiftUI previews. Select a view under `Sources/MonitorUI` and resume its canvas. The previews use fixed sample data and run without live sampling.

If you use only the Command Line Tools, disable the Xcode preview macros for a debug build.

```sh
swift run -Xswiftc -DMONITORING_SKIP_PREVIEWS MonitoringApp
```

## Bundle and install

Build an ad-hoc signed `build/Monitoring.app` for local use.

```sh
./scripts/bundle.sh
```

Build and copy it to `/Applications`.

```sh
./scripts/bundle.sh --install
```

## Clean Cache

Open Clean Cache from Memory or the menu bar and choose which caches to clear.

- **Memory** purges cached files from RAM. macOS already frees this memory on demand, and files may reload the next time an app needs them.
- **DNS** flushes the macOS resolver cache.
- **App caches** clears eligible entries in `~/Library/Caches`. The cleaner skips protected caches and caches it associates with running apps.

Apps keep running. Memory and DNS cleaning share a macOS administrator prompt. The result shows memory and disk space freed, cache folders cleaned or skipped, and any warnings.

## Disk Cleanup

Open Cleanup from the sidebar or Overview, or choose Free Up Space from Capacity or the menu bar. The first visit scans the startup disk and shows free, reclaimable, and selected space.

Cleanup scans temporary files, app and system caches, logs and crash reports, developer caches, Trash, Downloads, large files in your home folder, iPhone and iPad backups, local Time Machine snapshots, the sleep image, and swap. Open a category to review the items and their sizes. Right-click a folder to browse its contents or show it in Finder.

The scan marks known protected items, including files held open, caches of running apps, temporary folders with sockets, and Apple system data. These items are excluded from selection. Cleanup limits removal to known cleanup locations and eligible files in your home folder. Swap is informational. Downloads, large files, and device backups go to Trash by default. Emptying Trash releases the space used by items moved there.

**Like a Fresh Restart** cleans eligible temporary files and app and system caches, resets the Quick Look thumbnail cache, frees cached files from RAM, and flushes DNS. Apps keep running and macOS asks for the administrator password. Swap is left in place. Restart the Mac to clear it. The result shows measured free space separately because APFS accounting can make it differ from the sum of deleted items.

If a category such as Trash requires Full Disk Access, use **Grant Full Disk Access** to open System Settings. Enable Monitoring under Privacy & Security → Full Disk Access, then return to Cleanup and choose **Rescan**.

## System process data

A lock marks processes with limited data. Monitoring can show CPU usage and resident memory (RSS) for these processes. Threads and per-process disk rates appear as **—** when unavailable. Processes that Monitoring can inspect directly report memory footprint.
