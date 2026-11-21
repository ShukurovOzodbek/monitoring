import Foundation

// All byte values are bytes, all rates are per second, all percentages are
// 0...100 unless stated otherwise. Every type has a public memberwise init so
// UI previews can build fixtures.

// MARK: - System

public struct SystemInfo: Sendable, Hashable {
    public var chipName: String          // "Apple M2 Pro"
    public var modelIdentifier: String   // "Mac14,9"
    public var osVersion: String         // "macOS 26.3.1 (25D2128)"
    public var physicalMemory: UInt64
    public var bootDate: Date

    public init(chipName: String, modelIdentifier: String, osVersion: String, physicalMemory: UInt64, bootDate: Date) {
        self.chipName = chipName
        self.modelIdentifier = modelIdentifier
        self.osVersion = osVersion
        self.physicalMemory = physicalMemory
        self.bootDate = bootDate
    }

    public var uptime: TimeInterval { Date().timeIntervalSince(bootDate) }
}

// MARK: - CPU

public struct CoreUsage: Sendable, Hashable, Identifiable {
    public var index: Int
    public var user: Double
    public var system: Double
    public var id: Int { index }
    public var total: Double { user + system }

    public init(index: Int, user: Double, system: Double) {
        self.index = index
        self.user = user
        self.system = system
    }
}

public struct CPUSnapshot: Sendable, Hashable {
    /// Whole-machine usage, 0...100 (100 = every core busy).
    public var user: Double
    public var system: Double
    public var idle: Double
    public var cores: [CoreUsage]
    public var loadAverage: [Double]      // 1, 5, 15 minutes
    public var performanceCoreCount: Int
    public var efficiencyCoreCount: Int
    public var processCount: Int
    public var threadCount: Int           // threads of processes we can inspect

    public var total: Double { user + system }

    public init(user: Double, system: Double, idle: Double, cores: [CoreUsage], loadAverage: [Double],
                performanceCoreCount: Int, efficiencyCoreCount: Int, processCount: Int, threadCount: Int) {
        self.user = user
        self.system = system
        self.idle = idle
        self.cores = cores
        self.loadAverage = loadAverage
        self.performanceCoreCount = performanceCoreCount
        self.efficiencyCoreCount = efficiencyCoreCount
        self.processCount = processCount
        self.threadCount = threadCount
    }

    public static let empty = CPUSnapshot(user: 0, system: 0, idle: 100, cores: [], loadAverage: [0, 0, 0],
                                          performanceCoreCount: 0, efficiencyCoreCount: 0, processCount: 0, threadCount: 0)
}

// MARK: - Memory

public enum MemoryPressure: String, Sendable, Hashable {
    case normal, warning, critical
}

public struct MemorySnapshot: Sendable, Hashable {
    public var total: UInt64
    /// app + wired + compressed (matches Activity Monitor "Memory Used").
    public var used: UInt64
    public var app: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    /// File cache; macOS frees it on demand. This is what "Clean Cache" purges.
    public var cachedFiles: UInt64
    public var free: UInt64
    public var swapUsed: UInt64
    public var swapTotal: UInt64
    public var pressure: MemoryPressure

    public var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }

    public init(total: UInt64, used: UInt64, app: UInt64, wired: UInt64, compressed: UInt64, cachedFiles: UInt64,
                free: UInt64, swapUsed: UInt64, swapTotal: UInt64, pressure: MemoryPressure) {
        self.total = total
        self.used = used
        self.app = app
        self.wired = wired
        self.compressed = compressed
        self.cachedFiles = cachedFiles
        self.free = free
        self.swapUsed = swapUsed
        self.swapTotal = swapTotal
        self.pressure = pressure
    }

    public static let empty = MemorySnapshot(total: 0, used: 0, app: 0, wired: 0, compressed: 0, cachedFiles: 0,
                                             free: 0, swapUsed: 0, swapTotal: 0, pressure: .normal)
}

// MARK: - Network

public struct NetworkInterfaceStats: Sendable, Hashable, Identifiable {
    public var name: String               // "en0"
    public var isUp: Bool
    public var addresses: [String]        // IPv4 / IPv6
    public var bytesIn: UInt64            // since boot
    public var bytesOut: UInt64
    public var inRate: Double
    public var outRate: Double
    public var id: String { name }

    public init(name: String, isUp: Bool, addresses: [String], bytesIn: UInt64, bytesOut: UInt64, inRate: Double, outRate: Double) {
        self.name = name
        self.isUp = isUp
        self.addresses = addresses
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.inRate = inRate
        self.outRate = outRate
    }
}

public struct NetworkSnapshot: Sendable, Hashable {
    /// Physical interfaces only (VPN tunnels / loopback excluded to avoid double counting).
    public var inRate: Double
    public var outRate: Double
    public var totalIn: UInt64
    public var totalOut: UInt64
    public var interfaces: [NetworkInterfaceStats]

    public init(inRate: Double, outRate: Double, totalIn: UInt64, totalOut: UInt64, interfaces: [NetworkInterfaceStats]) {
        self.inRate = inRate
        self.outRate = outRate
        self.totalIn = totalIn
        self.totalOut = totalOut
        self.interfaces = interfaces
    }

    public static let empty = NetworkSnapshot(inRate: 0, outRate: 0, totalIn: 0, totalOut: 0, interfaces: [])
}

// MARK: - Disk activity

public struct DiskSnapshot: Sendable, Hashable {
    public var readRate: Double
    public var writeRate: Double
    public var readOpsRate: Double
    public var writeOpsRate: Double
    public var totalRead: UInt64          // since boot
    public var totalWritten: UInt64

    public init(readRate: Double, writeRate: Double, readOpsRate: Double, writeOpsRate: Double, totalRead: UInt64, totalWritten: UInt64) {
        self.readRate = readRate
        self.writeRate = writeRate
        self.readOpsRate = readOpsRate
        self.writeOpsRate = writeOpsRate
        self.totalRead = totalRead
        self.totalWritten = totalWritten
    }

    public static let empty = DiskSnapshot(readRate: 0, writeRate: 0, readOpsRate: 0, writeOpsRate: 0, totalRead: 0, totalWritten: 0)
}

// MARK: - Storage capacity

public struct VolumeInfo: Sendable, Hashable, Identifiable {
    public var name: String
    public var mountPath: String
    public var fileSystem: String
    public var total: UInt64
    public var available: UInt64
    /// Available including purgeable space macOS can reclaim (what Finder shows).
    public var availableIncludingPurgeable: UInt64
    public var isInternal: Bool
    public var isRemovable: Bool
    public var isRoot: Bool
    public var id: String { mountPath }

    public var used: UInt64 { total > availableIncludingPurgeable ? total - availableIncludingPurgeable : 0 }
    public var purgeable: UInt64 { availableIncludingPurgeable > available ? availableIncludingPurgeable - available : 0 }
    public var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }

    public init(name: String, mountPath: String, fileSystem: String, total: UInt64, available: UInt64,
                availableIncludingPurgeable: UInt64, isInternal: Bool, isRemovable: Bool, isRoot: Bool) {
        self.name = name
        self.mountPath = mountPath
        self.fileSystem = fileSystem
        self.total = total
        self.available = available
        self.availableIncludingPurgeable = availableIncludingPurgeable
        self.isInternal = isInternal
        self.isRemovable = isRemovable
        self.isRoot = isRoot
    }
}

// MARK: - Battery

public enum PowerSource: String, Sendable, Hashable {
    case battery, ac
}

public struct BatterySnapshot: Sendable, Hashable {
    public var level: Double              // 0...100 charge
    public var isCharging: Bool
    public var isFullyCharged: Bool
    public var powerSource: PowerSource
    /// Minutes; nil while macOS is still estimating or not applicable.
    public var minutesToEmpty: Int?
    public var minutesToFull: Int?
    public var cycleCount: Int?
    public var designCapacity: Int?       // mAh
    public var maxCapacity: Int?          // mAh, current full-charge capacity
    public var currentCapacity: Int?      // mAh
    public var health: Double?            // maxCapacity / designCapacity * 100
    public var temperatureCelsius: Double?
    public var voltage: Double?           // volts
    public var amperage: Double?          // amps, negative = discharging
    public var adapterWatts: Int?
    public var isLowPowerMode: Bool

    /// Watts flowing in (+) or out (-) of the battery.
    public var power: Double? {
        guard let voltage, let amperage else { return nil }
        return voltage * amperage
    }

    public init(level: Double, isCharging: Bool, isFullyCharged: Bool, powerSource: PowerSource, minutesToEmpty: Int?,
                minutesToFull: Int?, cycleCount: Int?, designCapacity: Int?, maxCapacity: Int?, currentCapacity: Int?,
                health: Double?, temperatureCelsius: Double?, voltage: Double?, amperage: Double?, adapterWatts: Int?,
                isLowPowerMode: Bool) {
        self.level = level
        self.isCharging = isCharging
        self.isFullyCharged = isFullyCharged
        self.powerSource = powerSource
        self.minutesToEmpty = minutesToEmpty
        self.minutesToFull = minutesToFull
        self.cycleCount = cycleCount
        self.designCapacity = designCapacity
        self.maxCapacity = maxCapacity
        self.currentCapacity = currentCapacity
        self.health = health
        self.temperatureCelsius = temperatureCelsius
        self.voltage = voltage
        self.amperage = amperage
        self.adapterWatts = adapterWatts
        self.isLowPowerMode = isLowPowerMode
    }
}

// MARK: - Processes

public enum ProcessDataQuality: String, Sendable, Hashable {
    /// Read directly: CPU, footprint memory, threads, disk I/O.
    case full
    /// Owned by another user (root/system). CPU and memory (RSS) via `ps`;
    /// threads and disk I/O unavailable.
    case limited
}

public struct ProcessSample: Sendable, Hashable, Identifiable {
    public var pid: Int32
    public var parentPID: Int32
    public var name: String               // "Google Chrome Helper (Renderer)"
    public var executablePath: String?
    /// Outermost .app bundle, e.g. "/Applications/Google Chrome.app". Use for icons and grouping.
    public var appBundlePath: String?
    public var user: String
    public var startDate: Date?
    /// 100 = one full core, so values above 100 are possible.
    public var cpuPercent: Double
    public var cpuTime: TimeInterval      // total seconds of CPU used
    public var memory: UInt64             // footprint (full) or RSS (limited)
    public var threads: Int?
    public var diskReadRate: Double?
    public var diskWriteRate: Double?
    public var networkInRate: Double
    public var networkOutRate: Double
    public var quality: ProcessDataQuality
    public var id: Int32 { pid }

    /// Display name of the owning app ("Google Chrome") or the process name.
    public var appName: String {
        guard let appBundlePath else { return name }
        return ((appBundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    public init(pid: Int32, parentPID: Int32, name: String, executablePath: String?, appBundlePath: String?, user: String,
                startDate: Date?, cpuPercent: Double, cpuTime: TimeInterval, memory: UInt64, threads: Int?,
                diskReadRate: Double?, diskWriteRate: Double?, networkInRate: Double, networkOutRate: Double,
                quality: ProcessDataQuality) {
        self.pid = pid
        self.parentPID = parentPID
        self.name = name
        self.executablePath = executablePath
        self.appBundlePath = appBundlePath
        self.user = user
        self.startDate = startDate
        self.cpuPercent = cpuPercent
        self.cpuTime = cpuTime
        self.memory = memory
        self.threads = threads
        self.diskReadRate = diskReadRate
        self.diskWriteRate = diskWriteRate
        self.networkInRate = networkInRate
        self.networkOutRate = networkOutRate
        self.quality = quality
    }
}

/// Processes summed per app (an app plus all its helpers).
public struct ProcessGroup: Sendable, Hashable, Identifiable {
    public var name: String
    public var appBundlePath: String?
    public var processes: [ProcessSample]
    public var id: String { appBundlePath ?? name }

    public var cpuPercent: Double { processes.reduce(0) { $0 + $1.cpuPercent } }
    public var memory: UInt64 { processes.reduce(0) { $0 + $1.memory } }
    public var networkInRate: Double { processes.reduce(0) { $0 + $1.networkInRate } }
    public var networkOutRate: Double { processes.reduce(0) { $0 + $1.networkOutRate } }
    public var diskReadRate: Double { processes.reduce(0) { $0 + ($1.diskReadRate ?? 0) } }
    public var diskWriteRate: Double { processes.reduce(0) { $0 + ($1.diskWriteRate ?? 0) } }

    public init(name: String, appBundlePath: String?, processes: [ProcessSample]) {
        self.name = name
        self.appBundlePath = appBundlePath
        self.processes = processes
    }
}

// MARK: - History

public struct MetricPoint: Sendable, Hashable, Identifiable {
    public var date: Date
    public var value: Double
    public var id: Date { date }

    public init(date: Date, value: Double) {
        self.date = date
        self.value = value
    }
}

public struct ProcessHistoryPoint: Sendable, Hashable, Identifiable {
    public var date: Date
    public var cpuPercent: Double
    public var memory: UInt64
    public var networkInRate: Double
    public var networkOutRate: Double
    public var id: Date { date }

    public init(date: Date, cpuPercent: Double, memory: UInt64, networkInRate: Double, networkOutRate: Double) {
        self.date = date
        self.cpuPercent = cpuPercent
        self.memory = memory
        self.networkInRate = networkInRate
        self.networkOutRate = networkOutRate
    }
}

/// Rolling time series for charts. Oldest first.
public struct MetricHistory: Sendable, Hashable {
    public var cpu: [MetricPoint] = []            // % total
    public var memoryUsed: [MetricPoint] = []     // bytes
    public var networkIn: [MetricPoint] = []      // bytes/s
    public var networkOut: [MetricPoint] = []
    public var diskRead: [MetricPoint] = []       // bytes/s
    public var diskWrite: [MetricPoint] = []
    public var batteryLevel: [MetricPoint] = []   // %

    public init(cpu: [MetricPoint] = [], memoryUsed: [MetricPoint] = [], networkIn: [MetricPoint] = [],
                networkOut: [MetricPoint] = [], diskRead: [MetricPoint] = [], diskWrite: [MetricPoint] = [],
                batteryLevel: [MetricPoint] = []) {
        self.cpu = cpu
        self.memoryUsed = memoryUsed
        self.networkIn = networkIn
        self.networkOut = networkOut
        self.diskRead = diskRead
        self.diskWrite = diskWrite
        self.batteryLevel = batteryLevel
    }
}

// MARK: - Sample bundle

/// Everything gathered in one sampling tick.
public struct SystemSnapshot: Sendable {
    public var date: Date
    public var cpu: CPUSnapshot
    public var memory: MemorySnapshot
    public var network: NetworkSnapshot
    public var disk: DiskSnapshot
    /// nil on Macs without a battery, or when not re-read this tick.
    public var battery: BatterySnapshot?
    public var hasBattery: Bool
    /// nil when not re-read this tick (volumes refresh every 30 s).
    public var volumes: [VolumeInfo]?
    public var processes: [ProcessSample]

    public init(date: Date, cpu: CPUSnapshot, memory: MemorySnapshot, network: NetworkSnapshot, disk: DiskSnapshot,
                battery: BatterySnapshot?, hasBattery: Bool, volumes: [VolumeInfo]?, processes: [ProcessSample]) {
        self.date = date
        self.cpu = cpu
        self.memory = memory
        self.network = network
        self.disk = disk
        self.battery = battery
        self.hasBattery = hasBattery
        self.volumes = volumes
        self.processes = processes
    }
}
