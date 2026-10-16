import Charts
import SwiftUI

/// Cores das fases, sempre do sistema: se ajustam sozinhas ao modo claro e escuro.
enum PhaseColors {
    static let download: [Color] = [.cyan, .blue]
    static let upload: [Color] = [.purple, .pink]
}

/// Bloco arredondado no estilo dos módulos da Central de Controle.
struct ModuleBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

extension View {
    func module() -> some View { modifier(ModuleBackground()) }
}

struct PopoverView: View {
    @EnvironmentObject var controller: TestController
    @EnvironmentObject var history: HistoryStore
    @EnvironmentObject var tester: SpeedTester

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Velocidade da internet").font(.headline)
                Spacer()
                if let last = history.last, !tester.isRunning {
                    Text(last.date.formatted(.relative(presentation: .named)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            SpeedGauge(value: gaugeValue, caption: gaugeCaption,
                       colors: tester.phase == .upload ? PhaseColors.upload : PhaseColors.download)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)

            if tester.isRunning {
                Button(role: .cancel, action: { controller.cancel() }) {
                    Label("Cancelar", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
            } else {
                Button(action: { controller.start() }) {
                    Label("Iniciar teste", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }

            if let error = controller.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            Metrics()
            HistoryList()
            Footer()
        }
        .padding(14)
        .frame(width: 330)
    }

    private var gaugeValue: Double? {
        tester.isRunning ? tester.liveSpeed : history.last?.downloadMbps
    }

    private var gaugeCaption: String {
        switch tester.phase {
        case .starting: tester.status ?? "Preparando…"
        case .download: "Mbps · download"
        case .upload: "Mbps · upload"
        case .idle: history.last == nil ? "Nenhum teste ainda" : "Mbps · download"
        }
    }
}

// MARK: - Medidas do último teste (ou ao vivo)

struct Metrics: View {
    @EnvironmentObject var history: HistoryStore
    @EnvironmentObject var tester: SpeedTester

    var body: some View {
        let last = history.last
        let live = tester.isRunning
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    metric("Download", live ? tester.liveDownload : last?.downloadMbps, "Mbps",
                           "arrow.down.circle.fill", tint: .blue)
                    metric("Upload", live ? tester.liveUpload : last?.uploadMbps, "Mbps",
                           "arrow.up.circle.fill", tint: .purple)
                }
                GridRow {
                    metric("Latência", live ? nil : last?.idleLatencyMs, "ms", "timer", tint: .secondary,
                           help: "Tempo de resposta com a conexão parada")
                    metric("Com carga", live ? nil : last?.loadedLatencyMs, "ms", "gauge.with.dots.needle.67percent",
                           tint: .secondary, help: "Latência enquanto a conexão está cheia (durante o download)")
                }
            }
            if live {
                if let server = tester.serverLabel {
                    Label("Testando com \(server)", systemImage: "server.rack")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            } else if let last {
                VStack(alignment: .leading, spacing: 3) {
                    Label(last.serverLabel ?? ServerName.friendly(last.server), systemImage: "server.rack")
                        .help("Servidor do teste: \(last.server ?? "—")")
                    if let conn = last.connection {
                        Label(connectionText(last, conn), systemImage: conn.symbol)
                            .help(last.wifi?.details ?? "Via \(InterfaceName.friendly(last.interface))")
                    }
                }
                .lineLimit(1)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .module()
    }

    /// "Wi-Fi · 5 GHz · canal 48 · sinal −54 dBm (bom)" ou só "Cabo".
    private func connectionText(_ r: SpeedRecord, _ conn: ConnectionKind) -> String {
        guard conn == .wifi, let wifi = r.wifi else { return conn.title }
        return "Wi-Fi · " + wifi.summary
    }

    private func metric(_ title: String, _ value: Double?, _ unit: String, _ icon: String,
                        tint: some ShapeStyle, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(title).foregroundStyle(.secondary)
            }
            .font(.caption)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value.map { String(Int($0.rounded())) } ?? "—")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(help ?? title)
    }
}

// MARK: - Histórico

struct HistoryList: View {
    @EnvironmentObject var history: HistoryStore
    /// "todos", "wifi" ou "cabo".
    @AppStorage("filtroConexao") private var filter = "todos"

    var body: some View {
        let all = history.state.records
        let records = filter == "todos" ? all : all.filter { $0.connection?.rawValue == filter }
        if !all.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Histórico")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("Conexão", selection: $filter) {
                        Text("Todos").tag("todos")
                        Image(systemName: ConnectionKind.wifi.symbol).help("Só Wi-Fi").tag("wifi")
                        Image(systemName: ConnectionKind.cabo.symbol).help("Só cabo").tag("cabo")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }

                if records.isEmpty {
                    Text("Nenhum teste por \(filter == "wifi" ? "Wi-Fi" : "cabo") ainda.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    Text(average(records))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if records.count >= 2 {
                        TrendChart(records: records)
                    }
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(records.reversed().enumerated()), id: \.element.id) { i, r in
                                if i > 0 { Divider() }
                                row(r)
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                }
            }
            .module()
        }
    }

    private func row(_ r: SpeedRecord) -> some View {
        HStack(spacing: 6) {
            Image(systemName: r.connection?.symbol ?? "questionmark")
                .frame(width: 16)
                .foregroundStyle(.secondary)
                .help(r.wifi.map { "Wi-Fi · " + $0.details } ?? r.connection?.title ?? "Conexão desconhecida")
            Text(r.date.formatted(.dateTime.day().month(.twoDigits).hour().minute()))
                .foregroundStyle(.secondary)
                .layoutPriority(1)
            Image(systemName: (r.engine ?? .apple).symbol)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .help(r.serverLabel ?? ServerName.friendly(r.server))
            if r.automatic {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("Teste automático")
            }
            Spacer()
            Label("\(Int(r.downloadMbps.rounded()))", systemImage: "arrow.down")
                .labelStyle(CompactLabel(tint: .blue))
                .frame(width: 48, alignment: .trailing)
            Label("\(Int(r.uploadMbps.rounded()))", systemImage: "arrow.up")
                .labelStyle(CompactLabel(tint: .purple))
                .frame(width: 48, alignment: .trailing)
        }
        .font(.callout.monospacedDigit())
        .lineLimit(1)
        .padding(.vertical, 5)
    }

    private func average(_ records: [SpeedRecord]) -> String {
        let n = Double(records.count)
        let down = records.map(\.downloadMbps).reduce(0, +) / n
        let up = records.map(\.uploadMbps).reduce(0, +) / n
        return "Média de \(records.count) \(records.count == 1 ? "teste" : "testes"): ↓ \(Int(down.rounded())) · ↑ \(Int(up.rounded())) Mbps"
    }
}

/// Seta colorida + número, compacto para as linhas do histórico.
struct CompactLabel: LabelStyle {
    var tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon.foregroundStyle(tint).font(.caption.bold())
            configuration.title
        }
    }
}

// MARK: - Rodapé: ajustes e sair

struct Footer: View {
    @EnvironmentObject var controller: TestController
    @EnvironmentObject var history: HistoryStore

    var body: some View {
        HStack {
            Group {
                if let reason = controller.autoSkipReason, history.state.autoIntervalHours > 0 {
                    Label("Automático adiado: \(reason)", systemImage: "pause.circle")
                } else {
                    Text(history.state.records.count == 1 ? "1 teste" : "\(history.state.records.count) testes")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            Spacer()
            Menu {
                Picker("Servidor do teste", selection: Binding(
                    get: { history.engine },
                    set: { history.setEngine($0) })) {
                    Text("Apple (padrão)").tag(TestEngine.apple)
                    Text("Operadora, estilo Speedtest").tag(TestEngine.operadora)
                }
                Divider()
                Picker("Barra de menus", selection: Binding(
                    get: { history.menuBarMode },
                    set: { controller.setMenuBarMode($0) })) {
                    ForEach(MenuBarMode.allCases) { Text($0.title).tag($0) }
                }
                Picker("Teste automático", selection: Binding(
                    get: { history.state.autoIntervalHours },
                    set: { controller.setAutoInterval(hours: $0) })) {
                    Text("Desligado").tag(0)
                    Text("A cada hora").tag(1)
                    Text("A cada 3 horas").tag(3)
                    Text("A cada 6 horas").tag(6)
                    Text("A cada 12 horas").tag(12)
                }
                Toggle("Automático só no carregador", isOn: Binding(
                    get: { history.autoOnlyOnAC },
                    set: { history.setAutoOnlyOnAC($0) }))
                .disabled(history.state.autoIntervalHours == 0)
                Divider()
                Toggle("Abrir ao iniciar a sessão", isOn: Binding(
                    get: { controller.launchAtLogin },
                    set: { controller.setLaunchAtLogin($0) }))
                Divider()
                Button("Sair") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Ajustes")
        }
    }
}

// MARK: - Gráfico do histórico

/// O ponto do gráfico sob o mouse. (Classe só para viver num @StateObject: o @State do
/// SwiftUI é uma macro que exige o Xcode completo para compilar.)
final class ChartHover: ObservableObject {
    @Published var date: Date?
}

/// Velocidade ao longo do tempo: uma linha só, ligando os testes em ordem, com os pontos
/// coloridos pela conexão (Wi-Fi ou cabo).
struct TrendChart: View {
    let records: [SpeedRecord]
    /// Só para o snapshot: simula o mouse sobre um ponto.
    var previewHover: Date?

    @AppStorage("graficoMetrica") private var metric = "download"
    @StateObject private var hover = ChartHover()

    private var shown: [SpeedRecord] { Array(records.suffix(30)) }
    private var isUpload: Bool { metric == "upload" }

    private func value(_ r: SpeedRecord) -> Double { isUpload ? r.uploadMbps : r.downloadMbps }

    /// Só as conexões que aparecem nos testes, para a legenda não mostrar sobras.
    private var kinds: [ConnectionKind] {
        ConnectionKind.allCases.filter { k in shown.contains { ($0.connection ?? .outra) == k } }
    }

    private func color(_ k: ConnectionKind) -> Color {
        switch k {
        case .wifi: .blue
        case .cabo: .teal
        case .outra: .gray
        }
    }

    private var average: Double {
        shown.map(value).reduce(0, +) / Double(max(shown.count, 1))
    }

    /// Teto arredondado, com folga para o rótulo da média e do mouse.
    private var yMax: Double {
        let top = (shown.map(value).max() ?? 0) * 1.15
        let step: Double = top > 500 ? 250 : top > 100 ? 50 : 10
        return max(step, (top / step).rounded(.up) * step)
    }

    /// Testes do mesmo dia mostram a hora; de dias diferentes, a data.
    private var spansDays: Bool {
        guard let first = shown.first?.date, let last = shown.last?.date else { return false }
        return last.timeIntervalSince(first) > 36 * 3600
    }

    /// De quantos em quantos dias rotular o eixo, para caberem até ~5 datas.
    private var dayStride: Int {
        guard let first = shown.first?.date, let last = shown.last?.date else { return 1 }
        let days = Int(last.timeIntervalSince(first) / 86400) + 1
        return max(1, Int((Double(days) / 5).rounded(.up)))
    }

    private var hovered: SpeedRecord? {
        guard let date = previewHover ?? hover.date else { return nil }
        return shown.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let h = hovered {
                    HoverReadout(record: h, isUpload: isUpload)
                } else {
                    Text(isUpload ? "Upload (Mbps)" : "Download (Mbps)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Medida", selection: $metric) {
                    Text("Download").tag("download")
                    Text("Upload").tag("upload")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .fixedSize()
            }
            chart
                .frame(height: 150)
        }
    }

    /// Cor da linha e da área: a da conexão quando só há uma; neutra quando há mais de uma.
    private var lineColor: Color {
        kinds.count == 1 ? color(kinds[0]) : .secondary
    }

    private var chart: some View {
        let single = kinds.count == 1
        return Chart {
            ForEach(shown) { r in
                let kind = r.connection ?? .outra
                AreaMark(x: .value("Data", r.date), y: .value("Mbps", value(r)))
                    .foregroundStyle(LinearGradient(
                        colors: [lineColor.opacity(single ? 0.25 : 0.12), lineColor.opacity(0)],
                        startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Data", r.date), y: .value("Mbps", value(r)))
                    .foregroundStyle(lineColor.opacity(single ? 1 : 0.55))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                PointMark(x: .value("Data", r.date), y: .value("Mbps", value(r)))
                    .foregroundStyle(by: .value("Conexão", kind.title))
                    .symbol {
                        Circle()
                            .fill(color(kind))
                            .frame(width: 8, height: 8)
                            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                    }
            }

            RuleMark(y: .value("Média", average))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .foregroundStyle(.secondary.opacity(0.7))
                .annotation(position: .top, alignment: .leading, spacing: 2) {
                    Text("média \(Int(average.rounded()))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

            if let h = hovered {
                RuleMark(x: .value("Data", h.date))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(.secondary.opacity(0.5))
                PointMark(x: .value("Data", h.date), y: .value("Mbps", value(h)))
                    .symbol {
                        Circle()
                            .fill(color(h.connection ?? .outra))
                            .frame(width: 11, height: 11)
                            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                    }
            }
        }
        .chartForegroundStyleScale(domain: kinds.map(\.title), range: kinds.map(color))
        .chartLegend(single ? .hidden : .automatic)
        .chartLegend(position: .bottom, alignment: .leading, spacing: 6)
        .chartYScale(domain: 0...yMax)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.secondary.opacity(0.3))
                AxisValueLabel {
                    if let mbps = v.as(Double.self) {
                        Text(verbatim: String(Int(mbps))).monospacedDigit()
                    }
                }
            }
        }
        .chartXAxis {
            if spansDays {
                AxisMarks(values: .stride(by: .day, count: dayStride)) { _ in
                    AxisTick(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(.secondary.opacity(0.5))
                    AxisValueLabel(format: .dateTime.day().month(.defaultDigits), centered: false)
                }
            } else {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisTick(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(.secondary.opacity(0.5))
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
        }
        .chartXSelection(value: $hover.date)
        .font(.caption2)
        .accessibilityLabel(isUpload ? "Upload ao longo do tempo" : "Download ao longo do tempo")
    }
}

/// Os valores do ponto sob o mouse, mostrados no lugar do título do gráfico.
struct HoverReadout: View {
    let record: SpeedRecord
    let isUpload: Bool

    var body: some View {
        HStack(spacing: 5) {
            Text("\(Int((isUpload ? record.uploadMbps : record.downloadMbps).rounded())) Mbps")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
            Group {
                Text(record.date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                if let conn = record.connection {
                    Image(systemName: conn.symbol)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .lineLimit(1)
    }
}
