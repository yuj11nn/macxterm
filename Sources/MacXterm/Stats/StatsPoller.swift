import Foundation
import Observation

/// Снимок метрик сервера (то, что показывает строка состояния).
struct ServerStats: Sendable, Equatable {
    var cpu: Double?            // 0…100, nil до второго опроса
    var cores: Int = 1
    var memTotal: UInt64 = 0    // байты
    var memUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var swapUsed: UInt64 = 0
    var diskTotal: UInt64 = 0
    var diskUsed: UInt64 = 0
    var diskPercent: Int = 0
    var uptime: TimeInterval = 0
    var load: [Double] = []
    var rxRate: Double?         // байт/с
    var txRate: Double?
    var hostname: String = ""

    var memPercent: Double { memTotal > 0 ? Double(memUsed) / Double(memTotal) * 100 : 0 }
}

/// Счётчики, по дельте которых считаются CPU% и скорость сети.
struct StatsCounters: Sendable, Equatable {
    var cpuTotal: UInt64
    var cpuIdle: UInt64
    var rx: UInt64
    var tx: UInt64
    var uptime: TimeInterval
}

enum StatsParser {
    /// Скрипт из SPEC 3.5 (+ hostname). Ошибки глушим: на не-Linux первая секция будет пустой.
    static let script = """
    head -1 /proc/stat 2>/dev/null; echo ---
    grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo 2>/dev/null; echo ---
    df -Pk / 2>/dev/null | tail -1; echo ---
    cat /proc/uptime /proc/loadavg 2>/dev/null; echo ---
    cat /proc/net/dev 2>/dev/null | tail -n +3; echo ---
    nproc 2>/dev/null; echo ---
    uname -n 2>/dev/null
    """

    struct Result: Sendable {
        var stats: ServerStats
        var counters: StatsCounters
    }

    /// nil — сервер не отдаёт `/proc` (не Linux).
    static func parse(_ text: String) -> Result? {
        // Секции разделены строками «---»; пустые секции сохраняют позицию.
        let raw = ("\n" + text).components(separatedBy: "\n---")
        func section(_ i: Int) -> [String] {
            guard raw.indices.contains(i) else { return [] }
            return raw[i].components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }

        // 1. CPU
        guard let cpuLine = section(0).first(where: { $0.hasPrefix("cpu") }) else { return nil }
        let cpuNums = cpuLine.split(separator: " ").dropFirst().compactMap { UInt64($0) }
        guard cpuNums.count >= 4 else { return nil }
        let total = cpuNums.prefix(8).reduce(0, +)
        let idle = cpuNums[3] + (cpuNums.count > 4 ? cpuNums[4] : 0)

        var st = ServerStats()

        // 2. Память (кБ)
        var mem: [String: UInt64] = [:]
        for l in section(1) {
            let p = l.split(separator: " ", omittingEmptySubsequences: true)
            if p.count >= 2, let v = UInt64(p[1]) { mem[String(p[0].dropLast())] = v * 1024 }
        }
        st.memTotal = mem["MemTotal"] ?? 0
        st.memUsed = st.memTotal - min(st.memTotal, mem["MemAvailable"] ?? 0)
        st.swapTotal = mem["SwapTotal"] ?? 0
        st.swapUsed = st.swapTotal - min(st.swapTotal, mem["SwapFree"] ?? 0)

        // 3. Диск: fs blocks used avail cap% mount
        if let l = section(2).last {
            let p = l.split(separator: " ", omittingEmptySubsequences: true)
            if p.count >= 5 {
                st.diskTotal = (UInt64(p[1]) ?? 0) * 1024
                st.diskUsed = (UInt64(p[2]) ?? 0) * 1024
                st.diskPercent = Int(p[4].replacingOccurrences(of: "%", with: "")) ?? 0
            }
        }

        // 4. uptime + loadavg
        let ul = section(3)
        if let u = ul.first?.split(separator: " ").first { st.uptime = TimeInterval(u) ?? 0 }
        if ul.count > 1 { st.load = ul[1].split(separator: " ").prefix(3).compactMap { Double($0) } }

        // 5. Сеть: «iface: rx_bytes … (8 полей) tx_bytes …», без lo
        var rx: UInt64 = 0, tx: UInt64 = 0
        for l in section(4) {
            guard let colon = l.firstIndex(of: ":") else { continue }
            let name = l[..<colon].trimmingCharacters(in: .whitespaces)
            if name == "lo" { continue }
            let n = l[l.index(after: colon)...].split(separator: " ", omittingEmptySubsequences: true).compactMap { UInt64($0) }
            if n.count >= 9 { rx &+= n[0]; tx &+= n[8] }
        }

        // 6. nproc, 7. hostname
        st.cores = max(1, Int(section(5).first ?? "") ?? 1)
        st.hostname = section(6).first ?? ""

        return Result(stats: st, counters: StatsCounters(cpuTotal: total, cpuIdle: idle, rx: rx, tx: tx, uptime: st.uptime))
    }

    /// Дополняет снимок CPU% и скоростями по разнице с предыдущими счётчиками.
    static func applyDelta(_ st: inout ServerStats, prev: StatsCounters?, cur: StatsCounters) {
        guard let p = prev else { return }
        if cur.cpuTotal > p.cpuTotal {
            let dt = Double(cur.cpuTotal - p.cpuTotal)
            let di = Double(cur.cpuIdle >= p.cpuIdle ? cur.cpuIdle - p.cpuIdle : 0)
            st.cpu = max(0, min(100, (1 - di / dt) * 100))
        }
        let dt = cur.uptime - p.uptime
        if dt > 0.2, cur.rx >= p.rx, cur.tx >= p.tx {
            st.rxRate = Double(cur.rx - p.rx) / dt
            st.txRate = Double(cur.tx - p.tx) / dt
        }
    }
}

/// Периодический опрос метрик через ControlMaster. Работает только для активной подключённой вкладки.
@MainActor @Observable
final class StatsPoller {
    static let historySize = 60

    private(set) var stats: ServerStats?
    private(set) var cpuHistory: [Double] = []
    private(set) var unavailable = false
    private(set) var isRunning = false

    @ObservationIgnored private let session: Session
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var prev: StatsCounters?

    init(session: Session) { self.session = session }

    func start() {
        guard task == nil, !unavailable, Prefs.statsEnabled else { return }
        prev = nil // после паузы дельта за долгий промежуток не показательна
        isRunning = true
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce()
                guard !Task.isCancelled, self.task != nil else { return }
                try? await Task.sleep(for: .seconds(Prefs.statsInterval))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    /// Сброс при новом подключении.
    func reset() {
        stop()
        stats = nil
        cpuHistory = []
        unavailable = false
        prev = nil
    }

    private func pollOnce() async {
        let runner = SSHRunner(session: session)
        guard let r = try? await runner.run("sh -s", stdin: Data(StatsParser.script.utf8)), !Task.isCancelled else { return }
        let text = String(decoding: r.out, as: UTF8.self)
        guard r.code == 0 || !text.isEmpty else { return } // мастер ещё/уже недоступен — попробуем позже
        guard let res = StatsParser.parse(text) else {
            unavailable = true
            stats = nil
            stop()
            return
        }
        var st = res.stats
        StatsParser.applyDelta(&st, prev: prev, cur: res.counters)
        if let c = st.cpu {
            cpuHistory.append(c)
            if cpuHistory.count > Self.historySize { cpuHistory.removeFirst(cpuHistory.count - Self.historySize) }
        } else {
            // первый опрос после паузы: держим прошлые значения, пока нет дельты
            st.cpu = stats?.cpu
            st.rxRate = stats?.rxRate
            st.txRate = stats?.txRate
        }
        prev = res.counters
        stats = st
    }
}
