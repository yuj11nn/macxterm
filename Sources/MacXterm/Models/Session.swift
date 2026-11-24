import Foundation

enum AuthType: String, Codable, CaseIterable, Identifiable, Sendable {
    case password, key, agent
    var id: String { rawValue }
    var title: String {
        switch self {
        case .password: "Пароль"
        case .key: "Ключ"
        case .agent: "SSH-агент / config"
        }
    }
}

/// Сохранённая SSH-сессия. Пароли сюда никогда не попадают — только в Keychain.
struct Session: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var host: String
    var port: Int = 22
    var user: String = ""
    var authType: AuthType = .password
    var keyPath: String?
    var folderId: UUID?
    var color: String?
    var initialRemoteDir: String?
    var extraSSHArgs: String?
    var createdAt: Date = Date()
    var lastUsed: Date?

    /// `user@host` или просто `host`.
    var destination: String { user.isEmpty ? host : "\(user)@\(host)" }
    var displayName: String { name.isEmpty ? destination : name }
    /// Ключ для совместного использования ControlMaster между вкладками.
    var connectionKey: String { "\(user)@\(host):\(port)|\(keyPath ?? "")|\(extraSSHArgs ?? "")" }

    /// Разбор быстрого ввода `user@host:port`.
    static func parse(quick: String) -> Session? {
        var s = quick.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("ssh ") { s.removeFirst(4) }
        var user = ""
        if let at = s.lastIndex(of: "@") {
            user = String(s[..<at]); s = String(s[s.index(after: at)...])
        }
        var port = 22
        if let colon = s.lastIndex(of: ":"), !s.contains("]"), s.filter({ $0 == ":" }).count == 1,
           let p = Int(s[s.index(after: colon)...]) {
            port = p; s = String(s[..<colon])
        }
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        return Session(name: s, host: s, port: port, user: user, authType: .agent)
    }
}

enum SessionColor: String, CaseIterable, Identifiable {
    case none, red, orange, yellow, green, blue, purple, gray
    var id: String { rawValue }
}
