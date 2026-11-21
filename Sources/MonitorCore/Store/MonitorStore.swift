import AppKit
import Foundation
import Observation

/// The single source of truth for the UI.
///
/// Create one, inject it with `.environment(store)`, and call `start()` once (for
/// example from the app's `init` or `.task`). Every property is observable and
/// refreshes each `sampleInterval`. All methods run on the main actor.
@MainActor
@Observable
public final class MonitorStore {
    // MARK: Live metrics

    public private(set) var systemInfo: SystemInfo
    public private(set) var cpu: CPUSnapshot = .empty
    public private(set) var memory: MemorySnapshot = .empty
    public private(set) var network: NetworkSnapshot = .empty
    public private(set) var disk: DiskSnapshot = .empty
    /// nil until the first read, or always nil on Macs without a battery.
    public private(set) var battery: BatterySnapshot?
    public private(set) var hasBattery = false
    public private(set) var volumes: [VolumeInfo] = []
    /// Every running process, unsorted. Use `sortedProcesses(by:)` or `processGroups`.
    public private(set) var processes: [ProcessSample] = []
    public private(set) var lastUpdated: Date?

    // MARK: History (for charts)

    /// Whole-system series, at most `historyLength` points each.
    public private(set) var history = MetricHistory()
    /// Per-process series keyed by pid (last `processHistoryLength` points).
    public private(set) var processHistory: [Int32: [ProcessHistoryPoint]] = [:]
    /// Series for watched processes, summed over every process with that name.
    public private(set) var watchedHistory: [String: [ProcessHistoryPoint]] = [:]

    public let historyLength = 300
    public let processHistoryLength = 120

    // MARK: Settings

    /// Seconds between samples (0.5...10). Change with `setSampleInterval(_:)`.
    public private(set) var sampleInterval: TimeInterval = 1
    public private(set) var isRunning = false

    /// Takes effect on the next tick and is remembered across launches.
    public func setSampleInterval(_ seconds: TimeInterval) {
        sampleInterval = min(max(seconds, 0.5), 10)
        saveSettings()
    }

    // MARK: Watched ("specific") processes

    /// Process names the user pinned. Matched against `ProcessSample.name`.
    public private(set) var watchedProcessNames: [String] = []

    // MARK: Websites & servers

    public private(set) var endpoints: [Endpoint] = []
    public private(set) var endpointStatuses: [UUID: EndpointStatus] = [:]

    // MARK: Cache cleaning

    public private(set) var cacheCleanState: CacheCleanState = .idle

    // MARK: Private

    private let sampler: SystemSampler?
    private var samplingTask: Task<Void, Never>?
    private var endpointTasks: [UUID: Task<Void, Never>] = [:]
    private let defaults: UserDefaults
    private let isPreview: Bool

    private enum Keys {
        static let endpoints = "monitoring.endpoints"
        static let watched = "monitoring.watchedProcesses"
        static let interval = "monitoring.sampleInterval"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isPreview = false
        self.sampler = SystemSampler()
        self.systemInfo = SystemSampler.systemInfo()
        loadSettings()
    }

    /// A store filled with fixed data that never samples. For SwiftUI previews.
    public init(preview snapshot: SystemSnapshot, systemInfo: SystemInfo, history: MetricHistory = MetricHistory(),
                watchedProcessNames: [String] = [], endpoints: [Endpoint] = [],
                endpointStatuses: [UUID: EndpointStatus] = [:]) {
        self.defaults = UserDefaults(suiteName: "monitoring.preview") ?? .standard
        self.isPreview = true
        self.sampler = nil
        self.systemInfo = systemInfo
        self.history = history
        self.watchedProcessNames = watchedProcessNames
        self.endpoints = endpoints
        self.endpointStatuses = endpointStatuses
        apply(snapshot, recordHistory: false)
    }

    // MARK: Lifecycle

    public func start() {
        guard let sampler, samplingTask == nil else { return }
        isRunning = true
        samplingTask = Task { [weak self] in
            await sampler.startStreams()
            while !Task.isCancelled {
                let began = ContinuousClock.now
                let snapshot = await sampler.sample()
                guard let self else { return }
                self.apply(snapshot, recordHistory: true)
                let interval = Duration.milliseconds(Int(self.sampleInterval * 1000))
                let remaining = interval - (ContinuousClock.now - began)
                try? await Task.sleep(for: max(remaining, .milliseconds(100)))
            }
        }
        for endpoint in endpoints where endpoint.isEnabled { scheduleChecks(for: endpoint) }
    }

    public func stop() {
        samplingTask?.cancel()
        samplingTask = nil
        endpointTasks.values.forEach { $0.cancel() }
        endpointTasks = [:]
        isRunning = false
        if let sampler { Task { await sampler.stopStreams() } }
    }

    // MARK: Process queries

    public enum ProcessSort: String, Sendable, CaseIterable {
        case cpu, memory, network, disk, name, pid
    }

    public func sortedProcesses(by sort: ProcessSort, matching search: String = "") -> [ProcessSample] {
        let filtered = search.isEmpty ? processes : processes.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.appName.localizedCaseInsensitiveContains(search)
                || String($0.pid) == search
        }
        return filtered.sorted { a, b in
            switch sort {
            case .cpu: a.cpuPercent > b.cpuPercent
            case .memory: a.memory > b.memory
            case .network: a.networkInRate + a.networkOutRate > b.networkInRate + b.networkOutRate
            case .disk: (a.diskReadRate ?? 0) + (a.diskWriteRate ?? 0) > (b.diskReadRate ?? 0) + (b.diskWriteRate ?? 0)
            case .name: a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .pid: a.pid < b.pid
            }
        }
    }

    /// Processes grouped by app (Chrome + all its helpers = one row), sorted by CPU.
    public var processGroups: [ProcessGroup] {
        Dictionary(grouping: processes) { $0.appBundlePath ?? "name:" + $0.name }
            .map { key, members in
                ProcessGroup(name: members[0].appName,
                             appBundlePath: key.hasPrefix("name:") ? nil : key,
                             processes: members.sorted { $0.cpuPercent > $1.cpuPercent })
            }
            .sorted { $0.cpuPercent > $1.cpuPercent }
    }

    public func process(pid: Int32) -> ProcessSample? {
        processes.first { $0.pid == pid }
    }

    /// Top N processes for a dashboard card.
    public func topProcesses(by sort: ProcessSort, limit: Int = 5) -> [ProcessSample] {
        Array(sortedProcesses(by: sort).prefix(limit))
    }

    // MARK: Process actions

    /// Quits a process (SIGTERM), or force-quits it (SIGKILL). For system
    /// processes this throws `.permissionDenied`; call again with
    /// `asAdministrator: true` to show the password prompt.
    public func terminate(pid: Int32, force: Bool = false, asAdministrator: Bool = false) async throws {
        try await ProcessActions.signal(pid: pid, force: force, asAdministrator: asAdministrator)
    }

    // MARK: Watched processes

    public func isWatched(_ name: String) -> Bool { watchedProcessNames.contains(name) }

    public func watch(_ name: String) {
        guard !watchedProcessNames.contains(name) else { return }
        watchedProcessNames.append(name)
        saveSettings()
    }

    public func unwatch(_ name: String) {
        watchedProcessNames.removeAll { $0 == name }
        watchedHistory[name] = nil
        saveSettings()
    }

    /// Live processes matching a watched name (it may be several, or none if it isn't running).
    public func processes(named name: String) -> [ProcessSample] {
        processes.filter { $0.name == name }
    }

    // MARK: Endpoints

    public func addEndpoint(_ endpoint: Endpoint) {
        endpoints.append(endpoint)
        endpointStatuses[endpoint.id] = EndpointStatus()
        saveSettings()
        if isRunning, endpoint.isEnabled { scheduleChecks(for: endpoint) }
    }

    public func updateEndpoint(_ endpoint: Endpoint) {
        guard let index = endpoints.firstIndex(where: { $0.id == endpoint.id }) else { return }
        let targetChanged = endpoints[index].kind != endpoint.kind
        endpoints[index] = endpoint
        if targetChanged { endpointStatuses[endpoint.id] = EndpointStatus() }
        saveSettings()
        endpointTasks[endpoint.id]?.cancel()
        endpointTasks[endpoint.id] = nil
        if isRunning, endpoint.isEnabled { scheduleChecks(for: endpoint) }
    }

    public func removeEndpoint(id: UUID) {
        endpointTasks[id]?.cancel()
        endpointTasks[id] = nil
        endpoints.removeAll { $0.id == id }
        endpointStatuses[id] = nil
        saveSettings()
    }

    /// Runs a check immediately, outside the regular schedule.
    public func checkNow(id: UUID) async {
        guard let endpoint = endpoints.first(where: { $0.id == id }) else { return }
        let result = await EndpointChecker.check(endpoint)
        endpointStatuses[id, default: EndpointStatus()].record(result)
    }

    private func scheduleChecks(for endpoint: Endpoint) {
        endpointTasks[endpoint.id]?.cancel()
        let id = endpoint.id
        endpointTasks[id] = Task { [weak self] in
            while !Task.isCancelled {
                let result = await EndpointChecker.check(endpoint)
                guard let self, !Task.isCancelled else { return }
                self.endpointStatuses[id, default: EndpointStatus()].record(result)
                try? await Task.sleep(for: .seconds(endpoint.interval))
            }
        }
    }

    // MARK: Cache cleaning

    /// Clears caches without closing any app. `.memory` and `.dns` show one
    /// admin password prompt. Progress and the result appear in `cacheCleanState`.
    public func cleanCaches(_ options: CacheCleanOptions = .all) async {
        guard cacheCleanState != .running, !isPreview else { return }
        cacheCleanState = .running
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        do {
            let report = try await CacheCleaner.run(options: options, runningBundleIDs: running)
            cacheCleanState = .finished(report)
            await sampler?.invalidateSlowMetrics()
        } catch AdminCommandError.cancelled {
            cacheCleanState = .idle
        } catch {
            cacheCleanState = .failed(error.localizedDescription)
        }
    }

    public func dismissCacheCleanResult() {
        if cacheCleanState != .running { cacheCleanState = .idle }
    }

    // MARK: Applying samples

    private func apply(_ snapshot: SystemSnapshot, recordHistory: Bool) {
        cpu = snapshot.cpu
        memory = snapshot.memory
        network = snapshot.network
        disk = snapshot.disk
        hasBattery = snapshot.hasBattery
        if let battery = snapshot.battery { self.battery = battery }
        if let volumes = snapshot.volumes { self.volumes = volumes }
        processes = snapshot.processes
        lastUpdated = snapshot.date
        guard recordHistory else { return }

        let date = snapshot.date
        // Mutate a copy and assign once so observers update once per tick.
        var h = history
        func append(_ keyPath: WritableKeyPath<MetricHistory, [MetricPoint]>, _ value: Double) {
            h[keyPath: keyPath].append(MetricPoint(date: date, value: value))
            let overflow = h[keyPath: keyPath].count - historyLength
            if overflow > 0 { h[keyPath: keyPath].removeFirst(overflow) }
        }
        append(\.cpu, snapshot.cpu.total)
        append(\.memoryUsed, Double(snapshot.memory.used))
        append(\.networkIn, snapshot.network.inRate)
        append(\.networkOut, snapshot.network.outRate)
        append(\.diskRead, snapshot.disk.readRate)
        append(\.diskWrite, snapshot.disk.writeRate)
        if let battery = snapshot.battery { append(\.batteryLevel, battery.level) }
        history = h

        // Per-process history; drop pids that exited.
        var perProcess = processHistory
        var alive = Set<Int32>()
        for process in snapshot.processes {
            alive.insert(process.pid)
            var series = perProcess[process.pid] ?? []
            series.append(ProcessHistoryPoint(date: date, cpuPercent: process.cpuPercent, memory: process.memory,
                                              networkInRate: process.networkInRate, networkOutRate: process.networkOutRate))
            if series.count > processHistoryLength { series.removeFirst(series.count - processHistoryLength) }
            perProcess[process.pid] = series
        }
        processHistory = perProcess.filter { alive.contains($0.key) }

        // Watched processes, summed by name (0 when not running).
        var watched = watchedHistory
        for name in watchedProcessNames {
            let matches = snapshot.processes.filter { $0.name == name }
            var series = watched[name] ?? []
            series.append(ProcessHistoryPoint(
                date: date,
                cpuPercent: matches.reduce(0) { $0 + $1.cpuPercent },
                memory: matches.reduce(0) { $0 + $1.memory },
                networkInRate: matches.reduce(0) { $0 + $1.networkInRate },
                networkOutRate: matches.reduce(0) { $0 + $1.networkOutRate }))
            if series.count > historyLength { series.removeFirst(series.count - historyLength) }
            watched[name] = series
        }
        watchedHistory = watched
    }

    // MARK: Persistence

    private func loadSettings() {
        if let data = defaults.data(forKey: Keys.endpoints),
           let saved = try? JSONDecoder().decode([Endpoint].self, from: data) {
            endpoints = saved
            for endpoint in saved { endpointStatuses[endpoint.id] = EndpointStatus() }
        }
        watchedProcessNames = defaults.stringArray(forKey: Keys.watched) ?? []
        let interval = defaults.double(forKey: Keys.interval)
        if interval > 0 { sampleInterval = min(max(interval, 0.5), 10) }
    }

    private func saveSettings() {
        guard !isPreview else { return }
        if let data = try? JSONEncoder().encode(endpoints) { defaults.set(data, forKey: Keys.endpoints) }
        defaults.set(watchedProcessNames, forKey: Keys.watched)
        defaults.set(sampleInterval, forKey: Keys.interval)
    }
}
