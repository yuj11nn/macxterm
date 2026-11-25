import Foundation

/// Популярные MCP-клиенты и способ подключить к ним MacXterm.
enum AgentClient: String, CaseIterable, Identifiable {
    case claudeDesktop, cursor, windsurf, claudeCode, codex, vscode, gemini

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claudeDesktop: "Claude Desktop"
        case .cursor: "Cursor"
        case .windsurf: "Windsurf"
        case .claudeCode: "Claude Code"
        case .codex: "Codex CLI"
        case .vscode: "VS Code"
        case .gemini: "Gemini CLI"
        }
    }

    /// Клиенты с JSON-конфигом `mcpServers` — MacXterm прописывается в один клик.
    var configURL: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claudeDesktop: return home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        case .cursor: return home.appendingPathComponent(".cursor/mcp.json")
        case .windsurf: return home.appendingPathComponent(".codeium/windsurf/mcp_config.json")
        case .gemini: return home.appendingPathComponent(".gemini/settings.json")
        default: return nil
        }
    }

    /// Для CLI-клиентов — команда, которую нужно выполнить в Терминале.
    func command(_ exe: String) -> String? {
        switch self {
        case .claudeCode: "claude mcp add --scope user macxterm -- \"\(exe)\" --mcp"
        case .codex: "codex mcp add macxterm -- \"\(exe)\" --mcp"
        case .vscode: "code --add-mcp '{\"name\":\"macxterm\",\"command\":\"\(exe)\",\"args\":[\"--mcp\"]}'"
        default: nil
        }
    }

    var restartHint: String {
        switch self {
        case .claudeDesktop, .cursor, .windsurf: "Перезапустите \(title)"
        default: "Готово"
        }
    }

    // MARK: - JSON-конфиг

    static func serverEntry(_ exe: String) -> [String: Any] { ["command": exe, "args": ["--mcp"]] }

    /// Универсальный фрагмент для любых других MCP-клиентов.
    static func genericJSON(_ exe: String) -> String {
        AgentController.json(["mcpServers": ["macxterm": serverEntry(exe)]])
    }

    var isInstalled: Bool {
        guard let url = configURL, let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = obj["mcpServers"] as? [String: Any] else { return false }
        return servers["macxterm"] != nil
    }

    /// Дописывает MacXterm в mcpServers, сохраняя остальные настройки (старый файл — рядом, в .bak).
    func install(_ exe: String) throws {
        guard let url = configURL else { return }
        var config: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SSHError(message: "Не удалось разобрать \(url.lastPathComponent). Добавьте MacXterm вручную через «Другой агент».")
            }
            config = obj
            try? data.write(to: url.appendingPathExtension("bak"))
        }
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers["macxterm"] = Self.serverEntry(exe)
        config["mcpServers"] = servers
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}

extension AgentController {
    var executablePath: String { Bundle.main.executablePath ?? "/Applications/MacXterm.app/Contents/MacOS/MacXterm" }
}
