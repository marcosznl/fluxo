import SwiftUI
import WidgetKit

struct FluxoEntry: TimelineEntry {
    let date: Date
    let records: [SpeedRecord]
}

/// O widget lê o histórico que o app grava no App Group. O app pede um redesenho a cada
/// teste; fora isso, ele relê o histórico a cada hora.
struct FluxoProvider: TimelineProvider {
    func placeholder(in context: Context) -> FluxoEntry {
        FluxoEntry(date: .now, records: Self.sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (FluxoEntry) -> Void) {
        let records = HistoryStore.loadRecords()
        completion(FluxoEntry(date: .now, records: context.isPreview && records.isEmpty ? Self.sample : records))
    }

    /// Uma entrada a cada 5 minutos na próxima hora, só para o "há X minutos" andar.
    func getTimeline(in context: Context, completion: @escaping (Timeline<FluxoEntry>) -> Void) {
        let records = HistoryStore.loadRecords()
        let entries = (0...12).map { FluxoEntry(date: .now.addingTimeInterval(Double($0) * 300), records: records) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    /// Exemplo para a galeria de widgets, antes do primeiro teste.
    static let sample: [SpeedRecord] = [(6, 480.0, 240.0), (4, 495, 250), (2, 470, 236), (0.2, 500, 248)].map {
        SpeedRecord(date: .now.addingTimeInterval(-$0.0 * 3600), downloadMbps: $0.1, uploadMbps: $0.2,
                    automatic: false, connection: .wifi)
    }
}

struct FluxoWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FluxoWidget", provider: FluxoProvider()) { entry in
            FluxoWidgetEntryView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Fluxo")
        .description("O último teste de velocidade e o histórico recente.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct FluxoWidgetEntryView: View {
    let entry: FluxoEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        FluxoWidgetView(records: entry.records, medium: family == .systemMedium, now: entry.date)
    }
}

// MARK: - Usando a internet

struct AppsEntry: TimelineEntry {
    let date: Date
    let snapshot: AppsSnapshot?
}

/// O app grava quem mais usou a rede a cada 15 minutos e pede o redesenho; as entradas a
/// cada 5 minutos só fazem o "há X minutos" andar.
struct AppsProvider: TimelineProvider {
    func placeholder(in context: Context) -> AppsEntry {
        AppsEntry(date: .now, snapshot: Self.sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (AppsEntry) -> Void) {
        let saved = AppsSnapshot.load()
        completion(AppsEntry(date: .now, snapshot: context.isPreview && saved == nil ? Self.sample : saved))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AppsEntry>) -> Void) {
        let saved = AppsSnapshot.load()
        let entries = (0...6).map { AppsEntry(date: .now.addingTimeInterval(Double($0) * 300), snapshot: saved) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    static let sample = AppsSnapshot(date: .now, intervalMinutes: 15, apps: [
        .init(name: "Safari", downBytes: 320_000_000, upBytes: 12_000_000, iconFile: nil),
        .init(name: "Música", downBytes: 85_000_000, upBytes: 1_000_000, iconFile: nil),
        .init(name: "iCloud Drive", downBytes: 4_000_000, upBytes: 60_000_000, iconFile: nil),
    ])
}

struct FluxoAppsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FluxoApps", provider: AppsProvider()) { entry in
            AppsEntryView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Usando a internet")
        .description("Os apps que mais usaram a rede nos últimos 15 minutos.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct AppsEntryView: View {
    let entry: AppsEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        AppsWidgetView(snapshot: entry.snapshot, medium: family == .systemMedium, now: entry.date)
    }
}

@main
struct FluxoWidgetBundle: WidgetBundle {
    var body: some Widget {
        FluxoWidget()
        FluxoAppsWidget()
    }
}
