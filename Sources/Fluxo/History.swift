import Foundation

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

/// Histórico dos testes e preferências, salvos num JSON local.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var state: SavedState

    private let fileURL: URL

    nonisolated static var defaultFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fluxo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("historico.json")
    }

    init(fileURL: URL = HistoryStore.defaultFileURL) {
        self.fileURL = fileURL
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

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func save() {
        guard let data = try? Self.encoder.encode(state) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
