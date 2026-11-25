import AppKit
import SwiftUI

/// Вкладка «Команды»: частые, свои и встроенные подсказки. Клик — вставить в терминал, ▶ — выполнить.
struct CommandsPanel: View {
    @Environment(AppState.self) private var app
    @State private var search = ""
    @State private var collapsed: Set<String> = []
    @State private var editing: Snippet?
    @FocusState private var searchFocused: Bool

    private var store: SnippetStore { app.snippets }

    private var sections: [(String, [Snippet])] {
        let q = search.lowercased()
        let items = store.all.filter {
            q.isEmpty || $0.title.lowercased().contains(q) || $0.command.lowercased().contains(q)
        }
        var out: [(String, [Snippet])] = []
        if q.isEmpty, !store.frequent.isEmpty { out.append(("Частые", store.frequent)) }
        var order: [String] = []
        for s in items where !order.contains(s.category) { order.append(s.category) }
        for c in order { out.append((c, items.filter { $0.category == c })) }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            List {
                ForEach(sections, id: \.0) { title, items in
                    Section(isExpanded: Binding(get: { !collapsed.contains(title) || !search.isEmpty },
                                                set: { if $0 { collapsed.remove(title) } else { collapsed.insert(title) } })) {
                        ForEach(items) { s in
                            SnippetRow(snippet: s, canSend: canSend,
                                       onInsert: { app.useSnippet(s, execute: false) },
                                       onRun: { app.useSnippet(s, execute: true) })
                                .contextMenu { menu(s) }
                        }
                    } header: {
                        Text(title)
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if sections.isEmpty { Text("Ничего не найдено").foregroundStyle(.secondary) }
            }
            footer
        }
        .sheet(item: $editing) { SnippetEditor(snippet: $0) }
        .onChange(of: app.focusCommands) { searchFocused = true }
    }

    private var canSend: Bool { app.activeTab?.state == .connected }

    private var header: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 11))
                TextField("Поиск команды", text: $search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit {
                        if let s = sections.first?.1.first { app.useSnippet(s, execute: false) }
                    }
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            Button { editing = Snippet(id: UUID().uuidString, title: "", command: "", category: SnippetStore.customCategory, isCustom: true) } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Своя команда")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Image(systemName: canSend ? "info.circle" : "bolt.slash").font(.system(size: 10))
            Text(canSend ? "Клик — вставить, ▶ — выполнить. ‸ — место курсора."
                         : "Подключитесь, чтобы отправлять команды")
                .lineLimit(2)
        }
        .font(.system(size: 10)).foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private func menu(_ s: Snippet) -> some View {
        Button("Вставить в терминал") { app.useSnippet(s, execute: false) }.disabled(!canSend)
        Button("Выполнить") { app.useSnippet(s, execute: true) }.disabled(!canSend || s.cursorBack > 0)
        Button("Копировать") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s.plainCommand, forType: .string)
            app.showToast("Скопировано", icon: "doc.on.doc")
        }
        Divider()
        if s.isCustom {
            Button("Изменить…") { editing = s }
            Button("Удалить", role: .destructive) { store.delete(s.id) }
        } else {
            Button("Сделать свою копию…") {
                editing = Snippet(id: UUID().uuidString, title: s.title, command: s.command, category: SnippetStore.customCategory, isCustom: true)
            }
        }
    }
}

private struct SnippetRow: View {
    let snippet: Snippet
    let canSend: Bool
    let onInsert: () -> Void
    let onRun: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(snippet.title).font(.system(size: 12)).lineLimit(1)
                Text(snippet.plainCommand).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if hover && canSend {
                Button(action: onInsert) { Image(systemName: "arrow.down.to.line.compact") }
                    .buttonStyle(.borderless).help("Вставить, не выполняя")
                Button(action: onRun) { Image(systemName: "play.fill") }
                    .buttonStyle(.borderless).help("Выполнить")
                    .disabled(snippet.cursorBack > 0)
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { if canSend { onInsert() } }
        .help(snippet.plainCommand)
    }
}

private struct SnippetEditor: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State var snippet: Snippet

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(app.snippets.custom.contains { $0.id == snippet.id } ? "Изменить команду" : "Новая команда").font(.headline)
            TextField("Название", text: $snippet.title)
            VStack(alignment: .leading, spacing: 4) {
                TextEditor(text: $snippet.command)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 80)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                Text("Символ ‸ отмечает, где встанет курсор после вставки — например, для имени файла или службы.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить") {
                    if snippet.title.trimmingCharacters(in: .whitespaces).isEmpty {
                        snippet.title = String(snippet.plainCommand.prefix(40))
                    }
                    app.snippets.save(snippet)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(snippet.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 420)
    }
}
