import Foundation

/// Режим `--mcp`: stdio MCP-сервер для любого MCP-клиента (Claude, Cursor, Codex, VS Code…).
/// Это тонкий мост: stdin/stdout ↔ unix-сокет запущенного MacXterm (при необходимости запускает приложение).
enum MCPBridge {
    static var socketPath: String { NSHomeDirectory() + "/.macxterm/mcp.sock" }

    static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        var fd = connectSocket()
        if fd < 0 {
            launchApp()
            let deadline = Date().addingTimeInterval(20)
            while fd < 0 && Date() < deadline {
                usleep(200_000)
                fd = connectSocket()
            }
        }
        guard fd >= 0 else { fallback() }

        // stdin → сокет
        let sock = fd
        Thread.detachNewThread {
            let input = FileHandle.standardInput
            while true {
                let chunk = input.availableData
                if chunk.isEmpty { shutdown(sock, SHUT_WR); return }
                chunk.withUnsafeBytes { raw in
                    var off = 0
                    while off < raw.count {
                        let n = write(sock, raw.baseAddress! + off, raw.count - off)
                        if n <= 0 { exit(0) }
                        off += n
                    }
                }
            }
        }
        // сокет → stdout
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { exit(0) }
            var off = 0
            while off < n {
                let w = buf.withUnsafeBytes { write(1, $0.baseAddress! + off, n - off) }
                if w <= 0 { exit(0) }
                off += w
            }
        }
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

    /// Приложение недоступно: отвечаем ошибкой на каждый запрос, чтобы клиент показал понятное сообщение.
    private static func fallback() -> Never {
        while let line = readLine() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = obj["id"] else { continue }
            let resp: [String: Any] = ["jsonrpc": "2.0", "id": id,
                                       "error": ["code": -32000, "message": "Не удалось запустить MacXterm. Откройте приложение и повторите."]]
            if let d = try? JSONSerialization.data(withJSONObject: resp) {
                FileHandle.standardOutput.write(d + Data([0x0A]))
            }
        }
        exit(0)
    }
}
