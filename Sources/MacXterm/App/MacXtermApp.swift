import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (() -> Void)?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { onTerminate?() }
}

struct MacXtermApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppState()

    var body: some Scene {
        Window("MacXterm", id: "main") {
            ContentView()
                .environment(app)
                .frame(minWidth: 820, minHeight: 480)
                .onAppear {
                    delegate.onTerminate = { [app] in
                        MainActor.assumeIsolated {
                            app.store.saveNow()
                            app.closeAll()
                        }
                    }
                }
        }
        .defaultSize(width: 1200, height: 760)
        .commands { AppCommands(app: app) }

        Settings {
            SettingsView().environment(app)
        }
    }
}

struct AppCommands: Commands {
    let app: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Быстрое подключение…") { app.showQuickConnect = true }
                .keyboardShortcut("t")
            Button("Новая сессия…") { app.newSession() }
                .keyboardShortcut("n")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Закрыть вкладку") { app.closeActiveTabOrWindow() }
                .keyboardShortcut("w")
        }
        CommandGroup(after: .textEditing) {
            Button("Найти в терминале…") { app.find() }
                .keyboardShortcut("f")
            Button("Найти далее") { app.activeTab?.find(.next) }
                .keyboardShortcut("g")
            Button("Найти ранее") { app.activeTab?.find(.previous) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Divider()
            Button("Найти сессию") { app.focusSessionSearch() }
                .keyboardShortcut("f", modifiers: [.command, .option])
            Button("Найти команду") { app.showCommands() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
        }
        CommandGroup(after: .sidebar) {
            Button("Сессии") { app.sidebarTab = .sessions }
                .keyboardShortcut("1", modifiers: .control)
            Button("SFTP") { app.sidebarTab = .sftp }
                .keyboardShortcut("2", modifiers: .control)
            Button("Команды") { app.sidebarTab = .commands }
                .keyboardShortcut("3", modifiers: .control)
            Divider()
        }
        CommandMenu("Терминал") {
            Button("Очистить") { app.activeTab?.clear() }
                .keyboardShortcut("k")
            Button("Переподключить") { app.activeTab?.reconnect() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Переподключить все разорванные") { app.reconnectAll() }
            Button("Сохранить вывод в файл…") { app.saveOutput() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(app.activeTab == nil)
            Divider()
            Button("Увеличить шрифт") { app.changeFontSize(1) }
                .keyboardShortcut("+")
            Button("Увеличить шрифт") { app.changeFontSize(1) }
                .keyboardShortcut("=")
            Button("Уменьшить шрифт") { app.changeFontSize(-1) }
                .keyboardShortcut("-")
            Button("Обычный размер") { app.changeFontSize(0) }
                .keyboardShortcut("0")
        }
        CommandMenu("Вкладки") {
            Toggle("Multi-exec: ввод во все вкладки", isOn: Binding(get: { app.multiExec }, set: { app.multiExec = $0 }))
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Переименовать вкладку…") { app.renamingTab = app.activeTab }
                .disabled(app.activeTab == nil)
            Button("Дублировать вкладку") { if let t = app.activeTab { app.duplicateTab(t) } }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(app.activeTab == nil)
            Divider()
            Button("Следующая вкладка") { app.selectAdjacentTab(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Предыдущая вкладка") { app.selectAdjacentTab(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            ForEach(1..<10) { n in
                Button("Вкладка \(n)") { app.selectTab(index: n - 1) }
                    .keyboardShortcut(KeyEquivalent(Character(String(n))))
            }
        }
    }
}
