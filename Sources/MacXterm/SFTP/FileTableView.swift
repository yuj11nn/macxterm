import AppKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers

/// Нативная таблица файлов SFTP-панели (NSTableView): двойной клик, клавиатура, сортировка,
/// переименование в строке, drag & drop с Finder и внутри сервера, Quick Look.
struct FileTableView: NSViewRepresentable {
    let app: AppState
    let tab: TerminalSession
    let fs: RemoteFS
    let items: [FileItem]
    let path: String
    let onChmod: (FileItem) -> Void

    func makeCoordinator() -> FileTableCoordinator { FileTableCoordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let c = context.coordinator
        let table = FileTable()
        table.coordinator = c
        c.table = table
        table.style = .plain
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.allowsTypeSelect = true
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.autosaveName = "MacXterm.SFTPTable"
        table.autosaveTableColumns = true

        for col in FileTableCoordinator.Column.allCases {
            let tc = NSTableColumn(identifier: col.id)
            tc.title = col.title
            tc.minWidth = col.minWidth
            tc.width = col.width
            tc.sortDescriptorPrototype = NSSortDescriptor(key: col.rawValue, ascending: true)
            tc.isHidden = col.hiddenByDefault
            tc.headerCell.alignment = col.alignment
            if col == .name { tc.resizingMask = .autoresizingMask } else { tc.resizingMask = .userResizingMask }
            table.addTableColumn(tc)
        }
        table.sortDescriptors = [NSSortDescriptor(key: FileTableCoordinator.Column.name.rawValue, ascending: true)]

        let header = NSTableHeaderView()
        header.menu = c.headerMenu()
        table.headerView = header

        table.dataSource = c
        table.delegate = c
        table.target = c
        table.doubleAction = #selector(FileTableCoordinator.doubleClicked)
        let menu = NSMenu()
        menu.delegate = c
        table.menu = menu
        table.registerForDraggedTypes([.fileURL, FileTableCoordinator.internalType])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        table.draggingDestinationFeedbackStyle = .regular

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.app = app
        c.tab = tab
        c.fs = fs
        c.onChmod = onChmod
        c.update(items: items, path: path)
    }
}

// MARK: - Table subclass (клавиатура, Quick Look, буфер обмена)

final class FileTable: NSTableView, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    weak var coordinator: FileTableCoordinator?
    var previewURLs: [URL] = []

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch (event.keyCode, flags.contains(.command)) {
        case (36, false), (76, false), (125, true):  // Return, Enter, ⌘↓
            coordinator?.openSelected()
        case (126, true):  // ⌘↑
            coordinator?.fs?.up()
        case (51, true), (117, _):  // ⌘⌫, Forward Delete
            coordinator?.deleteSelected()
        case (49, false):  // Space
            coordinator?.quickLook()
        case (120, false):  // F2
            coordinator?.renameSelected()
        default:
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.keyCode == 126 || event.keyCode == 125 || event.keyCode == 51 {
            keyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc func copy(_ sender: Any?) { coordinator?.copyPaths() }
    @objc func paste(_ sender: Any?) { coordinator?.pasteFromFinder() }
    @objc func delete(_ sender: Any?) { coordinator?.deleteSelected() }

    // Quick Look
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewURLs[index] as NSURL
    }
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown, event.keyCode == 49 { panel.orderOut(nil); return true }
        return false
    }
}

/// Пишет в pasteboard и обещание файла (для Finder), и внутренний тип с удалёнными путями (для перемещения на сервере).
final class RemoteFilePromiseProvider: NSFilePromiseProvider {
    var remotePaths: [String] = []

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [FileTableCoordinator.internalType]
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == FileTableCoordinator.internalType { return remotePaths.joined(separator: "\n") }
        return super.pasteboardPropertyList(forType: type)
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        if type == FileTableCoordinator.internalType { return [] }
        return super.writingOptions(forType: type, pasteboard: pasteboard)
    }
}

// MARK: - Coordinator

@MainActor
final class FileTableCoordinator: NSObject {
    nonisolated static let internalType = NSPasteboard.PasteboardType("com.macxterm.remote-paths")

    enum Column: String, CaseIterable {
        case name, size, mtime, mode, owner
        var id: NSUserInterfaceItemIdentifier { .init(rawValue) }
        var title: String {
            switch self {
            case .name: "Имя"; case .size: "Размер"; case .mtime: "Изменён"; case .mode: "Права"; case .owner: "Владелец"
            }
        }
        var width: CGFloat {
            switch self { case .name: 180; case .size: 62; case .mtime: 110; case .mode: 78; case .owner: 64 }
        }
        var minWidth: CGFloat { self == .name ? 80 : 40 }
        var hiddenByDefault: Bool { self == .mode || self == .owner }
        var alignment: NSTextAlignment { self == .size ? .right : .left }
    }

    weak var table: FileTable?
    weak var app: AppState?
    weak var tab: TerminalSession?
    weak var fs: RemoteFS?
    var onChmod: ((FileItem) -> Void)?
    private(set) var rows: [FileItem] = []
    private var sourceItems: [FileItem] = []
    private var currentPath = ""
    private var previewCache: [String: URL] = [:]
    nonisolated private let promiseQueue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        return q
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    // MARK: Data

    func update(items: [FileItem], path: String) {
        let pathChanged = path != currentPath
        guard pathChanged || items != sourceItems else { applyPendingSelection(); return }
        sourceItems = items
        currentPath = path
        reload(keepSelection: !pathChanged)
        if pathChanged { table?.scrollRowToVisible(0) }
        applyPendingSelection()
    }

    private func reload(keepSelection: Bool) {
        guard let table else { return }
        let selected = keepSelection ? Set(selectedItems.map(\.id)) : []
        rows = sorted(sourceItems, by: table.sortDescriptors.first)
        table.reloadData()
        let idx = IndexSet(rows.indices.filter { selected.contains(rows[$0].id) })
        table.selectRowIndexes(idx, byExtendingSelection: false)
    }

    private func applyPendingSelection() {
        guard let fs, let pending = fs.pendingSelection, let table,
              let row = rows.firstIndex(where: { $0.name == pending.name }) else { return }
        fs.pendingSelection = nil
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        table.window?.makeFirstResponder(table)
        if pending.rename { DispatchQueue.main.async { self.beginRename(row: row) } }
    }

    private func sorted(_ items: [FileItem], by sd: NSSortDescriptor?) -> [FileItem] {
        let key = Column(rawValue: sd?.key ?? "name") ?? .name
        let asc = sd?.ascending ?? true
        return items.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }
            let r: ComparisonResult
            switch key {
            case .name: r = a.name.localizedStandardCompare(b.name)
            case .size: r = a.size == b.size ? .orderedSame : (a.size < b.size ? .orderedAscending : .orderedDescending)
            case .mtime:
                let x = a.mtime ?? .distantPast, y = b.mtime ?? .distantPast
                r = x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
            case .mode: r = a.mode == b.mode ? .orderedSame : (a.mode < b.mode ? .orderedAscending : .orderedDescending)
            case .owner: r = a.owner.localizedStandardCompare(b.owner)
            }
            if r == .orderedSame { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
            return asc ? r == .orderedAscending : r == .orderedDescending
        }
    }

    var selectedItems: [FileItem] {
        guard let table else { return [] }
        return table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
    }

    /// Элементы для контекстного меню: кликнутая строка (если она вне выделения) или выделение.
    private var actionItems: [FileItem] {
        guard let table else { return [] }
        let clicked = table.clickedRow
        if clicked >= 0, clicked < rows.count, !table.selectedRowIndexes.contains(clicked) { return [rows[clicked]] }
        return selectedItems
    }

    // MARK: Actions

    @objc func doubleClicked() {
        guard let table, table.clickedRow >= 0, table.clickedRow < rows.count else { return }
        open(rows[table.clickedRow])
    }

    func openSelected() {
        let sel = selectedItems
        if sel.count == 1 { open(sel[0]) } else { sel.filter { !$0.isDir }.forEach { open($0) } }
    }

    func open(_ item: FileItem) {
        guard let fs, let app else { return }
        if item.isDir { fs.navigate(item.path) } else { app.editors.open(fs.session, item: item) }
    }

    func renameSelected() {
        guard let table, table.selectedRowIndexes.count == 1, let row = table.selectedRowIndexes.first else { return }
        beginRename(row: row)
    }

    private func beginRename(row: Int) {
        guard let table, row < rows.count,
              let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
              let tf = cell.textField else { return }
        tf.isEditable = true
        tf.delegate = self
        table.window?.makeFirstResponder(tf)
        if let editor = tf.currentEditor() {
            let name = rows[row].name
            let stem = rows[row].isDir ? name : (name as NSString).deletingPathExtension
            editor.selectedRange = NSRange(location: 0, length: (stem.isEmpty ? name : stem).utf16.count)
        }
    }

    func deleteSelected(_ items: [FileItem]? = nil) {
        let targets = items ?? selectedItems
        guard !targets.isEmpty, let fs, let window = table?.window else { return }
        let alert = NSAlert()
        alert.messageText = targets.count == 1 ? "Удалить «\(targets[0].name)»?" : "Удалить объекты (\(targets.count))?"
        alert.informativeText = "Файлы будут удалены на сервере (rm -rf). Это нельзя отменить."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Удалить").hasDestructiveAction = true
        alert.addButton(withTitle: "Отмена")
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .alertFirstButtonReturn else { return }
            Task { @MainActor in
                if let e = await fs.delete(targets) { self?.app?.showToast(e, icon: "xmark.octagon", isError: true) }
            }
        }
    }

    func copyPaths(_ items: [FileItem]? = nil) {
        let sel = items ?? selectedItems
        guard !sel.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sel.map(\.path).joined(separator: "\n"), forType: .string)
        app?.showToast(sel.count == 1 ? "Путь скопирован" : "Пути скопированы (\(sel.count))", icon: "doc.on.doc")
    }

    /// ⌘V: файлы, скопированные в Finder, заливаются в текущий каталог.
    func pasteFromFinder() {
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if urls.isEmpty { app?.showToast("В буфере нет файлов из Finder", icon: "doc.on.clipboard", isError: true); return }
        upload(urls, to: currentPath)
    }

    func upload(_ urls: [URL], to dir: String) {
        guard let app, let fs else { return }
        let files = urls.filter { $0.isFileURL && !TempDirs.contains($0) }
        for u in files {
            app.transfers.upload(fs.session, local: u, toRemoteDir: dir) { [weak fs] r in
                guard let fs, case .success = r else { return }
                if fs.path == dir {
                    fs.pendingSelection = (u.lastPathComponent, false)
                    fs.refresh()
                }
            }
        }
    }

    func download(_ items: [FileItem], to dir: URL?) {
        guard let app, let fs else { return }
        let target = dir ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        for item in items {
            app.transfers.download(fs.session, remote: item.path, isDir: item.isDir, size: item.size, to: target,
                                   uniqueName: true) { [weak app] r in
                if case .success(let url) = r {
                    app?.showToast("Скачано: \(url.lastPathComponent)", icon: "arrow.down.circle")
                }
            }
        }
    }

    func pickDownload(_ items: [FileItem]) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Скачать сюда"
        guard let w = table?.window else { return }
        p.beginSheetModal(for: w) { [weak self] r in
            if r == .OK, let u = p.url { self?.download(items, to: u) }
        }
    }

    func pickUpload(to dir: String? = nil) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.prompt = "Загрузить"
        let target = dir ?? currentPath
        guard let w = table?.window else { return }
        p.beginSheetModal(for: w) { [weak self] r in
            if r == .OK { self?.upload(p.urls, to: target) }
        }
    }

    func openWith(_ item: FileItem, app bundle: URL) {
        guard let app, let fs else { return }
        app.editors.open(fs.session, item: item, with: bundle)
    }

    /// Пробел: Quick Look (файлы до 100 МБ скачиваются во временную папку).
    func quickLook() {
        guard let table, let fs, let app else { return }
        if let panel = QLPreviewPanel.shared(), panel.isVisible { panel.orderOut(nil); return }
        let files = selectedItems.filter { !$0.isDir && $0.size < 100 * 1024 * 1024 }.prefix(10)
        guard !files.isEmpty else { return }
        var urls = [URL?](repeating: nil, count: files.count)
        var pending = files.count
        func show() {
            table.previewURLs = urls.compactMap { $0 }
            guard !table.previewURLs.isEmpty, let panel = QLPreviewPanel.shared() else { return }
            table.window?.makeFirstResponder(table)
            panel.makeKeyAndOrderFront(nil)
            panel.reloadData()
        }
        for (i, item) in files.enumerated() {
            let key = "\(item.path)|\(item.mtime?.timeIntervalSince1970 ?? 0)|\(item.size)"
            if let u = previewCache[key], FileManager.default.fileExists(atPath: u.path) {
                urls[i] = u; pending -= 1
                if pending == 0 { show() }
                continue
            }
            app.transfers.download(fs.session, remote: item.path, isDir: false, size: item.size,
                                   to: TempDirs.make("preview")) { [weak self] r in
                if case .success(let u) = r { urls[i] = u; self?.previewCache[key] = u }
                pending -= 1
                if pending == 0 { show() }
            }
        }
    }

    // MARK: Header menu (видимость колонок)

    func headerMenu() -> NSMenu {
        let m = NSMenu()
        m.delegate = self
        return m
    }
}

// MARK: - DataSource / Delegate

extension FileTableCoordinator: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let col = Column(rawValue: tableColumn.identifier.rawValue), row < rows.count else { return nil }
        let item = rows[row]
        let cell = (tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? NSTableCellView)
            ?? makeCell(col)
        cell.alphaValue = item.isHidden ? 0.55 : 1
        switch col {
        case .name:
            cell.textField?.stringValue = item.name
            cell.textField?.isEditable = false
            cell.imageView?.image = Self.icon(for: item)
            cell.toolTip = item.kind == .link ? "\(item.name) → ссылка" : nil
        case .size:
            cell.textField?.stringValue = item.isDir ? "—" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
        case .mtime:
            cell.textField?.stringValue = item.mtime.map { Self.dateFormatter.string(from: $0) } ?? ""
        case .mode:
            cell.textField?.stringValue = (item.isDir ? "d" : "-") + item.permString
        case .owner:
            cell.textField?.stringValue = item.owner
        }
        return cell
    }

    private func makeCell(_ col: Column) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = col.id
        let tf = NSTextField(labelWithString: "")
        tf.lineBreakMode = col == .name ? .byTruncatingMiddle : .byTruncatingTail
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.cell?.isScrollable = false
        tf.alignment = col.alignment
        if col == .name {
            tf.font = .systemFont(ofSize: 12)
        } else {
            tf.font = col == .mode ? .monospacedSystemFont(ofSize: 10.5, weight: .regular) : .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            tf.textColor = .secondaryLabelColor
        }
        cell.addSubview(tf)
        cell.textField = tf
        if col == .name {
            let iv = NSImageView()
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.imageScaling = .scaleProportionallyUpOrDown
            cell.addSubview(iv)
            cell.imageView = iv
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 16), iv.heightAnchor.constraint(equalToConstant: 16),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 5),
            ])
        } else {
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
        }
        NSLayoutConstraint.activate([
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private static var iconCache: [String: NSImage] = [:]

    static func icon(for item: FileItem) -> NSImage {
        let key = item.isDir ? "/dir" : (item.ext.isEmpty ? (item.mode & 0o111 != 0 ? "/exec" : "/plain") : item.ext.lowercased())
        if let i = iconCache[key] { return i }
        let ws = NSWorkspace.shared
        let img: NSImage
        switch key {
        case "/dir": img = ws.icon(for: .folder)
        case "/exec": img = ws.icon(for: .unixExecutable)
        case "/plain": img = ws.icon(for: .plainText)
        default: img = ws.icon(for: UTType(filenameExtension: key) ?? .data)
        }
        iconCache[key] = img
        return img
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        reload(keepSelection: true)
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        tableColumn?.identifier == Column.name.id && row < rows.count ? rows[row].name : nil
    }

    // MARK: Drag out

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard row < rows.count else { return nil }
        let item = rows[row]
        let type: UTType = item.isDir ? .folder : (UTType(filenameExtension: item.ext) ?? .data)
        let p = RemoteFilePromiseProvider(fileType: type.identifier, delegate: self)
        p.userInfo = item
        p.remotePaths = [item.path]
        return p
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        // В каждом элементе — все перетаскиваемые пути (для перемещения на сервере).
        let paths = rowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].path : nil }
        session.enumerateDraggingItems(options: [], for: nil, classes: [RemoteFilePromiseProvider.self],
                                       searchOptions: [:]) { di, _, _ in
            (di.item as? RemoteFilePromiseProvider)?.remotePaths = paths
        }
    }

    // MARK: Drop in

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        let internalDrag = info.draggingPasteboard.types?.contains(Self.internalType) == true
        if op == .on, row < rows.count, rows[row].isDir {
            if internalDrag {
                let paths = (info.draggingPasteboard.string(forType: Self.internalType) ?? "").split(separator: "\n").map(String.init)
                return paths.contains(rows[row].path) ? [] : .move
            }
            return .copy
        }
        if internalDrag { return [] }  // перенос в тот же каталог бессмыслен
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        let target = (row >= 0 && row < rows.count && rows[row].isDir && dropOperation == .on) ? rows[row].path : currentPath
        let pb = info.draggingPasteboard
        if let s = pb.string(forType: Self.internalType), let fs {
            let paths = s.split(separator: "\n").map(String.init)
            Task { @MainActor in
                if let e = await fs.move(paths, toDir: target) { self.app?.showToast(e, icon: "xmark.octagon", isError: true) }
            }
            return true
        }
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        upload(urls, to: target)
        return true
    }
}

// MARK: - File promises (перетаскивание в Finder)

extension FileTableCoordinator: NSFilePromiseProviderDelegate {
    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (provider.userInfo as? FileItem)?.name ?? "file"
    }

    nonisolated func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        promiseQueue
    }

    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                                         completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        let item = provider.userInfo as? FileItem
        Task { @MainActor in
            guard let item, let fs = self.fs, let app = self.app else {
                completionHandler(SSHError(message: "Нет соединения")); return
            }
            app.transfers.download(fs.session, remote: item.path, isDir: item.isDir, size: item.size,
                                   to: url.deletingLastPathComponent()) { r in
                switch r {
                case .success: completionHandler(nil)
                case .failure(let e): completionHandler(e)
                }
            }
        }
    }
}

// MARK: - Inline rename

extension FileTableCoordinator: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let tf = obj.object as? NSTextField, let table, let fs else { return }
        tf.isEditable = false
        let row = table.row(for: tf)
        guard row >= 0, row < rows.count else { return }
        let item = rows[row]
        let newName = tf.stringValue.trimmingCharacters(in: .whitespaces)
        let cancelled = (obj.userInfo?["NSTextMovement"] as? Int) == NSTextMovement.cancel.rawValue
        if cancelled || newName.isEmpty || newName == item.name || newName.contains("/") {
            tf.stringValue = item.name
            table.window?.makeFirstResponder(table)
            return
        }
        Task { @MainActor in
            if let e = await fs.rename(item, to: newName) {
                tf.stringValue = item.name
                self.app?.showToast(e, icon: "xmark.octagon", isError: true)
            }
        }
        table.window?.makeFirstResponder(table)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            textView.string = (control as? NSTextField).flatMap { tf in
                table.map { t in t.row(for: tf) }.flatMap { $0 >= 0 && $0 < rows.count ? rows[$0].name : nil }
            } ?? textView.string
            control.window?.makeFirstResponder(table)
            return true
        }
        return false
    }
}

// MARK: - Context menu

extension FileTableCoordinator: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === table?.headerView?.menu { buildHeaderMenu(menu); return }
        let items = actionItems
        if let table, table.clickedRow >= 0, !table.selectedRowIndexes.contains(table.clickedRow) {
            table.selectRowIndexes([table.clickedRow], byExtendingSelection: false)
        }
        func add(_ title: String, _ symbol: String? = nil, key: String = "", mods: NSEvent.ModifierFlags = .command,
                 _ action: @escaping () -> Void) {
            let mi = ClosureMenuItem(title: title, action: action)
            mi.keyEquivalent = key
            mi.keyEquivalentModifierMask = mods
            if let symbol { mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            menu.addItem(mi)
        }
        let dir = currentPath
        if items.isEmpty {
            add("Новая папка", "folder.badge.plus") { [weak self] in self?.createNew(folder: true) }
            add("Новый файл", "doc.badge.plus") { [weak self] in self?.createNew(folder: false) }
            add("Загрузить сюда…", "square.and.arrow.up") { [weak self] in self?.pickUpload() }
            add("Вставить файлы из Finder", "doc.on.clipboard", key: "v") { [weak self] in self?.pasteFromFinder() }
            menu.addItem(.separator())
            add("Обновить", "arrow.clockwise") { [weak self] in self?.fs?.refresh() }
            add("Копировать путь каталога", "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(dir, forType: .string) }
            add("cd сюда в терминале", "terminal") { [weak self] in self?.tab?.cdInTerminal(dir) }
            return
        }
        let single = items.count == 1 ? items[0] : nil
        if let single {
            if single.isDir {
                add("Открыть", "folder") { [weak self] in self?.open(single) }
            } else {
                add("Открыть в редакторе", "pencil.and.list.clipboard") { [weak self] in self?.open(single) }
                let sub = NSMenu()
                let ws = NSWorkspace.shared
                let type = UTType(filenameExtension: single.ext) ?? .plainText
                var apps = ws.urlsForApplications(toOpen: type)
                if let te = ws.urlForApplication(withBundleIdentifier: "com.apple.TextEdit"), !apps.contains(te) { apps.insert(te, at: 0) }
                for a in apps.prefix(15) {
                    let mi = ClosureMenuItem(title: FileManager.default.displayName(atPath: a.path)) { [weak self] in self?.openWith(single, app: a) }
                    let icon = ws.icon(forFile: a.path); icon.size = NSSize(width: 16, height: 16)
                    mi.image = icon
                    sub.addItem(mi)
                }
                sub.addItem(.separator())
                sub.addItem(ClosureMenuItem(title: "Другое…") { [weak self] in
                    let p = NSOpenPanel()
                    p.directoryURL = URL(fileURLWithPath: "/Applications")
                    p.allowedContentTypes = [.application]
                    if p.runModal() == .OK, let u = p.url { self?.openWith(single, app: u) }
                })
                let parent = NSMenuItem(title: "Открыть с помощью", action: nil, keyEquivalent: "")
                parent.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil)
                parent.submenu = sub
                menu.addItem(parent)
                add("Быстрый просмотр", "eye", key: " ", mods: []) { [weak self] in self?.quickLook() }
            }
            menu.addItem(.separator())
        }
        add(items.count > 1 ? "Скачать (\(items.count)) в Загрузки" : "Скачать в Загрузки", "arrow.down.circle") { [weak self] in self?.download(items, to: nil) }
        add("Скачать в…", "folder.badge.questionmark") { [weak self] in self?.pickDownload(items) }
        if let single, single.isDir {
            add("Загрузить в эту папку…", "square.and.arrow.up") { [weak self] in self?.pickUpload(to: single.path) }
        }
        menu.addItem(.separator())
        if let single {
            add("Переименовать", "character.cursor.ibeam") { [weak self] in
                guard let self, let r = self.rows.firstIndex(of: single) else { return }
                self.beginRename(row: r)
            }
            add("Дублировать", "plus.square.on.square") { [weak self] in
                guard let fs = self?.fs else { return }
                Task { @MainActor in if let e = await fs.duplicate(single) { self?.app?.showToast(e, icon: "xmark.octagon", isError: true) } }
            }
            add("Права доступа…", "lock") { [weak self] in self?.onChmod?(single) }
        }
        add(items.count > 1 ? "Копировать пути" : "Копировать путь", "doc.on.doc", key: "c") { [weak self] in self?.copyPaths(items) }
        if let single {
            add("Копировать имя", "textformat") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(single.name, forType: .string) }
            let target = single.isDir ? single.path : FileItem.parent(of: single.path)
            add("cd сюда в терминале", "terminal") { [weak self] in self?.tab?.cdInTerminal(target) }
        }
        menu.addItem(.separator())
        add("Удалить…", "trash", key: "\u{8}") { [weak self] in self?.deleteSelected(items) }
        menu.addItem(.separator())
        add("Новая папка", "folder.badge.plus") { [weak self] in self?.createNew(folder: true) }
        add("Новый файл", "doc.badge.plus") { [weak self] in self?.createNew(folder: false) }
    }

    func createNew(folder: Bool) {
        guard let fs else { return }
        Task { @MainActor in
            if let e = await fs.createAndRename(folder: folder) { self.app?.showToast(e, icon: "xmark.octagon", isError: true) }
        }
    }

    private func buildHeaderMenu(_ menu: NSMenu) {
        guard let table else { return }
        for col in table.tableColumns where col.identifier != Column.name.id {
            let mi = ClosureMenuItem(title: col.title) { col.isHidden.toggle() }
            mi.state = col.isHidden ? .off : .on
            menu.addItem(mi)
        }
    }
}

/// NSMenuItem с замыканием вместо target/action.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
