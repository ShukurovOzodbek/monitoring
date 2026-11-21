import AppKit
import SwiftUI
import MonitorCore
import MonitorUI

@main
@MainActor
struct MonitoringApp: App {
    @State private var store: MonitorStore
    @State private var cleanup: CleanupStore
    @State private var cleanupRequested = false
    @State private var cleanCacheRequested = false
    @State private var activated = false

    init() {
        #if DEBUG && !MONITORING_SKIP_PREVIEWS
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            _store = State(initialValue: PreviewData.store)
            _cleanup = State(initialValue: PreviewData.cleanup)
            return
        }
        #endif
        let store = MonitorStore()
        _store = State(initialValue: store)
        _cleanup = State(initialValue: CleanupStore())
        NSApplication.shared.setActivationPolicy(.regular)
        store.start()
    }

    var body: some Scene {
        Window("Monitoring", id: "monitor") {
            RootView(cleanCacheRequested: $cleanCacheRequested, cleanupRequested: $cleanupRequested)
                .environment(store).environment(cleanup)
                .frame(minWidth: 820, minHeight: 560)
                .task {
                    guard !activated, !store.isPreview else { return }
                    activated = true
                    NSApplication.shared.activate()
                }
        }
        .defaultSize(width: 1220, height: 780)

        MenuBarExtra {
            MenuPanel(cleanCacheRequested: $cleanCacheRequested, cleanupRequested: $cleanupRequested).environment(store).environment(cleanup)
        } label: {
            MenuLabel().environment(store).environment(cleanup)
        }
        .menuBarExtraStyle(.window)

        Settings {
            MonitorSettings().environment(store).environment(cleanup)
        }
    }
}

private struct MenuLabel: View {
    @Environment(MonitorStore.self) private var store

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "cpu")
            Text(Format.percent(store.cpu.total)).monospacedDigit()
        }
        .accessibilityLabel("CPU \(Format.percent(store.cpu.total))")
    }
}

private struct MenuPanel: View {
    @Environment(MonitorStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Binding var cleanCacheRequested: Bool
    @Binding var cleanupRequested: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Monitoring").font(.title2.weight(.semibold))
            LabeledContent {
                Text(Format.percent(store.cpu.total))
            } label: { Label("CPU", systemImage: "cpu").foregroundStyle(.cyan) }
            LabeledContent {
                Text(Format.bytes(store.memory.used))
            } label: { Label("Memory", systemImage: "memorychip").foregroundStyle(.purple) }
            LabeledContent {
                Text(Format.rate(store.network.inRate))
            } label: { Label("Download", systemImage: "arrow.down").foregroundStyle(.blue) }
            LabeledContent {
                Text(Format.rate(store.network.outRate))
            } label: { Label("Upload", systemImage: "arrow.up").foregroundStyle(.teal) }
            if store.hasBattery {
                LabeledContent {
                    Text(store.battery.map { Format.percent($0.level) } ?? "—")
                } label: { Label("Battery", systemImage: "battery.75percent").foregroundStyle(.green) }
            }
            Divider()
            Text("Top CPU Processes").font(.headline)
            ForEach(store.topProcesses(by: .cpu, limit: 5)) { process in
                LabeledContent {
                    Text(Format.percent(process.cpuPercent))
                } label: {
                    Text(process.name).lineLimit(1)
                }
            }
            Divider()
            Button("Clean Cache", systemImage: "sparkles") {
                cleanCacheRequested = true
                showMonitor()
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isPreview)
            Button("Free Up Space…", systemImage: "sparkles") {
                cleanupRequested = true
                showMonitor()
            }
            .disabled(store.isPreview)
            HStack {
                Button("Open Monitor", systemImage: "macwindow") {
                    showMonitor()
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .disabled(store.isPreview)
            }
        }
        .monospacedDigit()
        .padding(18)
        .frame(width: 310)
    }

    private func showMonitor() {
        openWindow(id: "monitor")
        NSApplication.shared.activate()
    }
}

private struct MonitorSettings: View {
    @Environment(MonitorStore.self) private var store

    var body: some View {
        Form {
            Slider(value: Binding(get: { store.sampleInterval }, set: { store.setSampleInterval($0) }),
                   in: 0.5...10, step: 0.5) {
                Text("Sample interval")
            } minimumValueLabel: {
                Text("0.5 s")
            } maximumValueLabel: {
                Text("10 s")
            }
            Text("Update every \(Format.decimal(store.sampleInterval)) seconds").foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 420)
    }
}

#if DEBUG && !MONITORING_SKIP_PREVIEWS
#Preview("Menu label") {
    MenuLabel().padding().environment(PreviewData.store).environment(PreviewData.cleanup)
}
#Preview("Menu") {
    MenuPanel(cleanCacheRequested: .constant(false), cleanupRequested: .constant(false)).environment(PreviewData.store).environment(PreviewData.cleanup)
}
#Preview("Settings") {
    MonitorSettings().environment(PreviewData.store).environment(PreviewData.cleanup)
}
#endif
