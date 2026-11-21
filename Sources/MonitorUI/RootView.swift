import SwiftUI
import MonitorCore

enum MonitorTab: String, CaseIterable, Identifiable {
    case overview = "Overview", processes = "Processes", cpu = "CPU", memory = "Memory"
    case network = "Network", disk = "Disk", battery = "Battery", watched = "Watched"
    case endpoints = "Websites & Servers", capacity = "Capacity"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .processes: "list.bullet.rectangle"
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .network: "arrow.up.arrow.down"
        case .disk: "internaldrive"
        case .battery: "battery.75percent"
        case .watched: "pin"
        case .endpoints: "globe"
        case .capacity: "chart.donut"
        }
    }

    var tint: Color {
        switch self {
        case .overview, .processes: .accentColor
        case .cpu: .cyan
        case .memory: .purple
        case .network: .blue
        case .disk: .orange
        case .battery, .endpoints: .green
        case .watched: .pink
        case .capacity: .indigo
        }
    }

    @MainActor
    func value(_ store: MonitorStore) -> String {
        switch self {
        case .overview:
            store.lastUpdated == nil ? "—" : "Live"
        case .processes: store.processes.count.formatted()
        case .cpu: Format.percent(store.cpu.total)
        case .memory: Format.percent(store.memory.usedFraction * 100)
        case .network: Format.rate(store.network.inRate + store.network.outRate)
        case .disk: Format.rate(store.disk.readRate + store.disk.writeRate)
        case .battery: store.battery.map { Format.percent($0.level) } ?? "—"
        case .watched: store.watchedProcessNames.count.formatted()
        case .endpoints:
            "\(endpointCount(.up, store))/\(store.endpoints.filter(\.isEnabled).count)"
        case .capacity:
            store.volumes.first(where: \.isRoot).map { Format.percent($0.usedFraction * 100) } ?? "—"
        }
    }

    @MainActor
    func endpointCount(_ state: EndpointStatus.State, _ store: MonitorStore) -> Int {
        store.endpoints.filter { $0.isEnabled && store.endpointStatuses[$0.id]?.state == state }.count
    }
}

public struct RootView: View {
    @Environment(MonitorStore.self) private var store
    @State private var selection: MonitorTab? = .overview

    public init() {}

    public var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Monitor") {
                    ForEach(MonitorTab.allCases.filter { $0 != .battery || store.hasBattery }) { tab in
                        HStack(spacing: 8) {
                            Image(systemName: tab.symbol).foregroundStyle(tab.tint).frame(width: 18)
                            Text(tab.rawValue)
                            Spacer(minLength: 4)
                            Text(tab.value(store)).font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                        .tag(tab)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 215, ideal: 245, max: 290)
        } detail: {
            let tab = selection ?? .overview
            Group {
                switch tab {
                case .processes: ProcessesView()
                case .watched: WatchedView()
                case .endpoints: EndpointsView()
                default: MetricsView(tab: tab) { selection = $0 }
                }
            }
            .navigationTitle(tab.rawValue)
        }
        .onChange(of: store.hasBattery) { _, available in
            if !available && selection == .battery { selection = .overview }
        }
    }
}

#if DEBUG && !MONITORING_SKIP_PREVIEWS
#Preview {
    RootView().frame(width: 1160, height: 740).environment(PreviewData.store)
}
#endif
