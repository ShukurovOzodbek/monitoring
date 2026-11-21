import AppKit
import ClipboardCore
import SwiftUI
import UniformTypeIdentifiers

public struct ClipboardPanelView: View {
    let history: ClipboardHistory
    let canAutoPaste: Bool
    let onPick: (ClipboardEntry) -> Void
    let onDelete: (ClipboardEntry) -> Void
    let onClose: () -> Void
    let onEnableAutoPaste: () -> Void

    @State private var query = ""
    @State private var selection = 0
    @State private var keyMonitor: Any?
    @FocusState private var searchFocused: Bool

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
        let entries = history.search(query)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search clipboard history", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                    .onSubmit { _ = handleKey(.return, command: false) }
                if !query.isEmpty {
                    Button { query = ""; searchFocused = true } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(18)
            Divider()
            if entries.isEmpty {
                ContentUnavailableView(
                    history.entries.isEmpty ? "No clipboard history yet" : "No search results",
                    systemImage: history.entries.isEmpty ? "doc.on.clipboard" : "magnifyingglass",
                    description: Text(history.entries.isEmpty
                                      ? "Copy some text to see it here."
                                      : "Try another search.")
                )
                .frame(maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    results(entries)
                        .frame(width: 268)
                    Divider()
                    preview(entries[min(selection, entries.count - 1)])
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 520)
        .background(.regularMaterial, in: .rect(cornerRadius: 18))
        .clipShape(.rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(.primary.opacity(0.13))
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat]) { press in
            let modifiers = press.modifiers.intersection([.command, .shift, .control, .option])
            guard modifiers.isEmpty || modifiers == .command else { return .ignored }
            return handleKey(press.key, command: modifiers == .command) ? .handled : .ignored
        }
        .onChange(of: query) { selection = 0 }
        .onChange(of: entries.count) { _, count in
            selection = min(selection, max(0, count - 1))
        }
        .onAppear {
            searchFocused = true
            if !history.isPreview, keyMonitor == nil {
                installFieldEditorShortcuts()
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    private func results(_ entries: [ClipboardEntry]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        Button {
                            selection = index
                        } label: {
                            row(entry, index: index)
                        }
                        .buttonStyle(.plain)
                        .onTapGesture(count: 2) { onPick(entry) }
                        .accessibilityAddTraits(index == selection ? .isSelected : [])
                        .id(entry.id)
                    }
                }
                .padding(8)
            }
            .onChange(of: entries[min(selection, entries.count - 1)].id) { _, id in
                proxy.scrollTo(id)
            }
        }
    }

    private func row(_ entry: ClipboardEntry, index: Int) -> some View {
        let title = entry.title
        return HStack(spacing: 8) {
            SourceIcons.image(for: entry.sourceBundleID)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(looksLikeCode(title) ? .body.monospaced() : .body)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(entry.sourceAppName ?? "Unknown app").lineLimit(1)
                    Text("·")
                    Text(entry.date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                        .fixedSize()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if entry.lineCount > 1 {
                Text("+\(entry.lineCount - 1) lines")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(.primary.opacity(0.07), in: .capsule)
                    .fixedSize()
            }
            if index < 9 {
                Text("\(index + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                    .accessibilityLabel("Command \(index + 1)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
        .contentShape(.rect)
        .background(index == selection ? Color.accentColor.opacity(0.20) : .clear,
                    in: .rect(cornerRadius: 8))
    }

    private func preview(_ entry: ClipboardEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(entry.text.count.formatted()) characters")
                    .font(.subheadline.weight(.semibold))
                Text(entry.date, format: .dateTime.year().month().day().hour().minute().second())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                Text(verbatim: entry.text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .id(entry.id)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !canAutoPaste {
                HStack(spacing: 12) {
                    Text("Return copies the item. Press ⌘V to paste it.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Enable auto-paste", action: onEnableAutoPaste)
                }
            }
            HStack {
                Text("Return to paste · ⌘1–9 quick pick · Esc to close")
                Spacer()
                Text("History is kept for 24 hours")
            }
            .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func handleKey(_ key: KeyEquivalent, command: Bool) -> Bool {
        handleKey(key, command: command, query: query, selection: $selection)
    }

    private func handleKey(_ key: KeyEquivalent, command: Bool, query: String, selection: Binding<Int>) -> Bool {
        if !command && key == .escape {
            onClose()
            return true
        }
        let entries = history.search(query)
        if command {
            if key == .delete {
                if entries.indices.contains(selection.wrappedValue) { onDelete(entries[selection.wrappedValue]) }
                return true
            }
            if let number = key.character.wholeNumberValue, (1...9).contains(number) {
                if entries.indices.contains(number - 1) { onPick(entries[number - 1]) }
                return true
            }
        } else {
            switch key {
            case .upArrow:
                selection.wrappedValue = max(0, selection.wrappedValue - 1)
                return true
            case .downArrow:
                selection.wrappedValue = min(selection.wrappedValue + 1, max(0, entries.count - 1))
                return true
            case .return:
                if entries.indices.contains(selection.wrappedValue) { onPick(entries[selection.wrappedValue]) }
                return true
            default: break
            }
        }
        return false
    }

    // The AppKit field editor consumes editing commands before SwiftUI can see them.
    private func installFieldEditorShortcuts() {
        // Read focus and selection through their bindings so the monitor follows view updates.
        let focused = $searchFocused
        let query = $query
        let selection = $selection
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated {
                guard focused.wrappedValue,
                      let editor = event.window?.firstResponder as? NSTextView,
                      editor.isFieldEditor, !editor.hasMarkedText() else { return false }
                let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
                guard modifiers.isEmpty || modifiers == .command else { return false }
                let key: KeyEquivalent
                switch event.keyCode {
                case 125: key = .downArrow
                case 126: key = .upArrow
                case 36, 76: key = .return
                case 53: key = .escape
                case 51: key = .delete
                default:
                    guard modifiers == .command,
                          let character = event.charactersIgnoringModifiers?.first,
                          character.isASCII, character.isNumber else { return false }
                    key = KeyEquivalent(character)
                }
                return handleKey(key, command: modifiers == .command,
                                 query: query.wrappedValue, selection: selection)
            }
            return handled ? nil : event
        }
    }

    private func looksLikeCode(_ title: String) -> Bool {
        let prefixes = ["$ ", "> ", "#!", "func ", "let ", "var ", "import ", "class ",
                        "struct ", "def ", "const ", "git ", "swift ", "npm ", "cd ", "sudo ",
                        "curl ", "ls ", "python ", "docker ", "./", "SELECT "]
        return prefixes.contains { title.hasPrefix($0) }
            || title.hasSuffix("{") || title.hasSuffix(";")
    }
}

@MainActor
private enum SourceIcons {
    private static var cache: [String: NSImage] = [:]

    static func image(for bundleID: String?) -> Image {
        guard let bundleID else { return Image(systemName: "app") }
        if let icon = cache[bundleID] { return Image(nsImage: icon).resizable() }

        let workspace = NSWorkspace.shared
        let icon = workspace.urlForApplication(withBundleIdentifier: bundleID)
            .map { workspace.icon(forFile: $0.path) }
            ?? workspace.icon(for: .application)
        cache[bundleID] = icon
        return Image(nsImage: icon).resizable()
    }
}

#if DEBUG && !MONITORING_SKIP_PREVIEWS
#Preview("Clipboard History") {
    let now = Date.now
    ClipboardPanelView(history: ClipboardHistory(preview: [
        ClipboardEntry(text: "func greet() {\n    print(\"Hello\")\n}", date: now.addingTimeInterval(-120),
                       sourceAppName: "Xcode", sourceBundleID: "com.apple.dt.Xcode"),
        ClipboardEntry(text: "https://developer.apple.com/swift/", date: now.addingTimeInterval(-300),
                       sourceAppName: "Safari", sourceBundleID: "com.apple.Safari"),
        ClipboardEntry(text: "Packing list\nNotebook\nLaptop charger", date: now.addingTimeInterval(-1200),
                       sourceAppName: "Notes", sourceBundleID: "com.apple.Notes"),
        ClipboardEntry(text: "Привет, мир!", date: now.addingTimeInterval(-3600),
                       sourceAppName: "Messages", sourceBundleID: "com.apple.MobileSMS"),
        ClipboardEntry(text: "git status --short", date: now.addingTimeInterval(-6200),
                       sourceAppName: "Terminal", sourceBundleID: "com.apple.Terminal")
    ]), canAutoPaste: false, onPick: { _ in }, onDelete: { _ in }, onClose: {}, onEnableAutoPaste: {})
}

#Preview("Empty Clipboard History") {
    ClipboardPanelView(history: ClipboardHistory(preview: []), canAutoPaste: true,
                       onPick: { _ in }, onDelete: { _ in }, onClose: {}, onEnableAutoPaste: {})
}
#endif
