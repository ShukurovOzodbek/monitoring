import Darwin
import Foundation

/// Owns all samplers and produces one `SystemSnapshot` per tick, off the main actor.
actor SystemSampler {
    private let processes = ProcessSampler()
    private let cpu = CPUSampler()
    private let network = NetworkSampler()
    private let disk = DiskSampler()
    private let processNetwork = ProcessNetworkMonitor()

    private var lastBatteryDate = Date.distantPast
    private var lastVolumesDate = Date.distantPast

    let hasBattery = BatterySampler.sample() != nil

    /// Kept for API compatibility; per-process network sampling no longer needs a background stream.
    func startStreams() {}
    func stopStreams() {}

    func sample() -> SystemSnapshot {
        let now = Date()
        processNetwork.update()
        let processList = processes.sample(networkRates: processNetwork.rates)
        killLeakedNettop(in: processList)

        var battery: BatterySnapshot?
        if hasBattery, now.timeIntervalSince(lastBatteryDate) >= 5 {
            battery = BatterySampler.sample()
            lastBatteryDate = now
        }
        var volumes: [VolumeInfo]?
        if now.timeIntervalSince(lastVolumesDate) >= 30 {
            volumes = VolumeSampler.sample()
            lastVolumesDate = now
        }

        return SystemSnapshot(
            date: now,
            cpu: cpu.sample(processCount: processList.count, threadCount: processes.lastThreadCount),
            memory: MemorySampler.sample(),
            network: network.sample(),
            disk: disk.sample(),
            battery: battery,
            hasBattery: hasBattery,
            volumes: volumes,
            processes: processList
        )
    }

    /// Builds before Nov 22 ran a streaming `nettop` (about 140% CPU) that could be
    /// left behind, orphaned to launchd, when the app quit. Clean those up: same user,
    /// parent launchd, hot for `leakStrikes` samples in a row. We no longer start any
    /// long-running nettop, and someone's own nettop in Terminal has a shell as its
    /// parent, so it's never touched.
    static let leakStrikes = 5
    private var nettopStrikes: [Int32: Int] = [:]

    func killLeakedNettop(in processes: [ProcessSample]) {
        var strikes: [Int32: Int] = [:]
        for process in processes where process.name == "nettop" && process.parentPID == 1
            && process.cpuPercent > 50 && process.user == NSUserName() {
            let count = (nettopStrikes[process.pid] ?? 0) + 1
            if count >= Self.leakStrikes { kill(process.pid, SIGKILL) } else { strikes[process.pid] = count }
        }
        nettopStrikes = strikes
    }

    /// Forces battery and volumes to be re-read on the next tick.
    func invalidateSlowMetrics() {
        lastBatteryDate = .distantPast
        lastVolumesDate = .distantPast
    }

    static func systemInfo() -> SystemInfo {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let build = Sysctl.string("kern.osversion") ?? ""
        var boot = timeval()
        boot = Sysctl.value("kern.boottime", initial: boot) ?? boot
        return SystemInfo(
            chipName: Sysctl.string("machdep.cpu.brand_string") ?? "Unknown",
            modelIdentifier: Sysctl.string("hw.model") ?? "Mac",
            osVersion: "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)" + (build.isEmpty ? "" : " (\(build))"),
            physicalMemory: MemorySampler.totalMemory,
            bootDate: Date(timeIntervalSince1970: TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1e6)
        )
    }
}
