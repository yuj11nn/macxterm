import Foundation

struct SSHError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// Результат внешнего процесса.
struct ProcessResult: Sendable {
    let out: Data
    let err: Data
    let code: Int32
    var timedOut = false
    var stdout: String { String(decoding: out, as: UTF8.self) }
    var stderr: String { String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum ProcessRunner {
    /// Запуск процесса без блокировки акторов: чтение пайпов на отдельных потоках.
    static func run(_ exe: String, _ args: [String], stdin: Data? = nil, env: [String: String]? = nil,
                    timeout: TimeInterval? = nil) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                if let env { p.environment = env }
                let o = Pipe(), e = Pipe(), i = Pipe()
                p.standardOutput = o
                p.standardError = e
                p.standardInput = stdin == nil ? FileHandle.nullDevice : i
                do { try p.run() } catch { cont.resume(throwing: error); return }
                let killed = DataBox()
                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                        if p.isRunning { killed.append(Data([1])); p.terminate() }
                    }
                }
                if let stdin {
                    DispatchQueue.global().async {
                        try? i.fileHandleForWriting.write(contentsOf: stdin)
                        try? i.fileHandleForWriting.close()
                    }
                }
                let g = DispatchGroup()
                nonisolated(unsafe) var errData = Data()
                g.enter()
                DispatchQueue.global().async { errData = e.fileHandleForReading.readDataToEndOfFile(); g.leave() }
                let outData = o.fileHandleForReading.readDataToEndOfFile()
                g.wait()
                p.waitUntilExit()
                cont.resume(returning: ProcessResult(out: outData, err: errData, code: p.terminationStatus,
                                                     timedOut: !killed.isEmpty))
            }
        }
    }
}

/// Выполнение удалённых команд по уже авторизованному ControlMaster-каналу.
struct SSHRunner: Sendable {
    let session: Session

    /// Команда с таймаутом (для агента): по истечении времени ssh-клиент завершается.
    func run(_ cmd: String, stdin: Data? = nil, timeout: TimeInterval) async throws -> ProcessResult {
        try await ProcessRunner.run(SSHCommandBuilder.ssh, SSHCommandBuilder.remoteCommandArgs(session, cmd), stdin: stdin, timeout: timeout)
    }

    func run(_ cmd: String, stdin: Data? = nil) async throws -> (out: Data, err: Data, code: Int32) {
        let r = try await ProcessRunner.run(SSHCommandBuilder.ssh, SSHCommandBuilder.remoteCommandArgs(session, cmd), stdin: stdin)
        return (r.out, r.err, r.code)
    }

    /// Выполняет команду и бросает ошибку при ненулевом коде.
    func check(_ cmd: String, stdin: Data? = nil) async throws -> String {
        let r = try await run(cmd, stdin: stdin)
        guard r.code == 0 else {
            let msg = String(decoding: r.err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHError(message: msg.isEmpty ? "Команда завершилась с кодом \(r.code)" : msg)
        }
        return String(decoding: r.out, as: UTF8.self)
    }
}
