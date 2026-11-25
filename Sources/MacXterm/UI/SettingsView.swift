import SwiftUI

struct SettingsView: View {
    @AppStorage(Prefs.theme) private var theme = TerminalTheme.defaultDark.rawValue
    @AppStorage(Prefs.fontName) private var fontName = Prefs.systemMono
    @AppStorage(Prefs.fontSize) private var fontSize = 13.0
    @AppStorage(Prefs.copyOnSelect) private var copyOnSelect = false
    @AppStorage(Prefs.pasteOnRightClick) private var pasteOnRightClick = false
    @AppStorage(Prefs.statsEnabledKey) private var statsEnabled = true
    @AppStorage(Prefs.statsIntervalKey) private var statsInterval = 3.0
    @AppStorage(AgentController.enabledKey) private var agentEnabled = false
    @AppStorage(AgentController.confirmKey) private var agentConfirm = true
    @State private var fonts = Prefs.monospacedFonts

    var body: some View {
        Form {
            Section("Терминал") {
                Picker("Тема", selection: $theme) {
                    ForEach(TerminalTheme.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("Шрифт", selection: $fontName) {
                    ForEach(fonts, id: \.self) { Text($0).tag($0) }
                }
                Stepper(value: $fontSize, in: 8...32, step: 1) {
                    LabeledContent("Размер", value: "\(Int(fontSize)) pt")
                }
            }
            Section("Мышь") {
                Toggle("Копировать выделенный текст", isOn: $copyOnSelect)
                Toggle("Вставка правой кнопкой", isOn: $pasteOnRightClick)
            }
            Section("Монитор сервера") {
                Toggle("Показывать метрики в строке состояния", isOn: $statsEnabled)
                Picker("Интервал опроса", selection: $statsInterval) {
                    ForEach([1.0, 2, 3, 5, 10, 30], id: \.self) { Text("\(Int($0)) с").tag($0) }
                }
                .disabled(!statsEnabled)
            }
            Section {
                Toggle("Разрешить ИИ-агентам (MCP) работать с серверами", isOn: $agentEnabled)
                Toggle("Спрашивать перед командами и записью файлов", isOn: $agentConfirm)
                    .disabled(!agentEnabled)
                AgentSetupCard().disabled(!agentEnabled)
            } header: {
                Text("Агент")
            } footer: {
                Text("Любой MCP-клиент (Claude, Cursor, Codex, VS Code и другие) подключается к MacXterm локально и работает с сохранёнными сессиями. Пароли остаются в Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize()
    }
}
