import SwiftUI
import MonitorCore

struct WatchedView: View {
    @Environment(MonitorStore.self) private var store
    @State private var showPicker = false

    var body: some View {
        Group {
            if store.watchedProcessNames.isEmpty {
                ContentUnavailableView {
                    Label("No watched processes", systemImage: "pin")
                } description: {
                    Text("Pin a process name to follow its resource usage.")
                } actions: {
                    Button("Add Process") { showPicker = true }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 310), spacing: 16)], spacing: 16) {
                        ForEach(store.watchedProcessNames, id: \.self) { name in
                            let matches = store.processes(named: name)
                            let points = store.watchedHistory[name] ?? []
                            Panel(title: name, symbol: "pin.fill", tint: .pink) {
                                HStack {
                                    Label(matches.isEmpty ? "Not running" : "\(matches.count) running",
                                          systemImage: matches.isEmpty ? "circle" : "circle.fill")
                                        .foregroundStyle(matches.isEmpty ? Color.secondary : Color.green)
                                    Spacer()
                                    Button(role: .destructive) {
                                        withAnimation(.easeInOut(duration: 0.2)) { store.unwatch(name) }
                                    } label: {
                                        Image(systemName: "pin.slash")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Unwatch \(name)")
                                    .accessibilityLabel("Unwatch \(name)")
                                }
                                chart("CPU", detail: Format.percent(matches.reduce(0) { $0 + $1.cpuPercent }), series: [
                                    .init(name: "CPU", points: metric(points, \.cpuPercent), color: .cyan)
                                ])
                                chart("Memory", detail: Format.bytes(matches.reduce(UInt64(0)) { $0 + $1.memory }), series: [
                                    .init(name: "Memory", points: points.map {
                                        MetricPoint(date: $0.date, value: Double($0.memory))
                                    }, color: .purple)
                                ])
                                chart("Network", detail: Format.rate(matches.reduce(0) { $0 + $1.networkInRate + $1.networkOutRate }), series: [
                                    .init(name: "In", points: metric(points, \.networkInRate), color: .blue),
                                    .init(name: "Out", points: metric(points, \.networkOutRate), color: .teal)
                                ])
                            }
                        }
                    }
                    .padding(24)
                }
            }
        }
        .toolbar { Button("Add Process", systemImage: "plus") { showPicker = true } }
        .sheet(isPresented: $showPicker) { WatchPicker() }
    }

    private func metric(_ points: [ProcessHistoryPoint], _ key: KeyPath<ProcessHistoryPoint, Double>) -> [MetricPoint] {
        points.map { MetricPoint(date: $0.date, value: $0[keyPath: key]) }
    }

    private func chart(_ title: String, detail: String, series: [MetricChart.Series]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title, value: detail).font(.caption.monospacedDigit())
            MetricChart(series: series, compact: true)
        }
    }
}

struct WatchPicker: View {
    @Environment(MonitorStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Watch a Process").font(.title2.weight(.semibold))
            TextField("Search running processes", text: $search).textFieldStyle(.roundedBorder)
            let names = Set(store.processes.map(\.name)).filter {
                !store.isWatched($0) && (search.isEmpty || $0.localizedCaseInsensitiveContains(search))
            }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            if names.isEmpty {
                ContentUnavailableView("No matching processes", systemImage: "magnifyingglass")
            } else {
                List(names, id: \.self) { name in
                    Button {
                        store.watch(name)
                        dismiss()
                    } label: {
                        HStack {
                            Text(name)
                            Spacer()
                            Image(systemName: "plus.circle").foregroundStyle(Color.accentColor)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(20)
        .frame(width: 420, height: 420)
    }
}

#if DEBUG && !MONITORING_SKIP_PREVIEWS
#Preview("Watched") {
    WatchedView()
        .frame(width: 760, height: 570).environment(PreviewData.store)
}
#Preview("Watch picker") {
    WatchPicker().environment(PreviewData.store)
}
#endif
