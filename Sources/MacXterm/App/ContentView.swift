import SwiftUI

/// Главное окно: сайдбар (сессии + SFTP) и область вкладок с терминалом.
struct ContentView: View {
    @Environment(AppState.self) private var app
    @AppStorage(Prefs.theme) private var theme = TerminalTheme.defaultDark.rawValue
    @AppStorage(Prefs.fontName) private var fontName = Prefs.systemMono
    @AppStorage(Prefs.fontSize) private var fontSize = 13.0
    @AppStorage(Prefs.copyOnSelect) private var copyOnSelect = false
    @AppStorage(Prefs.pasteOnRightClick) private var pasteOnRightClick = false
    @AppStorage(Prefs.statsEnabledKey) private var statsEnabled = true

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 320, max: 720)
        } detail: {
            VStack(spacing: 0) {
                if !app.tabs.isEmpty { TabBar() }
                if app.multiExec { MultiExecBanner() }
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
                StatsBar(tab: app.activeTab)
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
        .sheet(item: $app.renamingTab) { t in RenameTabSheet(tab: t) }
        .onChange(of: theme) { app.applyTerminalSettings() }
        .onChange(of: fontName) { app.applyTerminalSettings() }
        .onChange(of: fontSize) { app.applyTerminalSettings() }
        .onChange(of: copyOnSelect) { app.applyTerminalSettings() }
        .onChange(of: pasteOnRightClick) { app.applyTerminalSettings() }
        .onChange(of: statsEnabled) { app.applyStatsSettings() }
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

/// Плашка включённого multi-exec — чтобы не забыть, что ввод уходит во все вкладки.
private struct MultiExecBanner: View {
    @Environment(AppState.self) private var app
    var body: some View {
        let n = app.tabs.filter { $0.state == .connected }.count
        HStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right")
            Text("Multi-exec: ввод отправляется во все подключённые вкладки (\(n))")
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Button("Выключить  ⇧⌘I") { app.multiExec = false }
                .buttonStyle(.borderless).font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).frame(height: 26)
        .background(Color.orange.gradient)
    }
}

private struct RenameTabSheet: View {
    @Environment(\.dismiss) private var dismiss
    let tab: TerminalSession
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Имя вкладки").font(.headline)
            TextField(tab.title, text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            Text("Пустое имя — заголовок от сервера.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 340)
        .onAppear { name = tab.customTitle ?? "" }
    }

    private func save() {
        let t = name.trimmingCharacters(in: .whitespaces)
        tab.customTitle = t.isEmpty ? nil : t
        dismiss()
    }
}
