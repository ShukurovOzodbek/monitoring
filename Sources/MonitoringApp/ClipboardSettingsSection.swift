import ClipboardCore
import SwiftUI

actor ClipboardAgentService {
    static let shared = ClipboardAgentService()

    func ensureInstalled() {
        ClipboardAgentInstaller.ensureInstalled()
    }

    func snapshot() -> (status: ClipboardAgentInstaller.Status, enabled: Bool) {
        (ClipboardAgentInstaller.status(), !ClipboardAgentInstaller.isDisabledByUser)
    }

    func setEnabled(_ enabled: Bool) throws {
        let previous = ClipboardAgentInstaller.isDisabledByUser
        do {
            try ClipboardAgentInstaller.setEnabled(enabled)
        } catch {
            ClipboardAgentInstaller.isDisabledByUser = previous
            throw error
        }
    }

    static func showPanel() {
        post(ClipboardMessages.showPanel)
    }

    static func clearHistory() {
        post(ClipboardMessages.clear)
    }

    private static func post(_ name: Notification.Name) {
        DistributedNotificationCenter.default().postNotificationName(
            name, object: nil, userInfo: nil, deliverImmediately: true
        )
    }
}

struct ClipboardSettingsSection: View {
    let isPreview: Bool

    @State private var status: ClipboardAgentInstaller.Status?
    @State private var enabled = false
    @State private var updating = false
    @State private var revision = 0
    @State private var confirmClear = false
    @State private var errorMessage: String?

    var body: some View {
        Section("Clipboard") {
            LabeledContent("Status", value: statusText)
            Toggle("Enabled", isOn: Binding(get: { isPreview || enabled }, set: { changeEnabled($0) }))
                .disabled(isPreview || status == nil || updating)
            Button("Open Clipboard History (⌥V)") { ClipboardAgentService.showPanel() }
                .disabled(isPreview || !isRunning || updating)
            Button("Clear History…", role: .destructive) { confirmClear = true }
                .disabled(isPreview || !isRunning || updating)
            Text("When enabled, clipboard history starts at login, keeps running after Monitoring quits, and is unaffected by Swift Quit. The ⌥V shortcut replaces typing “√”.")
                .foregroundStyle(.secondary)
            Text("History stores text only and skips copies marked private by password managers. It keeps entries for 24 hours on this Mac in ~/Library/Application Support/Monitoring, readable only by you.")
                .foregroundStyle(.secondary)
        }
        .task {
            guard !isPreview else { return }
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .confirmationDialog("Clear clipboard history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { ClipboardAgentService.clearHistory() }
        } message: {
            Text("This removes all saved clipboard entries.")
        }
        .alert("Couldn’t change clipboard history", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var statusText: String {
        switch status {
        case .running(let pid): "Running (PID \(pid))"
        case .installedNotRunning: "Installed but not running"
        case .notInstalled: "Not installed"
        case nil: isPreview ? "Running (PID 142)" : "Checking…"
        }
    }

    private var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    private func refresh() async {
        let currentRevision = revision
        let snapshot = await ClipboardAgentService.shared.snapshot()
        guard !Task.isCancelled, currentRevision == revision, !updating else { return }
        status = snapshot.status
        enabled = snapshot.enabled
    }

    private func changeEnabled(_ value: Bool) {
        guard !updating else { return }
        updating = true
        revision += 1
        enabled = value
        Task {
            do {
                try await ClipboardAgentService.shared.setEnabled(value)
            } catch {
                errorMessage = error.localizedDescription
            }
            let snapshot = await ClipboardAgentService.shared.snapshot()
            revision += 1
            status = snapshot.status
            enabled = snapshot.enabled
            updating = false
        }
    }
}
