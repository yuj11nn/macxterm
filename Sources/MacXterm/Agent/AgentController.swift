import AppKit
import Observation

/// Агент: инструменты MCP поверх сессий MacXterm, подтверждение опасных действий и журнал.
@MainActor @Observable
final class AgentController {
    enum Status: Equatable {
        case waiting, running, ok, failed(String), denied
    }

    struct Entry: Identifiable {
        let id = UUID()
        let date = Date()
        let tool: String
        let target: String
        let detail: String
        var status: Status = .running
        var output = ""
    }

    static let enabledKey = "agentEnabled"
    static let confirmKey = "agentConfirm"
    /// Есть подключённые MCP-клиенты: приложение не закрывается вместе с последним окном.
    static var hasClients = false

    var entries: [Entry] = []
    var clientCount = 0 { didSet { Self.hasClients = clientCount > 0 } }
    var clientName: String?
    @ObservationIgnored weak var app: AppState?
    @ObservationIgnored private var trusted: Set<UUID> = []
    @ObservationIgnored private var approvalChain: Task<Void, Never>?

    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
    var confirm: Bool { UserDefaults.standard.bool(forKey: Self.confirmKey) }
    var displayClient: String { clientName ?? "Агент" }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [enabledKey: false, confirmKey: true])
    }

    func clearLog() { entries.removeAll { $0.status != .running && $0.status != .waiting } }
    func revokeTrust() { trusted.removeAll() }

    // MARK: - Вызов инструмента

    struct ToolResult {
        var text: String
        var isError = false
    }

    func call(_ name: String, _ args: [String: Any]) async -> ToolResult {
        guard enabled else {
            return ToolResult(text: "Agent access is turned off in MacXterm. Ask the user to enable it: MacXterm → Settings → Agent (or the «Агент» sidebar tab).", isError: true)
        }
        do {
            switch name {
            case "list_sessions": return ToolResult(text: listSessions())
            case "connect": return try await connect(args)
            case "run_command": return try await runCommand(args)
            case "terminal_send": return try await terminalSend(args)
            case "terminal_read": return try await terminalRead(args)
            case "list_directory": return try await listDirectory(args)
            case "read_file": return try await readFile(args)
            case "write_file": return try await writeFile(args)
            default: return ToolResult(text: "Unknown tool: \(name)", isError: true)
            }
        } catch {
            return ToolResult(text: error.localizedDescription, isError: true)
        }
    }

    // MARK: - Инструменты

    private func listSessions() -> String {
        guard let app else { return "{}" }
        let tabs: [[String: Any]] = app.tabs.map { t in
            ["name": t.title, "session": t.session.displayName, "host": t.session.destination + ":\(t.session.port)",
             "state": "\(t.state)", "active": t.id == app.activeTabID]
        }
        let saved: [[String: Any]] = app.store.sessions.map { s in
            var d: [String: Any] = ["name": s.displayName, "host": s.host, "port": s.port, "auth": s.authType.rawValue]
            if !s.user.isEmpty { d["user"] = s.user }
            if let f = s.folderId, let folder = app.store.folders.first(where: { $0.id == f }) { d["folder"] = folder.name }
            return d
        }
        return Self.json(["open_tabs": tabs, "saved_sessions": saved,
                          "hint": "Pass a saved session name, an open tab name or user@host[:port] as `session`."])
    }

    private func connect(_ args: [String: Any]) async throws -> ToolResult {
        let tab = try await ensureConnected(try Self.string(args, "session"), newTab: args["new_tab"] as? Bool ?? false)
        return ToolResult(text: "Connected to \(tab.session.displayName) (\(tab.session.destination)). The tab is open in MacXterm.")
    }

    private func runCommand(_ args: [String: Any]) async throws -> ToolResult {
        let command = try Self.string(args, "command")
        let timeout = min(max(Self.number(args, "timeout_seconds") ?? 120, 1), 1800)
        let tab = try await ensureConnected(try Self.string(args, "session"))
        var full = command
        if let cwd = args["cwd"] as? String, !cwd.isEmpty { full = "cd \(Self.shellPath(cwd)) && \(command)" }
        let idx = log("run_command", tab, command)
        guard await approve(idx, tab: tab, title: "выполнить команду", detail: command) else { return denied(idx) }
        return try await working(tab) {
            let r = try await SSHRunner(session: tab.session).run(full, timeout: timeout)
            var text = "exit_code: \(r.timedOut ? "timeout after \(Int(timeout))s" : String(r.code))\n"
            let out = String(decoding: r.out, as: UTF8.self), err = String(decoding: r.err, as: UTF8.self)
            if !out.isEmpty { text += "[stdout]\n" + Self.truncate(out, 40_000) + "\n" }
            if !err.isEmpty { text += "[stderr]\n" + Self.truncate(err, 20_000) + "\n" }
            if out.isEmpty && err.isEmpty { text += "(no output)\n" }
            finish(idx, r.code == 0 && !r.timedOut ? .ok : .failed(r.timedOut ? "таймаут" : "код \(r.code)"), text)
            return ToolResult(text: text)
        }
    }

    private func terminalSend(_ args: [String: Any]) async throws -> ToolResult {
        let text = try Self.string(args, "text")
        let enter = args["enter"] as? Bool ?? true
        let waitMs = min(max(Self.number(args, "wait_ms") ?? 1500, 0), 30_000)
        let tab = try await ensureConnected(try Self.string(args, "session"))
        let idx = log("terminal_send", tab, text.replacingOccurrences(of: "\u{3}", with: "^C"))
        guard await approve(idx, tab: tab, title: "ввести в терминал", detail: text) else { return denied(idx) }
        return await working(tab) {
            app?.activeTabID = tab.id
            tab.sendInternal(text + (enter ? "\r" : ""))
            try? await Task.sleep(for: .milliseconds(Int(waitMs)))
            let screen = Self.lastLines(tab.outputText(), 40)
            finish(idx, .ok, screen)
            return ToolResult(text: "Sent. Terminal now shows (last 40 lines):\n" + screen)
        }
    }

    private func terminalRead(_ args: [String: Any]) async throws -> ToolResult {
        let lines = Int(min(max(Self.number(args, "lines") ?? 60, 1), 2000))
        let tab = try findTab(try Self.string(args, "session"))
        return ToolResult(text: Self.lastLines(tab.outputText(), lines))
    }

    private func listDirectory(_ args: [String: Any]) async throws -> ToolResult {
        let path = (args["path"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "~"
        let tab = try await ensureConnected(try Self.string(args, "session"))
        let idx = log("list_directory", tab, path)
        return try await working(tab) {
            let r = try await SSHRunner(session: tab.session)
                .run("sh -s", stdin: Data("cd \(Self.shellPath(path)) && pwd && LC_ALL=C ls -la\n".utf8), timeout: 30)
            let text = String(decoding: r.out, as: UTF8.self) + String(decoding: r.err, as: UTF8.self)
            finish(idx, r.code == 0 ? .ok : .failed("код \(r.code)"), text)
            return ToolResult(text: Self.truncate(text, 60_000), isError: r.code != 0)
        }
    }

    private func readFile(_ args: [String: Any]) async throws -> ToolResult {
        let path = try Self.string(args, "path")
        let maxBytes = Int(min(max(Self.number(args, "max_bytes") ?? 100_000, 1), 2_000_000))
        let tab = try await ensureConnected(try Self.string(args, "session"))
        let idx = log("read_file", tab, path)
        return try await working(tab) {
            let p = Self.shellPath(path)
            let script = "[ -f \(p) ] || { echo 'not a regular file' >&2; exit 2; }; wc -c < \(p); head -c \(maxBytes) -- \(p)\n"
            let r = try await SSHRunner(session: tab.session).run("sh -s", stdin: Data(script.utf8), timeout: 60)
            guard r.code == 0, let nl = r.out.firstIndex(of: 0x0A) else {
                finish(idx, .failed("ошибка"), r.stderr)
                return ToolResult(text: r.stderr.isEmpty ? "Cannot read \(path)" : r.stderr, isError: true)
            }
            let size = Int(String(decoding: r.out[..<nl], as: UTF8.self).trimmingCharacters(in: .whitespaces)) ?? 0
            let body = r.out[(nl + 1)...]
            if body.contains(0) {
                finish(idx, .ok, "двоичный файл, \(size) байт")
                return ToolResult(text: "\(path) is a binary file (\(size) bytes); not shown.")
            }
            var text = String(decoding: body, as: UTF8.self)
            if size > maxBytes { text += "\n… [truncated: showing \(maxBytes) of \(size) bytes]" }
            finish(idx, .ok, "\(size) байт")
            return ToolResult(text: text)
        }
    }

    private func writeFile(_ args: [String: Any]) async throws -> ToolResult {
        let path = try Self.string(args, "path")
        let content = try Self.string(args, "content")
        let append = args["append"] as? Bool ?? false
        let tab = try await ensureConnected(try Self.string(args, "session"))
        let bytes = content.utf8.count
        let idx = log("write_file", tab, "\(append ? "дописать в" : "записать") \(path) (\(bytes) байт)")
        let preview = "\(path) — \(bytes) байт\(append ? ", в конец файла" : "")\n\n" + Self.truncate(content, 3000)
        guard await approve(idx, tab: tab, title: append ? "дописать в файл" : "записать файл", detail: preview) else { return denied(idx) }
        return try await working(tab) {
            let p = Self.shellPath(path)
            let r = try await SSHRunner(session: tab.session)
                .run("mkdir -p \"$(dirname -- \(p))\" && cat \(append ? ">>" : ">") \(p)", stdin: Data(content.utf8), timeout: 120)
            guard r.code == 0 else {
                finish(idx, .failed("код \(r.code)"), r.stderr)
                return ToolResult(text: r.stderr.isEmpty ? "Write failed (exit \(r.code))" : r.stderr, isError: true)
            }
            finish(idx, .ok, "записано \(bytes) байт")
            return ToolResult(text: "Wrote \(bytes) bytes to \(path).")
        }
    }

    // MARK: - Сессии

    private func findTab(_ name: String) throws -> TerminalSession {
        guard let app else { throw SSHError(message: "MacXterm is not ready") }
        let q = name.lowercased()
        let match = app.tabs.filter { $0.title.lowercased() == q || $0.session.displayName.lowercased() == q || $0.session.host.lowercased() == q }
        if let t = match.first(where: { $0.state == .connected }) ?? match.first { return t }
        throw SSHError(message: "No open tab named «\(name)». Call connect first or list_sessions to see what is available.")
    }

    /// Находит или открывает вкладку и ждёт подключения (пароль подставляется из Keychain).
    private func ensureConnected(_ name: String, newTab: Bool = false) async throws -> TerminalSession {
        guard let app else { throw SSHError(message: "MacXterm is not ready") }
        if !newTab, let t = try? findTab(name) {
            if t.state == .disconnected { t.reconnect() }
            return try await waitConnected(t)
        }
        let q = name.lowercased()
        let session = app.store.sessions.first { $0.displayName.lowercased() == q || $0.host.lowercased() == q || $0.id.uuidString.lowercased() == q }
            ?? Session.parse(quick: name)
        guard let session else {
            throw SSHError(message: "Unknown session «\(name)». Use list_sessions, or pass user@host[:port].")
        }
        if !newTab, let t = app.tabs.first(where: { $0.session.id == session.id && $0.state != .disconnected }) {
            return try await waitConnected(t)
        }
        app.connect(session)
        guard let t = app.tabs.last else { throw SSHError(message: "Could not open a tab") }
        return try await waitConnected(t)
    }

    private func waitConnected(_ t: TerminalSession) async throws -> TerminalSession {
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            switch t.state {
            case .connected: return t
            case .disconnected:
                throw SSHError(message: "Connection to \(t.session.destination) failed (exit \(t.exitCode ?? -1)). The terminal tab in MacXterm shows details.")
            case .connecting: try? await Task.sleep(for: .milliseconds(200))
            }
        }
        throw SSHError(message: "Still waiting for login to \(t.session.destination). The user may need to type a password in the MacXterm tab; try again in a moment.")
    }

    private func working<T>(_ tab: TerminalSession, _ body: () async throws -> T) async rethrows -> T {
        tab.agentWorking += 1
        defer { tab.agentWorking -= 1 }
        return try await body()
    }

    // MARK: - Подтверждение

    private func approve(_ idx: UUID, tab: TerminalSession, title: String, detail: String) async -> Bool {
        guard confirm, !trusted.contains(tab.session.id) else { setStatus(idx, .running); return true }
        setStatus(idx, .waiting)
        let prev = approvalChain
        let task = Task { @MainActor () -> Bool in
            await prev?.value
            return await self.presentApproval(tab: tab, title: title, detail: detail)
        }
        approvalChain = Task { _ = await task.value }
        let ok = await task.value
        setStatus(idx, ok ? .running : .denied)
        return ok
    }

    private func presentApproval(tab: TerminalSession, title: String, detail: String) async -> Bool {
        if trusted.contains(tab.session.id) { return true }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.requestUserAttention(.criticalRequest)
        let alert = NSAlert()
        alert.messageText = "\(displayClient) хочет \(title) на «\(tab.session.displayName)»"
        alert.informativeText = tab.session.destination
        alert.icon = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 460, height: min(220, max(60, CGFloat(detail.split(separator: "\n").count) * 16 + 20)))
        scroll.borderType = .bezelBorder
        if let tv = scroll.documentView as? NSTextView {
            tv.string = detail
            tv.isEditable = false
            tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            tv.textContainerInset = NSSize(width: 6, height: 6)
        }
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Разрешить")
        let deny = alert.addButton(withTitle: "Отклонить")
        deny.keyEquivalent = "\u{1B}"
        alert.addButton(withTitle: "Разрешать всё для «\(tab.session.displayName)»")
        let window = NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
        let resp: NSApplication.ModalResponse
        if let window {
            resp = await withCheckedContinuation { cont in
                alert.beginSheetModal(for: window) { cont.resume(returning: $0) }
            }
        } else {
            resp = alert.runModal()
        }
        switch resp {
        case .alertFirstButtonReturn: return true
        case .alertThirdButtonReturn: trusted.insert(tab.session.id); return true
        default: return false
        }
    }

    // MARK: - Журнал

    private func log(_ tool: String, _ tab: TerminalSession, _ detail: String) -> UUID {
        let e = Entry(tool: tool, target: tab.session.displayName, detail: detail)
        entries.insert(e, at: 0)
        if entries.count > 200 { entries.removeLast(entries.count - 200) }
        return e.id
    }

    private func setStatus(_ id: UUID, _ s: Status) {
        if let i = entries.firstIndex(where: { $0.id == id }) { entries[i].status = s }
    }

    private func finish(_ id: UUID, _ s: Status, _ output: String) {
        if let i = entries.firstIndex(where: { $0.id == id }) {
            entries[i].status = s
            entries[i].output = Self.truncate(output, 4000)
        }
    }

    private func denied(_ id: UUID) -> ToolResult {
        setStatus(id, .denied)
        return ToolResult(text: "The user declined this action in MacXterm.", isError: true)
    }

    // MARK: - Утилиты

    static func string(_ args: [String: Any], _ key: String) throws -> String {
        guard let v = args[key] as? String, !v.isEmpty else { throw SSHError(message: "Missing required argument `\(key)`") }
        return v
    }

    static func number(_ args: [String: Any], _ key: String) -> Double? {
        (args[key] as? NSNumber)?.doubleValue ?? (args[key] as? String).flatMap(Double.init)
    }

    static func shellPath(_ p: String) -> String {
        if p == "~" { return "\"$HOME\"" }
        if p.hasPrefix("~/") { return "\"$HOME\"/" + SSHCommandBuilder.quote(String(p.dropFirst(2))) }
        return SSHCommandBuilder.quote(p)
    }

    static func truncate(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n)) + "\n… [truncated, \(s.count - n) more characters]"
    }

    static func lastLines(_ s: String, _ n: Int) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false).suffix(n).joined(separator: "\n")
    }

    nonisolated static func json(_ obj: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }
}
