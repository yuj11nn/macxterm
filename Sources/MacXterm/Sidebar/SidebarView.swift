import SwiftUI

enum SidebarTab: String, CaseIterable, Identifiable {
    case sessions, sftp, commands, agent
    var id: String { rawValue }
    var title: String {
        switch self { case .sessions: "Сессии"; case .sftp: "SFTP"; case .commands: "Команды"; case .agent: "Агент" }
    }
    var icon: String {
        switch self { case .sessions: "server.rack"; case .sftp: "folder"; case .commands: "terminal"; case .agent: "sparkles" }
    }
}

/// Сайдбар как в MobaXterm: вкладки «Сессии / SFTP / Команды», каждая на всю высоту.
/// При подключении сам переключается на SFTP, при закрытии всех вкладок — обратно на сессии.
struct SidebarView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            SidebarSwitcher()
            Divider()
            ZStack {
                // Все панели живут постоянно — состояние (поиск, прокрутка) не теряется при переключении.
                SessionsSidebar().opacity(app.sidebarTab == .sessions ? 1 : 0)
                    .allowsHitTesting(app.sidebarTab == .sessions)
                SFTPPanel().opacity(app.sidebarTab == .sftp ? 1 : 0)
                    .allowsHitTesting(app.sidebarTab == .sftp)
                CommandsPanel().opacity(app.sidebarTab == .commands ? 1 : 0)
                    .allowsHitTesting(app.sidebarTab == .commands)
                AgentPanel().opacity(app.sidebarTab == .agent ? 1 : 0)
                    .allowsHitTesting(app.sidebarTab == .agent)
            }
            .transaction { $0.animation = nil } // без «наплыва» панелей друг на друга
        }
    }
}

private struct SidebarSwitcher: View {
    @Environment(AppState.self) private var app
    @Namespace private var ns
    /// Подпись только у выбранной вкладки — четыре вкладки помещаются в любой ширине сайдбара.
    private let compact = true

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SidebarTab.allCases) { t in
                let on = app.sidebarTab == t
                Button {
                    withAnimation(.snappy(duration: 0.18)) { app.sidebarTab = t }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: t.icon).font(.system(size: 11, weight: .medium))
                        if on || !compact {
                            Text(t.title).font(.system(size: 12, weight: on ? .semibold : .regular))
                                .lineLimit(1).fixedSize()
                        }
                        badge(t)
                    }
                    .foregroundStyle(on ? Color.primary : Color.secondary)
                    .frame(maxWidth: on || !compact ? .infinity : 40).frame(height: 24)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
                                .matchedGeometryEffect(id: "sel", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(help(t))
                .accessibilityLabel(t.title)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    @ViewBuilder
    private func badge(_ t: SidebarTab) -> some View {
        if t == .sftp, let tab = app.activeTab, tab.state == .connected {
            Circle().fill(.green).frame(width: 5, height: 5)
        } else if t == .agent, app.agent.clientCount > 0 {
            Circle().fill(.purple).frame(width: 5, height: 5)
        }
    }

    private func help(_ t: SidebarTab) -> String {
        switch t {
        case .sessions: "Сохранённые сессии (⌃1)"
        case .sftp: "Файлы сервера активной вкладки (⌃2)"
        case .commands: "Популярные и свои команды (⌃3)"
        case .agent: "ИИ-агенты через MCP (⌃4)"
        }
    }
}
