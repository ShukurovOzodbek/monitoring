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

    func startStreams() { processNetwork.start() }
    func stopStreams() { processNetwork.stop() }

    func sample() -> SystemSnapshot {
        let now = Date()
        let processList = processes.sample(networkRates: processNetwork.rates)
        Self.killRunawayNettop(in: processList)

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

    /// nettop spins at 100%+ CPU once its terminal is gone (it retries the failed
    /// write forever). A healthy one uses about 1%. Kill any that belong to this app
    /// (child of our watchdog shell) or were orphaned by an earlier build (parent
    /// launchd). The monitor restarts a fresh one. Someone's own interactive nettop
    /// in Terminal is left alone.
    static func killRunawayNettop(in processes: [ProcessSample]) {
        let me = getpid()
        let ourWrappers = Set(processes.filter { $0.parentPID == me }.map(\.pid))
        for process in processes where process.name == "nettop" && process.cpuPercent > 50
            && process.user == NSUserName()
            && (process.parentPID == 1 || ourWrappers.contains(process.parentPID)) {
            kill(process.pid, SIGKILL)
        }
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
