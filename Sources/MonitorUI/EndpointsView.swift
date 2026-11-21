import SwiftUI
import MonitorCore

struct EndpointsView: View {
    private struct Edit: Identifiable {
        var id = UUID()
        var endpoint: Endpoint?
    }

    @Environment(MonitorStore.self) private var store
    @State private var editing: Edit?
    @State private var removing: Endpoint?
    @State private var checking = Set<Endpoint.ID>()

    var body: some View {
        Group {
            if store.endpoints.isEmpty {
                ContentUnavailableView {
                    Label("No endpoints", systemImage: "globe")
                } description: {
                    Text("Add a website or server to track uptime and response time.")
                } actions: {
                    Button("Add Endpoint") { editing = Edit() }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 285), spacing: 16, alignment: .top)], spacing: 16) {
                        ForEach(store.endpoints) { endpoint in card(endpoint) }
                    }
                    .padding(24)
                }
            }
        }
        .toolbar { Button("Add Endpoint", systemImage: "plus") { editing = Edit() } }
        .sheet(item: $editing) { edit in EndpointEditor(endpoint: edit.endpoint) }
        .alert("Delete endpoint?", isPresented: Binding(get: { removing != nil }, set: {
            if !$0 { removing = nil }
        }), presenting: removing) { endpoint in
            Button("Delete", role: .destructive) { store.removeEndpoint(id: endpoint.id) }
            Button("Cancel", role: .cancel) {}
        } message: { endpoint in
            Text("This removes \(endpoint.name) and its check history.")
        }
    }

    private func card(_ endpoint: Endpoint) -> some View {
        let status = store.endpointStatuses[endpoint.id] ?? EndpointStatus()
        let state = endpoint.isEnabled ? status.state.rawValue.capitalized : "Disabled"
        let color: Color = if endpoint.isEnabled && status.state == .up { .green }
        else if endpoint.isEnabled && status.state == .down { .red }
        else { .secondary }
        var sum = 0.0
        var count = 0
        let averages = status.history.compactMap { check -> MetricPoint? in
            guard let latency = check.latency else { return nil }
            sum += latency
            count += 1
            return MetricPoint(date: check.date, value: sum / Double(count))
        }

        return Panel(title: endpoint.name, symbol: "globe", tint: .accentColor) {
            HStack {
                Label(state, systemImage: "circle.fill").foregroundStyle(color)
                Spacer()
                if checking.contains(endpoint.id) { ProgressView().controlSize(.small) }
                Menu {
                    Button("Check Now", systemImage: "arrow.clockwise") { check(endpoint) }
                        .disabled(checking.contains(endpoint.id) || store.isPreview)
                    Button("Edit", systemImage: "pencil") { editing = Edit(endpoint: endpoint) }
                        .disabled(checking.contains(endpoint.id))
                    Button(endpoint.isEnabled ? "Disable" : "Enable", systemImage: endpoint.isEnabled ? "pause" : "play") {
                        var updated = endpoint
                        updated.isEnabled.toggle()
                        store.updateEndpoint(updated)
                    }
                    .disabled(checking.contains(endpoint.id))
                    Divider()
                    Button("Delete", systemImage: "trash", role: .destructive) { removing = endpoint }
                        .disabled(checking.contains(endpoint.id))
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Actions for \(endpoint.name)")
            }
            Text(endpoint.target).font(.callout.monospaced()).foregroundStyle(.secondary)
                .textSelection(.enabled)
            LabeledContent("Latest latency", value: status.lastCheck?.latency.map(Format.latency) ?? "—")
            LabeledContent("Uptime", value: status.uptimePercent.map(Format.percent) ?? "—")
            LabeledContent("Average latency", value: status.averageLatency.map(Format.latency) ?? "—")
            MetricChart(series: [.init(name: "Average latency", points: averages, color: .blue)], compact: true)
                .accessibilityLabel("Average latency history")
            if let check = status.lastCheck, !check.isUp, let error = check.error {
                Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red)
            }
        }
    }

    private func check(_ endpoint: Endpoint) {
        guard checking.insert(endpoint.id).inserted else { return }
        Task {
            defer { checking.remove(endpoint.id) }
            await store.checkNow(id: endpoint.id)
        }
    }
}

struct EndpointEditor: View {
    @Environment(MonitorStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    private let endpoint: Endpoint?
    @State private var target: String
    @State private var name: String
    @State private var interval: Double

    init(endpoint: Endpoint? = nil) {
        self.endpoint = endpoint
        _target = State(initialValue: endpoint?.target ?? "")
        _name = State(initialValue: endpoint?.name ?? "")
        _interval = State(initialValue: endpoint?.interval ?? 30)
    }

    var body: some View {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = Endpoint.parse(target, name: label, interval: interval)
        VStack(alignment: .leading, spacing: 16) {
            Text(endpoint == nil ? "Add Endpoint" : "Edit Endpoint").font(.title2.weight(.semibold))
            Form {
                TextField("Target", text: $target, prompt: Text("https://example.com, host:port, or host"))
                TextField("Name", text: $name, prompt: Text("Optional"))
                TextField("Interval in seconds", value: $interval, format: .number)
                Text("Minimum interval is 5 seconds.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    guard var updated = parsed, interval.isFinite, interval >= 5 else { return }
                    if let endpoint {
                        updated.id = endpoint.id
                        updated.isEnabled = endpoint.isEnabled
                        if target.trimmingCharacters(in: .whitespacesAndNewlines) == endpoint.target {
                            updated.kind = endpoint.kind
                        }
                        store.updateEndpoint(updated)
                    } else {
                        store.addEndpoint(updated)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(parsed == nil || !interval.isFinite || interval < 5)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

#if DEBUG && !MONITORING_SKIP_PREVIEWS
#Preview("Endpoints") {
    EndpointsView().frame(width: 960, height: 550).environment(PreviewData.store)
}
#Preview("Edit endpoint") {
    EndpointEditor(endpoint: PreviewData.store.endpoints.first).environment(PreviewData.store)
}
#endif
