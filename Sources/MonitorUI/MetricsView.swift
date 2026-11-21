import SwiftUI
import MonitorCore

struct MetricsView: View {
    @Environment(MonitorStore.self) private var store
    let tab: MonitorTab
    @Binding var cleanCachePresented: Bool
    var open: (MonitorTab) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch tab {
                case .overview: overview
                case .cpu: cpu
                case .memory: memory
                case .network: network
                case .disk: disk
                case .battery: battery
                case .capacity: capacity
                default: EmptyView()
                }
            }
            .padding(24)
            .frame(maxWidth: 1240)
            .frame(maxWidth: .infinity)
        }
        .background(.background.secondary)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text(store.systemInfo.chipName).font(.largeTitle.weight(.semibold))
                Text("\(store.systemInfo.modelIdentifier) · \(store.systemInfo.osVersion)")
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16, alignment: .top)], spacing: 16) {
                overviewCard(.cpu, series: [.init(name: "Total", points: store.history.cpu, color: .cyan)], sort: .cpu)
                overviewCard(.memory, series: memorySeries, sort: .memory)
                overviewCard(.network, series: networkSeries, sort: .network)
                overviewCard(.disk, series: diskSeries, sort: .disk)
                if store.hasBattery { overviewCard(.battery, series: batterySeries) }
                overviewCard(.capacity, title: "Storage")
                overviewCard(.endpoints, value: "\(tab.endpointCount(.up, store)) up · \(tab.endpointCount(.down, store)) down")
            }
        }
    }

    private func overviewCard(_ destination: MonitorTab, title: String? = nil, value: String? = nil,
                              series: [MetricChart.Series] = [], sort: MonitorStore.ProcessSort? = nil) -> some View {
        Panel(title: title ?? destination.rawValue, symbol: destination.symbol, tint: destination.tint) {
            HStack {
                headline(value ?? destination.value(store))
                Spacer()
                Button { open(destination) } label: { Image(systemName: "arrow.up.right") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Open \(destination.rawValue)")
            }
            if !series.isEmpty { MetricChart(series: series, compact: true) }
            if let sort { TopProcesses(sort: sort, limit: 3) }
            if destination == .capacity, let root = store.volumes.first(where: \.isRoot) {
                Breakdown(parts: volumeParts(root))
            }
            if destination == .endpoints {
                Text("\(store.endpoints.filter(\.isEnabled).count) enabled")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var cpuSeries: [MetricChart.Series] {
        [.init(name: "User", points: store.history.cpuUser, color: .cyan),
         .init(name: "System", points: store.history.cpuSystem, color: .blue)]
    }

    private var memorySeries: [MetricChart.Series] {
        [.init(name: "Used", points: store.history.memoryUsed, color: .purple)]
    }

    private var networkSeries: [MetricChart.Series] {
        [.init(name: "In", points: store.history.networkIn, color: .blue),
         .init(name: "Out", points: store.history.networkOut, color: .teal)]
    }

    private var diskSeries: [MetricChart.Series] {
        [.init(name: "Read", points: store.history.diskRead, color: .orange),
         .init(name: "Write", points: store.history.diskWrite, color: .pink)]
    }

    private var batterySeries: [MetricChart.Series] {
        [.init(name: "Charge", points: store.history.batteryLevel, color: .green)]
    }

    private var cpu: some View {
        let sample = store.cpu
        return Group {
            Panel(title: store.systemInfo.chipName, symbol: "cpu", tint: .cyan) {
                headline(Format.percent(sample.total))
                MetricChart(series: cpuSeries, stacked: true, range: 0...100, format: Format.percent)
                GeometryReader { geometry in
                    let width = geometry.size.width
                    HStack(spacing: 0) {
                        Color.cyan.frame(width: width * min(max(sample.user / 100, 0), 1))
                        Color.blue.frame(width: width * min(max(sample.system / 100, 0), 1))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary)
                    .clipShape(.capsule)
                }
                .frame(height: 10)
                .accessibilityHidden(true)
                HStack {
                    Label("User \(Format.percent(sample.user))", systemImage: "circle.fill").foregroundStyle(.cyan)
                    Label("System \(Format.percent(sample.system))", systemImage: "circle.fill").foregroundStyle(.blue)
                    Spacer()
                    Text("Idle \(Format.percent(sample.idle))").foregroundStyle(.secondary)
                }
                .font(.callout.monospacedDigit())
                Divider()
                LabeledContent("Load average (1, 5, 15 min)", value: sample.loadAverage.map(Format.decimal).joined(separator: " / "))
                LabeledContent("Processes", value: sample.processCount.formatted())
                LabeledContent("Reported threads", value: sample.threadCount.formatted())
            }
            Panel(title: "Core activity", symbol: "square.grid.3x3.fill", tint: .cyan) {
                if sample.performanceCoreCount + sample.efficiencyCoreCount > 0 {
                    Text("\(sample.performanceCoreCount) performance · \(sample.efficiencyCoreCount) efficiency")
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 18)], spacing: 16) {
                    ForEach(sample.cores) { core in
                        ProgressView(value: min(max(core.total, 0), 100), total: 100) {
                            HStack {
                                Text("Core \(core.index + 1)")
                                Spacer()
                                Text(Format.percent(core.total)).monospacedDigit()
                            }
                            .font(.caption)
                        }
                        .tint(.cyan)
                    }
                }
            }
            processPanel(.cpu)
        }
    }

    private var memory: some View {
        let sample = store.memory
        let pressureColor: Color = switch sample.pressure {
        case .normal: .green
        case .warning: .yellow
        case .critical: .red
        }
        return Group {
            Panel(title: "Physical memory", symbol: "memorychip", tint: .purple) {
                HStack {
                    headline(Format.bytes(sample.used))
                    Text("of \(Format.bytes(sample.total))").foregroundStyle(.secondary)
                    Spacer()
                    Button("Clean Cache", systemImage: "sparkles") { cleanCachePresented = true }
                        .buttonStyle(.borderedProminent)
                }
                Gauge(value: min(max(sample.usedFraction, 0), 1)) {
                    Text("Memory used")
                } currentValueLabel: {
                    Text(Format.percent(sample.usedFraction * 100))
                }
                .tint(.purple)
                Breakdown(parts: [
                    .init(name: "App", bytes: sample.app, color: .purple),
                    .init(name: "Wired", bytes: sample.wired, color: .indigo),
                    .init(name: "Compressed", bytes: sample.compressed, color: .pink),
                    .init(name: "Cached files", bytes: sample.cachedFiles, color: .teal),
                    .init(name: "Free", bytes: sample.free, color: .gray.opacity(0.25))
                ])
                Divider()
                LabeledContent("Memory pressure") {
                    Label(sample.pressure.rawValue.capitalized, systemImage: "circle.fill").foregroundStyle(pressureColor)
                }
                LabeledContent("Swap used", value: "\(Format.bytes(sample.swapUsed)) of \(Format.bytes(sample.swapTotal))")
            }
            Panel(title: "Memory history", symbol: "waveform.path", tint: .purple) {
                MetricChart(series: memorySeries, format: { Format.bytes($0) })
            }
            processPanel(.memory)
        }
    }

    private var network: some View {
        let sample = store.network
        return Group {
            Panel(title: "Network traffic", symbol: "arrow.up.arrow.down", tint: .blue) {
                HStack(spacing: 28) {
                    rateStat("Download", sample.inRate, color: .blue)
                    rateStat("Upload", sample.outRate, color: .teal)
                }
                MetricChart(series: networkSeries, format: Format.rate)
                LabeledContent("Received since boot", value: Format.bytes(sample.totalIn))
                LabeledContent("Sent since boot", value: Format.bytes(sample.totalOut))
            }
            Panel(title: "Interfaces", symbol: "network", tint: .blue) {
                if sample.interfaces.isEmpty { Text("No interfaces available").foregroundStyle(.secondary) }
                ForEach(sample.interfaces) { interface in
                    LabeledContent {
                        Text(interface.addresses.isEmpty ? "—" : interface.addresses.joined(separator: ", "))
                            .textSelection(.enabled)
                    } label: {
                        Label(interface.name, systemImage: interface.isUp ? "circle.fill" : "circle")
                            .foregroundStyle(interface.isUp ? Color.green : Color.secondary)
                    }
                }
            }
            processPanel(.network)
        }
    }

    private var disk: some View {
        let sample = store.disk
        return Group {
            Panel(title: "Disk activity", symbol: "internaldrive", tint: .orange) {
                HStack(spacing: 28) {
                    rateStat("Read", sample.readRate, color: .orange)
                    rateStat("Write", sample.writeRate, color: .pink)
                }
                MetricChart(series: diskSeries, format: Format.rate)
                LabeledContent("Read IOPS", value: Format.decimal(sample.readOpsRate))
                LabeledContent("Write IOPS", value: Format.decimal(sample.writeOpsRate))
                LabeledContent("Read since boot", value: Format.bytes(sample.totalRead))
                LabeledContent("Written since boot", value: Format.bytes(sample.totalWritten))
            }
            processPanel(.disk)
        }
    }

    @ViewBuilder private var battery: some View {
        if let sample = store.battery {
            Panel(title: "Battery charge", symbol: "battery.75percent", tint: .green) {
                HStack(spacing: 24) {
                    ZStack {
                        Circle().stroke(.green.opacity(0.17), lineWidth: 9)
                        Circle().trim(from: 0, to: min(max(sample.level / 100, 0), 1))
                            .stroke(.green, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text(Format.percent(sample.level)).font(.title2.weight(.semibold).monospacedDigit())
                    }
                    .frame(width: 112, height: 112)
                    .accessibilityLabel("Battery charge \(Format.percent(sample.level))")
                    VStack(alignment: .leading, spacing: 7) {
                        Text(chargeState(sample)).font(.title2.weight(.semibold))
                        if let minutes = sample.isCharging ? sample.minutesToFull : sample.minutesToEmpty {
                            Text("\(minutes / 60) hr \(minutes % 60) min \(sample.isCharging ? "until full" : "remaining")")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                MetricChart(series: batterySeries, range: 0...100, format: Format.percent)
            }
            Panel(title: "Battery health & power", symbol: "bolt.heart", tint: .green) {
                LabeledContent("Health", value: sample.health.map(Format.percent) ?? "—")
                if let health = sample.health, health < 80 {
                    Label("Service recommended", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                LabeledContent("Cycle count", value: sample.cycleCount?.formatted() ?? "—")
                LabeledContent("Design capacity", value: sample.designCapacity.map { "\($0.formatted()) mAh" } ?? "—")
                LabeledContent("Maximum capacity", value: sample.maxCapacity.map { "\($0.formatted()) mAh" } ?? "—")
                LabeledContent("Temperature", value: sample.temperatureCelsius.map { "\(Format.decimal($0)) °C" } ?? "—")
                LabeledContent("Voltage", value: sample.voltage.map { "\(Format.decimal($0)) V" } ?? "—")
                LabeledContent("Battery power", value: sample.power.map { "\(Format.decimal(abs($0))) W \($0 < 0 ? "out" : "in")" } ?? "—")
                LabeledContent("Adapter", value: sample.adapterWatts.map { "\($0) W" } ?? "—")
                LabeledContent("Low Power Mode", value: sample.isLowPowerMode ? "On" : "Off")
            }
        } else {
            ContentUnavailableView("Battery data unavailable", systemImage: "battery.0percent")
        }
    }

    private var capacity: some View {
        let volumes = store.volumes.sorted {
            if $0.isRoot != $1.isRoot { return $0.isRoot }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return Group {
            if volumes.isEmpty { ContentUnavailableView("No volumes available", systemImage: "internaldrive") }
            ForEach(volumes) { volume in
                Panel(title: volume.name, symbol: volume.isInternal ? "internaldrive" : "externaldrive", tint: .indigo) {
                    HStack {
                        headline(Format.bytes(volume.total))
                        Spacer()
                        Text("\(volume.fileSystem.uppercased()) · \(volume.isInternal ? "Internal" : "External")")
                            .foregroundStyle(.secondary)
                    }
                    Breakdown(parts: volumeParts(volume))
                    Text(volume.mountPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
    }

    private func volumeParts(_ volume: VolumeInfo) -> [Breakdown.Part] {
        [.init(name: "Used", bytes: volume.used, color: .indigo),
         .init(name: "Purgeable", bytes: volume.purgeable, color: .teal),
         .init(name: "Free", bytes: volume.available, color: .gray.opacity(0.25))]
    }

    private func chargeState(_ battery: BatterySnapshot) -> String {
        if battery.isFullyCharged { return "Fully charged" }
        if battery.isCharging { return "Charging" }
        return battery.powerSource == .ac ? "Connected to power" : "On battery"
    }

    private func headline(_ value: String) -> some View {
        Text(value).font(.system(.largeTitle, design: .rounded, weight: .semibold))
            .monospacedDigit()
    }

    private func rateStat(_ title: String, _ value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout.weight(.medium)).foregroundStyle(color)
            headline(Format.rate(value))
        }
    }

    private func processPanel(_ sort: MonitorStore.ProcessSort) -> some View {
        Panel(title: "Process activity", symbol: "list.bullet", tint: tab.tint) {
            TopProcesses(sort: sort)
        }
    }
}

#if DEBUG && !MONITORING_SKIP_PREVIEWS
#Preview("Overview") {
    MetricsView(tab: .overview, cleanCachePresented: .constant(false)).frame(width: 890, height: 700).environment(PreviewData.store)
}
#Preview("Memory") {
    MetricsView(tab: .memory, cleanCachePresented: .constant(false))
        .frame(width: 760, height: 700).environment(PreviewData.store)
}
#endif
