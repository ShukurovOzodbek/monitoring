import Darwin
import Foundation

/// Samples every running process.
///
/// Strategy:
/// - The process list, parent, owner, and start time come from `sysctl(KERN_PROC_ALL)`.
///   This works for every process without privileges.
/// - Processes we may inspect (same user) are read with `proc_pid_rusage`:
///   CPU time, footprint memory (as Activity Monitor shows), and disk I/O.
/// - Processes owned by root or system users deny that call. For those we use
///   `/bin/ps`, which is setuid root, to get CPU time and RSS.
/// - CPU % is the CPU-time delta divided by the wall-time delta between ticks.
///
/// Not thread-safe; owned by `SystemSampler`.
final class ProcessSampler {
    private struct Identity: Hashable {
        let pid: Int32
        let startSec: Int
        let startUsec: Int32
    }

    private struct Static {
        let name: String
        let path: String?
        let appBundlePath: String?
        let user: String
    }

    private struct Counters {
        let cpuNanos: UInt64
        let diskRead: UInt64?
        let diskWritten: UInt64?
    }

    private var statics: [Identity: Static] = [:]
    private var previous: [Identity: Counters] = [:]
    private var previousTime: UInt64 = 0
    private var userNames: [uid_t: String] = [:]

    private(set) var lastThreadCount = 0

    func sample(networkRates: [Int32: (in: Double, out: Double)]) -> [ProcessSample] {
        let now = MachTime.now()
        let elapsed = previousTime == 0 ? 0 : Double(now - previousTime) / 1e9
        previousTime = now

        let kinfos = Self.allProcesses()
        var current: [Identity: Counters] = [:]
        current.reserveCapacity(kinfos.count)
        var limitedPIDs: [Int32: Identity] = [:]
        var samples: [ProcessSample] = []
        samples.reserveCapacity(kinfos.count)
        var threadTotal = 0

        for kp in kinfos {
            let pid = kp.kp_proc.p_pid
            if kp.kp_proc.p_stat == SZOMB { continue }
            let start = kp.kp_proc.p_un.__p_starttime
            let identity = Identity(pid: pid, startSec: start.tv_sec, startUsec: start.tv_usec)
            let info = staticInfo(for: identity, kinfo: kp)
            let startDate = start.tv_sec > 0
                ? Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1e6)
                : nil
            let net = networkRates[pid]

            var sample = ProcessSample(
                pid: pid, parentPID: kp.kp_eproc.e_ppid, name: info.name, executablePath: info.path,
                appBundlePath: info.appBundlePath, user: info.user, startDate: startDate,
                cpuPercent: 0, cpuTime: 0, memory: 0, threads: nil, diskReadRate: nil, diskWriteRate: nil,
                networkInRate: net?.in ?? 0, networkOutRate: net?.out ?? 0, quality: .full
            )

            if let usage = Self.rusage(pid) {
                let cpu = MachTime.nanoseconds(fromTicks: usage.ri_user_time + usage.ri_system_time)
                let counters = Counters(cpuNanos: cpu, diskRead: usage.ri_diskio_bytesread,
                                        diskWritten: usage.ri_diskio_byteswritten)
                current[identity] = counters
                sample.cpuTime = Double(cpu) / 1e9
                sample.memory = usage.ri_phys_footprint
                if let prev = previous[identity], elapsed > 0 {
                    sample.cpuPercent = rate(from: prev.cpuNanos, to: cpu, seconds: elapsed) / 1e9 * 100
                    sample.diskReadRate = rate(from: prev.diskRead ?? 0, to: usage.ri_diskio_bytesread, seconds: elapsed)
                    sample.diskWriteRate = rate(from: prev.diskWritten ?? 0, to: usage.ri_diskio_byteswritten, seconds: elapsed)
                } else {
                    sample.diskReadRate = 0
                    sample.diskWriteRate = 0
                }
                if let threads = Self.threadCount(pid) {
                    sample.threads = threads
                    threadTotal += threads
                }
            } else {
                sample.quality = .limited
                limitedPIDs[pid] = identity
            }
            samples.append(sample)
        }

        if !limitedPIDs.isEmpty {
            let psRows = Self.psSnapshot()
            for index in samples.indices where samples[index].quality == .limited {
                let pid = samples[index].pid
                guard let identity = limitedPIDs[pid], let row = psRows[pid] else { continue }
                current[identity] = Counters(cpuNanos: row.cpuNanos, diskRead: nil, diskWritten: nil)
                samples[index].cpuTime = Double(row.cpuNanos) / 1e9
                samples[index].memory = row.rssBytes
                if let prev = previous[identity], elapsed > 0 {
                    samples[index].cpuPercent = rate(from: prev.cpuNanos, to: row.cpuNanos, seconds: elapsed) / 1e9 * 100
                }
            }
        }

        previous = current
        // Drop cached names for processes that exited.
        if statics.count > current.count + limitedPIDs.count + 256 {
            let alive = Set(current.keys).union(limitedPIDs.values)
            statics = statics.filter { alive.contains($0.key) }
        }
        lastThreadCount = threadTotal
        return samples
    }

    // MARK: - Static per-process info

    private func staticInfo(for identity: Identity, kinfo kp: kinfo_proc) -> Static {
        if let cached = statics[identity] { return cached }
        let path = Self.executablePath(identity.pid)
        let comm = withUnsafeBytes(of: kp.kp_proc.p_comm) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        let info = Static(
            name: Self.displayName(path: path, fallback: comm),
            path: path,
            appBundlePath: path.flatMap(Self.outermostAppBundle),
            user: userName(kp.kp_eproc.e_ucred.cr_uid)
        )
        statics[identity] = info
        return info
    }

    private func userName(_ uid: uid_t) -> String {
        if let cached = userNames[uid] { return cached }
        let name = getpwuid(uid).map { String(cString: $0.pointee.pw_name) } ?? String(uid)
        userNames[uid] = name
        return name
    }

    /// Innermost `.app` name (as Activity Monitor shows) or the executable name.
    static func displayName(path: String?, fallback: String) -> String {
        guard let path, !path.isEmpty else { return fallback }
        let components = path.split(separator: "/")
        if let app = components.last(where: { $0.hasSuffix(".app") }),
           path.contains(".app/Contents/MacOS/") {
            return String(app.dropLast(4))
        }
        return components.last.map(String.init) ?? fallback
    }

    static func outermostAppBundle(_ path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    // MARK: - Kernel calls

    static func allProcesses() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return [] }
            size += size / 8 // room for processes spawned between calls
            let stride = MemoryLayout<kinfo_proc>.stride
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride)
            let result = procs.withUnsafeMutableBytes { buffer in
                sysctl(&mib, u_int(mib.count), buffer.baseAddress, &size, nil, 0)
            }
            if result == 0 {
                return Array(procs.prefix(size / stride))
            }
            if errno != ENOMEM { return [] }
        }
        return []
    }

    static func rusage(_ pid: Int32) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info : nil
    }

    static func threadCount(_ pid: Int32) -> Int? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return Int(info.pti_threadnum)
    }

    static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cBuffer: buffer)
    }

    // MARK: - ps fallback

    struct PSRow: Equatable {
        let cpuNanos: UInt64
        let rssBytes: UInt64
    }

    static func psSnapshot() -> [Int32: PSRow] {
        guard let output = Shell.captureStdout("/bin/ps", ["-axo", "pid=,time=,rss="]) else { return [:] }
        return parsePS(output)
    }

    static func parsePS(_ output: String) -> [Int32: PSRow] {
        var rows: [Int32: PSRow] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3,
                  let pid = Int32(fields[0]),
                  let cpu = parseCPUTime(fields[1]),
                  let rssKB = UInt64(fields[2]) else { continue }
            rows[pid] = PSRow(cpuNanos: cpu, rssBytes: rssKB * 1024)
        }
        return rows
    }

    /// Parses `ps` CPU time: "[[dd-]hh:]mm:ss.cc". macOS usually prints "mmm:ss.cc".
    static func parseCPUTime<S: StringProtocol>(_ text: S) -> UInt64? {
        var days = 0.0
        var rest = Substring(text)
        if let dash = rest.firstIndex(of: "-") {
            guard let d = Double(rest[..<dash]) else { return nil }
            days = d
            rest = rest[rest.index(after: dash)...]
        }
        let parts = rest.split(separator: ":")
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var seconds = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }
            seconds = seconds * 60 + value
        }
        seconds += days * 86_400
        return UInt64((seconds * 1e9).rounded())
    }
}
