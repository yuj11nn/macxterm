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
    var filter = ""
    private(set) var backStack: [String] = []
    private(set) var forwardStack: [String] = []
    /// Имя, которое таблица должна выделить (и, если rename = true, начать переименование) после перезагрузки.
    var pendingSelection: (name: String, rename: Bool)?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(session: Session) { self.session = session }

    private var runner: SSHRunner { SSHRunner(session: session) }

    var visibleItems: [FileItem] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return items.filter { (showHidden || !$0.isHidden) && (q.isEmpty || $0.name.lowercased().contains(q)) }
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
        navigate(p)
    }

    // MARK: - Навигация

    func refresh() { load(path.isEmpty ? "~" : path) }
    func up() { if !path.isEmpty && path != "/" { navigate(FileItem.parent(of: path)) } }
    func goHome() { navigate("~") }

    /// Переход с записью в историю (назад/вперёд).
    func navigate(_ p: String) {
        guard p != path else { refresh(); return }
        if !path.isEmpty { backStack.append(path); forwardStack.removeAll() }
        filter = ""
        load(p)
    }

    func goBack() {
        guard let p = backStack.popLast() else { return }
        forwardStack.append(path)
        filter = ""
        load(p)
    }

    func goForward() {
        guard let p = forwardStack.popLast() else { return }
        backStack.append(path)
        filter = ""
        load(p)
    }

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

    func uniqueName(_ base: String) -> String {
        let names = Set(items.map(\.name))
        guard names.contains(base) else { return base }
        let ext = (base as NSString).pathExtension, stem = (base as NSString).deletingPathExtension
        for i in 2...999 {
            let n = ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)"
            if !names.contains(n) { return n }
        }
        return base
    }

    /// Создаёт «Новая папка» / «новый файл.txt» и просит таблицу начать переименование.
    func createAndRename(folder: Bool) async -> String? {
        let name = uniqueName(folder ? "Новая папка" : "новый файл.txt")
        pendingSelection = (name, true)
        return folder ? await mkdir(name) : await touch(name)
    }

    func move(_ paths: [String], toDir dir: String) async -> String? {
        let src = paths.filter { $0 != dir && FileItem.parent(of: $0) != dir && !dir.hasPrefix($0 + "/") }
        guard !src.isEmpty else { return nil }
        return await perform("mv -- " + src.map { SSHCommandBuilder.quote($0) }.joined(separator: " ") + " " + SSHCommandBuilder.quote(dir + "/"))
    }

    func duplicate(_ item: FileItem) async -> String? {
        let ext = (item.name as NSString).pathExtension, stem = (item.name as NSString).deletingPathExtension
        let name = uniqueName(item.isDir || ext.isEmpty ? "\(item.name) копия" : "\(stem) копия.\(ext)")
        pendingSelection = (name, false)
        return await perform("cp -a -- \(SSHCommandBuilder.quote(item.path)) \(SSHCommandBuilder.quote(FileItem.join(path, name)))")
    }

    func mkdir(_ name: String) async -> String? {
        await perform("mkdir -p -- \(SSHCommandBuilder.quote(FileItem.join(path, name)))")
    }

    func touch(_ name: String) async -> String? {
        await perform("touch -- \(SSHCommandBuilder.quote(FileItem.join(path, name)))")
    }

    func rename(_ item: FileItem, to name: String) async -> String? {
        let dst = FileItem.join(FileItem.parent(of: item.path), name)
        pendingSelection = (name, false)
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
