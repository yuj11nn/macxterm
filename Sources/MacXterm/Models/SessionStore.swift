import Foundation
import Observation

/// Хранилище сессий и папок: `~/Library/Application Support/MacXterm/sessions.json`.
@MainActor @Observable
final class SessionStore {
    private struct FileFormat: Codable {
        var folders: [Folder]
        var sessions: [Session]
    }

    var folders: [Folder] = [] { didSet { scheduleSave() } }
    var sessions: [Session] = [] { didSet { scheduleSave() } }

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var loading = false

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacXterm", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sessions.json")
    }

    init() { load() }

    func load() {
        loading = true
        defer { loading = false }
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let f = try? dec.decode(FileFormat.self, from: data) {
            folders = f.folders
            sessions = f.sessions
        }
    }

    private func scheduleSave() {
        guard !loading else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(FileFormat(folders: folders, sessions: sessions)) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    // MARK: - CRUD

    func session(_ id: UUID) -> Session? { sessions.first { $0.id == id } }

    func upsert(_ s: Session) {
        if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i] = s } else { sessions.append(s) }
    }

    func delete(sessionID: UUID) {
        sessions.removeAll { $0.id == sessionID }
        Keychain.deleteAll(for: sessionID)
    }

    func duplicate(_ id: UUID) {
        guard var s = session(id) else { return }
        let old = s.id
        s.id = UUID()
        s.name += " копия"
        s.createdAt = Date()
        s.lastUsed = nil
        sessions.append(s)
        if let p = Keychain.get(old, kind: .password) { Keychain.set(p, for: s.id, kind: .password) }
        if let p = Keychain.get(old, kind: .passphrase) { Keychain.set(p, for: s.id, kind: .passphrase) }
    }

    func touch(_ id: UUID) {
        if let i = sessions.firstIndex(where: { $0.id == id }) { sessions[i].lastUsed = Date() }
    }

    func addFolder(name: String) -> Folder {
        let f = Folder(name: name)
        folders.append(f)
        return f
    }

    func renameFolder(_ id: UUID, to name: String) {
        if let i = folders.firstIndex(where: { $0.id == id }) { folders[i].name = name }
    }

    func setExpanded(_ id: UUID, _ value: Bool) {
        if let i = folders.firstIndex(where: { $0.id == id }), folders[i].expanded != value { folders[i].expanded = value }
    }

    /// Удаляет папку; сессии переезжают в корень.
    func deleteFolder(_ id: UUID) {
        for i in sessions.indices where sessions[i].folderId == id { sessions[i].folderId = nil }
        folders.removeAll { $0.id == id }
    }

    func move(sessionID: UUID, toFolder folderID: UUID?) {
        if let i = sessions.firstIndex(where: { $0.id == sessionID }) { sessions[i].folderId = folderID }
    }
}
