import Foundation

/// Режим `--mcp`: stdio MCP-сервер для любого MCP-клиента (Claude, Cursor, Codex, VS Code…).
///
/// Мост «ленивый»: рукопожатие, список инструментов и ping он обслуживает сам, а MacXterm
/// запускает только при первом вызове инструмента. Дальше он просто пересылает строки JSON
/// между stdin/stdout и unix-сокетом приложения. Если приложение закрыли, следующий вызов
/// запустит его снова, и рукопожатие повторится незаметно для клиента.
enum MCPBridge {
    static var socketPath: String { NSHomeDirectory() + "/.macxterm/mcp.sock" }

    private static let replayID = "__macxterm_bridge_init__"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var socketFD: Int32 = -1
    nonisolated(unsafe) private static var initializeLine: Data?
    nonisolated(unsafe) private static var clientInitialized = false

    static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        // Приложение уже запущено — сразу работаем через него.
        let fd = connectSocket()
        if fd >= 0 { attach(fd) }

        while let line = Swift.readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            let data = Data(line.utf8)
            let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let method = msg?["method"] as? String
            if method == "initialize" { initializeLine = data }
            if method == "notifications/initialized" { clientInitialized = true }

            if currentSocket() >= 0, send(data) { continue }
            handleLocally(data, msg, method)
        }
        exit(0)
    }

    // MARK: - Локальная обработка (приложение не запущено)

    private static func handleLocally(_ data: Data, _ msg: [String: Any]?, _ method: String?) {
        guard let msg, let method else { return }
        guard let id = msg["id"] else { return }  // уведомления без ответа
        let params = msg["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            reply(id, result: [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "macxterm", "title": "MacXterm",
                               "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"],
                "instructions": MCPServer.instructions,
            ])
        case "ping":
            reply(id, result: [:])
        case "tools/list":
            reply(id, result: ["tools": MCPServer.tools])
        case "tools/call":
            guard UserDefaults.standard.bool(forKey: AgentController.enabledKey) else {
                toolError(id, "Agent access is turned off in MacXterm. Ask the user to enable it in MacXterm → «Агент» tab (⌃4) or Settings.")
                return
            }
            if startApp(), send(data) { return }
            toolError(id, "Could not start MacXterm. Ask the user to open MacXterm and try again.")
        default:
            write(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
    }

    private static func reply(_ id: Any, result: [String: Any]) {
        write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func toolError(_ id: Any, _ text: String) {
        reply(id, result: ["content": [["type": "text", "text": text]], "isError": true])
    }

    private static func write(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
        writeStdout(d + Data([0x0A]))
    }

    private static func writeStdout(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = Foundation.write(1, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { exit(0) }
                off += n
            }
        }
    }

    // MARK: - Приложение

    /// Запускает MacXterm (если нужно), подключается и незаметно повторяет рукопожатие клиента.
    private static func startApp() -> Bool {
        var fd = connectSocket()
        if fd < 0 {
            launchApp()
            let deadline = Date().addingTimeInterval(20)
            while fd < 0 && Date() < deadline {
                usleep(200_000)
                fd = connectSocket()
            }
        }
        guard fd >= 0 else { return false }
        if let initData = initializeLine,
           var obj = (try? JSONSerialization.jsonObject(with: initData)) as? [String: Any] {
            obj["id"] = replayID
            if let d = try? JSONSerialization.data(withJSONObject: obj), writeAll(fd, d + Data([0x0A])) {
                _ = readSocketLine(fd)  // ответ на повторное рукопожатие клиенту не нужен
            }
            if clientInitialized {
                _ = writeAll(fd, Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8) + Data([0x0A]))
            }
        }
        attach(fd)
        return true
    }

    /// Начинает пересылку сокет → stdout. При закрытии сокета мост возвращается в ленивый режим.
    private static func attach(_ fd: Int32) {
        lock.lock(); socketFD = fd; lock.unlock()
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { break }
                writeStdout(Data(buf[0..<n]))
            }
            lock.lock()
            if socketFD == fd { socketFD = -1 }
            lock.unlock()
            close(fd)
        }
    }

    private static func currentSocket() -> Int32 {
        lock.lock(); defer { lock.unlock() }
        return socketFD
    }

    private static func send(_ line: Data) -> Bool {
        let fd = currentSocket()
        guard fd >= 0 else { return false }
        if writeAll(fd, line + Data([0x0A])) { return true }
        lock.lock(); if socketFD == fd { socketFD = -1 }; lock.unlock()
        return false
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = Foundation.write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
    }

    /// Блокирующее чтение одной строки из сокета (только для повторного рукопожатия).
    private static func readSocketLine(_ fd: Int32) -> Data? {
        var out = Data()
        var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1 {
            if byte == 0x0A { return out }
            out.append(byte)
        }
        return nil
    }

    private static func connectSocket() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = UnixSocketServer.address(socketPath)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if r != 0 { close(fd); return -1 }
        return fd
    }

    /// Запускает MacXterm в фоне (бандл, внутри которого лежит этот бинарник).
    private static func launchApp() {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let bundle = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = bundle.pathExtension == "app" ? ["-g", bundle.path] : ["-g", "-b", "com.macxterm.app"]
        try? p.run()
        p.waitUntilExit()
    }
}
