import Foundation
import MonitorCore

#if DEBUG && !MONITORING_SKIP_PREVIEWS
@MainActor
public enum PreviewData {
    private static let date = Date(timeIntervalSince1970: 1_791_106_200)
    private static let gb: UInt64 = 1_000_000_000
    private static let chrome = "/Applications/Google Chrome.app"

    public static let cleanup: CleanupStore = {
        let modified = date
        func item(_ kind: CleanupCategoryKind, _ path: String, _ size: UInt64,
                  files: Int = 1, directory: Bool = false, admin: Bool = false, recommended: Bool = true,
                  skip: CleanupSkipReason? = nil, removal: CleanupItem.Removal = .removeItem,
                  detail: String? = nil) -> CleanupItem {
            let url = URL(fileURLWithPath: path, isDirectory: directory)
            return CleanupItem(url: url, name: url.lastPathComponent, category: kind, size: size,
                               fileCount: files, modified: modified, isDirectory: directory, requiresAdmin: admin,
                               removal: removal, skipReason: skip, recommended: recommended, detail: detail)
        }

        let home = "/Users/preview"
        let categories: [CleanupCategoryKind: CleanupCategory] = [
            .temporaryFiles: .init(kind: .temporaryFiles, state: .ready, items: [
                item(.temporaryFiles, "/private/tmp/export-staging", 920_000_000, files: 68, directory: true),
                item(.temporaryFiles, "/private/tmp/editor-session", 58_000_000, skip: .inUse),
                item(.temporaryFiles, "/private/tmp/postgresql", 20_000_000, files: 4, directory: true, skip: .containsSockets),
                item(.temporaryFiles, "/private/tmp/com.apple.session.lock", 4096, skip: .protected)
            ], location: URL(fileURLWithPath: "/private/tmp")),
            .userCaches: .init(kind: .userCaches, state: .ready, items: [
                item(.userCaches, home + "/Library/Caches/com.spotify.client", 1_800_000_000, files: 819,
                     directory: true, removal: .emptyFolder, detail: "Spotify media cache"),
                item(.userCaches, home + "/Library/Caches/com.google.Chrome", 740_000_000, files: 612,
                     directory: true, skip: .runningApp, removal: .emptyFolder)
            ], location: URL(fileURLWithPath: home + "/Library/Caches")),
            .developer: .init(kind: .developer, state: .ready, items: [
                item(.developer, home + "/.npm/_cacache", 6_700_000_000, files: 4200,
                     directory: true, removal: .emptyFolder, detail: "npm download cache"),
                item(.developer, home + "/.gradle/caches", 4_400_000_000, files: 2300,
                     directory: true, removal: .emptyFolder, detail: "Gradle dependency cache"),
                item(.developer, home + "/Library/Developer/Xcode/DerivedData", 2_800_000_000, files: 1800,
                     directory: true, removal: .emptyFolder, detail: "Xcode build products")
            ], location: URL(fileURLWithPath: home + "/Library/Developer")),
            .trash: .init(kind: .trash, state: .needsFullDiskAccess, location: URL(fileURLWithPath: home + "/.Trash")),
            .downloads: .init(kind: .downloads, state: .ready, items: [
                item(.downloads, home + "/Downloads/DesignTool.dmg", 840_000_000, recommended: false, detail: "Installer"),
                item(.downloads, home + "/Downloads/project-archive.zip", 370_000_000, recommended: false)
            ], location: URL(fileURLWithPath: home + "/Downloads")),
            .sleepImage: .init(kind: .sleepImage, state: .ready, items: [
                item(.sleepImage, "/private/var/vm/sleepimage", 1_100_000_000, admin: true, recommended: false)
            ], location: URL(fileURLWithPath: "/private/var/vm")),
            .swap: .init(kind: .swap, state: .ready, items: [
                item(.swap, "/private/var/vm/swapfile0", 2 * gb, recommended: false, removal: .none)
            ], location: URL(fileURLWithPath: "/private/var/vm"), note: "2 GB of swap is currently in use.")
        ]
        return CleanupStore(preview: CleanupCategoryKind.allCases.map { categories[$0] ?? .init(kind: $0, state: .ready) },
                            freeSpace: 48 * gb)
    }()

    static let processes: [ProcessSample] = {
        let apps: [(String, String)] = [
            ("Google Chrome", chrome),
            ("Xcode", "/Applications/Xcode.app"),
            ("Finder", "/System/Library/CoreServices/Finder.app"),
            ("Safari", "/Applications/Safari.app"),
            ("Music", "/System/Applications/Music.app"),
            ("Terminal", "/System/Applications/Utilities/Terminal.app"),
            ("Mail", "/System/Applications/Mail.app"),
            ("Notes", "/System/Applications/Notes.app"),
            ("Preview", "/System/Applications/Preview.app"),
            ("Calendar", "/System/Applications/Calendar.app")
        ]
        let daemons = ["WindowServer", "launchd", "kernel_task", "logd", "powerd", "mDNSResponder",
                       "coreaudiod", "bluetoothd", "runningboardd", "launchservicesd", "notifyd", "fseventsd",
                       "distnoted", "cfprefsd", "usernoted", "sharingd", "mds", "mdworker_shared"]
        return (0..<40).map { index in
            let app = index < apps.count ? apps[index] : nil
            let helper = (10..<22).contains(index)
            let limited = (22..<31).contains(index)
            let helpers = ["Google Chrome Helper (Renderer)", "Google Chrome Helper (GPU)", "Google Chrome Helper"]
            let name = app?.0 ?? (helper ? helpers[(index - 10) % helpers.count] : daemons[index - 22])
            let bundle = app?.1 ?? (helper ? chrome : nil)
            let path = bundle.map { "\($0)/Contents/MacOS/\(name)" }
                ?? "/usr/libexec/\(name)"
            return ProcessSample(pid: Int32(410 + index), parentPID: helper ? 410 : 1, name: name,
                                 executablePath: path, appBundlePath: bundle, user: limited ? "root" : "alex",
                                 startDate: date.addingTimeInterval(-Double(700 + 87 * index)),
                                 cpuPercent: index == 0 ? 29.6 : Double((37 * index) % 41) / 3,
                                 cpuTime: Double(58 * index),
                                 memory: UInt64(index == 0 ? 924 : 25 + (index * 47) % 475) * 1_000_000,
                                 threads: limited ? nil : 3 + index % 27,
                                 diskReadRate: limited ? nil : Double((index * 23) % 64) * 3000,
                                 diskWriteRate: limited ? nil : Double((index * 11) % 49) * 1800,
                                 networkInRate: Double((index * 17) % 43) * 5200,
                                 networkOutRate: Double((index * 7) % 29) * 4300,
                                 quality: limited ? .limited : .full)
        }
    }()

    private static func points(_ base: Double, variation: Double, phase: Double = 0) -> [MetricPoint] {
        (0..<120).map { index in
            let time = Double(index)
            let wave = sin(time / 6 + phase) * 0.44 + cos(time / 2.4 + phase) * 0.22
            let spike = pow(max(0, sin(time / 12 + phase)), 8) * 0.65
            return MetricPoint(date: date.addingTimeInterval(time - 119),
                               value: max(0, base + variation * (wave + spike)))
        }
    }

    static let processHistory: [ProcessHistoryPoint] = {
        let cpu = points(22, variation: 17)
        let memory = points(890_000_000, variation: 41_000_000, phase: 2)
        let input = points(230_000, variation: 260_000, phase: 3)
        let output = points(76_000, variation: 80_000, phase: 5)
        return cpu.indices.map {
            ProcessHistoryPoint(date: cpu[$0].date, cpuPercent: cpu[$0].value,
                                memory: UInt64(memory[$0].value), networkInRate: input[$0].value,
                                networkOutRate: output[$0].value)
        }
    }()

    public static let store: MonitorStore = {
        let info = SystemInfo(chipName: "Apple M3 Pro", modelIdentifier: "Mac15,7",
                              osVersion: "macOS 15.4", physicalMemory: 18 * gb,
                              bootDate: date.addingTimeInterval(-259_200))
        let cpu = CPUSnapshot(user: 18.6, system: 6.2, idle: 75.2,
                              cores: (0..<12).map { .init(index: $0, user: Double(4 + ($0 * 17) % 43), system: Double(3 + $0 % 9)) },
                              loadAverage: [2.34, 2.85, 2.62], performanceCoreCount: 6, efficiencyCoreCount: 6,
                              processCount: processes.count, threadCount: 536)
        let memory = MemorySnapshot(total: 18 * gb, used: 12 * gb, app: 8 * gb, wired: 2 * gb, compressed: 2 * gb,
                                    cachedFiles: 4 * gb, free: 2 * gb, swapUsed: 524_000_000, swapTotal: 2 * gb,
                                    pressure: .normal)
        let network = NetworkSnapshot(inRate: 1_420_000, outRate: 287_000, totalIn: 32 * gb, totalOut: 6 * gb,
                                      interfaces: [
                                        .init(name: "en0", isUp: true, addresses: ["192.168.1.42", "fe80::1c2:4a3f:feee:912a"],
                                              bytesIn: 32 * gb, bytesOut: 6 * gb, inRate: 1_420_000, outRate: 287_000),
                                        .init(name: "en5", isUp: false, addresses: [], bytesIn: 0, bytesOut: 0, inRate: 0, outRate: 0)
                                      ])
        let disk = DiskSnapshot(readRate: 4_900_000, writeRate: 2_100_000, readOpsRate: 159, writeOpsRate: 78,
                                totalRead: 96 * gb, totalWritten: 37 * gb)
        let battery = BatterySnapshot(level: 76.4, isCharging: false, isFullyCharged: false, powerSource: .battery,
                                      minutesToEmpty: 298, minutesToFull: nil, cycleCount: 211, designCapacity: 6075,
                                      maxCapacity: 5670, currentCapacity: 4332, health: 93.3, temperatureCelsius: 32.4,
                                      voltage: 11.9, amperage: -0.81, adapterWatts: nil, isLowPowerMode: false)
        let volumes: [VolumeInfo] = [
            .init(name: "Macintosh HD", mountPath: "/", fileSystem: "apfs", total: 494 * gb, available: 147 * gb,
                  availableIncludingPurgeable: 173 * gb, isInternal: true, isRemovable: false, isRoot: true),
            .init(name: "Studio SSD", mountPath: "/Volumes/Studio SSD", fileSystem: "apfs", total: 1000 * gb,
                  available: 418 * gb, availableIncludingPurgeable: 439 * gb, isInternal: false, isRemovable: true, isRoot: false)
        ]
        let snapshot = SystemSnapshot(date: date, cpu: cpu, memory: memory, network: network, disk: disk,
                                      battery: battery, hasBattery: true, volumes: volumes, processes: processes)
        let userHistory = points(18.6, variation: 14)
        let systemHistory = points(6.2, variation: 4, phase: 1)
        let totalHistory = zip(userHistory, systemHistory).map { user, system in
            MetricPoint(date: user.date, value: user.value + system.value)
        }
        let history = MetricHistory(cpu: totalHistory, cpuUser: userHistory, cpuSystem: systemHistory,
                                    memoryUsed: points(11.8e9, variation: 0.45e9),
                                    networkIn: points(1.3e6, variation: 1.5e6), networkOut: points(280e3, variation: 420e3, phase: 3),
                                    diskRead: points(4.8e6, variation: 5.3e6, phase: 1), diskWrite: points(2.1e6, variation: 2.8e6, phase: 4),
                                    batteryLevel: (0..<120).map {
                                        MetricPoint(date: date.addingTimeInterval(Double($0 - 119) * 60),
                                                    value: 76.4 + Double(119 - $0) * 0.16)
                                    })
        let endpoints = [
            Endpoint.parse("https://apple.com", name: "Apple"),
            Endpoint.parse("nas.local:445", name: "Studio NAS"),
            Endpoint.parse("build.local:8080", name: "Build Server")
        ].compactMap { $0 }
        let statuses = Dictionary(uniqueKeysWithValues: endpoints.enumerated().map { index, endpoint in
            let checks = (0..<30).map { tick in
                let up = index < 2 || tick < 26
                return EndpointCheck(date: date.addingTimeInterval(Double(tick - 29) * 30), isUp: up,
                                     latency: up ? Double(12 + (tick * 13 + index * 7) % 35) / 1000 : nil,
                                     statusCode: index == 0 ? 200 : nil, error: up ? nil : "Connection timed out")
            }
            return (endpoint.id, EndpointStatus(state: index < 2 ? .up : .down, lastCheck: checks.last, history: checks))
        })
        return MonitorStore(preview: snapshot, systemInfo: info, history: history,
                            processHistory: [processes[0].pid: processHistory],
                            watchedHistory: ["Google Chrome": processHistory],
                            watchedProcessNames: ["Google Chrome", "Final Cut Pro"],
                            endpoints: endpoints, endpointStatuses: statuses)
    }()
}
#endif
