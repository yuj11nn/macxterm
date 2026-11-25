import Foundation

/// MCP-сервер (JSON-RPC 2.0) внутри приложения. Клиенты приходят через `MacXterm --mcp` по unix-сокету.
@MainActor
final class MCPServer {
    let agent: AgentController
    private let socket = UnixSocketServer(path: MCPBridge.socketPath)

    init(agent: AgentController) { self.agent = agent }

    func start() {
        _ = SSHCommandBuilder.controlDir  // создаёт ~/.macxterm с правами 700
        socket.onLine = { [weak self] client, line in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(client, line) } }
        }
        socket.onClientsChanged = { [weak self] n in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.agent.clientCount = n
                    if n == 0 { self?.agent.clientName = nil }
                }
            }
        }
        do { try socket.start() } catch { NSLog("MacXterm MCP: \(error.localizedDescription)") }
    }

    func stop() { socket.stop() }

    // MARK: - JSON-RPC

    private func handle(_ client: Int32, _ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) else {
            reply(client, ["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
            return
        }
        if let batch = obj as? [[String: Any]] { batch.forEach { handleMessage(client, $0) } }
        else if let msg = obj as? [String: Any] { handleMessage(client, msg) }
    }

    private func handleMessage(_ client: Int32, _ msg: [String: Any]) {
        guard let method = msg["method"] as? String else { return }  // ответы клиента нам не нужны
        let id = msg["id"]
        let params = msg["params"] as? [String: Any] ?? [:]
        guard let id else { return }  // уведомление (notifications/initialized и т.п.)

        switch method {
        case "initialize":
            if let info = params["clientInfo"] as? [String: Any], let name = info["name"] as? String {
                agent.clientName = Self.prettyClient(name)
            }
            result(client, id, [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "macxterm", "title": "MacXterm",
                               "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"],
                "instructions": Self.instructions,
            ])
        case "ping":
            result(client, id, [:])
        case "tools/list":
            result(client, id, ["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            Task { @MainActor in
                let r = await agent.call(name, args)
                result(client, id, ["content": [["type": "text", "text": r.text]], "isError": r.isError])
            }
        default:
            reply(client, ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
    }

    private func result(_ client: Int32, _ id: Any, _ result: [String: Any]) {
        reply(client, ["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func reply(_ client: Int32, _ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
        socket.send(client, data)
    }

    /// Человекочитаемое имя клиента из clientInfo.name.
    private static func prettyClient(_ raw: String) -> String {
        let l = raw.lowercased()
        let known: [(String, String)] = [
            ("claude-code", "Claude Code"), ("claude code", "Claude Code"), ("claude", "Claude"),
            ("cursor", "Cursor"), ("codex", "Codex"), ("windsurf", "Windsurf"), ("visual studio code", "VS Code"),
            ("vscode", "VS Code"), ("zed", "Zed"), ("cline", "Cline"), ("continue", "Continue"),
            ("gemini", "Gemini CLI"), ("lm studio", "LM Studio"), ("lmstudio", "LM Studio"), ("goose", "Goose"),
        ]
        if let hit = known.first(where: { l.contains($0.0) }) { return hit.1 }
        return raw.isEmpty ? "Агент" : raw.prefix(1).uppercased() + raw.dropFirst()
    }

    // MARK: - Описание инструментов

    nonisolated static let instructions = """
    MacXterm is the user's SSH client on macOS. These tools act on the user's real servers through MacXterm, \
    reusing its saved sessions and already-authenticated connections (passwords come from the macOS Keychain; you never see them).
    Start with list_sessions. Use run_command for non-interactive shell commands (exact stdout/stderr and exit code). \
    Use terminal_send + terminal_read for interactive things the user should see: sudo password prompts, editors, REPLs, \
    long-running TUIs. Commands and file writes may require the user's approval in a MacXterm dialog; if declined, \
    do not retry the same action without asking the user. Prefer safe, reversible commands and explain risky ones before running them.
    """

    nonisolated private static func schema(_ props: [String: [String: Any]], required: [String]) -> [String: Any] {
        ["type": "object", "properties": props, "required": required]
    }

    nonisolated(unsafe) private static let sessionProp: [String: Any] = [
        "type": "string",
        "description": "Saved session name, open tab name, or user@host[:port] for an ad-hoc connection",
    ]

    nonisolated(unsafe) static let tools: [[String: Any]] = [
        [
            "name": "list_sessions",
            "title": "List sessions",
            "description": "List the user's saved SSH sessions and currently open MacXterm tabs with their connection state.",
            "inputSchema": schema([:], required: []),
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "connect",
            "title": "Connect",
            "description": "Open (or reuse) a MacXterm tab for a server and wait until it is connected. Other tools connect automatically, so this is only needed to open a tab up front.",
            "inputSchema": schema(["session": sessionProp,
                                   "new_tab": ["type": "boolean", "description": "Open a new tab even if one is already connected"]],
                                  required: ["session"]),
        ],
        [
            "name": "run_command",
            "title": "Run command",
            "description": "Run a non-interactive shell command on the server and return stdout, stderr and the exit code. No TTY: for commands that prompt (sudo with password, editors) use terminal_send instead.",
            "inputSchema": schema(["session": sessionProp,
                                   "command": ["type": "string", "description": "Shell command line"],
                                   "cwd": ["type": "string", "description": "Working directory (default: home)"],
                                   "timeout_seconds": ["type": "number", "description": "Default 120, max 1800"]],
                                  required: ["session", "command"]),
            "annotations": ["destructiveHint": true, "openWorldHint": true],
        ],
        [
            "name": "terminal_send",
            "title": "Type into terminal",
            "description": "Type text into the visible MacXterm terminal tab (like the user typing), then return the last 40 lines of the screen. Use for interactive programs. Control characters are allowed, e.g. \"\\u0003\" for Ctrl-C.",
            "inputSchema": schema(["session": sessionProp,
                                   "text": ["type": "string", "description": "Text to type"],
                                   "enter": ["type": "boolean", "description": "Press Enter after the text (default true)"],
                                   "wait_ms": ["type": "number", "description": "How long to wait before reading the screen (default 1500)"]],
                                  required: ["session", "text"]),
            "annotations": ["destructiveHint": true, "openWorldHint": true],
        ],
        [
            "name": "terminal_read",
            "title": "Read terminal",
            "description": "Return the last lines of an open terminal tab, including scrollback.",
            "inputSchema": schema(["session": sessionProp,
                                   "lines": ["type": "number", "description": "Number of lines (default 60, max 2000)"]],
                                  required: ["session"]),
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "list_directory",
            "title": "List directory",
            "description": "List files in a directory on the server (ls -la).",
            "inputSchema": schema(["session": sessionProp,
                                   "path": ["type": "string", "description": "Directory path (default ~)"]],
                                  required: ["session"]),
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "read_file",
            "title": "Read file",
            "description": "Read a text file from the server.",
            "inputSchema": schema(["session": sessionProp,
                                   "path": ["type": "string"],
                                   "max_bytes": ["type": "number", "description": "Default 100000, max 2000000"]],
                                  required: ["session", "path"]),
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "write_file",
            "title": "Write file",
            "description": "Create or overwrite a file on the server (parent directories are created). Set append to add to the end instead.",
            "inputSchema": schema(["session": sessionProp,
                                   "path": ["type": "string"],
                                   "content": ["type": "string"],
                                   "append": ["type": "boolean"]],
                                  required: ["session", "path", "content"]),
            "annotations": ["destructiveHint": true],
        ],
    ]
}
