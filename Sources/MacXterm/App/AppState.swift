import AppKit
import Observation
import SwiftUI

/// Корневое состояние окна: хранилище, вкладки, очередь передач, тосты.
@MainActor @Observable
final class AppState {
    let store = SessionStore()
    let transfers = TransferQueue()
    let editors = RemoteEditWatcher()
    var tabs: [TerminalSession] = []
    var activeTabID: UUID? {
        didSet { for t in tabs { t.isActiveTab = t.id == activeTabID } }
    }

    var showQuickConnect = false
    var editorTarget: EditorTarget?
    var focusSearch = 0
    var toast: Toast?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    struct EditorTarget: Identifiable {
        let id = UUID()
        var session: Session
        var isNew: Bool
    }

    init() {
        editors.transfers = transfers
        editors.onUploaded = { [weak self] name in self?.showToast("Загружено: \(name)", icon: "checkmark.icloud") }
        editors.onError = { [weak self] msg in self?.showToast(msg, icon: "exclamationmark.triangle", isError: true) }
        transfers.onError = { [weak self] msg in self?.showToast(msg, icon: "exclamationmark.triangle", isError: true) }
    }

    var activeTab: TerminalSession? { tabs.first { $0.id == activeTabID } }

    // MARK: - Tabs

    func connect(_ s: Session) {
        if store.session(s.id) != nil { store.touch(s.id) }
        let t = TerminalSession(session: s)
        tabs.append(t)
        activeTabID = t.id
        t.start()
    }

    func connect(sessionID: UUID) {
        if let s = store.session(sessionID) { connect(s) }
    }

    func closeTab(_ id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let t = tabs[idx]
        let shared = tabs.contains { $0.id != id && $0.session.connectionKey == t.session.connectionKey && $0.state != .disconnected }
        t.close(masterStillUsed: shared)
        tabs.remove(at: idx)
        if activeTabID == id {
            activeTabID = tabs.isEmpty ? nil : tabs[min(idx, tabs.count - 1)].id
        }
    }

    func closeActiveTabOrWindow() {
        if let id = activeTabID { closeTab(id) } else { NSApp.keyWindow?.performClose(nil) }
    }

    func selectTab(index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeTabID = tabs[index].id
    }

    func selectAdjacentTab(_ delta: Int) {
        guard !tabs.isEmpty, let i = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        activeTabID = tabs[(i + delta + tabs.count) % tabs.count].id
    }

    func moveTab(_ id: UUID, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }), from != index else { return }
        let t = tabs.remove(at: from)
        tabs.insert(t, at: min(index, tabs.count))
    }

    func closeAll() {
        for t in tabs { t.close(masterStillUsed: false) }
        tabs.removeAll()
    }

    // MARK: - Settings

    func applyTerminalSettings() { tabs.forEach { $0.applySettings() } }

    func applyStatsSettings() { tabs.forEach { $0.restartStats() } }

    func changeFontSize(_ delta: Double) {
        let d = UserDefaults.standard
        let v = delta == 0 ? 13 : max(8, min(32, d.double(forKey: Prefs.fontSize) + delta))
        d.set(v, forKey: Prefs.fontSize)
        applyTerminalSettings()
    }

    // MARK: - Sessions

    func newSession(folder: UUID? = nil) {
        editorTarget = EditorTarget(session: Session(name: "", host: "", folderId: folder), isNew: true)
    }

    func edit(_ id: UUID) {
        if let s = store.session(id) { editorTarget = EditorTarget(session: s, isNew: false) }
    }

    func copySSHCommand(_ id: UUID) {
        guard let s = store.session(id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(SSHCommandBuilder.shellCommand(s), forType: .string)
        showToast("Команда скопирована", icon: "doc.on.doc")
    }

    // MARK: - Toast

    func showToast(_ text: String, icon: String = "checkmark.circle", isError: Bool = false) {
        toast = Toast(text: text, icon: icon, isError: isError)
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(isError ? 4 : 2.5))
            guard !Task.isCancelled else { return }
            withAnimation { self?.toast = nil }
        }
    }
}
