import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Собственный таббар: индикатор состояния, перестановка перетаскиванием, закрытие средней кнопкой.
struct TabBar: View {
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(app.tabs.enumerated()), id: \.element.id) { idx, tab in
                        TabItem(tab: tab, index: idx, selected: tab.id == app.activeTabID)
                    }
                }
                .padding(.horizontal, 8)
            }
            Button { app.showQuickConnect = true } label: {
                Image(systemName: "plus").frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Новое подключение (⌘T)")
            .padding(.trailing, 8)
        }
        .frame(height: 36)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct TabItem: View {
    @Environment(AppState.self) private var app
    let tab: TerminalSession
    let index: Int
    let selected: Bool
    @State private var hover = false
    @State private var dropTarget = false

    private var dotColor: Color {
        switch tab.state {
        case .connected: .green
        case .connecting: .yellow
        case .disconnected: .red
        }
    }

    private var tint: Color? { SessionColor(rawValue: tab.colorName ?? "")?.color }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(dotColor).frame(width: 7, height: 7)
                .shadow(color: dotColor.opacity(0.6), radius: tab.state == .connected ? 2 : 0)
            if tab.agentWorking > 0 {
                Image(systemName: "sparkles").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.purple)
                    .symbolEffect(.pulse)
                    .help("Сейчас здесь работает агент")
            }
            if app.multiExec && tab.state == .connected {
                Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.orange).help("Multi-exec: вкладка получает ввод")
            }
            Text(tab.displayTitle).lineLimit(1).truncationMode(.middle)
                .font(.system(size: 12, weight: selected ? .medium : .regular))
                .frame(maxWidth: 180, alignment: .leading)
            Button { app.closeTab(tab.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.primary.opacity(hover ? 0.1 : 0)))
            }
            .buttonStyle(.plain)
            .opacity(hover || selected ? 1 : 0)
            .help("Закрыть (⌘W)")
        }
        .padding(.leading, 10).padding(.trailing, 6).frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color(nsColor: .controlBackgroundColor) : Color.primary.opacity(hover ? 0.06 : 0))
                .overlay {
                    if let c = tint {
                        RoundedRectangle(cornerRadius: 7, style: .continuous).fill(c.opacity(selected ? 0.22 : 0.13))
                    }
                }
                .overlay(alignment: .bottom) {
                    if let c = tint {
                        Capsule().fill(c).frame(height: 2.5).padding(.horizontal, 8).padding(.bottom, 1)
                    }
                }
                .shadow(color: .black.opacity(selected ? 0.12 : 0), radius: 1, y: 0.5)
        )
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor.opacity(dropTarget ? 0.8 : 0), lineWidth: 1.5))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { app.activeTabID = tab.id }
        .overlay(MiddleClickCatcher { app.closeTab(tab.id) })
        .help(tab.session.destination + (index < 9 ? "  ⌘\(index + 1)" : "") + "\nДвойной щелчок — переименовать")
        .simultaneousGesture(TapGesture(count: 2).onEnded { app.renamingTab = tab })
        .draggable(tab.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let s = items.first, let id = UUID(uuidString: s) else { return false }
            app.moveTab(id, to: index)
            return true
        } isTargeted: { dropTarget = $0 }
        .contextMenu {
            Button("Переподключить") { tab.reconnect() }.disabled(tab.state != .disconnected)
            Button("Дублировать вкладку") { app.duplicateTab(tab) }
            Button("Переименовать…") { app.renamingTab = tab }
            Menu("Цвет вкладки") {
                Button("Как у сессии") { tab.tabColor = nil }
                Button("Без цвета") { tab.tabColor = SessionColor.none.rawValue }
                Divider()
                ForEach(SessionColor.allCases.filter { $0 != .none }) { c in
                    Button { tab.tabColor = c.rawValue } label: {
                        Label(c.title, systemImage: tab.colorName == c.rawValue ? "checkmark.circle.fill" : "circle.fill")
                    }
                    .tint(c.color)
                }
            }
            Divider()
            Button("Закрыть") { app.closeTab(tab.id) }
            Button("Закрыть остальные") { app.closeOtherTabs(tab.id) }.disabled(app.tabs.count < 2)
        }
    }
}

/// Прозрачный слой, который ловит только средний клик и пропускает остальные события.
private struct MiddleClickCatcher: NSViewRepresentable {
    let action: () -> Void

    final class CatcherView: NSView {
        var action: (() -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let t = NSApp.currentEvent?.type, t == .otherMouseDown || t == .otherMouseUp else { return nil }
            return super.hitTest(point)
        }
        override func otherMouseUp(with event: NSEvent) {
            if event.buttonNumber == 2 { action?() }
        }
    }

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.action = action
        return v
    }

    func updateNSView(_ v: CatcherView, context: Context) { v.action = action }
}

extension SessionColor {
    var title: String {
        switch self {
        case .none: "Нет"
        case .red: "Красный"
        case .orange: "Оранжевый"
        case .yellow: "Жёлтый"
        case .green: "Зелёный"
        case .blue: "Синий"
        case .purple: "Фиолетовый"
        case .gray: "Серый"
        }
    }
}
