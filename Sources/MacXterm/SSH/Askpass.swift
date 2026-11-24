import Foundation

/// Режим `--askpass`: ssh вызывает нас через `Resources/askpass.sh` и ждёт секрет в stdout.
enum Askpass {
    static func run(arguments: [String]) -> Never {
        let prompt = arguments.joined(separator: " ").lowercased()
        guard let sid = ProcessInfo.processInfo.environment["MACXTERM_SID"],
              let id = UUID(uuidString: sid) else { exit(1) }
        let kind: Keychain.Kind = prompt.contains("passphrase") ? .passphrase : .password
        guard let secret = Keychain.get(id, kind: kind) else { exit(1) }
        FileHandle.standardOutput.write(Data((secret + "\n").utf8))
        exit(0)
    }

    /// Путь к askpass.sh внутри бандла (nil при запуске не из .app).
    static var scriptPath: String? {
        let p = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/askpass.sh").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }
}
