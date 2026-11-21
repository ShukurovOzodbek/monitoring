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

    @Test func nettopSkipsCumulativeBlockAndSumsDeltas() {
        var parser = NettopParser()
        let lines = [
            ",bytes_in,bytes_out,",          // block 1 header (cumulative)
            "mDNSResponder.519,208291959,179102546,",
            ",bytes_in,bytes_out,\r",        // block 2 header (pty adds \r)
            "Safari.900,1000,200,",
            "Some.Helper.900,24,0,",         // same pid twice -> summed
            "cloudd.25557,0,10,",
            ",bytes_in,bytes_out,",          // block 3 header -> emits block 2
        ]
        var emitted: [[Int32: (in: Double, out: Double)]] = []
        for line in lines { if let block = parser.consume(line) { emitted.append(block) } }
        #expect(emitted.count == 1)
        #expect(emitted[0][900]?.in == 1024)
        #expect(emitted[0][900]?.out == 200)
        #expect(emitted[0][25557]?.out == 10)
        #expect(emitted[0][519] == nil)
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

    @Test func perProcessNetworkStream() async throws {
        let monitor = ProcessNetworkMonitor()
        monitor.start()
        defer { monitor.stop() }
        // First delta block arrives ~2-3 s after start.
        var rates: [Int32: (in: Double, out: Double)] = [:]
        for _ in 0..<12 where rates.isEmpty {
            try await Task.sleep(for: .milliseconds(500))
            rates = monitor.rates
        }
        #expect(!rates.isEmpty, "nettop delta blocks should arrive within 6 s")
    }

    @Test func systemInfo() {
        let info = SystemSampler.systemInfo()
        #expect(info.chipName.contains("Apple") || info.chipName.contains("Intel"))
        #expect(info.uptime > 0)
        #expect(info.osVersion.hasPrefix("macOS "))
    }
}
