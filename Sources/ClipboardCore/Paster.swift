import AppKit
import ApplicationServices

/// Pastes into the app that was frontmost before the history panel opened.
@MainActor
public enum Paster {
    /// Auto-paste needs Accessibility permission (to send ⌘V). Without it, the
    /// text is only copied and the user presses ⌘V.
    public static var canAutoPaste: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that adds this app to Accessibility settings.
    public static func requestAutoPastePermission() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Re-activates `app` and sends ⌘V to it once it's frontmost.
    public static func paste(into app: NSRunningApplication?) {
        guard canAutoPaste else { return }
        app?.activate()
        // Give the target app a moment to become key before the keystroke arrives.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let source = CGEventSource(stateID: .combinedSessionState)
            let keyV = CGKeyCode(0x09)
            let down = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cgAnnotatedSessionEventTap)
            up?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}
