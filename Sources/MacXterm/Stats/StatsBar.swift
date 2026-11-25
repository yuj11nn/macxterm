import SwiftUI

/// Нижняя строка состояния: подключение и метрики сервера активной вкладки.
struct StatsBar: View {
    let tab: TerminalSession?

    var body: some View {
        HStack(spacing: 8) {
            if let tab {
                ConnectionLabel(tab: tab)
                Spacer(minLength: 8)
                if tab.state == .connected { MetricsRow(poller: tab.stats) }
            } else {
                Text("Не подключено").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct ConnectionLabel: View {
    let tab: TerminalSession

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(destination).font(.system(size: 11, design: .monospaced)).lineLimit(1)
            if tab.state != .connected {
                Text(tab.state == .connecting ? "подключение…" : "отключено")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .help(tab.session.destination + (tab.session.port != 22 ? ":\(tab.session.port)" : ""))
    }

    private var destination: String {
        let s = tab.session
        var d = s.destination + (s.port != 22 ? ":\(s.port)" : "")
        if let h = tab.stats.stats?.hostname, !h.isEmpty, h != s.host, !s.host.hasPrefix(h + ".") {
            d += "  (\(h))"
        }
        return d
    }

    private var color: Color {
        switch tab.state { case .connected: .green; case .connecting: .yellow; case .disconnected: .red }
    }
}

private enum Metric: Hashable { case cpu, mem, disk, load, net, uptime }

private struct MetricsRow: View {
    let poller: StatsPoller
    @State private var open: Metric?
    @AppStorage(Prefs.statsEnabledKey) private var enabled = true

    var body: some View {
        if !enabled {
            EmptyView()
        } else if poller.unavailable {
            Label("stats unavailable", systemImage: "chart.line.downtrend.xyaxis")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .help("Сервер не отдаёт /proc (не Linux) — метрики недоступны")
        } else if let st = poller.stats {
            HStack(spacing: 2) {
                chip(.cpu, help: "Загрузка процессора") {
                    let cpu = st.cpu ?? 0
                    Image(systemName: "cpu").foregroundStyle(.secondary)
                    Sparkline(values: poller.cpuHistory, color: .load(cpu)).frame(width: 60, height: 14)
                    Text(st.cpu.map { String(format: "%3.0f%%", $0) } ?? " —").monospacedDigit()
                        .frame(minWidth: 30, alignment: .trailing)
                }
                chip(.mem, help: "Память: занято / всего") {
                    Image(systemName: "memorychip").foregroundStyle(.secondary)
                    Text("\(Fmt.bytes(st.memUsed)) / \(Fmt.bytes(st.memTotal))").monospacedDigit()
                        .foregroundStyle(st.memPercent >= 90 ? Color.red : Color.primary)
                }
                chip(.disk, help: "Заполнение корневого раздела") {
                    Image(systemName: "internaldrive").foregroundStyle(.secondary)
                    Text("\(st.diskPercent)%").monospacedDigit()
                        .foregroundStyle(st.diskPercent >= 90 ? Color.red : Color.primary)
                }
                chip(.load, help: "Load average (1, 5, 15 мин)") {
                    Image(systemName: "gauge.with.dots.needle.33percent").foregroundStyle(.secondary)
                    Text(st.load.map { String(format: "%.2f", $0) }.joined(separator: " ")).monospacedDigit()
                        .foregroundStyle((st.load.first ?? 0) > Double(st.cores) ? Color.orange : Color.primary)
                }
                chip(.net, help: "Сеть: приём / передача") {
                    Text("↓ \(Fmt.rate(st.rxRate))  ↑ \(Fmt.rate(st.txRate))").monospacedDigit()
                }
                chip(.uptime, help: "Время работы сервера") {
                    Image(systemName: "clock").foregroundStyle(.secondary)
                    Text(Fmt.uptime(st.uptime))
                }
            }
            .font(.system(size: 11))
            .fixedSize()
        } else {
            ProgressView().controlSize(.mini)
        }
    }

    private func chip<C: View>(_ m: Metric, help: String, @ViewBuilder _ content: () -> C) -> some View {
        Button { open = m } label: {
            HStack(spacing: 4) { content() }
                .padding(.horizontal, 6).frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(open == m ? 0.1 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .popover(isPresented: Binding(get: { open == m }, set: { if !$0 { open = nil } }), arrowEdge: .top) {
            StatsDetail(poller: poller, metric: m)
        }
    }
}

/// Поповер с подробностями по метрике.
private struct StatsDetail: View {
    let poller: StatsPoller
    let metric: Metric

    var body: some View {
        if let st = poller.stats {
            VStack(alignment: .leading, spacing: 10) {
                switch metric {
                case .cpu:
                    header("Процессор", "cpu")
                    Sparkline(values: poller.cpuHistory, color: .load(st.cpu ?? 0))
                        .frame(width: 260, height: 60)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                    row("Сейчас", st.cpu.map { String(format: "%.1f %%", $0) } ?? "—")
                    row("Среднее за период", avg.map { String(format: "%.1f %%", $0) } ?? "—")
                    row("Пик за период", poller.cpuHistory.max().map { String(format: "%.1f %%", $0) } ?? "—")
                    row("Ядер", "\(st.cores)")
                case .mem:
                    header("Память", "memorychip")
                    bar(st.memPercent)
                    row("Занято", "\(Fmt.bytes(st.memUsed)) из \(Fmt.bytes(st.memTotal))")
                    row("Доступно", Fmt.bytes(st.memTotal - st.memUsed))
                    if st.swapTotal > 0 {
                        row("Swap", "\(Fmt.bytes(st.swapUsed)) из \(Fmt.bytes(st.swapTotal))")
                    } else {
                        row("Swap", "нет")
                    }
                case .disk:
                    header("Диск /", "internaldrive")
                    bar(Double(st.diskPercent))
                    row("Занято", "\(Fmt.bytes(st.diskUsed)) из \(Fmt.bytes(st.diskTotal))")
                    row("Свободно", Fmt.bytes(st.diskTotal > st.diskUsed ? st.diskTotal - st.diskUsed : 0))
                case .load:
                    header("Load average", "gauge.with.dots.needle.33percent")
                    ForEach(Array(zip(["1 мин", "5 мин", "15 мин"], st.load)), id: \.0) { name, v in
                        row(name, String(format: "%.2f  (%.0f%% от %d ядер)", v, v / Double(st.cores) * 100, st.cores))
                    }
                case .net:
                    header("Сеть (все интерфейсы, кроме lo)", "network")
                    row("Приём", Fmt.rate(st.rxRate))
                    row("Передача", Fmt.rate(st.txRate))
                case .uptime:
                    header("Сервер", "server.rack")
                    row("Хост", st.hostname.isEmpty ? "—" : st.hostname)
                    row("Работает", Fmt.uptime(st.uptime, long: true))
                    row("Запущен", Date(timeIntervalSinceNow: -st.uptime).formatted(date: .abbreviated, time: .shortened))
                }
                Text("Обновление каждые \(Int(Prefs.statsInterval)) с").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(minWidth: 260, alignment: .leading)
        }
    }

    private var avg: Double? {
        poller.cpuHistory.isEmpty ? nil : poller.cpuHistory.reduce(0, +) / Double(poller.cpuHistory.count)
    }

    private func header(_ t: String, _ icon: String) -> some View {
        Label(t, systemImage: icon).font(.headline)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(v).monospacedDigit().textSelection(.enabled)
        }
        .font(.callout)
    }

    private func bar(_ p: Double) -> some View {
        ProgressView(value: max(0, min(100, p)), total: 100).tint(.load(p))
    }
}

/// Форматирование размеров, скоростей и времени работы.
enum Fmt {
    static func bytes(_ b: UInt64) -> String {
        let units = ["Б", "КБ", "МБ", "ГБ", "ТБ", "ПБ"]
        var v = Double(b), i = 0
        while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
        return i == 0 ? "\(b) Б" : String(format: v >= 100 ? "%.0f %@" : "%.1f %@", v, units[i])
    }

    static func rate(_ r: Double?) -> String {
        guard let r else { return "—" }
        let kb = r / 1024
        if kb >= 1024 { return String(format: "%.1f МБ/с", kb / 1024) }
        return String(format: kb >= 100 ? "%.0f КБ/с" : "%.1f КБ/с", kb)
    }

    static func uptime(_ t: TimeInterval, long: Bool = false) -> String {
        let s = Int(t)
        let d = s / 86400, h = s % 86400 / 3600, m = s % 3600 / 60
        if long { return "\(d) д \(h) ч \(m) мин" }
        if d > 0 { return "\(d)д \(h)ч" }
        if h > 0 { return "\(h)ч \(m)м" }
        return "\(m)м"
    }
}
