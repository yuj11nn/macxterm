import Foundation

/// Локальный сервер на unix-сокете: построчный обмен JSON (по строке на сообщение).
/// Работает на собственной очереди; колбэки вызываются на ней же.
final class UnixSocketServer: @unchecked Sendable {
    let path: String
    private let queue = DispatchQueue(label: "macxterm.mcp.socket")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [Int32: (source: DispatchSourceRead, buffer: Data)] = [:]

    var onLine: (@Sendable (Int32, Data) -> Void)?
    var onClientsChanged: (@Sendable (Int) -> Void)?

    init(path: String) { self.path = path }

    func start() throws {
        try queue.sync {
            unlink(path)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw SSHError(message: "socket(): \(errno)") }
            var addr = Self.address(path)
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard ok == 0 else { close(fd); throw SSHError(message: "bind(\(path)): \(errno)") }
            chmod(path, 0o600)
            guard listen(fd, 8) == 0 else { close(fd); throw SSHError(message: "listen(): \(errno)") }
            listenFD = fd
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            src.setEventHandler { [weak self] in self?.acceptClient() }
            src.resume()
            acceptSource = src
        }
    }

    func stop() {
        queue.sync {
            acceptSource?.cancel()
            for (fd, c) in clients { c.source.cancel(); close(fd) }
            clients.removeAll()
            if listenFD >= 0 { close(listenFD) }
            unlink(path)
        }
    }

    /// Отправить сообщение клиенту (добавляется перевод строки).
    func send(_ client: Int32, _ data: Data) {
        queue.async { [weak self] in
            guard self?.clients[client] != nil else { return }
            var payload = data
            payload.append(0x0A)
            payload.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let n = write(client, raw.baseAddress! + off, raw.count - off)
                    if n <= 0 { break }
                    off += n
                }
            }
        }
    }

    static func address(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8.prefix(MemoryLayout.size(ofValue: addr.sun_path) - 1))
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
        }
        return addr
    }

    private func acceptClient() {
        let c = accept(listenFD, nil, nil)
        guard c >= 0 else { return }
        var one: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let src = DispatchSource.makeReadSource(fileDescriptor: c, queue: queue)
        src.setEventHandler { [weak self] in self?.readClient(c) }
        src.resume()
        clients[c] = (src, Data())
        onClientsChanged?(clients.count)
    }

    private func readClient(_ c: Int32) {
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = read(c, &buf, buf.count)
        guard n > 0 else { drop(c); return }
        clients[c]?.buffer.append(contentsOf: buf[0..<n])
        while let data = clients[c]?.buffer, let nl = data.firstIndex(of: 0x0A) {
            let line = data[data.startIndex..<nl]
            clients[c]?.buffer = Data(data[(nl + 1)...])
            if !line.isEmpty { onLine?(c, Data(line)) }
        }
    }

    private func drop(_ c: Int32) {
        clients[c]?.source.cancel()
        clients[c] = nil
        close(c)
        onClientsChanged?(clients.count)
    }
}
