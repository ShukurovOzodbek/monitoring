import AppKit
import Foundation
import Testing
@testable import ClipboardCore

/// Mutable clock for expiry tests.
@MainActor
final class TestClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(hours: Double) { now = now.addingTimeInterval(hours * 3600) }
}

@Suite("Clipboard history")
@MainActor
struct ClipboardHistoryTests {
    func tempStorage() -> ClipboardStorage {
        ClipboardStorage(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-test-\(UUID().uuidString)/history.json"))
    }

    @Test func addsNewestFirstAndDeduplicates() {
        let clock = TestClock()
        let history = ClipboardHistory(storage: nil, now: { clock.now })
        history.add("first")
        clock.advance(hours: 1)
        history.add("second", sourceAppName: "Safari")
        clock.advance(hours: 1)
        history.add("first")
        #expect(history.entries.map(\.text) == ["first", "second"])
        #expect(history.entries[0].date == clock.now, "re-copy refreshes the date")
        #expect(history.add("   \n ") == nil, "whitespace is ignored")
        #expect(history.add(String(repeating: "x", count: ClipboardHistory.maxTextBytes + 1)) == nil)
        #expect(history.entries.count == 2)
    }

    @Test func expiresAfter24Hours() {
        let clock = TestClock()
        let history = ClipboardHistory(storage: nil, now: { clock.now })
        history.add("old")
        clock.advance(hours: 23)
        history.add("recent")
        clock.advance(hours: 1.01) // "old" is now just over 24 h
        #expect(history.prune() == 1)
        #expect(history.entries.map(\.text) == ["recent"])
        clock.advance(hours: 24)
        history.prune()
        #expect(history.entries.isEmpty)
    }

    @Test func persistsPrivatelyAndDropsExpiredOnLoad() throws {
        let clock = TestClock()
        let storage = tempStorage()
        defer { try? FileManager.default.removeItem(at: storage.url.deletingLastPathComponent()) }
        let history = ClipboardHistory(storage: storage, now: { clock.now })
        history.add("keep me", sourceAppName: "Notes", sourceBundleID: "com.apple.Notes")
        history.add("expire me")

        let attributes = try FileManager.default.attributesOfItem(atPath: storage.url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "history file must be private")

        let reloaded = ClipboardHistory(storage: storage, now: { clock.now })
        #expect(reloaded.entries.map(\.text) == ["expire me", "keep me"])
        #expect(reloaded.entries[1].sourceBundleID == "com.apple.Notes")

        // Simulate the agent being off for a day: entries expire on next launch.
        clock.advance(hours: 25)
        let afterADay = ClipboardHistory(storage: storage, now: { clock.now })
        #expect(afterADay.entries.isEmpty)
        #expect(storage.load().isEmpty, "expired entries are deleted from disk too")
    }

    @Test func searchAndRemove() {
        let history = ClipboardHistory(storage: nil)
        history.add("git commit -m 'Fix'", sourceAppName: "Ghostty")
        history.add("Привет мир")
        history.add("café menu")
        #expect(history.search("CAFE").map(\.text) == ["café menu"])
        #expect(history.search("ghostty").count == 1)
        #expect(history.search("мир").count == 1)
        #expect(history.search("  ").count == 3)
        history.remove(id: history.entries[0].id)
        #expect(history.entries.count == 2)
        history.clear()
        #expect(history.entries.isEmpty)
    }

    @Test func entryTitleSkipsBlankLines() {
        let entry = ClipboardEntry(text: "\n\n   hello world  \nsecond", date: Date())
        #expect(entry.title == "hello world")
        #expect(entry.lineCount == 2)
    }
}

@Suite("Pasteboard watcher")
@MainActor
struct PasteboardWatcherTests {
    @Test func recordsTextSkipsConcealedAndOwnWrites() {
        let board = NSPasteboard(name: NSPasteboard.Name("monitoring-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        var recorded: [String] = []
        let watcher = PasteboardWatcher(pasteboard: board) { text, _ in recorded.append(text) }

        board.clearContents()
        board.setString("hello", forType: .string)
        watcher.check()
        watcher.check() // no change -> no duplicate callback
        #expect(recorded == ["hello"])

        // Password managers mark secrets as concealed.
        board.clearContents()
        board.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
        board.setString("hunter2", forType: .string)
        watcher.check()
        #expect(recorded == ["hello"], "concealed copies must not be recorded")

        // Picking an entry writes to the pasteboard; that must not echo back as a copy.
        watcher.write("from history")
        watcher.check()
        #expect(recorded == ["hello"])
        #expect(board.string(forType: .string) == "from history")

        // Non-text content is ignored.
        board.clearContents()
        board.setData(Data([1, 2, 3]), forType: .png)
        watcher.check()
        #expect(recorded == ["hello"])
    }
}

@Suite("Clipboard agent installer")
struct ClipboardInstallerTests {
    @Test func plistKeepsAgentAliveAndStartsAtLogin() {
        let plist = ClipboardAgentInstaller.plist(executable: URL(fileURLWithPath: "/tmp/agent"))
        #expect(plist["Label"] as? String == "com.ozodbek.monitoring.clipboard")
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["KeepAlive"] as? Bool == true, "must restart even after a normal quit")
        #expect(plist["ProgramArguments"] as? [String] == ["/tmp/agent"])
        #expect(plist["LimitLoadToSessionType"] as? String == "Aqua")
    }
}
