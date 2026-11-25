import SwiftUI

/// Главное окно: сайдбар (сессии + SFTP) и область вкладок с терминалом.
struct ContentView: View {
    @Environment(AppState.self) private var app
    @AppStorage(Prefs.theme) private var theme = TerminalTheme.defaultDark.rawValue
    @AppStorage(Prefs.fontName) private var fontName = Prefs.systemMono
    @AppStorage(Prefs.fontSize) private var fontSize = 13.0
    @AppStorage(Prefs.copyOnSelect) private var copyOnSelect = false
    @AppStorage(Prefs.pasteOnRightClick) private var pasteOnRightClick = false

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 320, max: 720)
        } detail: {
            VStack(spacing: 0) {
                if !app.tabs.isEmpty { TabBar() }
                ZStack {
                    if let tab = app.activeTab {
                        Color(nsColor: Prefs.currentTheme.background)
                        TerminalHostView(terminal: tab)
                            .padding(.leading, 6).padding(.top, 4)
                        if tab.state == .disconnected { DisconnectedOverlay(tab: tab) }
                    } else {
                        EmptyStateView()
                    }
                }
                StatusBar(tab: app.activeTab)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { app.showQuickConnect = true } label: { Label("Подключиться", systemImage: "bolt.horizontal") }
                        .help("Быстрое подключение (⌘T)")
                }
            }
        }
        .overlay(alignment: .bottom) { ToastView() }
        .sheet(isPresented: $app.showQuickConnect) { QuickConnectSheet() }
        .sheet(item: $app.editorTarget) { t in SessionEditor(target: t) }
        .onChange(of: theme) { app.applyTerminalSettings() }
        .onChange(of: fontName) { app.applyTerminalSettings() }
        .onChange(of: fontSize) { app.applyTerminalSettings() }
        .onChange(of: copyOnSelect) { app.applyTerminalSettings() }
        .onChange(of: pasteOnRightClick) { app.applyTerminalSettings() }
        .onChange(of: app.activeTabID) { app.activeTab?.focus() }
    }
}

private struct DisconnectedOverlay: View {
    let tab: TerminalSession
    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                Image(systemName: "bolt.slash.fill").foregroundStyle(.red)
                Text("Соединение закрыто" + (tab.exitCode.map { $0 != 0 ? " (код \($0))" : "" } ?? ""))
                    .font(.callout.weight(.medium))
                Button { tab.reconnect() } label: { Label("Переподключить (R)", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
            .padding(.bottom, 24)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

private struct EmptyStateView: View {
    @Environment(AppState.self) private var app
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "terminal").font(.system(size: 46, weight: .thin)).foregroundStyle(.secondary)
            Text("Нет открытых сессий").font(.title3.weight(.medium))
            Text("Дважды щёлкните сессию в списке слева или подключитесь быстро.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Быстрое подключение  ⌘T") { app.showQuickConnect = true }
                Button("Новая сессия  ⌘N") { app.newSession() }
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

/// Нижняя строка состояния (метрики сервера появятся на этапе 3).
struct StatusBar: View {
    let tab: TerminalSession?
    var body: some View {
        HStack(spacing: 8) {
            if let tab {
                Circle().fill(color(tab.state)).frame(width: 7, height: 7)
                Text(tab.session.destination + (tab.session.port != 22 ? ":\(tab.session.port)" : ""))
                    .font(.system(size: 11, design: .monospaced))
                Text(label(tab.state)).font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Text("Не подключено").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
    private func color(_ s: ConnectionState) -> Color {
        switch s { case .connected: .green; case .connecting: .yellow; case .disconnected: .red }
    }
    private func label(_ s: ConnectionState) -> String {
        switch s { case .connected: "подключено"; case .connecting: "подключение…"; case .disconnected: "отключено" }
    }
}
