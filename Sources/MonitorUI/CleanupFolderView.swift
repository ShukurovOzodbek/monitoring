import SwiftUI
import MonitorCore

struct CleanupFolderView: View {
    private struct Removal {
        let entry: DirectoryEntry
        let mode: CleanupDeletionMode

        var title: String { mode == .moveToTrash ? "Move to Trash" : "Delete Immediately" }
        var message: String {
            if mode == .moveToTrash {
                return "Move “\(entry.name)” to the Trash? Its space becomes available when you empty the Trash."
            }
            return "Permanently delete “\(entry.name)” and its contents? This action cannot be undone."
        }
    }

    @Environment(CleanupStore.self) private var cleanup
    let url: URL
    @Binding var path: [CleanupRoute]
    @State var entries: [DirectoryEntry]? = nil
    @State private var pendingRemoval: Removal?
    @State private var isRemoving = false
    @State private var removalError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            breadcrumbs
                .padding(16)
            Divider()
            if let entries {
                if entries.isEmpty {
                    ContentUnavailableView("No Entries Found", systemImage: "folder")
                } else {
                    let total = entries.reduce(UInt64.zero) { $0 + $1.size }
                    List(entries) { entry in
                        entryRow(entry, total: total)
                    }
                    .disabled(isRemoving)
                }
            } else {
                ProgressView(isRemoving ? "Refreshing folder sizes…" : "Calculating folder sizes…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(url.lastPathComponent)
        .task(id: cleanup.lastScan) {
            guard !cleanup.isPreview, !isRemoving else { return }
            await refresh()
        }
        .alert(pendingRemoval?.title ?? "Remove Item", isPresented: Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        ), presenting: pendingRemoval) { removal in
            Button("Cancel", role: .cancel) {}
            Button(removal.title, role: .destructive) {
                isRemoving = true
                Task { await remove(removal) }
            }
        } message: { removal in
            Text(removal.message)
        }
        .alert("Couldn’t Remove Item", isPresented: Binding(
            get: { removalError != nil },
            set: { if !$0 { removalError = nil } }
        ), presenting: removalError) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    private var breadcrumbs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(path.enumerated()), id: \.offset) { index, route in
                    switch route {
                    case .category(let kind):
                        breadcrumb(kind.title, at: index)
                    case .folder(let folder):
                        Image(systemName: "chevron.right")
                            .font(.caption).foregroundStyle(.secondary)
                        if folder == url {
                            Text(folder.lastPathComponent).fontWeight(.semibold)
                        } else {
                            breadcrumb(folder.lastPathComponent, at: index)
                        }
                    }
                }
            }
            .font(.callout)
        }
        .scrollIndicators(.hidden)
        .disabled(isRemoving)
    }

    private func breadcrumb(_ title: String, at index: Int) -> some View {
        Button(title) { path = Array(path.prefix(index + 1)) }
            .buttonStyle(.link)
    }

    private func entryRow(_ entry: DirectoryEntry, total: UInt64) -> some View {
        Group {
            if entry.canBrowse {
                NavigationLink(value: CleanupRoute.folder(entry.url)) {
                    entryLabel(entry, total: total)
                }
            } else {
                entryLabel(entry, total: total)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Show in Finder") { cleanup.revealInFinder(entry.url) }
            Button("Open") { cleanup.open(entry.url) }
            if cleanup.canDelete(entry) {
                Divider()
                Button("Move to Trash…") { pendingRemoval = Removal(entry: entry, mode: .moveToTrash) }
                Button("Delete Immediately…", role: .destructive) {
                    pendingRemoval = Removal(entry: entry, mode: .delete)
                }
            }
        }
    }

    private func entryLabel(_ entry: DirectoryEntry, total: UInt64) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.accessDenied ? "lock.fill" : entry.isDirectory ? "folder" : "doc")
                .foregroundStyle(.mint).frame(width: 22)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(entry.name).lineLimit(1)
                    Spacer()
                    Text(entry.accessDenied ? "—" : Format.bytes(entry.size)).monospacedDigit()
                }
                cleanupShare(entry.size, of: total, label: "Share of folder size")
                HStack {
                    Text(entry.accessDenied ? "Access denied" : "\(entry.fileCount.formatted()) files")
                    Spacer()
                    Text(entry.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func refresh() async {
        entries = nil
        let contents = await cleanup.contents(of: url)
        guard !Task.isCancelled else { return }
        entries = contents
    }

    private func remove(_ removal: Removal) async {
        defer { isRemoving = false }
        do {
            try await cleanup.remove([removal.entry], mode: removal.mode)
            await refresh()
        } catch {
            removalError = error.localizedDescription
        }
    }
}

#if DEBUG && !MONITORING_SKIP_PREVIEWS
#Preview("Cleanup folder") {
    let folder = URL(fileURLWithPath: "/Users/preview/Library/Developer/Xcode/DerivedData", isDirectory: true)
    NavigationStack {
        CleanupFolderView(url: folder, path: .constant([.category(.developer), .folder(folder)]), entries: [
            DirectoryEntry(url: folder.appendingPathComponent("Monitoring"), size: 830_000_000, fileCount: 1_240,
                           isDirectory: true, isPackage: false, isHidden: false, modified: .now, accessDenied: false),
            DirectoryEntry(url: folder.appendingPathComponent("info.plist"), size: 4096, fileCount: 1,
                           isDirectory: false, isPackage: false, isHidden: false, modified: .now, accessDenied: false)
        ])
    }
    .environment(PreviewData.cleanup)
    .frame(width: 720, height: 420)
}
#endif
