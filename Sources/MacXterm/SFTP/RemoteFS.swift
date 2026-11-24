import Foundation
import Observation

/// Удалённая файловая система вкладки поверх ControlMaster: листинг и операции через `sh -s`.
@MainActor @Observable
final class RemoteFS {
    enum Phase: Equatable { case waiting, ready, failed(String), offline }

    let session: Session
    @ObservationIgnored weak var terminal: TerminalSession?
    var phase: Phase = .waiting
    var path = ""
    var home = ""
    var items: [FileItem] = []
    var isLoading = false
    var error: String?
    var showHidden = false
    var followTerminal = false {
        didSet { if followTerminal && !oldValue { terminal?.installOSC7Hook() } }
    }
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(session: Session) { self.session = session }

    private var runner: SSHRunner { SSHRunner(session: session) }

    var visibleItems: [FileItem] {
        items.filter { showHidden || !$0.isHidden }.sorted {
            if $0.isDir != $1.isDir { return $0.isDir }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Жизненный цикл

    func connectionReady() {
        phase = .ready
        if followTerminal { terminal?.installOSC7Hook() }
        if path.isEmpty {
            load(session.initialRemoteDir.flatMap { $0.isEmpty ? nil : $0 } ?? "~")
        } else {
            refresh()
        }
    }

    func connectionFailed(_ msg: String) { phase = .failed(msg) }
    func connectionLost() { phase = .offline; loadTask?.cancel(); isLoading = false }
    func shutdown() { loadTask?.cancel() }

    func retry() {
        phase = .waiting
        let s = session
        Task {
            if await ControlMaster.waitReady(s, timeout: .seconds(10)) { connectionReady() }
            else { phase = .failed("Мастер-соединение недоступно") }
        }
    }

    func terminalDirectoryChanged(_ p: String) {
        guard followTerminal, phase == .ready, p != path else { return }
        load(p)
    }

    // MARK: - Навигация

    func refresh() { load(path.isEmpty ? "~" : path) }
    func up() { if !path.isEmpty && path != "/" { load(FileItem.parent(of: path)) } }
    func goHome() { load("~") }

    func load(_ target: String) {
        loadTask?.cancel()
        isLoading = true
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (resolved, list) = try await self.list(target)
                guard !Task.isCancelled else { return }
                self.path = resolved
                if target == "~" && self.home.isEmpty { self.home = resolved }
                self.items = list
                self.error = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            self.isLoading = false
        }
    }

    private func shellPath(_ p: String) -> String {
        if p == "~" { return "\"$HOME\"" }
        if p.hasPrefix("~/") { return "\"$HOME\"/" + SSHCommandBuilder.quote(String(p.dropFirst(2))) }
        return SSHCommandBuilder.quote(p)
    }

    private func list(_ target: String) async throws -> (String, [FileItem]) {
        let script = """
        cd \(shellPath(target)) 2>/dev/null || { echo "No access: \(target.replacingOccurrences(of: "\"", with: ""))" >&2; exit 2; }
        pwd
        if find . -maxdepth 0 -printf '' >/dev/null 2>&1; then
          echo __FIND__
          LC_ALL=C find . -mindepth 1 -maxdepth 1 -printf '%y\\t%Y\\t%s\\t%T@\\t%m\\t%u\\t%f\\n' 2>/dev/null
        else
          echo __LS__
          LC_ALL=C ls -laL 2>/dev/null
        fi
        exit 0
        """
        let out = try await sh(script)
        var lines = out.split(separator: "\n", omittingEmptySubsequences: true)[...]
        guard let dirLine = lines.popFirst(), let marker = lines.popFirst() else {
            throw SSHError(message: "Пустой ответ сервера")
        }
        let dir = String(dirLine)
        let useFind = marker == "__FIND__"
        let result = lines.compactMap { useFind ? FileItem.parseFind($0, dir: dir) : FileItem.parseLS($0, dir: dir) }
        return (dir, result)
    }

    // MARK: - Операции

    @discardableResult
    func sh(_ script: String) async throws -> String {
        try await runner.check("sh -s", stdin: Data(script.utf8))
    }

    private func perform(_ script: String) async -> String? {
        do { try await sh(script); refresh(); return nil }
        catch { self.error = error.localizedDescription; refresh(); return error.localizedDescription }
    }

    func mkdir(_ name: String) async -> String? {
        await perform("mkdir -p -- \(SSHCommandBuilder.quote(FileItem.join(path, name)))")
    }

    func touch(_ name: String) async -> String? {
        await perform("touch -- \(SSHCommandBuilder.quote(FileItem.join(path, name)))")
    }

    func rename(_ item: FileItem, to name: String) async -> String? {
        let dst = FileItem.join(FileItem.parent(of: item.path), name)
        return await perform("mv -- \(SSHCommandBuilder.quote(item.path)) \(SSHCommandBuilder.quote(dst))")
    }

    func delete(_ items: [FileItem]) async -> String? {
        guard !items.isEmpty else { return nil }
        return await perform("rm -rf -- " + items.map { SSHCommandBuilder.quote($0.path) }.joined(separator: " "))
    }

    func chmod(_ item: FileItem, mode: String) async -> String? {
        guard Int(mode, radix: 8) != nil else { return "Неверный режим: \(mode)" }
        return await perform("chmod \(mode) -- \(SSHCommandBuilder.quote(item.path))")
    }
}
