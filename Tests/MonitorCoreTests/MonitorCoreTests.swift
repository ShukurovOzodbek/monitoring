import Foundation
import Testing
@testable import MonitorCore

@Suite("Parsers")
struct ParserTests {
    @Test func psCPUTime() {
        #expect(ProcessSampler.parseCPUTime("0:00.50") == 500_000_000)
        #expect(ProcessSampler.parseCPUTime("112:21.66") == 6_741_660_000_000)
        #expect(ProcessSampler.parseCPUTime("1:02:03.00") == 3_723_000_000_000)
        #expect(ProcessSampler.parseCPUTime("2-00:00:01.00") == 172_801_000_000_000)
        #expect(ProcessSampler.parseCPUTime("abc") == nil)
    }

    @Test func psOutput() {
        let rows = ProcessSampler.parsePS("    1 112:21.66  20592\n  366   1:30.32   2128\ngarbage\n")
        #expect(rows[1] == .init(cpuNanos: 6_741_660_000_000, rssBytes: 20592 * 1024))
        #expect(rows[366]?.rssBytes == 2128 * 1024)
        #expect(rows.count == 2)
    }

    @Test func nettopSnapshotsBecomeRates() {
        let first = NettopParser.parseSnapshot(",bytes_in,bytes_out,\nSafari.900,1000,200,\nSome.Helper.900,24,0,\ncloudd.25557,500,10,\ngarbage\n")
        #expect(first[900]?.in == 1024, "same pid on two rows is summed; dotted names parse")
        #expect(first[25557]?.out == 10)
        let second = NettopParser.parseSnapshot("Safari.900,3024,600,\nSome.Helper.900,24,0,\ncloudd.25557,100,10,\nnew.77,50,50,\n")
        let rates = NettopParser.rates(from: first, to: second, seconds: 2)
        #expect(rates[900]?.in == 1012, "(3024+24 - (1000+24)) / 2 s")
        #expect(rates[900]?.out == 200)
        #expect(rates[25557] == nil, "closed connections lower the counter: 0, not negative")
        #expect(rates[77] == nil, "no rate until a process has two snapshots")
    }

    @Test func pingRTT() {
        let output = "round-trip min/avg/max/stddev = 12.1/14.500/16.2/0.4 ms\n"
        #expect(EndpointChecker.parsePingRTT(output) == 0.0145)
        #expect(EndpointChecker.parsePingRTT("no reply") == nil)
    }

    @Test func processNames() {
        let chrome = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        #expect(ProcessSampler.displayName(path: chrome, fallback: "x") == "Google Chrome Helper (Renderer)")
        #expect(ProcessSampler.outermostAppBundle(chrome) == "/Applications/Google Chrome.app")
        #expect(ProcessSampler.displayName(path: "/usr/sbin/syslogd", fallback: "x") == "syslogd")
        #expect(ProcessSampler.displayName(path: nil, fallback: "kernel_task") == "kernel_task")
    }
}

@Suite("Endpoint parsing")
struct EndpointParseTests {
    @Test func kinds() {
        #expect(Endpoint.parse("https://apple.com")?.kind == .http(url: URL(string: "https://apple.com")!))
        #expect(Endpoint.parse("apple.com")?.kind == .http(url: URL(string: "https://apple.com")!))
        #expect(Endpoint.parse("db.local:5432")?.kind == .tcp(host: "db.local", port: 5432))
        #expect(Endpoint.parse("192.168.1.1")?.kind == .ping(host: "192.168.1.1"))
        #expect(Endpoint.parse("router")?.kind == .ping(host: "router"))
        #expect(Endpoint.parse("") == nil)
        #expect(Endpoint.parse("has space") == nil)
    }

    @Test func codableRoundTrip() throws {
        let endpoints = [Endpoint.parse("https://example.com")!, Endpoint.parse("localhost:22")!]
        let decoded = try JSONDecoder().decode([Endpoint].self, from: JSONEncoder().encode(endpoints))
        #expect(decoded == endpoints)
    }
}

@Suite("Cache cleaner")
struct CacheCleanerTests {
    @Test func skipsRunningAndProtected() {
        let running: Set<String> = ["com.google.chrome", "com.tinyspeck.slackmacgap.helper"]
        #expect(CacheCleaner.shouldSkip(folder: "com.google.Chrome", runningBundleIDs: running))
        #expect(CacheCleaner.shouldSkip(folder: "com.google.Chrome.helper", runningBundleIDs: running))
        #expect(CacheCleaner.shouldSkip(folder: "com.tinyspeck.slackmacgap", runningBundleIDs: running))
        #expect(CacheCleaner.shouldSkip(folder: "com.apple.Safari", runningBundleIDs: []))
        #expect(!CacheCleaner.shouldSkip(folder: "Homebrew", runningBundleIDs: running))
        #expect(!CacheCleaner.shouldSkip(folder: "com.google.chromeX", runningBundleIDs: running))
    }

    @Test func emptiesFoldersButKeepsThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cache-test-\(UUID())")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("org.example.Closed/sub"), withIntermediateDirectories: true)
        try Data(count: 10_000).write(to: root.appendingPathComponent("org.example.Closed/sub/blob"))
        try fm.createDirectory(at: root.appendingPathComponent("org.example.Running"), withIntermediateDirectories: true)
        try Data(count: 10).write(to: root.appendingPathComponent("org.example.Running/keep"))
        defer { try? fm.removeItem(at: root) }

        let result = CacheCleaner.cleanUserCaches(runningBundleIDs: ["org.example.running"], cachesURL: root)
        #expect(result.cleaned == 1)
        #expect(result.freed >= 10_000)
        #expect(result.skipped == ["org.example.Running"])
        #expect(fm.fileExists(atPath: root.appendingPathComponent("org.example.Closed").path))
        #expect(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("org.example.Closed").path).isEmpty)
        #expect(fm.fileExists(atPath: root.appendingPathComponent("org.example.Running/keep").path))
    }
}

@Suite("Live sampling", .serialized)
struct LiveSamplingTests {
    @Test func samplesThisMac() async throws {
        let sampler = SystemSampler()
        let first = await sampler.sample()
        // Burn some CPU in this process so its usage is measurable.
        let deadline = Date().addingTimeInterval(1)
        var x = 0.0
        while Date() < deadline { x += sin(x) + 1 }
        #expect(x > 0)
        let snapshot = await sampler.sample()

        #expect(snapshot.processes.count > 100)
        let me = try #require(snapshot.processes.first { $0.pid == getpid() })
        #expect(me.quality == .full)
        #expect(me.cpuPercent > 50, "busy loop should show ~100%: got \(me.cpuPercent)")
        #expect(me.memory > 1_000_000)
        #expect((me.threads ?? 0) >= 1)

        let launchd = try #require(snapshot.processes.first { $0.pid == 1 })
        #expect(launchd.quality == .limited)
        #expect(launchd.memory > 0, "ps fallback should give launchd RSS")
        #expect(launchd.cpuTime > 0)

        let limited = snapshot.processes.filter { $0.quality == .limited }
        let limitedWithData = limited.filter { $0.memory > 0 }
        #expect(Double(limitedWithData.count) / Double(max(limited.count, 1)) > 0.9)

        #expect(snapshot.cpu.cores.count == ProcessInfo.processInfo.activeProcessorCount)
        #expect(snapshot.cpu.total > 0 && snapshot.cpu.total <= 100)
        #expect(snapshot.memory.total == ProcessInfo.processInfo.physicalMemory)
        #expect(snapshot.memory.used > 0 && snapshot.memory.used < snapshot.memory.total)
        #expect(!snapshot.network.interfaces.isEmpty)
        #expect(snapshot.disk.totalRead > 0)
        // Volumes (30 s) and battery (5 s) refresh slower, so only the first tick carries them.
        #expect(snapshot.volumes == nil)
        let volumes = try #require(first.volumes)
        #expect(volumes.contains { $0.isRoot && $0.total > 0 })
        if first.hasBattery {
            let battery = try #require(first.battery)
            #expect((0...100).contains(battery.level))
            #expect(battery.cycleCount != nil)
        }
    }

    @Test func perProcessNetworkSnapshots() async throws {
        let monitor = ProcessNetworkMonitor()
        monitor.update()
        try await Task.sleep(for: .seconds(ProcessNetworkMonitor.minimumInterval + 0.2))
        // Generate some traffic so at least this process shows a rate.
        _ = try? await URLSession.shared.data(from: URL(string: "https://www.apple.com")!)
        monitor.update()
        #expect(!monitor.rates.isEmpty, "two snapshots should yield rates for active processes")
    }

    @Test func systemInfo() {
        let info = SystemSampler.systemInfo()
        #expect(info.chipName.contains("Apple") || info.chipName.contains("Intel"))
        #expect(info.uptime > 0)
        #expect(info.osVersion.hasPrefix("macOS "))
    }
}

@Suite("Disk cleanup")
struct CleanupTests {
    let home = CleanupPaths.home

    @Test func guardAllowsOnlyCleanupLocations() {
        func allowed(_ path: String, _ category: CleanupCategoryKind? = .userCaches) -> Bool {
            CleanupGuard.isAllowed(URL(fileURLWithPath: path), category: category)
        }
        #expect(allowed(home.path + "/Library/Caches/com.example.app"))
        #expect(!allowed(home.path + "/Library/Caches"), "root itself is never deleted")
        #expect(allowed("/tmp/leftover", .temporaryFiles), "/tmp is normalized to /private/tmp")
        #expect(!allowed("/System/Library/Caches/x"))
        #expect(!allowed("/Applications/Safari.app"))
        #expect(!allowed(home.path + "/Library/Caches/../Preferences/x"))
        #expect(!allowed(home.path + "/Documents", .largeFiles))
        #expect(!allowed(home.path, .largeFiles))
        #expect(allowed(home.path + "/Movies/huge.mov", .largeFiles))
        #expect(!allowed(home.path + "/Library/Mobile Documents/x.mov", .largeFiles), "iCloud Drive is off limits")
        #expect(!allowed(home.path + "/Movies/huge.mov", .userCaches), "only large files may target the home folder")
        #expect(allowed("/private/var/vm/sleepimage", .sleepImage))
        #expect(!allowed("/private/var/vm/sleepimage", .userCaches))
        #expect(!allowed("/private/var/vm/swapfile0", .swap))
        #expect(!CleanupGuard.isAllowed(URL(string: "snapshot:///com.apple.TimeMachine.x")!, category: .localSnapshots))
    }

    @Test func openFilesPrefixMatching() {
        let open = OpenFiles(paths: ["/tmp/a/b.sock", "/private/var/folders/x/C/app/db.sqlite", "/Users/u/file"])
        #expect(open.containsOpenFile(under: URL(fileURLWithPath: "/private/tmp/a")))
        #expect(open.containsOpenFile(under: URL(fileURLWithPath: "/var/folders/x/C/app")))
        #expect(!open.containsOpenFile(under: URL(fileURLWithPath: "/private/tmp/ab")))
        #expect(!open.containsOpenFile(under: URL(fileURLWithPath: "/Users/u/fil")))
        #expect(open.containsOpenFile(under: URL(fileURLWithPath: "/Users/u/file")))
        let unknown = OpenFiles(paths: [], isReliable: false)
        #expect(unknown.containsOpenFile(under: URL(fileURLWithPath: "/private/tmp/anything")), "fails closed")
        #expect(OpenFiles.snapshot().isReliable)
    }

    @Test func shellQuoting() {
        #expect(CleanupExecutor.quote("/tmp/it's here") == #"'/tmp/it'\''s here'"#)
        let item = CleanupItem(url: URL(fileURLWithPath: "/Library/Caches/a b"), name: "a b", category: .systemCaches,
                               size: 1, fileCount: 1, modified: nil, isDirectory: true, requiresAdmin: true,
                               removal: .emptyFolder, skipReason: nil, recommended: true)
        let line = CleanupExecutor.adminScript(for: [item])[0]
        #expect(line.hasPrefix("/usr/bin/find '/Library/Caches/a b' -mindepth 1 -maxdepth 1"))
    }

    @Test func snapshotNames() {
        let output = """
        Snapshots for volume group containing disk /:
        com.apple.TimeMachine.2026-11-20-101010.local
        com.apple.os.update-5514FF97DEE9C60C
        """
        let names = CleanupScanner.parseSnapshots(output)
        #expect(names.count == 2)
        #expect(CleanupScanner.timeMachineSnapshotDate(names[0]) == "2026-11-20-101010")
        #expect(CleanupScanner.timeMachineSnapshotDate(names[1]) == nil)
    }

    @Test func deletesFreeItemsAndKeepsOpenOnes() async throws {
        let fm = FileManager.default
        let root = try #require(CleanupPaths.userTemp).appendingPathComponent("cleanup-test-\(UUID().uuidString)")
        let freeFolder = root.appendingPathComponent("free")
        let busyFolder = root.appendingPathComponent("busy")
        try fm.createDirectory(at: freeFolder, withIntermediateDirectories: true)
        try fm.createDirectory(at: busyFolder, withIntermediateDirectories: true)
        try Data(count: 50_000).write(to: freeFolder.appendingPathComponent("a.bin"))
        try Data(count: 50_000).write(to: busyFolder.appendingPathComponent("open.bin"))
        try Data(count: 10_000).write(to: busyFolder.appendingPathComponent("closed.bin"))
        defer { try? fm.removeItem(at: root) }
        let handle = try FileHandle(forReadingFrom: busyFolder.appendingPathComponent("open.bin"))
        defer { try? handle.close() }

        let context = CleanupContext.current(runningBundleIDs: [])
        func item(_ url: URL, _ removal: CleanupItem.Removal) -> CleanupItem {
            CleanupItem(url: url, name: url.lastPathComponent, category: .temporaryFiles,
                        size: DiskUsage.stats(of: url).size, fileCount: 1, modified: nil, isDirectory: true,
                        requiresAdmin: false, removal: removal, skipReason: nil, recommended: true)
        }
        let report = try await CleanupExecutor.run(
            items: [item(freeFolder, .removeItem), item(busyFolder, .removeItem),
                    item(busyFolder.appendingPathComponent("closed.bin"), .removeItem)],
            userDataMode: .delete, context: context, progress: { _ in })

        #expect(!fm.fileExists(atPath: freeFolder.path))
        #expect(fm.fileExists(atPath: busyFolder.appendingPathComponent("open.bin").path), "open file must survive")
        #expect(!fm.fileExists(atPath: busyFolder.appendingPathComponent("closed.bin").path))
        #expect(report.itemsRemoved == 2)
        #expect(report.skipped.map(\.name) == ["busy"])
        #expect(report.bytesDeleted >= 60_000)
    }

    @Test func emptyFolderKeepsFolderAndOpenFiles() async throws {
        let fm = FileManager.default
        let root = try #require(CleanupPaths.userTemp).appendingPathComponent("cleanup-test-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(count: 20_000).write(to: root.appendingPathComponent("old.bin"))
        try Data(count: 20_000).write(to: root.appendingPathComponent("open.bin"))
        defer { try? fm.removeItem(at: root) }
        let handle = try FileHandle(forReadingFrom: root.appendingPathComponent("open.bin"))
        defer { try? handle.close() }

        let item = CleanupItem(url: root, name: "cache", category: .userCaches, size: 40_000, fileCount: 2, modified: nil,
                               isDirectory: true, requiresAdmin: false, removal: .emptyFolder, skipReason: nil, recommended: true)
        let result = CleanupExecutor.removeUserItems([item], mode: .delete, context: .current(runningBundleIDs: []))
        #expect(fm.fileExists(atPath: root.path))
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("old.bin").path))
        #expect(fm.fileExists(atPath: root.appendingPathComponent("open.bin").path))
        #expect(result.skipped.first?.reason.contains("in use") == true)
    }

    @Test func liveScanFindsSpaceAndProtectsLiveItems() async {
        let context = CleanupContext.current(runningBundleIDs: [])
        #expect(context.openFiles.count > 100)
        let temp = await CleanupScanner.scan(.temporaryFiles, context: context)
        #expect(temp.state == .ready)
        // Live sockets in /tmp (databases, agents) must never be selectable.
        for item in temp.items where item.name.hasPrefix(".s.") || item.name.hasPrefix("com.apple.launchd") {
            #expect(!item.isRemovable, "\(item.name) must be protected")
        }
        let caches = await CleanupScanner.scan(.userCaches, context: context)
        #expect(caches.items.contains { $0.name.hasPrefix("com.apple.") && $0.skipReason == .protected })
        let swap = CleanupScanner.swap()
        #expect(swap.items.allSatisfy { !$0.isRemovable })
    }
}
