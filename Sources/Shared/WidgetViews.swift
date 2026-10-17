import Charts
import SwiftUI

/// O conteúdo do widget, sem nada de WidgetKit: assim o app também consegue desenhá-lo
/// (no modo --snapshot) para conferir o visual.
struct FluxoWidgetView: View {
    let records: [SpeedRecord]
    /// Tamanho médio: mostra também o gráfico e o botão "Testar agora".
    let medium: Bool
    /// O momento em que o widget é desenhado ("há 8 minutos" é contado a partir daqui).
    var now: Date = .now

    static let testURL = URL(string: "fluxo://testar")!

    var body: some View {
        if let last = records.last {
            if medium {
                HStack(spacing: 14) {
                    summary(last)
                    VStack(alignment: .trailing, spacing: 8) {
                        MiniChart(records: Array(records.suffix(12)))
                        testButton
                    }
                }
            } else {
                summary(last)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                header(nil)
                Spacer()
                Text("Nenhum teste ainda")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if medium { testButton }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private func header(_ last: SpeedRecord?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.up.arrow.down")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.blue)
            Text("Fluxo").font(.caption.weight(.semibold))
            Spacer(minLength: 4)
            if let conn = last?.connection {
                Image(systemName: conn.symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func summary(_ last: SpeedRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(last)
            Spacer(minLength: 4)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Image(systemName: "arrow.down")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.blue)
                Text(String(Int(last.downloadMbps.rounded())))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                Text("Mbps").font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Image(systemName: "arrow.up")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.purple)
                Text(String(Int(last.uploadMbps.rounded())))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text("Mbps").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(Self.relative.localizedString(for: last.date, relativeTo: max(now, last.date)))
                .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private var testButton: some View {
        Link(destination: Self.testURL) {
            Label("Testar agora", systemImage: "play.fill")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(.white)
                .background(Color.blue.gradient, in: Capsule())
        }
    }
}

/// Gráfico compacto do widget: uma linha só, com os pontos coloridos pela conexão.
private struct MiniChart: View {
    let records: [SpeedRecord]

    var body: some View {
        Chart(records) { r in
            LineMark(x: .value("Data", r.date), y: .value("Mbps", r.downloadMbps))
                .foregroundStyle(Color.secondary.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            PointMark(x: .value("Data", r.date), y: .value("Mbps", r.downloadMbps))
                .foregroundStyle(r.connection == .cabo ? Color.teal : Color.blue)
                .symbolSize(22)
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(.secondary.opacity(0.3))
                AxisValueLabel {
                    if let mbps = v.as(Double.self) { Text(verbatim: String(Int(mbps))) }
                }
            }
        }
        .font(.caption2)
    }
}

/// Widget "Usando a internet": os apps que mais usaram a rede no último intervalo medido.
struct AppsWidgetView: View {
    let snapshot: AppsSnapshot?
    let medium: Bool
    var now: Date = .now

    private static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .decimal
        f.allowedUnits = [.useKB, .useMB, .useGB]
        return f
    }()

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private static let shortRelative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let snapshot, !snapshot.apps.isEmpty {
                ForEach(snapshot.apps.prefix(medium ? 5 : 3)) { app in
                    row(app)
                }
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                Text(snapshot == nil
                     ? "Medindo… o primeiro resultado sai em até 15 minutos."
                     : "Nenhum app usou a rede nesse intervalo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.blue)
                Text("Usando a internet").font(.caption.weight(.semibold)).lineLimit(1)
            }
            if let snapshot {
                Text("\(interval(snapshot.intervalMinutes)) · \((medium ? Self.relative : Self.shortRelative).localizedString(for: snapshot.date, relativeTo: max(now, snapshot.date)))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func row(_ app: AppsSnapshot.App) -> some View {
        HStack(spacing: 6) {
            icon(app).frame(width: 16, height: 16)
            Text(app.name)
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 4)
            if medium {
                Group {
                    Text("↓ ").foregroundStyle(.blue) + Text(Self.bytes.string(fromByteCount: Int64(app.downBytes)))
                    Text("↑ ").foregroundStyle(.purple) + Text(Self.bytes.string(fromByteCount: Int64(app.upBytes)))
                }
                .font(.caption.monospacedDigit())
                .frame(width: 76, alignment: .trailing)
            } else {
                Text(Self.bytes.string(fromByteCount: Int64(app.totalBytes)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func icon(_ app: AppsSnapshot.App) -> some View {
        if let file = app.iconFile,
           let image = NSImage(contentsOf: SharedFiles.directory.appendingPathComponent(file)) {
            Image(nsImage: image).resizable()
        } else {
            Image(systemName: "gearshape.2").foregroundStyle(.secondary)
        }
    }

    private func interval(_ minutes: Int) -> String {
        minutes >= 90 ? "últimas \(Int((Double(minutes) / 60).rounded())) h" : "últimos \(minutes) min"
    }
}
