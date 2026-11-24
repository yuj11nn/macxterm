import AppKit
import SwiftUI

/// Контейнер, который меняет subview на терминал активной вкладки.
/// Сами NSView не пересоздаются — ssh-процессы живут, пока жива вкладка.
struct TerminalHostView: NSViewRepresentable {
    let terminal: TerminalSession?

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        return v
    }

    func updateNSView(_ container: NSView, context: Context) {
        let target = terminal?.view
        if container.subviews.first === target { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        guard let target else { return }
        target.frame = container.bounds
        target.autoresizingMask = [.width, .height]
        container.addSubview(target)
        DispatchQueue.main.async { target.window?.makeFirstResponder(target) }
    }
}
