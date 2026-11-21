import ClipboardCore
import SwiftUI

// Placeholder; Codex builds the real panel UI here. Keep this initializer's signature.
public struct ClipboardPanelView: View {
    let history: ClipboardHistory
    let canAutoPaste: Bool
    let onPick: (ClipboardEntry) -> Void
    let onDelete: (ClipboardEntry) -> Void
    let onClose: () -> Void
    let onEnableAutoPaste: () -> Void

    public init(history: ClipboardHistory, canAutoPaste: Bool, onPick: @escaping (ClipboardEntry) -> Void,
                onDelete: @escaping (ClipboardEntry) -> Void, onClose: @escaping () -> Void,
                onEnableAutoPaste: @escaping () -> Void) {
        self.history = history
        self.canAutoPaste = canAutoPaste
        self.onPick = onPick
        self.onDelete = onDelete
        self.onClose = onClose
        self.onEnableAutoPaste = onEnableAutoPaste
    }

    public var body: some View {
        List(history.entries) { entry in
            Button(entry.title) { onPick(entry) }
        }
        .frame(width: 560, height: 520)
    }
}
