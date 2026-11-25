import AppKit
import SwiftUI

/// SFTP-панель активной вкладки (вкладка «SFTP» сайдбара).
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

private struct FileBrowser: View {
    @Environment(AppState.self) private var app
    let tab: TerminalSession
    @Bindable var fs: RemoteFS
    @State private var editingPath = false
    @State private var pathText = ""
    @State private var chmodTarget: FileItem?
    @FocusState private var pathFocused: Bool

    private var ready: Bool { fs.phase == .ready }

    var body: some View {
        VStack(spacing: 0) {
            navBar
            if ready { filterBar }
            Divider()
            content
        }
        .sheet(item: $chmodTarget) { ChmodSheet(item: $0, fs: fs) }
    }

    // MARK: Навигация

    private var navBar: some View {
        HStack(spacing: 1) {
            navButton("chevron.left", "Назад") { fs.goBack() }.disabled(!ready || fs.backStack.isEmpty)
            navButton("chevron.right", "Вперёд") { fs.goForward() }.disabled(!ready || fs.forwardStack.isEmpty)
            navButton("arrow.up", "Вверх (⌘↑)") { fs.up() }.disabled(!ready || fs.path == "/")
            Group {
                if editingPath {
                    TextField("Путь", text: $pathText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .focused($pathFocused)
                        .onSubmit { fs.navigate(pathText.isEmpty ? "/" : pathText); editingPath = false }
                        .onExitCommand { editingPath = false }
                        .onChange(of: pathFocused) { if !pathFocused { editingPath = false } }
                } else {
                    Breadcrumbs(path: fs.path, home: fs.home) { fs.navigate($0) }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { beginEditPath() }
                }
            }
            .padding(.horizontal, 6).frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            .padding(.horizontal, 3)
            .disabled(!ready)
            navButton("pencil.line", "Ввести путь") { beginEditPath() }.disabled(!ready)
            navButton(fs.isLoading ? "hourglass" : "arrow.clockwise", "Обновить") { fs.refresh() }.disabled(!ready)
        }
        .padding(.horizontal, 5).padding(.vertical, 5)
    }

    private var filterBar: some View {
        HStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10)).foregroundStyle(.secondary)
                TextField("Фильтр", text: $fs.filter).textFieldStyle(.plain).font(.system(size: 11))
                if !fs.filter.isEmpty {
                    Button { fs.filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6).frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))
            toggleButton("eye", "eye.slash", on: $fs.showHidden, help: "Показывать скрытые файлы")
            toggleButton("link", "link", on: $fs.followTerminal, help: "Следовать за каталогом терминала (bash/zsh)")
            Menu {
                Button("Новая папка") { create(folder: true) }
                Button("Новый файл") { create(folder: false) }
                Divider()
                Button("Загрузить файлы…") { pickUpload() }
                Button("Домой") { fs.goHome() }
                Button("cd сюда в терминале") { tab.cdInTerminal(fs.path) }
            } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Создать / загрузить")
        }
        .padding(.horizontal, 8).padding(.bottom, 5)
    }

    private func navButton(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .medium)).frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.borderless).help(help)
    }

    private func toggleButton(_ on: String, _ off: String, on binding: Binding<Bool>, help: String) -> some View {
        Button { binding.wrappedValue.toggle() } label: {
            Image(systemName: binding.wrappedValue ? on : off).font(.system(size: 11))
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(binding.wrappedValue ? 0.18 : 0)))
                .foregroundStyle(binding.wrappedValue ? Color.accentColor : .secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
    }

    private func beginEditPath() {
        pathText = fs.path
        editingPath = true
        DispatchQueue.main.async { pathFocused = true }
    }

    private func create(folder: Bool) {
        Task { if let e = await fs.createAndRename(folder: folder) { app.showToast(e, icon: "xmark.octagon", isError: true) } }
    }

    private func pickUpload() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.prompt = "Загрузить"
        guard p.runModal() == .OK else { return }
        let dir = fs.path
        for u in p.urls {
            app.transfers.upload(fs.session, local: u, toRemoteDir: dir) { [fs] r in
                if case .success = r, fs.path == dir { fs.refresh() }
            }
        }
    }

    // MARK: Контент

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
            VStack(spacing: 0) {
                FileTableView(app: app, tab: tab, fs: fs, items: fs.visibleItems, path: fs.path) { chmodTarget = $0 }
                    .overlay {
                        if fs.isLoading && fs.items.isEmpty { ProgressView().controlSize(.small) }
                        else if fs.visibleItems.isEmpty && !fs.isLoading && fs.error == nil {
                            Text(fs.filter.isEmpty ? "Пустой каталог\nПеретащите сюда файлы из Finder" : "Ничего не найдено")
                                .multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: .bottom) { errorBanner }
                statusLine
            }
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let e = fs.error {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(e).font(.caption).lineLimit(3).textSelection(.enabled)
                Spacer()
                Button { fs.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).font(.caption)
            }
            .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(6)
        }
    }

    private var statusLine: some View {
        let visible = fs.visibleItems
        let dirs = visible.filter(\.isDir).count
        let size = visible.filter { !$0.isDir }.reduce(Int64(0)) { $0 + $1.size }
        return HStack(spacing: 6) {
            Text("\(visible.count) объект." + (dirs > 0 ? "  папок: \(dirs)" : "") + "  ·  " +
                 ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
            Spacer()
            if fs.followTerminal { Label("следует", systemImage: "link").labelStyle(.titleAndIcon) }
        }
        .font(.system(size: 10)).foregroundStyle(.secondary)
        .padding(.horizontal, 8).frame(height: 20)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Кликабельный путь: / › var › www. Домашний каталог показывается как «~».
private struct Breadcrumbs: View {
    let path: String
    let home: String
    let onSelect: (String) -> Void

    private var segments: [(title: String, path: String)] {
        guard !path.isEmpty else { return [] }
        var result: [(String, String)] = []
        var start = "/"
        var rest = path
        if !home.isEmpty, home != "/", path == home || path.hasPrefix(home + "/") {
            result.append(("~", home))
            start = home
            rest = String(path.dropFirst(home.count))
        } else {
            result.append(("/", "/"))
        }
        var cur = start
        for part in rest.split(separator: "/") {
            cur = FileItem.join(cur, String(part))
            result.append((String(part), cur))
        }
        return result
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { i, seg in
                        if i > 0 && segments[i - 1].title != "/" {
                            Image(systemName: "chevron.compact.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                        Button { onSelect(seg.path) } label: {
                            Text(seg.title)
                                .font(.system(size: 11, weight: i == segments.count - 1 ? .semibold : .regular))
                                .lineLimit(1)
                                .padding(.horizontal, 3).padding(.vertical, 1)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(CrumbStyle())
                        .help(seg.path)
                        .id(i)
                    }
                }
            }
            .onChange(of: path, initial: true) { proxy.scrollTo(segments.count - 1, anchor: .trailing) }
        }
    }
}

private struct CrumbStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(configuration.isPressed ? 0.15 : hover ? 0.08 : 0)))
            .onHover { hover = $0 }
    }
}

/// Права доступа: галочки rwx и восьмеричное поле, синхронизированные между собой.
private struct ChmodSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let item: FileItem
    let fs: RemoteFS
    @State private var mode: Int
    @State private var octal: String

    init(item: FileItem, fs: RemoteFS) {
        self.item = item
        self.fs = fs
        _mode = State(initialValue: item.mode & 0o7777)
        _octal = State(initialValue: String(item.mode & 0o7777, radix: 8))
    }

    private func bit(_ b: Int) -> Binding<Bool> {
        Binding(get: { mode & b != 0 }, set: { v in
            mode = v ? mode | b : mode & ~b
            octal = String(mode, radix: 8)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(nsImage: FileTableCoordinator.icon(for: item)).resizable().frame(width: 32, height: 32)
                VStack(alignment: .leading) {
                    Text(item.name).font(.headline).lineLimit(1)
                    Text(item.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    Text("")
                    Text("Чтение").font(.caption).foregroundStyle(.secondary)
                    Text("Запись").font(.caption).foregroundStyle(.secondary)
                    Text("Выполнение").font(.caption).foregroundStyle(.secondary)
                }
                ForEach([("Владелец", 6), ("Группа", 3), ("Остальные", 0)], id: \.1) { title, shift in
                    GridRow {
                        Text(title)
                        Toggle("", isOn: bit(4 << shift)).labelsHidden()
                        Toggle("", isOn: bit(2 << shift)).labelsHidden()
                        Toggle("", isOn: bit(1 << shift)).labelsHidden()
                    }
                }
            }
            HStack {
                Text("Режим")
                TextField("755", text: $octal)
                    .font(.system(.body, design: .monospaced)).frame(width: 70)
                    .onChange(of: octal) { if let v = Int(octal, radix: 8), v <= 0o7777 { mode = v } }
                Text(FileItem(name: "", path: "", kind: .file, mode: mode).permString)
                    .font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Отмена", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Применить") {
                    let m = octal
                    dismiss()
                    Task { if let e = await fs.chmod(item, mode: m) { app.showToast(e, icon: "xmark.octagon", isError: true) } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(Int(octal, radix: 8) == nil)
            }
        }
        .padding(20)
        .frame(width: 380)
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
