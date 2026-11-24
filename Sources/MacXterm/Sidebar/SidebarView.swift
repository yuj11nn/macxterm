import SwiftUI

/// Сайдбар: сессии сверху, SFTP снизу; высота SFTP-части регулируется и запоминается.
struct SidebarView: View {
    @AppStorage(Prefs.sftpHeight) private var sftpHeight = 300.0
    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { geo in
            let maxH = max(140, geo.size.height - 160)
            let h = min(max(sftpHeight, 120), maxH)
            VStack(spacing: 0) {
                SessionsSidebar().frame(maxHeight: .infinity)
                SplitHandle()
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { v in
                            if dragStart == nil { dragStart = h }
                            sftpHeight = min(max((dragStart ?? h) - v.translation.height, 120), maxH)
                        }
                        .onEnded { _ in dragStart = nil })
                SFTPPanel().frame(height: h)
            }
        }
    }
}

private struct SplitHandle: View {
    @State private var hover = false
    var body: some View {
        ZStack {
            Rectangle().fill(Color.clear).frame(height: 7)
            Divider()
            Capsule().fill(Color.secondary.opacity(hover ? 0.5 : 0.25)).frame(width: 34, height: 4)
        }
        .contentShape(Rectangle())
        .onHover { h in
            hover = h
            if h { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
    }
}
