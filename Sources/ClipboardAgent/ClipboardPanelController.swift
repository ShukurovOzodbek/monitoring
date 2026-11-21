import AppKit
import ClipboardCore
import ClipboardUI
import SwiftUI

/// Floating panel that shows the history over whatever app is in front,
/// on every Space and over full-screen apps, like Spotlight.
@MainActor
final class ClipboardPanelController: NSObject, NSWindowDelegate {
    private let history: ClipboardHistory
    private let onPick: (ClipboardEntry, NSRunningApplication?) -> Void
    private var panel: KeyablePanel?
    /// The app to paste into: whatever was frontmost when ⌥V was pressed.
    private var targetApp: NSRunningApplication?

    init(history: ClipboardHistory, onPick: @escaping (ClipboardEntry, NSRunningApplication?) -> Void) {
        self.history = history
        self.onPick = onPick
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { targetApp = front }
        history.prune()

        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Fresh view each time: search cleared, selection on the newest entry.
        panel.contentView = NSHostingView(rootView: ClipboardPanelView(
            history: history,
            canAutoPaste: Paster.canAutoPaste,
            onPick: { [weak self] entry in self?.pick(entry) },
            onDelete: { [weak self] entry in self?.history.remove(id: entry.id) },
            onClose: { [weak self] in self?.hide() },
            onEnableAutoPaste: { Paster.requestAutoPastePermission() }
        ))
        position(panel)
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func pick(_ entry: ClipboardEntry) {
        hide()
        onPick(entry, targetApp)
    }

    private func makePanel() -> KeyablePanel {
        let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                                 styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                                 backing: .buffered, defer: true)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { panel.standardWindowButton($0)?.isHidden = true }
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.delegate = self
        return panel
    }

    /// Centered horizontally on the screen with the mouse, slightly above the middle.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                     y: visible.midY - size.height / 2 + visible.height * 0.1))
    }

    // Clicking anywhere else closes it, like Spotlight.
    func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}

/// Borderless-style panels can't become key by default; the search field needs it.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
