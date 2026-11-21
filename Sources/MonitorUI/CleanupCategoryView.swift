import SwiftUI
import MonitorCore

struct CleanupCategoryView: View {
    @Environment(CleanupStore.self) private var cleanup
    let kind: CleanupCategoryKind
    var browse: (URL) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let category = cleanup.category(kind) {
                Panel(title: kind.title, symbol: kind.symbol, tint: .mint) {
                    Text(kind.summary).foregroundStyle(.secondary)
                    cleanupCategoryStatus(category, grantAccess: cleanup.openFullDiskAccessSettings)
                    if category.state == .ready && category.items.contains(where: \.isRemovable) {
                        HStack {
                            Button("Select all") { cleanup.selectAll(in: kind) }
                            Button("Select none") { cleanup.deselectAll(in: kind) }
                            Button("Select recommended") {
                                let categoryIDs = Set(category.items.map(\.id))
                                let recommendedIDs = category.items.filter(\.selectedByDefault).map(\.id)
                                cleanup.selection = cleanup.selection.subtracting(categoryIDs).union(recommendedIDs)
                            }
                            Spacer()
                            Text("\(Format.bytes(cleanup.selectedSize(in: kind))) selected")
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        .disabled(cleanup.isRunning)
                    }
                }
                .padding([.horizontal, .top], 16)

                if category.state == .scanning {
                    ProgressView("Scanning…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if category.state == .ready && category.items.isEmpty {
                    ContentUnavailableView("No Items Found", systemImage: kind.symbol)
                } else if !category.items.isEmpty {
                    List(category.items) { item in
                        itemRow(item)
                    }
                } else {
                    Spacer()
                }
            }
        }
        .background(.background.secondary)
        .navigationTitle(kind.title)
        .toolbar {
            if let location = cleanup.category(kind)?.location {
                Button("Show in Finder", systemImage: "folder") { cleanup.revealInFinder(location) }
            }
        }
    }

    private func itemRow(_ item: CleanupItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(isOn: Binding(
                get: { cleanup.isSelected(item) },
                set: { selected in
                    if selected != cleanup.isSelected(item) { cleanup.toggle(item) }
                }
            )) {
                Text(item.name)
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!item.isRemovable || cleanup.isRunning)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).fontWeight(.medium)
                if let detail = item.detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
                if let reason = item.skipReason {
                    Label(reason.description, systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if item.requiresAdmin {
                Text("Admin")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.red.opacity(0.12), in: Capsule())
            }
            VStack(alignment: .trailing, spacing: 4) {
                Text(item.size.map(Format.bytes) ?? "—").monospacedDigit()
                Text(item.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .opacity(item.skipReason == nil ? 1 : 0.65)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Show in Finder") { cleanup.revealInFinder(item.url) }
                .disabled(!item.url.isFileURL)
            if item.isDirectory {
                Button("Browse") { browse(item.url) }
            }
        }
    }
}

#if DEBUG && !MONITORING_SKIP_PREVIEWS
#Preview("Cleanup category") {
    NavigationStack {
        CleanupCategoryView(kind: .temporaryFiles)
    }
    .environment(PreviewData.cleanup)
    .frame(width: 720, height: 500)
}
#endif
