import SwiftUI

enum SidebarTab: String, CaseIterable, Identifiable {
    case sessions, sftp, commands
    var id: String { rawValue }
    var title: String {
        switch self { case .sessions: "Сессии"; case .sftp: "SFTP"; case .commands: "Команды" }
    }
    var icon: String {
        switch self { case .sessions: "server.rack"; case .sftp: "folder"; case .commands: "terminal" }
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
            }
            .transaction { $0.animation = nil } // без «наплыва» панелей друг на друга
        }
    }
}

private struct SidebarSwitcher: View {
    @Environment(AppState.self) private var app
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SidebarTab.allCases) { t in
                let on = app.sidebarTab == t
                Button {
                    withAnimation(.snappy(duration: 0.18)) { app.sidebarTab = t }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: t.icon).font(.system(size: 11, weight: .medium))
                        Text(t.title).font(.system(size: 12, weight: on ? .semibold : .regular))
                        if t == .sftp, let tab = app.activeTab, tab.state == .connected {
                            Circle().fill(.green).frame(width: 5, height: 5)
                        }
                    }
                    .foregroundStyle(on ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity).frame(height: 24)
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
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    private func help(_ t: SidebarTab) -> String {
        switch t {
        case .sessions: "Сохранённые сессии (⌃1)"
        case .sftp: "Файлы сервера активной вкладки (⌃2)"
        case .commands: "Популярные и свои команды (⌃3)"
        }
    }
}
