import Foundation
import Observation

/// One copied text.
public struct ClipboardEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var text: String
    /// When it was (last) copied. Re-copying the same text moves it to the top.
    public var date: Date
    /// Frontmost app at copy time, e.g. "Safari".
    public var sourceAppName: String?
    public var sourceBundleID: String?

    public init(id: UUID = UUID(), text: String, date: Date, sourceAppName: String? = nil, sourceBundleID: String? = nil) {
        self.id = id
        self.text = text
        self.date = date
        self.sourceAppName = sourceAppName
        self.sourceBundleID = sourceBundleID
    }

    /// First non-empty line, trimmed, for list rows.
    public var title: String {
        let line = text.split(whereSeparator: \.isNewline).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return line.map { $0.trimmingCharacters(in: .whitespaces) } ?? text
    }

    public var lineCount: Int { text.split(whereSeparator: \.isNewline).count }
}

/// Copied texts from the last 24 hours, newest first, saved to disk.
///
/// The agent owns the only writable instance. Everything older than
/// `retention` is deleted from memory and disk by `prune()` (called on every
/// change and once a minute by the agent).
@MainActor
@Observable
public final class ClipboardHistory {
    public static let retention: TimeInterval = 24 * 60 * 60
    /// Texts larger than this are not stored (huge logs, base64 blobs).
    public static let maxTextBytes = 1_000_000
    public static let maxEntries = 2_000

    public private(set) var entries: [ClipboardEntry] = []
    public let isPreview: Bool

    private let storage: ClipboardStorage?
    private let now: () -> Date

    /// Loads saved history (dropping anything expired). `storage: nil` keeps it in memory only.
    public init(storage: ClipboardStorage? = .default, now: @escaping () -> Date = Date.init) {
        self.storage = storage
        self.now = now
        self.isPreview = false
        entries = storage?.load() ?? []
        prune()
    }

    /// Fixed entries for SwiftUI previews.
    public init(preview entries: [ClipboardEntry]) {
        self.storage = nil
        self.now = Date.init
        self.isPreview = true
        self.entries = entries
    }

    /// Records a copy. Empty/whitespace-only and oversized texts are ignored.
    /// Copying an existing text again moves it to the top instead of duplicating it.
    @discardableResult
    public func add(_ text: String, sourceAppName: String? = nil, sourceBundleID: String? = nil) -> ClipboardEntry? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= Self.maxTextBytes else { return nil }
        let date = now()
        let entry: ClipboardEntry
        if let index = entries.firstIndex(where: { $0.text == text }) {
            var existing = entries.remove(at: index)
            existing.date = date
            existing.sourceAppName = sourceAppName ?? existing.sourceAppName
            existing.sourceBundleID = sourceBundleID ?? existing.sourceBundleID
            entry = existing
        } else {
            entry = ClipboardEntry(text: text, date: date, sourceAppName: sourceAppName, sourceBundleID: sourceBundleID)
        }
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries { entries.removeLast(entries.count - Self.maxEntries) }
        prune()
        save()
        return entry
    }

    public func remove(id: ClipboardEntry.ID) {
        entries.removeAll { $0.id == id }
        save()
    }

    public func clear() {
        entries = []
        save()
    }

    /// Deletes entries older than 24 hours. Returns how many were removed.
    @discardableResult
    public func prune() -> Int {
        let cutoff = now().addingTimeInterval(-Self.retention)
        let before = entries.count
        entries.removeAll { $0.date < cutoff }
        let removed = before - entries.count
        if removed > 0 { save() }
        return removed
    }

    /// Case- and diacritic-insensitive search over text and source app.
    public func search(_ query: String) -> [ClipboardEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return entries }
        return entries.filter {
            $0.text.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || ($0.sourceAppName?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    /// Re-reads the file (another process changed it, e.g. "Clear" from the main app).
    public func reload() {
        guard let storage else { return }
        entries = storage.load()
        prune()
    }

    private func save() {
        guard let storage, !isPreview else { return }
        storage.save(entries)
    }
}

/// JSON file readable only by the user (0600 in a 0700 folder).
public struct ClipboardStorage: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static let `default` = ClipboardStorage(url: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Monitoring", isDirectory: true)
        .appendingPathComponent("ClipboardHistory.json"))

    public func load() -> [ClipboardEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ClipboardEntry].self, from: data)) ?? []
    }

    public func save(_ entries: [ClipboardEntry]) {
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent()
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        // Write to a private temp file first so the history is never world-readable, even briefly.
        let temp = folder.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if (try? fm.replaceItemAt(url, withItemAt: temp)) == nil {
            try? fm.removeItem(at: temp)
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
