import SwiftUI
import MonitorCore

public struct CleanCacheButton: View {
    @Environment(MonitorStore.self) private var store
    @State private var presented = false

    public init() {}

    public var body: some View {
        Button("Clean Cache", systemImage: "sparkles") { presented = true }
            .sheet(isPresented: $presented, onDismiss: store.dismissCacheCleanResult) {
                CleanCacheView()
            }
    }
}

struct CleanCacheView: View {
    @Environment(MonitorStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var options: CacheCleanOptions = .all
    var previewState: CacheCleanState? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Clean Cache", systemImage: "sparkles")
                .font(.title2.weight(.semibold))
            switch previewState ?? store.cacheCleanState {
            case .idle:
                option("Memory", detail: "Purge cached files from memory, as after a fresh boot.", flag: .memory)
                option("DNS", detail: "Flush the macOS DNS resolver cache.", flag: .dns)
                option("App caches", detail: "Clear ~/Library/Caches for apps that aren’t running.", flag: .userCaches)
                Text("Apps keep running. macOS asks for an administrator password when cleaning memory or DNS.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Clean Cache") {
                        let selected = options
                        Task { await store.cleanCaches(selected) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(options.isEmpty || store === PreviewData.store)
                }
            case .running:
                ProgressView("Cleaning selected caches…")
                    .frame(maxWidth: .infinity, minHeight: 90)
            case .finished(let report):
                Label("Cache cleaning complete", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                LabeledContent("Memory freed", value: Format.bytes(report.memoryFreed))
                LabeledContent("App cache freed", value: Format.bytes(report.userCacheBytesFreed))
                LabeledContent("Cache folders cleaned", value: report.userCacheFoldersCleaned.formatted())
                LabeledContent("Cache folders skipped", value: report.skipped.count.formatted())
                if report.dnsFlushed {
                    Label("DNS cache flushed", systemImage: "checkmark")
                }
                if !report.warnings.isEmpty {
                    DisclosureGroup("Warnings (\(report.warnings.count))") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(report.warnings.enumerated()), id: \.offset) { warning in
                                    Text(warning.element)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 100)
                    }
                }
                done
            case .failed(let error):
                Label("Cache cleaning failed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(error).textSelection(.enabled)
                done
            }
        }
        .padding(24)
        .frame(width: 460)
        .interactiveDismissDisabled(store.cacheCleanState == .running)
    }

    private var done: some View {
        Button("Done") {
            store.dismissCacheCleanResult()
            dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func option(_ title: String, detail: String, flag: CacheCleanOptions) -> some View {
        Toggle(isOn: Binding(get: { options.contains(flag) }, set: { enabled in
            if enabled { options.insert(flag) }
            else { options.remove(flag) }
        })) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

#if DEBUG && !MONITORING_SKIP_PREVIEWS
#Preview("Cache button") {
    CleanCacheButton().padding(24).environment(PreviewData.store)
}
#Preview("Cache options") {
    CleanCacheView().environment(PreviewData.store)
}
#Preview("Cache result") {
    CleanCacheView(previewState: .finished(.init(memoryFreed: 840_000_000, userCacheBytesFreed: 62_000_000,
                                                userCacheFoldersCleaned: 12, skipped: ["com.apple.finder"],
                                                dnsFlushed: true, warnings: [], duration: 2)))
        .environment(PreviewData.store)
}
#endif
