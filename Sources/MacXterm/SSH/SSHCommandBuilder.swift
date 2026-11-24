import Foundation

/// Собирает аргументы и окружение для ssh/scp. Чистые функции, без состояния.
enum SSHCommandBuilder {
    static let ssh = "/usr/bin/ssh"
    static let scp = "/usr/bin/scp"

    /// `~/.macxterm/cm` (права 700). Путь короткий из-за лимита ~104 байта на unix-сокет.
    static var controlDir: String {
        let dir = NSHomeDirectory() + "/.macxterm/cm"
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: NSHomeDirectory() + "/.macxterm")
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        return dir
    }
    static var controlPath: String { controlDir + "/%C" }

    /// Экранирование для удалённого shell: `'` → `'\''`.
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func extraArgs(_ s: Session) -> [String] {
        guard let e = s.extraSSHArgs?.trimmingCharacters(in: .whitespaces), !e.isEmpty else { return [] }
        return splitArgs(e)
    }

    /// Простой разбор строки аргументов с поддержкой кавычек.
    static func splitArgs(_ s: String) -> [String] {
        var out: [String] = [], cur = "", q: Character? = nil, has = false
        for c in s {
            if let qq = q { if c == qq { q = nil } else { cur.append(c) }; continue }
            if c == "\"" || c == "'" { q = c; has = true; continue }
            if c == " " { if has || !cur.isEmpty { out.append(cur); cur = ""; has = false }; continue }
            cur.append(c)
        }
        if has || !cur.isEmpty { out.append(cur) }
        return out
    }

    private static func keyArgs(_ s: Session) -> [String] {
        if s.authType == .key, let k = s.keyPath, !k.isEmpty {
            return ["-i", (k as NSString).expandingTildeInPath]
        }
        return []
    }

    private static func savedSecret(_ s: Session) -> Bool {
        switch s.authType {
        case .password: Keychain.has(s.id, kind: .password)
        case .key: Keychain.has(s.id, kind: .passphrase)
        case .agent: false
        }
    }

    /// Аргументы интерактивного (мастер) ssh для терминала.
    static func terminalArgs(_ s: Session) -> [String] {
        var a = ["-tt",
                 "-o", "ControlMaster=auto",
                 "-o", "ControlPath=\(controlPath)",
                 "-o", "ControlPersist=30",
                 "-o", "ServerAliveInterval=30",
                 "-o", "StrictHostKeyChecking=accept-new"]
        if savedSecret(s) && Askpass.scriptPath != nil { a += ["-o", "NumberOfPasswordPrompts=1"] }
        a += ["-p", String(s.port)] + keyArgs(s) + extraArgs(s) + [s.destination]
        if let dir = s.initialRemoteDir, !dir.isEmpty {
            a += ["cd \(quote(dir)) 2>/dev/null; exec \"${SHELL:-/bin/sh}\" -l"]
        }
        return a
    }

    /// Аргументы фоновых вызовов через уже открытый мастер.
    static func slaveOptions(_ s: Session) -> [String] {
        ["-o", "ControlPath=\(controlPath)", "-o", "ControlMaster=no", "-o", "BatchMode=yes",
         "-o", "StrictHostKeyChecking=accept-new"] + keyArgs(s) + extraArgs(s)
    }

    static func remoteCommandArgs(_ s: Session, _ cmd: String) -> [String] {
        slaveOptions(s) + ["-p", String(s.port), s.destination, "--", cmd]
    }

    static func controlArgs(_ s: Session, _ op: String) -> [String] {
        ["-O", op, "-o", "ControlPath=\(controlPath)", "-p", String(s.port)] + extraArgs(s) + [s.destination]
    }

    /// scp в режиме SFTP (по умолчанию в OpenSSH 9): удалённые пути не нужно экранировать.
    static func scpArgs(_ s: Session, from: String, to: String) -> [String] {
        slaveOptions(s) + ["-P", String(s.port), "-r", "-p", from, to]
    }

    static func remoteSpec(_ s: Session, _ path: String) -> String {
        let host = s.host.contains(":") ? "[\(s.host)]" : s.host
        return (s.user.isEmpty ? host : "\(s.user)@\(host)") + ":" + path
    }

    /// Окружение терминального ssh. Askpass подключаем только если секрет сохранён.
    static func environment(_ s: Session) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env["COLORTERM"] = "truecolor"
        env.removeValue(forKey: "MACXTERM_SID")
        env.removeValue(forKey: "SSH_ASKPASS")
        env.removeValue(forKey: "SSH_ASKPASS_REQUIRE")
        if savedSecret(s), let ap = Askpass.scriptPath {
            env["SSH_ASKPASS"] = ap
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["MACXTERM_SID"] = s.id.uuidString
            if env["DISPLAY"] == nil { env["DISPLAY"] = ":0" }
        }
        return env
    }

    /// Строка для «Копировать ssh-команду».
    static func shellCommand(_ s: Session) -> String {
        var a = ["ssh"]
        if s.port != 22 { a += ["-p", String(s.port)] }
        a += keyArgs(s).map { $0.contains(" ") ? quote($0) : $0 }
        a += extraArgs(s).map { $0.contains(" ") ? quote($0) : $0 }
        a.append(s.destination)
        return a.joined(separator: " ")
    }
}
