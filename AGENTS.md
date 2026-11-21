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
