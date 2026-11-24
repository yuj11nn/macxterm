import SwiftUI

struct Toast: Equatable, Identifiable {
    let id = UUID()
    let text: String
    let icon: String
    let isError: Bool
}

struct ToastView: View {
    @Environment(AppState.self) private var app
    var body: some View {
        Group {
            if let t = app.toast {
                HStack(spacing: 8) {
                    Image(systemName: t.icon).foregroundStyle(t.isError ? .orange : .green)
                    Text(t.text).font(.callout).lineLimit(3)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
                .padding(.bottom, 40)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(t.id)
                .onTapGesture { app.toast = nil }
            }
        }
        .animation(.spring(duration: 0.3), value: app.toast)
    }
}
