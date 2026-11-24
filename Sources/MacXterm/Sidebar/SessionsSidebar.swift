import SwiftUI

enum SidebarID: Hashable {
    case folder(UUID)
    case session(UUID)
}

/// Список сохранённых сессий с папками и поиском.
struct SessionsSidebar: View {
    @Environment(AppState.self) private var app
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var selection: Set<SidebarID> = []
    @State private var renaming: Folder?
    @State private var folderName = ""
    @State private var deleting: [Session] = []
    @State private var deletingFolder: Folder?

    private var store: SessionStore { app.store }

    private var filtered: [Session] {
        let q = search.lowercased()
        return store.sessions.filter {
            $0.name.lowercased().contains(q) || $0.host.lowercased().contains(q) || $0.user.lowercased().contains(q)
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private func sessions(in folder: UUID?) -> [Session] {
        store.sessions.filter { $0.folderId == folder }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            List(selection: $selection) {
                if search.isEmpty {
                    ForEach(store.folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { f in
                        DisclosureGroup(isExpanded: Binding(get: { f.expanded }, set: { store.setExpanded(f.id, $0) })) {
                            ForEach(sessions(in: f.id)) { row($0) }
                        } label: {
                            FolderLabel(folder: f, count: sessions(in: f.id).count)
                                .tag(SidebarID.folder(f.id))
                        }
                    }
                    ForEach(sessions(in: nil)) { row($0) }
                } else {
                    ForEach(filtered) { row($0) }
                }
            }
            .listStyle(.sidebar)
            .contextMenu(forSelectionType: SidebarID.self) { ids in
                menu(for: ids)
            } primaryAction: { ids in
                for id in ids { if case .session(let sid) = id { app.connect(sessionID: sid) } }
            }
            .overlay {
                if store.sessions.isEmpty && store.folders.isEmpty {
                    VStack(spacing: 8) {
                        Text("Нет сохранённых сессий").foregroundStyle(.secondary)
                        Button("Создать сессию") { app.newSession() }
                    }
                } else if !search.isEmpty && filtered.isEmpty {
                    Text("Ничего не найдено").foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: app.focusSearch) { searchFocused = true }
        .alert("Папка", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Название", text: $folderName)
            Button("Сохранить") {
                if let f = renaming, !folderName.isEmpty {
                    if store.folders.contains(where: { $0.id == f.id }) { store.renameFolder(f.id, to: folderName) }
                    else { var nf = f; nf.name = folderName; store.folders.append(nf) }
                }
                renaming = nil
            }
            Button("Отмена", role: .cancel) { renaming = nil }
        }
        .confirmationDialog(deleting.count == 1 ? "Удалить сессию «\(deleting[0].displayName)»?" : "Удалить сессии (\(deleting.count))?",
                            isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } })) {
            Button("Удалить", role: .destructive) { deleting.forEach { store.delete(sessionID: $0.id) }; deleting = [] }
        } message: { Text("Сохранённые пароли тоже будут удалены из Keychain.") }
        .confirmationDialog("Удалить папку «\(deletingFolder?.name ?? "")»?",
                            isPresented: Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } })) {
            Button("Удалить", role: .destructive) { if let f = deletingFolder { store.deleteFolder(f.id) }; deletingFolder = nil }
        } message: { Text("Сессии из папки переместятся в корень.") }
    }

    private var header: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 11))
                TextField("Поиск", text: $search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { if let s = filtered.first { app.connect(s) } }
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            Menu {
                Button("Новая сессия…") { app.newSession() }
                Button("Новая папка…") { folderName = ""; renaming = Folder(name: "") }
            } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Добавить")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func row(_ s: Session) -> some View {
        SessionRow(session: s, connected: app.tabs.contains { $0.session.id == s.id && $0.state == .connected })
            .tag(SidebarID.session(s.id))
            .draggable(s.id.uuidString)
    }

    @ViewBuilder
    private func menu(for ids: Set<SidebarID>) -> some View {
        let sessionIDs = ids.compactMap { if case .session(let x) = $0 { x } else { nil } }
        let folderIDs = ids.compactMap { if case .folder(let x) = $0 { x } else { nil } }
        if ids.isEmpty {
            Button("Новая сессия…") { app.newSession() }
            Button("Новая папка…") { folderName = ""; renaming = Folder(name: "") }
        } else if let fid = folderIDs.first, sessionIDs.isEmpty, let f = store.folders.first(where: { $0.id == fid }) {
            Button("Подключить все") { sessions(in: fid).forEach { app.connect($0) } }
            Button("Новая сессия в папке…") { app.newSession(folder: fid) }
            Divider()
            Button("Переименовать…") { folderName = f.name; renaming = f }
            Button("Удалить папку…", role: .destructive) { deletingFolder = f }
        } else if !sessionIDs.isEmpty {
            Button(sessionIDs.count > 1 ? "Подключить (\(sessionIDs.count))" : "Подключить") {
                sessionIDs.forEach { app.connect(sessionID: $0) }
            }
            if sessionIDs.count == 1, let id = sessionIDs.first {
                Button("Изменить…") { app.edit(id) }
                Button("Дублировать") { store.duplicate(id) }
                Button("Копировать ssh-команду") { app.copySSHCommand(id) }
            }
            Menu("Переместить в") {
                Button("Без папки") { sessionIDs.forEach { store.move(sessionID: $0, toFolder: nil) } }
                ForEach(store.folders) { f in
                    Button(f.name) { sessionIDs.forEach { store.move(sessionID: $0, toFolder: f.id) } }
                }
            }
            Divider()
            Button("Удалить…", role: .destructive) { deleting = sessionIDs.compactMap { store.session($0) } }
        }
    }
}

private struct FolderLabel: View {
    @Environment(AppState.self) private var app
    let folder: Folder
    let count: Int
    @State private var target = false

    var body: some View {
        HStack {
            Label(folder.name, systemImage: target ? "folder.fill.badge.plus" : "folder")
            Spacer()
            Text("\(count)").font(.caption).foregroundStyle(.tertiary)
        }
        .dropDestination(for: String.self) { items, _ in
            items.compactMap(UUID.init(uuidString:)).forEach { app.store.move(sessionID: $0, toFolder: folder.id) }
            return true
        } isTargeted: { target = $0 }
    }
}

private struct SessionRow: View {
    let session: Session
    let connected: Bool

    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "server.rack")
                    .foregroundStyle(SessionColor(rawValue: session.color ?? "")?.color ?? .accentColor)
                    .frame(width: 18)
                if connected {
                    Circle().fill(.green).frame(width: 6, height: 6).offset(x: 2, y: 2)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayName).lineLimit(1)
                if session.name != session.host && !session.name.isEmpty {
                    Text(session.destination + (session.port != 22 ? ":\(session.port)" : ""))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .help(SSHCommandBuilder.shellCommand(session))
    }
}
