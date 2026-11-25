import AppKit
import Observation
import SwiftUI
import UserNotifications

/// Корневое состояние окна: хранилище, вкладки, очередь передач, тосты.
@MainActor @Observable
final class AppState {
    let store = SessionStore()
    let transfers = TransferQueue()
    let editors = RemoteEditWatcher()
    let snippets = SnippetStore()
    let agent = AgentController()
    @ObservationIgnored private(set) var mcp: MCPServer?
    var tabs: [TerminalSession] = []
    var activeTabID: UUID? {
        didSet { for t in tabs { t.isActiveTab = t.id == activeTabID } }
    }

    var showQuickConnect = false
    var sidebarTab: SidebarTab = .sessions
    /// Ввод с клавиатуры уходит во все подключённые вкладки.
    var multiExec = false
    var focusCommands = 0
    var renamingTab: TerminalSession?
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
        agent.app = self
        let server = MCPServer(agent: agent)
        server.start()
        mcp = server
    }

    var activeTab: TerminalSession? { tabs.first { $0.id == activeTabID } }

    // MARK: - Tabs

    func connect(_ s: Session) {
        if store.session(s.id) != nil { store.touch(s.id) }
        let t = TerminalSession(session: s)
        t.onInput = { [weak self, weak t] data in
            guard let self, let t, self.multiExec else { return }
            for other in self.tabs where other !== t { other.receiveBroadcast(data) }
        }
        t.onDisconnected = { [weak self, weak t] in
            guard let self, let t else { return }
            self.connectionLost(t)
        }
        tabs.append(t)
        activeTabID = t.id
        sidebarTab = .sftp
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
        if tabs.isEmpty {
            multiExec = false
            if sidebarTab == .sftp { sidebarTab = .sessions }
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

    func closeOtherTabs(_ keep: UUID) {
        for t in tabs where t.id != keep { closeTab(t.id) }
    }

    func closeAll() {
        for t in tabs { t.close(masterStillUsed: false) }
        tabs.removeAll()
    }

    func duplicateTab(_ t: TerminalSession) {
        connect(t.session)
        if let n = tabs.last { n.tabColor = t.tabColor }
    }

    func reconnectAll() {
        for t in tabs where t.state == .disconnected { t.reconnect() }
    }

    func focusSessionSearch() {
        sidebarTab = .sessions
        focusSearch += 1
    }

    func showCommands() {
        sidebarTab = .commands
        focusCommands += 1
    }

    // MARK: - Terminal: поиск, вывод, команды

    /// ⌘F: поиск по выводу терминала; без вкладок — поиск сессий.
    func find() {
        if let t = activeTab { t.find(.showFindPanel) } else { focusSessionSearch() }
    }

    func saveOutput() {
        guard let t = activeTab else { return }
        let panel = NSSavePanel()
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(t.session.displayName) \(stamp).log"
        panel.allowedContentTypes = [.plainText, .log]
        panel.allowsOtherFileTypes = true
        let text = t.outputText()
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                do {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                    self?.showToast("Вывод сохранён: \(url.lastPathComponent)", icon: "square.and.arrow.down")
                } catch {
                    self?.showToast(error.localizedDescription, icon: "exclamationmark.triangle", isError: true)
                }
            }
        }
    }

    func useSnippet(_ s: Snippet, execute: Bool) {
        guard let t = activeTab, t.state == .connected else { return }
        snippets.markUsed(s)
        let back = s.cursorBack
        // Через send(), чтобы в multi-exec команда ушла во все вкладки.
        t.send(s.plainCommand + (execute && back == 0 ? "\r" : ""))
        if !execute, back > 0 { t.send(String(repeating: "\u{1B}[D", count: back)) }
        t.focus()
    }

    // MARK: - Обрыв соединения

    private func connectionLost(_ t: TerminalSession) {
        guard tabs.contains(where: { $0 === t }), t.exitCode != 0 else { return }
        let name = t.displayTitle
        if NSApp.isActive {
            if t.id != activeTabID { showToast("Соединение «\(name)» разорвано", icon: "bolt.slash", isError: true) }
            return
        }
        NSApp.requestUserAttention(.informationalRequest)
        let code = t.exitCode.map { " (код \($0))" } ?? ""
        let dest = t.session.destination
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let c = UNMutableNotificationContent()
            c.title = "Соединение разорвано"
            c.body = "\(name) — \(dest)\(code)"
            c.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
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
