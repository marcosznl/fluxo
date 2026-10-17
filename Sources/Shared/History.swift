import Combine
import Foundation
import WidgetKit

/// O resultado de um teste, antes de virar um registro do histórico.
struct SpeedResult {
    var downloadMbps: Double
    var uploadMbps: Double
    var idleLatencyMs: Double?
    var loadedLatencyMs: Double?   // latência durante o download
    var server: String?            // nome técnico, ex.: brsao4-edge-bx-021.aaplimg.com
    var serverLabel: String?       // nome amigável, ex.: Apple · São Paulo
    var interface: String?
}

struct SpeedRecord: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var downloadMbps: Double
    var uploadMbps: Double
    var idleLatencyMs: Double?
    var loadedLatencyMs: Double?
    var server: String?
    var interface: String?
    var automatic: Bool
    // Campos novos são opcionais, para o histórico antigo continuar abrindo.
    var engine: TestEngine?
    var serverLabel: String?
    var connection: ConnectionKind?
    var wifi: WifiInfo?
}

/// O que a barra de menus mostra quando não há teste rodando.
enum MenuBarMode: String, Codable, CaseIterable, Identifiable {
    case trafego, ultimoTeste, icone
    var id: String { rawValue }

    var title: String {
        switch self {
        case .trafego: "Tráfego ao vivo (↓ ↑)"
        case .ultimoTeste: "Velocidade do último teste"
        case .icone: "Só o ícone"
        }
    }
}

struct SavedState: Codable {
    var records: [SpeedRecord] = []
    var menuBarMode: MenuBarMode?   // nil = tráfego ao vivo
    var autoIntervalHours = 0   // 0 = desligado
    var engine: TestEngine?     // nil = Apple
    var autoOnlyOnAC: Bool?     // nil = sim
}

/// Histórico dos testes e preferências, salvos num JSON na pasta compartilhada com o widget.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var state: SavedState

    private let fileURL: URL

    nonisolated static var legacyFileURL: URL {
        SharedFiles.legacyDirectory.appendingPathComponent("historico.json")
    }

    nonisolated static var defaultFileURL: URL {
        SharedFiles.directory.appendingPathComponent("historico.json")
    }

    /// Leitura simples, para o widget (que só lê, fora da thread principal).
    nonisolated static func loadRecords(from url: URL = defaultFileURL) -> [SpeedRecord] {
        guard let data = try? Data(contentsOf: url),
              let saved = try? decoder.decode(SavedState.self, from: data) else { return [] }
        return saved.records
    }

    init(fileURL: URL = HistoryStore.defaultFileURL) {
        self.fileURL = fileURL
        // Primeira vez com o App Group: traz o histórico da pasta antiga (que fica como cópia).
        let legacy = Self.legacyFileURL
        if fileURL != legacy, !FileManager.default.fileExists(atPath: fileURL.path),
           FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.copyItem(at: legacy, to: fileURL)
        }
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? Self.decoder.decode(SavedState.self, from: data) {
            state = saved
        } else {
            state = SavedState()
        }
    }

    var last: SpeedRecord? { state.records.last }

    var engine: TestEngine { state.engine ?? .apple }

    var autoOnlyOnAC: Bool { state.autoOnlyOnAC ?? true }

    @discardableResult
    func add(_ r: SpeedResult, engine: TestEngine, automatic: Bool, at date: Date = .now,
             connection: ConnectionKind? = nil, wifi: WifiInfo? = nil) -> SpeedRecord {
        let record = SpeedRecord(
            date: date, downloadMbps: r.downloadMbps, uploadMbps: r.uploadMbps,
            idleLatencyMs: r.idleLatencyMs, loadedLatencyMs: r.loadedLatencyMs,
            server: r.server, interface: r.interface, automatic: automatic,
            engine: engine, serverLabel: r.serverLabel,
            connection: connection ?? ConnectionKind.of(interface: r.interface), wifi: wifi)
        state.records.append(record)
        save()
        return record
    }

    /// Download típico (mediana dos últimos 10) numa conexão, sem contar um teste específico.
    func typicalDownload(on connection: ConnectionKind?, excluding id: UUID) -> Double? {
        let values = state.records.filter { $0.connection == connection && $0.id != id }
            .suffix(10).map(\.downloadMbps).sorted()
        return values.count >= 3 ? values[values.count / 2] : nil
    }

    func setAutoOnlyOnAC(_ on: Bool) {
        state.autoOnlyOnAC = on
        save()
    }

    func delete(_ id: UUID) {
        state.records.removeAll { $0.id == id }
        save()
    }

    func clearHistory() {
        state.records.removeAll()
        save()
    }

    func setEngine(_ engine: TestEngine) {
        state.engine = engine
        save()
    }

    var menuBarMode: MenuBarMode { state.menuBarMode ?? .trafego }

    func setMenuBarMode(_ mode: MenuBarMode) {
        state.menuBarMode = mode
        save()
    }

    func setAutoInterval(hours: Int) {
        state.autoIntervalHours = hours
        save()
    }

    nonisolated private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    nonisolated private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func save() {
        guard let data = try? Self.encoder.encode(state) else { return }
        try? data.write(to: fileURL, options: .atomic)
        // O widget redesenha com o histórico novo.
        WidgetCenter.shared.reloadAllTimelines()
    }
}
