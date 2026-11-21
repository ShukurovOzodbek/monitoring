import SwiftUI
import MonitorCore

enum CleanupRoute: Hashable {
    case category(CleanupCategoryKind)
    case folder(URL)
}

struct CleanupView: View {
    @Environment(CleanupStore.self) private var cleanup
    @State private var path: [CleanupRoute] = []
    @State private var confirmRestart = false
    @State private var restartConfirmed = false

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(spacing: 14) {
                    header
                    let total = cleanup.categories.reduce(UInt64.zero) { $0 + $1.totalSize }
                    ForEach(cleanup.categories) { category in
                        categoryCard(category, total: total)
                    }
                }
                .padding(24)
                .frame(maxWidth: 1020)
                .frame(maxWidth: .infinity)
            }
            .background(.background.secondary)
            .navigationDestination(for: CleanupRoute.self) { route in
                switch route {
                case let .category(kind):
                    CleanupCategoryView(kind: kind) { path.append(.folder($0)) }
                case let .folder(url): CleanupFolderView(url: url, path: $path)
                }
            }
        }
        .task {
            if cleanup.lastScan == nil { await cleanup.scan() }
        }
        .sheet(isPresented: $confirmRestart, onDismiss: startRestartIfConfirmed) {
            restartConfirmation
        }
        .sheet(isPresented: Binding(
            get: { cleanup.runState != .idle },
            set: { if !$0 { cleanup.dismissResult() } }
        )) {
            CleanupOutcomeView()
                .interactiveDismissDisabled(cleanup.isRunning)
        }
    }

    private var header: some View {
        @Bindable var cleanup = cleanup
        return Panel(title: "Startup Disk", symbol: "internaldrive", tint: .mint) {
            HStack(spacing: 24) {
                stat("Free space", cleanup.freeSpace)
                stat("Selected", cleanup.selectedSize)
                stat("Reclaimable", cleanup.lastScan == nil && cleanup.reclaimableSize == 0 ? nil : cleanup.reclaimableSize)
            }
            Divider()
            HStack(alignment: .top, spacing: 12) {
                Button {
                    Task { await cleanup.cleanSelected() }
                } label: {
                    if cleanup.selectionNeedsAdmin {
                        Label("Clean Selected", systemImage: "lock.fill")
                    } else {
                        Text("Clean Selected")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(cleanup.selectedItems.isEmpty || cleanup.isRunning || cleanup.isScanning)

                VStack(spacing: 5) {
                    Button("Like a Fresh Restart") { confirmRestart = true }
                        .disabled(cleanup.isRunning || cleanup.isScanning)
                    Text(cleanup.lastScan == nil ? "—" : Format.bytes(cleanup.restartCleanupSize))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Rescan", systemImage: "arrow.clockwise") {
                    Task { await cleanup.scan() }
                }
                .disabled(cleanup.isScanning || cleanup.isRunning)
            }
            Picker("Downloads & large files", selection: $cleanup.userDataMode) {
                Text("Move to Trash").tag(CleanupDeletionMode.moveToTrash)
                Text("Delete immediately").tag(CleanupDeletionMode.delete)
            }
            .fixedSize()
            .help("Also applies to iPhone and iPad backups")
            .disabled(cleanup.isRunning)
            if let lastScan = cleanup.lastScan {
                Text("Last scanned \(lastScan.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .tint(.mint)
    }

    private func stat(_ title: String, _ value: UInt64?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(value.map(Format.bytes) ?? "—")
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func categoryCard(_ category: CleanupCategory, total: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink(value: CleanupRoute.category(category.kind)) {
                HStack(spacing: 12) {
                    Image(systemName: category.kind.symbol)
                        .foregroundStyle(.mint)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(category.kind.title).font(.headline)
                        Text(category.kind.summary).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    safetyBadge(category.kind.safety)
                    if category.state == .scanning {
                        ProgressView().controlSize(.small).accessibilityLabel("Scanning")
                    } else {
                        Text(cleanupCategorySize(category)).monospacedDigit()
                    }
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if category.state == .ready {
                cleanupShare(category.totalSize, of: total, label: "Share of scanned storage")
            }
            cleanupCategoryStatus(category, grantAccess: cleanup.openFullDiskAccessSettings)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.08)) }
    }

    private func safetyBadge(_ safety: CleanupSafety) -> some View {
        let (title, tint): (String, Color) = switch safety {
        case .safe: ("Safe", .green)
        case .review: ("Review", .orange)
        case .informational: ("Info", .gray)
        }
        return Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private var restartConfirmation: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Like a Fresh Restart", systemImage: "sparkles")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.mint)
            Text("Removes temporary files, app caches, and system caches that nothing has open. It also clears the Quick Look cache, frees the file cache in RAM, and flushes DNS.")
            Text("Apps keep running. Running apps’ caches and files in use are kept.")
            Text("Swap is only released by a real restart.")
            Text("macOS asks for the administrator password.")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { confirmRestart = false }
                    .keyboardShortcut(.cancelAction)
                Button("Run Cleanup") {
                    restartConfirmed = true
                    confirmRestart = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func startRestartIfConfirmed() {
        guard restartConfirmed else { return }
        restartConfirmed = false
        Task { await cleanup.restartCleanup() }
    }
}

private struct CleanupOutcomeView: View {
    @Environment(CleanupStore.self) private var cleanup

    var body: some View {
        Group {
            switch cleanup.runState {
            case .idle: EmptyView()
            case let .running(step):
                VStack(spacing: 14) {
                    ProgressView()
                    Text(step).font(.headline)
                }
                .padding(32)
            case let .finished(report):
                VStack(alignment: .leading, spacing: 14) {
                    Label("Cleanup Complete", systemImage: "checkmark.circle")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.mint)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            LabeledContent("Freed now", value: Format.bytes(report.bytesDeleted))
                            if report.bytesMovedToTrash > 0 {
                                LabeledContent("Moved to Trash", value: Format.bytes(report.bytesMovedToTrash))
                            }
                            LabeledContent("Disk free changed by", value: measuredChange(report.measuredFreed))
                            Text("APFS storage accounting can make the measured change differ from the sum of item sizes.")
                                .font(.caption).foregroundStyle(.secondary)
                            LabeledContent("Memory freed", value: Format.bytes(report.memoryFreed))
                            LabeledContent("Items removed", value: report.itemsRemoved.formatted())
                            ForEach(report.actions.indices, id: \.self) { index in
                                Label(report.actions[index], systemImage: "checkmark")
                            }
                            if !report.skipped.isEmpty {
                                DisclosureGroup("Skipped (\(report.skipped.count))") {
                                    ForEach(report.skipped.indices, id: \.self) { index in
                                        let item = report.skipped[index]
                                        LabeledContent(item.name, value: item.reason)
                                    }
                                }
                            }
                            if !report.failures.isEmpty {
                                DisclosureGroup("Failures (\(report.failures.count))") {
                                    ForEach(report.failures.indices, id: \.self) { index in
                                        Text(report.failures[index])
                                    }
                                }
                            }
                        }
                    }
                    .frame(height: 250)
                    doneButton
                }
                .padding(24)
            case let .failed(message):
                VStack(alignment: .leading, spacing: 14) {
                    Label("Cleanup Failed", systemImage: "exclamationmark.triangle")
                        .font(.title2.weight(.semibold))
                    Text(message).textSelection(.enabled)
                    doneButton
                }
                .padding(24)
            }
        }
        .frame(width: 460)
    }

    private var doneButton: some View {
        Button("Done") { cleanup.dismissResult() }
            .keyboardShortcut(.defaultAction)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func measuredChange(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        let prefix = bytes < 0 ? "−" : bytes > 0 ? "+" : ""
        return prefix + Format.bytes(bytes.magnitude)
    }
}

@ViewBuilder
func cleanupCategoryStatus(_ category: CleanupCategory, grantAccess: @escaping () -> Void) -> some View {
    if let note = category.note {
        Text(note).font(.caption).foregroundStyle(.secondary)
    }
    switch category.state {
    case .needsFullDiskAccess:
        VStack(alignment: .leading, spacing: 6) {
            Label("Grant Full Disk Access in System Settings, then rescan.", systemImage: "lock.shield")
                .foregroundStyle(.secondary)
            Button("Grant Full Disk Access", action: grantAccess)
        }
        .font(.callout)
    case let .unavailable(message):
        Label(message, systemImage: "exclamationmark.circle")
            .font(.callout).foregroundStyle(.secondary)
    default: EmptyView()
    }
}

func cleanupCategorySize(_ category: CleanupCategory) -> String {
    guard category.state == .ready else { return "—" }
    if category.totalSize == 0 && category.items.contains(where: { $0.size == nil }) { return "—" }
    return Format.bytes(category.totalSize)
}

func cleanupShare(_ size: UInt64, of total: UInt64, label: String) -> some View {
    let share = total > 0 ? min(Double(size) / Double(total), 1) : 0
    return GeometryReader { geometry in
        Capsule().fill(.mint)
            .frame(width: geometry.size.width * share)
    }
    .frame(height: 3)
    .background(.quaternary, in: Capsule())
    .accessibilityLabel(label)
    .accessibilityValue(share.formatted(.percent.precision(.fractionLength(0))))
}

#if DEBUG && !MONITORING_SKIP_PREVIEWS
#Preview("Cleanup") {
    CleanupView().environment(PreviewData.cleanup).frame(width: 720, height: 760)
}

#Preview("Cleanup result") {
    CleanupOutcomeView()
        .environment(CleanupStore(preview: [], freeSpace: nil, runState: .finished(
            CleanupReport(bytesDeleted: 2_400_000_000, bytesMovedToTrash: 800_000_000, itemsRemoved: 18,
                          skipped: [.init(name: "editor-session", reason: "In use by a running process")],
                          failures: ["archive.zip: Permission denied"], memoryFreed: 1_200_000_000,
                          actions: ["Flushed the DNS cache", "Reset the Quick Look thumbnail cache"],
                          freeSpaceBefore: 40_000_000_000, freeSpaceAfter: 42_100_000_000)
        )))
}
#endif
