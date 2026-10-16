import SwiftUI

/// Escala não linear, como a do Speedtest: cada marca ocupa o mesmo ângulo, então
/// velocidades baixas não ficam espremidas no começo do arco.
enum GaugeScale {
    static let marks: [Double] = [0, 5, 10, 50, 100, 250, 500, 750, 1000]

    static func fraction(for value: Double) -> Double {
        let v = max(0, value)
        guard v < marks[marks.count - 1] else { return 1 }
        let i = marks.lastIndex { $0 <= v } ?? 0
        let a = marks[i]
        let b = marks[i + 1]
        return (Double(i) + (v - a) / (b - a)) / Double(marks.count - 1)
    }

    static func label(_ mark: Double) -> String {
        mark >= 1000 ? "1G" : String(Int(mark))
    }
}

/// Trecho da meia-lua entre duas frações (0 = esquerda, 1 = direita, passando pelo topo).
struct GaugeArc: Shape {
    var from: Double
    var to: Double
    var inset: CGFloat

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(from, to) }
        set { from = newValue.first; to = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2 - inset
        var p = Path()
        p.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY), radius: radius,
            startAngle: .degrees(180 + 180 * from), endAngle: .degrees(180 + 180 * to), clockwise: false)
        return p
    }
}

/// Velocímetro em meia-lua: o arco enche como um termômetro conforme a velocidade.
struct SpeedGauge: View {
    var value: Double?
    var caption: String
    var colors: [Color]

    private let size: CGFloat = 250
    private let lineWidth: CGFloat = 14

    var body: some View {
        let f = GaugeScale.fraction(for: value ?? 0)
        let radius = size / 2 - lineWidth / 2
        let center = CGPoint(x: size / 2, y: size / 2)

        ZStack {
            GaugeArc(from: 0, to: 1, inset: lineWidth / 2)
                .stroke(Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            GaugeArc(from: 0, to: f, inset: lineWidth / 2)
                .stroke(
                    LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .opacity(value == nil ? 0 : 1)

            ForEach(Array(GaugeScale.marks.enumerated()), id: \.offset) { i, mark in
                let angle = Angle.degrees(180 + 180 * Double(i) / Double(GaugeScale.marks.count - 1))
                let r = radius - lineWidth - 10
                Text(GaugeScale.label(mark))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .position(x: center.x + r * cos(angle.radians), y: center.y + r * sin(angle.radians))
            }

            // Marcador na ponta do arco; gira com a velocidade.
            Circle()
                .fill(.white)
                .frame(width: lineWidth - 2, height: lineWidth - 2)
                .shadow(color: .black.opacity(0.3), radius: 2)
                .offset(x: -radius)
                .rotationEffect(.degrees(180 * f))
                .opacity(value == nil ? 0 : 1)

            VStack(spacing: 0) {
                Text(value.map { String(Int($0.rounded())) } ?? "—")
                    .font(.system(size: 46, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .position(x: center.x, y: center.y - 22)
        }
        .frame(width: size, height: size)
        .frame(height: size / 2 + 20, alignment: .top)
        .animation(.easeOut(duration: 0.5), value: f)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption)
        .accessibilityValue(value.map { "\(Int($0.rounded())) megabits por segundo" } ?? "sem medição")
    }
}
