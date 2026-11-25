import AppKit
import SwiftUI

/// Вкладка «Агент»: доступ ИИ-агентов к серверам через MCP, подключение клиентов и журнал действий.
struct AgentPanel: View {
    @Environment(AppState.self) private var app
    @AppStorage(AgentController.enabledKey) private var enabled = false
    @AppStorage(AgentController.confirmKey) private var confirm = true

    private var agent: AgentController { app.agent }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !enabled {
                intro
            } else if agent.entries.isEmpty {
                ScrollView {
                    VStack(spacing: 14) {
                        if agent.clientCount == 0 { AgentSetupCard() }
                        examples
                    }
                    .padding(12)
                }
            } else {
                log
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 26, height: 26)
                    Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("ИИ-агент").font(.system(size: 13, weight: .semibold))
                    HStack(spacing: 4) {
                        Circle().fill(statusColor).frame(width: 6, height: 6)
                        Text(statusText).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Toggle("", isOn: $enabled).toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .help("Разрешить ИИ-агентам работать с серверами через MacXterm")
            }
            if enabled {
                Toggle(isOn: $confirm) {
                    Text("Спрашивать перед командами и записью файлов").font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
                .onChange(of: confirm) { if confirm { agent.revokeTrust() } }
            }
        }
        .padding(12)
    }

    private var statusColor: Color {
        !enabled ? .gray : agent.clientCount > 0 ? .green : .orange
    }

    private var statusText: String {
        if !enabled { return "Выключен" }
        if agent.clientCount > 0 { return "\(agent.displayClient) подключён" }
        return "Ждёт подключения"
    }

    private var intro: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Дайте ИИ-агенту доступ к вашим серверам")
                    .font(.system(size: 13, weight: .semibold))
                Text("MacXterm работает как MCP-сервер. Любой агент с поддержкой MCP — Claude, Cursor, Codex, VS Code и другие — подключается к нему и выполняет то, что вы попросите, на ваших сохранённых серверах. Пароли остаются в Keychain, агент их не видит.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    feature("checkmark.shield", "Команды и запись файлов — только после вашего подтверждения")
                    feature("eye", "Все действия видны здесь и во вкладках")
                    feature("lock", "Работает только на этом Mac, без облака")
                }
                Button { enabled = true } label: {
                    Text("Включить агента").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            }
            .padding(14)
        }
    }

    private func feature(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(.purple).frame(width: 16)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var examples: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Попросите агента, например:").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(["Почему тормозит prod-web? Посмотри нагрузку и логи",
                     "Обнови пакеты на staging и перезапусти nginx",
                     "Найди, что съело место на диске",
                     "Настрой бэкап базы по крону каждую ночь"], id: \.self) { s in
                Text("«\(s)»").font(.system(size: 12)).foregroundStyle(.primary.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var log: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Журнал").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Очистить") { agent.clearLog() }.buttonStyle(.link).font(.system(size: 11))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            List {
                ForEach(agent.entries) { AgentEntryRow(entry: $0) }
            }
            .listStyle(.sidebar)
            if agent.clientCount == 0 {
                Divider()
                AgentSetupCard().padding(10)
            }
        }
    }
}

private struct AgentEntryRow: View {
    let entry: AgentController.Entry
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                statusIcon
                Text(title).font(.system(size: 11, weight: .semibold))
                Text(entry.target).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Text(entry.date, style: .time).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Text(entry.detail)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(expanded ? nil : 2)
                .textSelection(.enabled)
            if expanded && !entry.output.isEmpty {
                Text(entry.output)
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy(duration: 0.15)) { expanded.toggle() } }
    }

    private var title: String {
        switch entry.tool {
        case "run_command": "Команда"
        case "terminal_send": "Ввод"
        case "read_file": "Чтение"
        case "write_file": "Запись"
        case "list_directory": "Папка"
        default: entry.tool
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch entry.status {
        case .waiting: Image(systemName: "hand.raised.fill").foregroundStyle(.orange).help("Ждёт вашего подтверждения")
        case .running: ProgressView().controlSize(.mini)
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let m): Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).help(m)
        case .denied: Image(systemName: "xmark.circle.fill").foregroundStyle(.red).help("Отклонено")
        }
    }
}

/// Подключение MacXterm к любому MCP-клиенту: конфиг в один клик или команда для Терминала.
struct AgentSetupCard: View {
    @Environment(AppState.self) private var app
    @State private var installed: Set<AgentClient> = []

    private var exe: String { app.agent.executablePath }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Подключить агента").font(.system(size: 12, weight: .semibold))
            ForEach(AgentClient.allCases) { c in
                HStack(spacing: 6) {
                    Text(c.title).font(.system(size: 12))
                    Spacer(minLength: 4)
                    if c.configURL != nil {
                        if installed.contains(c) {
                            Label("Подключён", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 11)).foregroundStyle(.green).labelStyle(.titleAndIcon)
                        } else {
                            Button("Добавить") { install(c) }.controlSize(.small)
                        }
                    } else if let cmd = c.command(exe) {
                        Button("Команда") { copy(cmd, "Команда для \(c.title) скопирована — выполните её в Терминале") }
                            .controlSize(.small)
                            .help(cmd)
                    }
                }
            }
            Divider().padding(.vertical, 2)
            HStack {
                Text("Другой агент").font(.system(size: 12))
                Spacer()
                Button("JSON") { copy(AgentClient.genericJSON(exe), "Конфиг MCP скопирован") }
                    .controlSize(.small)
                    .help("Скопировать конфигурацию MCP-сервера для любого клиента")
            }
            if !exe.hasPrefix("/Applications/") {
                Text("Совет: сначала переместите MacXterm в «Программы», иначе путь в настройках агента сломается.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.purple.opacity(0.08)))
        .onAppear { installed = Set(AgentClient.allCases.filter(\.isInstalled)) }
    }

    private func install(_ c: AgentClient) {
        do {
            try c.install(exe)
            installed.insert(c)
            app.showToast("\(c.title): MacXterm добавлен. \(c.restartHint)", icon: "sparkles")
        } catch {
            app.showToast(error.localizedDescription, icon: "exclamationmark.triangle", isError: true)
        }
    }

    private func copy(_ text: String, _ toast: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        app.showToast(toast, icon: "doc.on.doc")
    }
}
