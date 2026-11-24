import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// SFTP-панель активной вкладки (нижняя часть сайдбара).
struct SFTPPanel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            if let tab = app.activeTab {
                FileBrowser(tab: tab, fs: tab.fs).id(tab.id)
            } else {
                placeholder("Подключитесь к серверу", icon: "externaldrive.badge.wifi")
            }
            TransfersView()
        }
    }
}

func placeholder(_ text: String, icon: String) -> some View {
    VStack(spacing: 8) {
        Image(systemName: icon).font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary)
        Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}

private enum Prompt: Identifiable {
    case newFolder, newFile, rename(FileItem), chmod(FileItem)
    var id: String {
        switch self {
        case .newFolder: "nf"; case .newFile: "nfile"
        case .rename(let i): "r" + i.path; case .chmod(let i): "c" + i.path
        }
    }
    var title: String {
        switch self {
        case .newFolder: "Новая папка"; case .newFile: "Новый файл"
        case .rename: "Переименовать"; case .chmod: "Права доступа (восьмерично)"
        }
    }
}

private struct FileBrowser: View {
    @Environment(AppState.self) private var app
    let tab: TerminalSession
    @Bindable var fs: RemoteFS
    @State private var selection: Set<String> = []
    @State private var pathText = ""
    @State private var prompt: Prompt?
    @State private var promptText = ""
    @State private var deleting: [FileItem] = []
    @State private var dropActive = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .onChange(of: fs.path, initial: true) { pathText = fs.path }
        .alert(prompt?.title ?? "", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
            TextField("", text: $promptText)
            Button("OK") { submitPrompt() }
            Button("Отмена", role: .cancel) { prompt = nil }
        }
        .confirmationDialog(deleting.count == 1 ? "Удалить «\(deleting[0].name)»?" : "Удалить объекты (\(deleting.count))?",
                            isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } })) {
            Button("Удалить", role: .destructive) {
                let items = deleting
                deleting = []
                Task { if let e = await fs.delete(items) { app.showToast(e, icon: "xmark.octagon", isError: true) } }
            }
        } message: { Text("Удаление на сервере (rm -rf) нельзя отменить.") }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 2) {
            iconButton("arrow.up", "Вверх") { fs.up() }.disabled(fs.path == "/" || fs.phase != .ready)
            TextField("Путь", text: $pathText)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
                .onSubmit { fs.load(pathText) }
                .disabled(fs.phase != .ready)
            iconButton("arrow.clockwise", "Обновить") { fs.refresh() }.disabled(fs.phase != .ready)
            Toggle(isOn: $fs.followTerminal) {
                Image(systemName: "link").frame(width: 20, height: 20)
            }
            .toggleStyle(.button).buttonStyle(.borderless)
            .foregroundStyle(fs.followTerminal ? Color.accentColor : .secondary)
            .help("Следовать за каталогом терминала (bash/zsh)")
            .disabled(fs.phase != .ready)
            Menu {
                Button("Домашний каталог") { fs.goHome() }
                Divider()
                Button("Новая папка…") { ask(.newFolder, "") }
                Button("Новый файл…") { ask(.newFile, "") }
                Button("Загрузить файлы…") { pickUpload() }
                Divider()
                Toggle("Скрытые файлы", isOn: $fs.showHidden)
                Toggle("Следовать за терминалом", isOn: $fs.followTerminal)
                Divider()
                Button("cd сюда в терминале") { tab.cdInTerminal(fs.path) }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(fs.phase != .ready)
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
    }

    private func iconButton(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 20, height: 20).contentShape(Rectangle()) }
            .buttonStyle(.borderless).help(help)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch fs.phase {
        case .waiting:
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Ожидание входа в терминале…").font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let msg):
            VStack(spacing: 8) {
                placeholder(msg, icon: "exclamationmark.triangle")
                Button("Повторить") { fs.retry() }.padding(.bottom)
            }
        case .offline:
            placeholder("Соединение закрыто", icon: "bolt.slash")
        case .ready:
            fileList
        }
    }

    private var fileList: some View {
        List(selection: $selection) {
            ForEach(fs.visibleItems) { item in
                FileRow(item: item)
                    .tag(item.id)
                    .onDrag { dragProvider(item) }
                    .dropDestination(for: URL.self) { urls, _ in
                        guard item.isDir else { return false }
                        return upload(urls, to: item.path)
                    }
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 22)
        .contextMenu(forSelectionType: String.self) { ids in
            menu(ids)
        } primaryAction: { ids in
            guard ids.count == 1, let item = fs.items.first(where: { $0.id == ids.first }) else { return }
            open(item)
        }
        .dropDestination(for: URL.self) { urls, _ in upload(urls, to: fs.path) } isTargeted: { dropActive = $0 }
        .overlay {
            if dropActive {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .background(Color.accentColor.opacity(0.06)).padding(4).allowsHitTesting(false)
            } else if fs.isLoading && fs.items.isEmpty {
                ProgressView().controlSize(.small)
            } else if fs.visibleItems.isEmpty && !fs.isLoading {
                Text(fs.error == nil ? "Пустой каталог" : "").foregroundStyle(.secondary).font(.callout)
            }
        }
        .overlay(alignment: .bottom) {
            if let e = fs.error {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(e).font(.caption).lineLimit(3)
                    Spacer()
                    Button { fs.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).font(.caption)
                }
                .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(6)
            }
        }
        .overlay(alignment: .topTrailing) {
            if fs.isLoading && !fs.items.isEmpty { ProgressView().controlSize(.mini).padding(6) }
        }
    }

    @ViewBuilder
    private func menu(_ ids: Set<String>) -> some View {
        let sel = fs.items.filter { ids.contains($0.id) }
        if sel.isEmpty {
            Button("Новая папка…") { ask(.newFolder, "") }
            Button("Новый файл…") { ask(.newFile, "") }
            Button("Загрузить файлы…") { pickUpload() }
            Divider()
            Button("Обновить") { fs.refresh() }
            Button("cd сюда в терминале") { tab.cdInTerminal(fs.path) }
        } else {
            if sel.count == 1, let item = sel.first {
                if item.isDir { Button("Открыть") { fs.load(item.path) } }
                else { Button("Открыть в редакторе") { app.editors.open(fs.session, item: item) } }
            }
            Button(sel.count > 1 ? "Скачать (\(sel.count))" : "Скачать") { download(sel, to: nil) }
            Button("Скачать в…") { pickDownloadDir(sel) }
            if sel.count == 1, let item = sel.first {
                Divider()
                Button("Переименовать…") { ask(.rename(item), item.name) }
                Button("Права…") { ask(.chmod(item), item.octalMode) }
                Button("Копировать путь") { copy(item.path) }
                Button("cd сюда в терминале") { tab.cdInTerminal(item.isDir ? item.path : FileItem.parent(of: item.path)) }
            } else {
                Button("Копировать пути") { copy(sel.map(\.path).joined(separator: "\n")) }
            }
            Divider()
            Button("Удалить…", role: .destructive) { deleting = sel }
        }
    }

    // MARK: Actions

    private func open(_ item: FileItem) {
        if item.isDir { fs.load(item.path) } else { app.editors.open(fs.session, item: item) }
    }

    private func ask(_ p: Prompt, _ initial: String) {
        promptText = initial
        prompt = p
    }

    private func submitPrompt() {
        guard let p = prompt else { return }
        prompt = nil
        let text = promptText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.contains("/") || { if case .chmod = p { true } else { false } }() else { return }
        Task {
            let err: String? = switch p {
            case .newFolder: await fs.mkdir(text)
            case .newFile: await fs.touch(text)
            case .rename(let i): text == i.name ? nil : await fs.rename(i, to: text)
            case .chmod(let i): await fs.chmod(i, mode: text)
            }
            if let err { app.showToast(err, icon: "xmark.octagon", isError: true) }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func upload(_ urls: [URL], to dir: String) -> Bool {
        let files = urls.filter { $0.isFileURL && !TempDirs.contains($0) }
        guard !files.isEmpty else { return false }
        let fs = self.fs
        for u in files {
            app.transfers.upload(fs.session, local: u, toRemoteDir: dir) { r in
                if case .success = r, fs.path == dir || FileItem.parent(of: dir) == fs.path { fs.refresh() }
            }
        }
        return true
    }

    private func pickUpload() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.prompt = "Загрузить"
        if p.runModal() == .OK { _ = upload(p.urls, to: fs.path) }
    }

    private func pickDownloadDir(_ items: [FileItem]) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Скачать сюда"
        if p.runModal() == .OK, let u = p.url { download(items, to: u) }
    }

    private func download(_ items: [FileItem], to dir: URL?) {
        let target = dir ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        for item in items {
            app.transfers.download(fs.session, remote: item.path, isDir: item.isDir, size: item.size, to: target,
                                   uniqueName: true) { [app] r in
                if case .success(let url) = r { app.showToast("Скачано: \(url.lastPathComponent)", icon: "arrow.down.circle") }
            }
        }
    }

    /// Перетаскивание в Finder: файл-обещание, данные скачиваются по scp в момент drop.
    private func dragProvider(_ item: FileItem) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = item.name
        let type: UTType = item.isDir ? .folder : (UTType(filenameExtension: item.ext) ?? .data)
        let transfers = app.transfers
        let session = fs.session
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            let progress = Progress(totalUnitCount: 1)
            Task { @MainActor in
                transfers.download(session, remote: item.path, isDir: item.isDir, size: item.size,
                                   to: TempDirs.make("drag")) { r in
                    progress.completedUnitCount = 1
                    switch r {
                    case .success(let url): completion(url, false, nil)
                    case .failure(let e): completion(nil, false, e)
                    }
                }
            }
            return progress
        }
        return provider
    }
}

private struct FileRow: View {
    let item: FileItem

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            Text(item.name).lineLimit(1).truncationMode(.middle)
                .font(.system(size: 12))
            if item.kind == .link {
                Image(systemName: "arrow.turn.up.right").font(.system(size: 8)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if !item.isDir {
                Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                    .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .opacity(item.isHidden ? 0.6 : 1)
        .help("\(item.permString)  \(item.owner)" + (item.mtime.map { "  " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""))
    }

    private var icon: NSImage {
        if item.isDir { return NSWorkspace.shared.icon(for: .folder) }
        if let t = UTType(filenameExtension: item.ext), !item.ext.isEmpty { return NSWorkspace.shared.icon(for: t) }
        return NSWorkspace.shared.icon(for: item.mode & 0o111 != 0 ? .unixExecutable : .plainText)
    }
}

/// Очередь передач под списком файлов.
private struct TransfersView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let items = app.transfers.items
        if !items.isEmpty {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Text("Передачи").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if items.contains(where: { !$0.isActive }) {
                        Button("Очистить") { app.transfers.clearFinished() }.buttonStyle(.link).font(.caption)
                    }
                }
                .padding(.horizontal, 10).padding(.top, 5)
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(items) { TransferRow(item: $0) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                }
                .frame(maxHeight: 110)
            }
        }
    }
}

private struct TransferRow: View {
    @Environment(AppState.self) private var app
    let item: TransferQueue.Item

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: item.direction == .upload ? "arrow.up.circle" : "arrow.down.circle")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                switch item.state {
                case .queued: Text("в очереди").font(.system(size: 9)).foregroundStyle(.secondary)
                case .running:
                    if let p = item.progress { ProgressView(value: p).controlSize(.mini) }
                    else { ProgressView().progressViewStyle(.linear).controlSize(.mini) }
                case .done: Text("готово").font(.system(size: 9)).foregroundStyle(.green)
                case .failed(let m): Text(m).font(.system(size: 9)).foregroundStyle(.red).lineLimit(2)
                case .cancelled: Text("отменено").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if item.isActive {
                Button { app.transfers.cancel(item) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
    }
}
