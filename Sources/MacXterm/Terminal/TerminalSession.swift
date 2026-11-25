import AppKit
import Observation
import SwiftTerm

enum ConnectionState: Sendable { case connecting, connected, disconnected }

/// Вкладка: владеет NSView терминала (живёт дольше SwiftUI-представлений), процессом ssh и SFTP-моделью.
@MainActor @Observable
final class TerminalSession: Identifiable {
    let id = UUID()
    private(set) var session: Session
    var state: ConnectionState = .connecting { didSet { if oldValue != state { updateStats() } } }
    /// Вкладка выбрана в окне — только для неё работает монитор сервера.
    var isActiveTab = false { didSet { if oldValue != isActiveTab { updateStats() } } }
    var title: String
    var exitCode: Int32?
    @ObservationIgnored let view: MXTerminalView
    let fs: RemoteFS
    let stats: StatsPoller
    @ObservationIgnored private var masterTask: Task<Void, Never>?
    @ObservationIgnored private var osc7Installed = false
    @ObservationIgnored var onConnected: (() -> Void)?

    init(session: Session) {
        self.session = session
        self.title = session.displayName
        self.view = MXTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        self.fs = RemoteFS(session: session)
        self.stats = StatsPoller(session: session)
        view.owner = self
        view.processDelegate = self
        fs.terminal = self
        view.installMouseMonitor()
        applySettings()
    }

    func start() {
        state = .connecting
        exitCode = nil
        osc7Installed = false
        let env = SSHCommandBuilder.environment(session).map { "\($0.key)=\($0.value)" }
        view.startProcess(executable: SSHCommandBuilder.ssh, args: SSHCommandBuilder.terminalArgs(session),
                          environment: env, execName: "ssh", currentDirectory: NSHomeDirectory())
        masterTask?.cancel()
        let s = session
        masterTask = Task { [weak self] in
            let ok = await ControlMaster.waitReady(s)
            guard let self, !Task.isCancelled, self.state == .connecting else { return }
            if ok {
                self.state = .connected
                self.fs.connectionReady()
                self.onConnected?()
            } else {
                self.fs.connectionFailed("Не удалось дождаться входа в терминале")
            }
        }
    }

    func reconnect() {
        guard state == .disconnected else { return }
        view.feed(text: "\r\n\u{1B}[2m— переподключение —\u{1B}[0m\r\n")
        start()
    }

    /// Закрывает процесс; мастер гасим, только если его больше никто не использует.
    func close(masterStillUsed: Bool) {
        masterTask?.cancel()
        stats.stop()
        fs.shutdown()
        if state != .disconnected { view.terminate() }
        view.teardown()
        if !masterStillUsed { ControlMaster.exit(session) }
    }

    func send(_ text: String) { view.send(txt: text) }

    /// Монитор работает только пока вкладка активна и подключена; новое подключение сбрасывает историю.
    func updateStats() {
        switch state {
        case .connecting: stats.reset()
        case .connected: isActiveTab ? stats.start() : stats.stop()
        case .disconnected: stats.stop()
        }
    }

    /// Перезапуск после смены настроек монитора.
    func restartStats() {
        stats.stop()
        updateStats()
    }

    func focus() { view.window?.makeFirstResponder(view) }

    func clear() {
        view.getTerminal().resetToInitialState()
        view.needsDisplay = true
        if state == .connected || state == .connecting { send("\u{0C}") }
    }

    func applySettings() {
        let theme = Prefs.currentTheme
        view.font = Prefs.font
        view.installColors(theme.ansi)
        view.nativeBackgroundColor = theme.background
        view.nativeForegroundColor = theme.foreground
        view.caretColor = theme.cursor
        view.selectedTextBackgroundColor = theme.selection
        view.layer?.backgroundColor = theme.background.cgColor
        let d = UserDefaults.standard
        view.copyOnSelect = d.bool(forKey: Prefs.copyOnSelect)
        view.pasteOnRightClick = d.bool(forKey: Prefs.pasteOnRightClick)
    }

    // MARK: - Follow terminal (OSC 7)

    /// Однократно подсовываем bash/zsh хук, печатающий OSC 7 с текущим каталогом.
    func installOSC7Hook() {
        guard !osc7Installed, state == .connected else { return }
        osc7Installed = true
        let hook = #" __mx7(){ printf '\033]7;file://%s%s\007' "${HOSTNAME:-$HOST}" "$PWD"; }; if [ -n "$ZSH_VERSION" ]; then precmd_functions+=(__mx7); elif [ -n "$BASH_VERSION" ]; then PROMPT_COMMAND="__mx7${PROMPT_COMMAND:+;$PROMPT_COMMAND}"; fi; clear"#
        send(hook + "\r")
    }

    static func path(fromOSC7 s: String) -> String? {
        var rest = Substring(s)
        if rest.hasPrefix("file://") {
            rest = rest.dropFirst(7)
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            rest = rest[slash...]
        }
        guard rest.hasPrefix("/") else { return nil }
        let raw = String(rest)
        return raw.removingPercentEncoding ?? raw
    }

    func cdInTerminal(_ path: String) {
        send(" cd \(SSHCommandBuilder.quote(path))\r")
        focus()
    }
}

extension TerminalSession: @preconcurrency LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        let t = title.trimmingCharacters(in: .whitespaces)
        self.title = t.isEmpty ? session.displayName : t
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let d = directory, let p = Self.path(fromOSC7: d) else { return }
        fs.terminalDirectoryChanged(p)
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        masterTask?.cancel()
        self.exitCode = exitCode.map { $0 > 255 ? ($0 >> 8) & 0xFF : $0 }
        state = .disconnected
        fs.connectionLost()
    }
}

/// Терминал с опциями copy-on-select / paste-on-right-click и клавишей R для переподключения.
final class MXTerminalView: LocalProcessTerminalView {
    weak var owner: TerminalSession?
    var copyOnSelect = false
    var pasteOnRightClick = false

    private var mouseUpMonitor: Any?

    /// mouseUp в SwiftTerm не open, поэтому copy-on-select ловим локальным монитором событий.
    func installMouseMonitor() {
        guard mouseUpMonitor == nil else { return }
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            if let self, self.copyOnSelect, event.window === self.window, self.window != nil {
                DispatchQueue.main.async {
                    if self.selectionActive, self.window?.firstResponder === self { self.copy(self) }
                }
            }
            return event
        }
    }

    func teardown() {
        if let m = mouseUpMonitor { NSEvent.removeMonitor(m) }
        mouseUpMonitor = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        if pasteOnRightClick { paste(self) } else { super.rightMouseDown(with: event) }
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if let owner, owner.state == .disconnected {
            if data.count == 1, data.first == UInt8(ascii: "r") || data.first == UInt8(ascii: "R") {
                owner.reconnect()
            }
            return
        }
        super.send(source: source, data: data)
    }
}
