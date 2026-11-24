import AppKit
import SwiftUI

/// Sheet создания/редактирования сессии. Секреты пишутся только в Keychain.
struct SessionEditor: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let target: AppState.EditorTarget

    @State private var s: Session
    @State private var portText: String
    @State private var password = ""
    @State private var passphrase = ""
    @State private var hasPassword = false
    @State private var hasPassphrase = false
    @State private var forgetSecret = false
    @State private var color: SessionColor

    init(target: AppState.EditorTarget) {
        self.target = target
        _s = State(initialValue: target.session)
        _portText = State(initialValue: String(target.session.port))
        _color = State(initialValue: SessionColor(rawValue: target.session.color ?? "") ?? .none)
    }

    private var valid: Bool { !s.host.trimmingCharacters(in: .whitespaces).isEmpty && Int(portText) != nil }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Подключение") {
                    TextField("Название", text: $s.name, prompt: Text(s.host.isEmpty ? "prod-1" : s.host))
                    TextField("Хост", text: $s.host, prompt: Text("example.com или алиас из ~/.ssh/config"))
                    TextField("Порт", text: $portText)
                    TextField("Пользователь", text: $s.user, prompt: Text("root"))
                }
                Section("Аутентификация") {
                    Picker("Способ", selection: $s.authType) {
                        ForEach(AuthType.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    switch s.authType {
                    case .password:
                        SecureField("Пароль", text: $password,
                                    prompt: Text(hasPassword ? "сохранён в Keychain — оставьте пустым" : "не сохраняется, если пусто"))
                        if hasPassword { Toggle("Забыть сохранённый пароль", isOn: $forgetSecret) }
                    case .key:
                        HStack {
                            TextField("Ключ", text: Binding(get: { s.keyPath ?? "" }, set: { s.keyPath = $0.isEmpty ? nil : $0 }),
                                      prompt: Text("~/.ssh/id_ed25519"))
                            Button("Выбрать…") { pickKey() }
                        }
                        SecureField("Passphrase", text: $passphrase,
                                    prompt: Text(hasPassphrase ? "сохранена в Keychain — оставьте пустым" : "необязательно"))
                        if hasPassphrase { Toggle("Забыть passphrase", isOn: $forgetSecret) }
                    case .agent:
                        Text("Используются ssh-agent и ~/.ssh/config. Пароль, если нужен, вводится в терминале.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Section("Дополнительно") {
                    Picker("Папка", selection: $s.folderId) {
                        Text("Без папки").tag(UUID?.none)
                        ForEach(app.store.folders) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    Picker("Цвет", selection: $color) {
                        ForEach(SessionColor.allCases) { c in
                            if let col = c.color {
                                Label { Text(c.rawValue.capitalized) } icon: { Image(systemName: "circle.fill").foregroundStyle(col) }.tag(c)
                            } else { Text("Нет").tag(c) }
                        }
                    }
                    TextField("Начальный каталог", text: Binding(get: { s.initialRemoteDir ?? "" },
                                                                 set: { s.initialRemoteDir = $0.isEmpty ? nil : $0 }),
                              prompt: Text("/var/www"))
                    TextField("Доп. аргументы ssh", text: Binding(get: { s.extraSSHArgs ?? "" },
                                                                  set: { s.extraSSHArgs = $0.isEmpty ? nil : $0 }),
                              prompt: Text("-J bastion -o Compression=yes"))
                }
            }
            .formStyle(.grouped)
            HStack {
                if !target.isNew {
                    Text(SSHCommandBuilder.shellCommand(s)).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                Spacer()
                Button("Отмена", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                if target.isNew {
                    Button("Сохранить") { save(connect: false) }.disabled(!valid)
                }
                Button(target.isNew ? "Сохранить и подключить" : "Сохранить") { save(connect: target.isNew) }
                    .keyboardShortcut(.defaultAction).disabled(!valid)
            }
            .padding(14)
        }
        .frame(width: 500)
        .onAppear {
            hasPassword = Keychain.has(s.id, kind: .password)
            hasPassphrase = Keychain.has(s.id, kind: .passphrase)
        }
        .onChange(of: s.authType) { forgetSecret = false }
    }

    private func pickKey() {
        let p = NSOpenPanel()
        p.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
        p.showsHiddenFiles = true
        p.canChooseDirectories = false
        if p.runModal() == .OK, let url = p.url {
            s.keyPath = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        }
    }

    private func save(connect: Bool) {
        s.host = s.host.trimmingCharacters(in: .whitespaces)
        s.user = s.user.trimmingCharacters(in: .whitespaces)
        s.port = Int(portText) ?? 22
        s.color = color == .none ? nil : color.rawValue
        if s.name.trimmingCharacters(in: .whitespaces).isEmpty { s.name = s.host }
        switch s.authType {
        case .password:
            Keychain.delete(s.id, kind: .passphrase)
            if !password.isEmpty { Keychain.set(password, for: s.id, kind: .password) }
            else if forgetSecret { Keychain.delete(s.id, kind: .password) }
        case .key:
            Keychain.delete(s.id, kind: .password)
            if !passphrase.isEmpty { Keychain.set(passphrase, for: s.id, kind: .passphrase) }
            else if forgetSecret { Keychain.delete(s.id, kind: .passphrase) }
        case .agent:
            Keychain.deleteAll(for: s.id)
        }
        app.store.upsert(s)
        dismiss()
        if connect { app.connect(s) }
    }
}

/// ⌘T: быстрый ввод `user@host:port`.
struct QuickConnectSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @AppStorage("quickSave") private var saveToList = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Быстрое подключение").font(.headline)
            TextField("user@host:port", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .focused($focused)
                .onSubmit(go)
            Toggle("Сохранить в список сессий", isOn: $saveToList)
            if !app.store.sessions.isEmpty {
                let recent = app.store.sessions.filter { $0.lastUsed != nil }
                    .sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }.prefix(5)
                if !recent.isEmpty {
                    Text("Недавние").font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(recent)) { s in
                        Button { dismiss(); app.connect(s) } label: {
                            Label(s.displayName, systemImage: "clock.arrow.circlepath")
                        }.buttonStyle(.link)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Отмена", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Подключить", action: go).keyboardShortcut(.defaultAction)
                    .disabled(Session.parse(quick: text) == nil)
            }
        }
        .padding(18)
        .frame(width: 380)
        .onAppear { focused = true }
    }

    private func go() {
        guard let s = Session.parse(quick: text) else { return }
        if saveToList { app.store.upsert(s) }
        dismiss()
        app.connect(s)
    }
}
