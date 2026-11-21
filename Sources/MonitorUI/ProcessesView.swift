import SwiftUI
import MonitorCore

private struct ProcessIdentity: Hashable {
    let pid: Int32
    let started: Date?
}

private struct ProcessRow: Identifiable {
    var process: ProcessSample?
    var group: ProcessGroup?
    var depth = 0

    var id: String { process.map { "pid:\($0.pid)" } ?? "app:\(group?.id ?? "")" }
    var name: String { process?.name ?? group?.name ?? "" }
    var bundle: String? { process?.appBundlePath ?? group?.appBundlePath }
    var pid: Int32 { process?.pid ?? 0 }
    var cpu: Double { process?.cpuPercent ?? group?.cpuPercent ?? 0 }
    var memory: UInt64 { process?.memory ?? group?.memory ?? 0 }
    var threads: Int? { process?.threads }
    var read: Double? { process == nil ? group?.diskReadRate : process?.diskReadRate }
    var write: Double? { process == nil ? group?.diskWriteRate : process?.diskWriteRate }
    var inbound: Double { process?.networkInRate ?? group?.networkInRate ?? 0 }
    var outbound: Double { process?.networkOutRate ?? group?.networkOutRate ?? 0 }
    var threadSort: Int { threads ?? -1 }
    var readSort: Double { read ?? -1 }
    var writeSort: Double { write ?? -1 }
    var user: String { process?.user ?? "—" }
}

struct ProcessesView: View {
    @Environment(MonitorStore.self) private var store
    @State private var search = ""
    @State private var grouped = false
    @State private var expanded = Set<String>()
    @State private var selection: String?
    @State private var showInspector = false
    @State private var sort = [KeyPathComparator(\ProcessRow.cpu, order: .reverse)]

    var body: some View {
        Table(of: ProcessRow.self, selection: $selection, sortOrder: $sort) {
            TableColumn("Process", value: \.name) { row in
                HStack(spacing: 5) {
                    if let group = row.group {
                        Button {
                            if expanded.contains(group.id) { expanded.remove(group.id) }
                            else { expanded.insert(group.id) }
                        } label: {
                            Image(systemName: expanded.contains(group.id) ? "chevron.down" : "chevron.right")
                                .font(.caption2.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(expanded.contains(group.id) ? "Collapse \(row.name)" : "Expand \(row.name)")
                    }
                    Image(nsImage: ProcessIcons.image(bundle: row.bundle, executable: row.process?.executablePath))
                        .resizable().frame(width: 16, height: 16).accessibilityHidden(true)
                    Text(row.name).lineLimit(1).help(row.name)
                    if row.process?.quality == .limited {
                        Image(systemName: "lock.fill")
                            .font(.caption2).foregroundStyle(.secondary)
                            .help("System process with limited data. Threads and disk activity are unavailable.")
                            .accessibilityLabel("Limited system process data")
                    }
                }
                .padding(.leading, CGFloat(row.depth) * 18)
            }
            .width(min: 155, ideal: 230)
            TableColumn("PID", value: \.pid) { row in cell(row.process == nil ? "—" : String(row.pid)) }
                .width(min: 44, ideal: 54)
            TableColumn("CPU %", value: \.cpu) { cell(Format.percent($0.cpu)) }.width(min: 59, ideal: 70)
            TableColumn("Memory", value: \.memory) { cell(Format.bytes($0.memory)) }.width(min: 65, ideal: 84)
            TableColumn("Threads", value: \.threadSort) { cell($0.threads?.formatted() ?? "—") }.width(min: 56, ideal: 66)
            TableColumn("Disk read/s", value: \.readSort) { cell($0.read.map(Format.rate) ?? "—") }.width(min: 78, ideal: 92)
            TableColumn("Disk write/s", value: \.writeSort) { cell($0.write.map(Format.rate) ?? "—") }.width(min: 78, ideal: 92)
            TableColumn("Net in/s", value: \.inbound) { cell(Format.rate($0.inbound)) }.width(min: 68, ideal: 85)
            TableColumn("Net out/s", value: \.outbound) { cell(Format.rate($0.outbound)) }.width(min: 68, ideal: 85)
            TableColumn("User", value: \.user).width(min: 60, ideal: 86)
        } rows: {
            ForEach(rows) { TableRow($0) }
        }
        .searchable(text: $search, prompt: "Process name or PID")
        .toolbar {
            Toggle("Group by app", systemImage: "square.stack", isOn: $grouped)
                .toggleStyle(.button)
            Button("Inspector", systemImage: "sidebar.right") { showInspector.toggle() }
        }
        .onChange(of: selection) { _, value in
            if value?.hasPrefix("pid:") == true { showInspector = true }
        }
        .inspector(isPresented: $showInspector) {
            if let selection, selection.hasPrefix("pid:"),
               let pid = Int32(selection.dropFirst(4)), let process = store.process(pid: pid) {
                ProcessInspector(process: process)
                    .id(ProcessIdentity(pid: process.pid, started: process.startDate))
                    .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
            } else {
                ContentUnavailableView("Select a process", systemImage: "sidebar.right")
                    .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
            }
        }
    }

    private var rows: [ProcessRow] {
        let comparator = sort.first ?? KeyPathComparator(\ProcessRow.cpu, order: .reverse)
        let searchTerm = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = store.sortedProcesses(by: coreSort(for: comparator), matching: searchTerm)
        let sorted = matches.map { ProcessRow(process: $0) }.sorted(using: sort)
        guard grouped else { return sorted }
        let matchingPIDs = Set(matches.map(\.pid))
        let groups = store.processGroups.filter { $0.processes.contains { matchingPIDs.contains($0.pid) } }
            .map { ProcessRow(group: $0) }.sorted(using: sort)
        let children = Dictionary(grouping: sorted) { row in row.bundle ?? row.name }
        return groups.flatMap { row -> [ProcessRow] in
            guard let group = row.group, expanded.contains(group.id) || !searchTerm.isEmpty else { return [row] }
            return [row] + (children[group.id] ?? []).map { child in
                ProcessRow(process: child.process, depth: 1)
            }
        }
    }

    private func coreSort(for comparator: KeyPathComparator<ProcessRow>) -> MonitorStore.ProcessSort {
        switch comparator.keyPath {
        case \ProcessRow.name: .name
        case \ProcessRow.pid: .pid
        case \ProcessRow.memory: .memory
        case \ProcessRow.readSort, \ProcessRow.writeSort: .disk
        case \ProcessRow.inbound, \ProcessRow.outbound: .network
        default: .cpu
        }
    }

    private func cell(_ value: String) -> some View {
        Text(value).monospacedDigit().lineLimit(1)
    }
}

struct ProcessInspector: View {
    private enum Prompt: String, Identifiable {
        case confirm, administrator, error
        var id: Self { self }
    }

    @Environment(MonitorStore.self) private var store
    let process: ProcessSample
    var previewHistory: [ProcessHistoryPoint]? = nil
    @State private var force = false
    @State private var working = false
    @State private var prompt: Prompt?
    @State private var errorMessage = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(nsImage: ProcessIcons.image(bundle: process.appBundlePath, executable: process.executablePath))
                    .resizable().frame(width: 42, height: 42).accessibilityHidden(true)
                Text(process.name).font(.title2.weight(.semibold))
                Text("PID \(process.pid) · \(process.user)").font(.callout).foregroundStyle(.secondary)
                LabeledContent("Started") {
                    Text(process.startDate?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                }
                Text(process.executablePath ?? "Path unavailable")
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                Divider()
                let points = previewHistory ?? store.processHistory[process.pid] ?? []
                Text("CPU · \(Format.percent(process.cpuPercent))").font(.headline)
                MetricChart(series: [.init(name: "CPU", points: points.map {
                    MetricPoint(date: $0.date, value: $0.cpuPercent)
                }, color: .cyan)], compact: true)
                Text("Memory · \(Format.bytes(process.memory))").font(.headline)
                MetricChart(series: [.init(name: "Memory", points: points.map {
                    MetricPoint(date: $0.date, value: Double($0.memory))
                }, color: .purple)], compact: true)
                Divider()
                Button(store.isWatched(process.name) ? "Unwatch" : "Watch", systemImage: "pin") {
                    if store.isWatched(process.name) { store.unwatch(process.name) }
                    else { store.watch(process.name) }
                }
                HStack {
                    Button("Quit") { confirm(force: false) }
                    Button("Force Quit") { confirm(force: true) }.foregroundStyle(.red)
                }
                .disabled(working || store === PreviewData.store)
            }
            .padding(18)
        }
        .alert(item: $prompt) { item in
            switch item {
            case .confirm:
                Alert(title: Text(force ? "Force quit \(process.name)?" : "Quit \(process.name)?"),
                      message: Text("The process may have unsaved work."),
                      primaryButton: .destructive(Text(force ? "Force Quit" : "Quit")) { terminate() },
                      secondaryButton: .cancel())
            case .administrator:
                Alert(title: Text("Administrator access required"),
                      message: Text("Enter an administrator password to quit \(process.name)."),
                      primaryButton: .destructive(Text("Enter Password")) { terminate(administrator: true) },
                      secondaryButton: .cancel())
            case .error:
                Alert(title: Text("Couldn’t quit process"), message: Text(errorMessage), dismissButton: .default(Text("OK")))
            }
        }
    }

    private func confirm(force: Bool) {
        self.force = force
        prompt = .confirm
    }

    private func terminate(administrator: Bool = false) {
        working = true
        Task {
            defer { working = false }
            guard let current = store.process(pid: process.pid), current.startDate == process.startDate,
                  current.name == process.name else {
                errorMessage = ProcessActionError.notFound.localizedDescription
                prompt = .error
                return
            }
            do {
                try await store.terminate(pid: process.pid, force: force, asAdministrator: administrator)
            } catch ProcessActionError.permissionDenied where !administrator {
                prompt = .administrator
            } catch {
                errorMessage = error.localizedDescription
                prompt = .error
            }
        }
    }
}

#if DEBUG && !MONITORING_SKIP_PREVIEWS
#Preview("Processes") {
    ProcessesView().frame(width: 1050, height: 620).environment(PreviewData.store)
}
#Preview("Process inspector") {
    ProcessInspector(process: PreviewData.processes[0], previewHistory: PreviewData.processHistory)
        .frame(width: 320, height: 570).environment(PreviewData.store)
}
#endif
