import Foundation
import Observation

/// Очередь scp-передач через ControlMaster (до 3 одновременно).
@MainActor @Observable
final class TransferQueue {
    enum Direction: Sendable { case upload, download }
    enum State: Equatable { case queued, running, done, failed(String), cancelled }

    @MainActor @Observable
    final class Item: Identifiable {
        let id = UUID()
        let direction: Direction
        let name: String
        let session: Session
        let source: String
        let destination: String
        let localWatch: String?
        let total: Int64?
        var state: State = .queued
        var progress: Double?
        @ObservationIgnored var process: Process?
        @ObservationIgnored var completion: ((Result<Void, Error>) -> Void)?

        init(direction: Direction, name: String, session: Session, source: String, destination: String,
             localWatch: String?, total: Int64?) {
            self.direction = direction; self.name = name; self.session = session
            self.source = source; self.destination = destination; self.localWatch = localWatch; self.total = total
        }

        var isActive: Bool { state == .queued || state == .running }
    }

    var items: [Item] = []
    @ObservationIgnored var onError: ((String) -> Void)?
    private let maxConcurrent = 3

    var hasActive: Bool { items.contains { $0.isActive } }

    // MARK: - API

    /// Скачивает файл/каталог в `localDir`, возвращает итоговый локальный URL.
    func download(_ s: Session, remote: String, isDir: Bool, size: Int64?, to localDir: URL, uniqueName: Bool = false,
                  completion: @escaping (Result<URL, Error>) -> Void) {
        let name = (remote as NSString).lastPathComponent
        var dest = localDir.appendingPathComponent(name)
        if uniqueName { dest = Self.uniqueURL(dest) }
        let item = Item(direction: .download, name: name, session: s, source: SSHCommandBuilder.remoteSpec(s, remote),
                        destination: dest.path, localWatch: isDir ? nil : dest.path, total: isDir ? nil : size)
        item.completion = { r in completion(r.map { dest }) }
        enqueue(item)
    }

    /// Заливает локальный файл/каталог в удалённый каталог.
    func upload(_ s: Session, local: URL, toRemoteDir dir: String, completion: ((Result<Void, Error>) -> Void)? = nil) {
        let target = dir.hasSuffix("/") ? dir : dir + "/"
        let item = Item(direction: .upload, name: local.lastPathComponent, session: s, source: local.path,
                        destination: SSHCommandBuilder.remoteSpec(s, target), localWatch: nil, total: nil)
        item.completion = completion
        enqueue(item)
    }

    /// Перезаписывает конкретный удалённый файл (для «Открыть в редакторе»).
    func upload(_ s: Session, local: URL, toRemotePath path: String, completion: ((Result<Void, Error>) -> Void)? = nil) {
        let item = Item(direction: .upload, name: local.lastPathComponent, session: s, source: local.path,
                        destination: SSHCommandBuilder.remoteSpec(s, path), localWatch: nil, total: nil)
        item.completion = completion
        enqueue(item)
    }

    func cancel(_ item: Item) {
        if item.state == .queued { finish(item, .cancelled); return }
        item.state = .cancelled
        item.process?.terminate()
    }

    func clearFinished() { items.removeAll { !$0.isActive } }

    // MARK: - Внутреннее

    private func enqueue(_ item: Item) {
        items.append(item)
        pump()
    }

    private func pump() {
        let running = items.filter { $0.state == .running }.count
        guard running < maxConcurrent, let next = items.first(where: { $0.state == .queued }) else { return }
        start(next)
        pump()
    }

    private func start(_ item: Item) {
        item.state = .running
        let p = Process()
        p.executableURL = URL(fileURLWithPath: SSHCommandBuilder.scp)
        p.arguments = SSHCommandBuilder.scpArgs(item.session, from: item.source, to: item.destination)
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        p.standardError = errPipe
        let errBuf = DataBox()
        errPipe.fileHandleForReading.readabilityHandler = { h in errBuf.append(h.availableData) }
        p.terminationHandler = { [weak self] proc in
            errPipe.fileHandleForReading.readabilityHandler = nil
            let code = proc.terminationStatus
            let msg = errBuf.string
            Task { @MainActor in
                guard let self else { return }
                if item.state == .cancelled { self.finish(item, .cancelled) }
                else if code == 0 { self.finish(item, .done) }
                else { self.finish(item, .failed(msg.isEmpty ? "scp: код \(code)" : msg)) }
            }
        }
        do {
            try p.run()
            item.process = p
        } catch {
            finish(item, .failed(error.localizedDescription))
            return
        }
        if let watch = item.localWatch, let total = item.total, total > 0 {
            Task { [weak item] in
                while let item, item.state == .running {
                    let size = (try? FileManager.default.attributesOfItem(atPath: watch)[.size] as? Int64) ?? 0
                    item.progress = min(1, Double(size) / Double(total))
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
        }
    }

    private func finish(_ item: Item, _ state: State) {
        item.state = state
        item.process = nil
        if state == .done { item.progress = 1 }
        let c = item.completion
        item.completion = nil
        switch state {
        case .done: c?(.success(()))
        case .failed(let m):
            onError?("\(item.name): \(m)")
            c?(.failure(SSHError(message: m)))
        case .cancelled: c?(.failure(CancellationError()))
        default: break
        }
        // Успешные передачи убираем из списка через пару секунд.
        if state == .done {
            Task { [weak self, weak item] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, let item else { return }
                self.items.removeAll { $0 === item }
            }
        }
        pump()
    }

    static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        let dir = url.deletingLastPathComponent()
        for i in 2...999 {
            let u = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)")
            if !fm.fileExists(atPath: u.path) { return u }
        }
        return url
    }
}

/// Потокобезопасный буфер для stderr.
final class DataBox: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return data.isEmpty }
    var string: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum TempDirs {
    static let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MacXterm", isDirectory: true)

    static func make(_ kind: String) -> URL {
        let u = root.appendingPathComponent(kind).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func contains(_ url: URL) -> Bool { url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path) }
}
