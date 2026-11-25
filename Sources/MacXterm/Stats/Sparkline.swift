import SwiftUI

/// Мини-график последних значений (0…100) с заливкой градиентом.
struct Sparkline: View {
    let values: [Double]
    var capacity: Int = StatsPoller.historySize
    var color: Color = .accentColor

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 2), with: .color(.primary.opacity(0.06)))
            guard values.count > 1 else {
                var base = Path()
                base.move(to: CGPoint(x: 0, y: size.height - 0.5))
                base.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
                ctx.stroke(base, with: .color(color.opacity(0.35)), lineWidth: 1)
                return
            }
            let step = size.width / CGFloat(max(1, capacity - 1))
            let x0 = size.width - step * CGFloat(values.count - 1)
            let pts = values.enumerated().map { i, v in
                CGPoint(x: x0 + step * CGFloat(i),
                        y: size.height - 1 - (size.height - 2) * CGFloat(max(0, min(100, v)) / 100))
            }
            var line = Path()
            line.addLines(pts)
            var fill = line
            fill.addLine(to: CGPoint(x: pts.last!.x, y: size.height))
            fill.addLine(to: CGPoint(x: pts[0].x, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(Gradient(colors: [color.opacity(0.45), color.opacity(0.05)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
        }
    }
}

extension Color {
    /// Зелёный → оранжевый → красный по уровню загрузки.
    static func load(_ percent: Double) -> Color {
        percent >= 85 ? .red : percent >= 60 ? .orange : .green
    }
}
