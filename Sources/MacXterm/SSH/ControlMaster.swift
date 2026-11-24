import Foundation

/// Управление мультиплексором ssh (`-O check` / `-O exit`).
enum ControlMaster {
    static func isReady(_ s: Session) async -> Bool {
        let r = try? await ProcessRunner.run(SSHCommandBuilder.ssh, SSHCommandBuilder.controlArgs(s, "check"))
        return r?.code == 0
    }

    /// Опрос каждые 300 мс, пока пользователь логинится в терминале (таймаут 60 с).
    static func waitReady(_ s: Session, timeout: Duration = .seconds(60)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if Task.isCancelled { return false }
            if await isReady(s) { return true }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return false
    }

    static func exit(_ s: Session) {
        Task.detached { _ = try? await ProcessRunner.run(SSHCommandBuilder.ssh, SSHCommandBuilder.controlArgs(s, "exit")) }
    }
}
