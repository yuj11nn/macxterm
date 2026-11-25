import AppKit
import Foundation

/// «Открыть в редакторе»: скачиваем во временный каталог, следим за ним и заливаем файл обратно после сохранения.
/// Следим за каталогом, а не за файлом: редакторы (TextEdit и др.) сохраняют атомарно через rename.
@MainActor
final class RemoteEditWatcher {
    private final class Watch {
        let session: Session
        let remotePath: String
        let local: URL
        var source: DispatchSourceFileSystemObject?
        var lastMod: Date?
        var debounce: Task<Void, Never>?
        var uploading = false
        var pending = false
        init(session: Session, remotePath: String, local: URL) {
            self.session = session; self.remotePath = remotePath; self.local = local
        }
    }

    weak var transfers: TransferQueue?
    var onUploaded: ((String) -> Void)?
    var onError: ((String) -> Void)?
    private var watches: [String: Watch] = [:]

    func open(_ s: Session, item: FileItem, with appURL: URL? = nil) {
        let key = s.id.uuidString + "|" + s.destination + "|" + item.path
        if let w = watches[key], FileManager.default.fileExists(atPath: w.local.path) {
            openInEditor(w.local, with: appURL)
            return
        }
        let dir = TempDirs.make("edit")
        transfers?.download(s, remote: item.path, isDir: false, size: item.size, to: dir) { [weak self] r in
            guard let self else { return }
            switch r {
            case .success(let url):
                let w = Watch(session: s, remotePath: item.path, local: url)
                w.lastMod = Self.mtime(url)
                self.watches[key] = w
                self.startWatching(w, dir: dir)
                self.openInEditor(url, with: appURL)
            case .failure(let e):
                if !(e is CancellationError) { self.onError?("Не удалось открыть \(item.name): \(e.localizedDescription)") }
            }
        }
    }

    private func openInEditor(_ url: URL, with appURL: URL? = nil) {
        let ws = NSWorkspace.shared
        if let appURL {
            ws.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        var app = ws.urlForApplication(toOpen: url)
        let unsafe = ["com.apple.Terminal", "com.googlecode.iterm2", "com.apple.ScriptEditor2", "com.apple.installer"]
        if let a = app, let bid = Bundle(url: a)?.bundleIdentifier,
           unsafe.contains(bid) || bid == Bundle.main.bundleIdentifier { app = nil }
        let editor = app ?? ws.urlForApplication(withBundleIdentifier: "com.apple.TextEdit")
        guard let editor else { ws.open(url); return }
        ws.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }

    private func startWatching(_ w: Watch, dir: URL) {
        let fd = Darwin.open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .extend], queue: .main)
        src.setEventHandler { [weak self, weak w] in
            MainActor.assumeIsolated {
                guard let self, let w else { return }
                self.changed(w)
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        w.source = src
    }

    private func changed(_ w: Watch) {
        w.debounce?.cancel()
        w.debounce = Task { [weak self, weak w] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self, let w else { return }
            guard let m = Self.mtime(w.local), m != w.lastMod else { return }
            self.upload(w, mod: m)
        }
    }

    private func upload(_ w: Watch, mod: Date) {
        if w.uploading { w.pending = true; return }
        w.uploading = true
        w.lastMod = mod
        transfers?.upload(w.session, local: w.local, toRemotePath: w.remotePath) { [weak self, weak w] r in
            guard let self, let w else { return }
            w.uploading = false
            switch r {
            case .success: self.onUploaded?(w.local.lastPathComponent)
            case .failure(let e): self.onError?("Не удалось загрузить \(w.local.lastPathComponent): \(e.localizedDescription)")
            }
            if w.pending {
                w.pending = false
                if let m = Self.mtime(w.local), m != w.lastMod { self.upload(w, mod: m) }
            }
        }
    }

    private static func mtime(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    func stopAll() {
        watches.values.forEach { $0.source?.cancel() }
        watches.removeAll()
    }
}
