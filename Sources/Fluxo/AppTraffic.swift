import AppKit

/// Um app e quanto ele está usando da rede agora.
struct AppUsage: Identifiable {
    var id: String { name }
    let name: String
    let downBps: Double
    let upBps: Double
    let icon: NSImage?

    var totalBps: Double { downBps + upBps }
}

/// Quem está usando a internet agora, lido do `nettop` (já vem no macOS). Só roda com o
/// painel aberto: o nettop gasta um pouco de processador, e ninguém está olhando a lista
/// com o painel fechado.
@MainActor
final class AppTrafficMonitor: ObservableObject {
    @Published private(set) var top: [AppUsage] = []
    @Published private(set) var isRunning = false
    /// Já chegou a primeira leitura (antes dela, a lista vazia quer dizer "medindo").
    @Published private(set) var hasReading = false

    static let interval: Double = 2
    private var running: RunningProcess?

    /// Painel aberto há mais tempo que isso sem ser fechado: desliga por segurança.
    private static let maxRunSeconds: Double = 600
    private var watchdog: Timer?

    func start() {
        guard running == nil else { return }
        watchdog = Timer.scheduledTimer(withTimeInterval: Self.maxRunSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        let running = RunningProcess()
        self.running = running
        isRunning = true
        let parser = NettopParser { [weak self] bytes in
            Task { @MainActor in self?.publish(bytes) }
        }
        Task {
            // -P por processo, -d diferença desde a amostra anterior, -x números exatos,
            // -L 0 sem parar, -s a cada 2 s, só bytes recebidos e enviados.
            _ = try? await PTY.run(
                "/usr/bin/nettop",
                ["-P", "-d", "-x", "-n", "-L", "0", "-s", String(Int(Self.interval)), "-J", "bytes_in,bytes_out"],
                running: running, collect: false) { parser.consume($0) }
        }
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        running?.terminate()
        running = nil
        isRunning = false
        hasReading = false
        top = []
    }

    private func publish(_ bytes: [(process: String, pid: Int32, rx: Double, tx: Double)]) {
        guard isRunning else { return }
        hasReading = true
        // Junta processos do mesmo app (auxiliares, abas, renderizadores).
        var grouped: [String: (rx: Double, tx: Double, pid: Int32)] = [:]
        for b in bytes where b.rx + b.tx > 0 {
            let name = Self.displayName(process: b.process, pid: b.pid)
            let current = grouped[name] ?? (0, 0, b.pid)
            grouped[name] = (current.rx + b.rx, current.tx + b.tx, current.pid)
        }
        top = grouped
            .map { name, v in
                AppUsage(name: name, downBps: v.rx * 8 / Self.interval, upBps: v.tx * 8 / Self.interval,
                         icon: Self.icon(for: name, pid: v.pid))
            }
            .filter { $0.totalBps >= 1_000 }   // ignora o que está abaixo de 1 kbps
            .sorted { $0.totalBps > $1.totalBps }
            .prefix(5)
            .map { $0 }
    }

    // MARK: Nomes e ícones

    /// Processos do sistema com nomes que não dizem nada a quem usa.
    private static let systemNames: [String: String] = [
        "mDNSResponder": "DNS do sistema",
        "com.apple.WebKi": "Safari e WebKit",
        "apsd": "Notificações da Apple",
        "nsurlsessiond": "Downloads em segundo plano",
        "softwareupdated": "Atualização do macOS",
        "cloudd": "iCloud",
        "bird": "iCloud Drive",
        "networkQuality": "Teste de velocidade",
        "trustd": "Certificados do sistema",
        "rapportd": "Continuidade (outros aparelhos Apple)",
        "sharingd": "AirDrop e compartilhamento",
        "identityservice": "iMessage e FaceTime",
    ]

    static func displayName(process: String, pid: Int32) -> String {
        if let known = systemNames[process] { return known }
        if let app = NSRunningApplication(processIdentifier: pid)?.localizedName {
            return mainAppName(app)
        }
        return mainAppName(process)
    }

    /// "Discord Helper (Renderer)" → "Discord".
    private static func mainAppName(_ name: String) -> String {
        if let range = name.range(of: " Helper") { return String(name[..<range.lowerBound]) }
        return name.trimmingCharacters(in: .whitespaces)
    }

    private static func icon(for name: String, pid: Int32) -> NSImage? {
        if let app = NSRunningApplication(processIdentifier: pid), app.bundleURL?.pathExtension == "app",
           mainAppName(app.localizedName ?? "") == name {
            return app.icon
        }
        // Auxiliar: usa o ícone do app principal que está aberto.
        return NSWorkspace.shared.runningApplications.first { $0.localizedName == name }?.icon
    }
}

/// Lê a saída do nettop em CSV: cada amostra começa com o cabeçalho ",bytes_in,bytes_out,"
/// e traz uma linha por processo ("nome.pid,recebidos,enviados,").
private final class NettopParser: @unchecked Sendable {
    private let lock = NSLock()
    private var block: [(process: String, pid: Int32, rx: Double, tx: Double)] = []
    private var samples = 0
    private let onSample: @Sendable ([(process: String, pid: Int32, rx: Double, tx: Double)]) -> Void

    init(onSample: @escaping @Sendable ([(process: String, pid: Int32, rx: Double, tx: Double)]) -> Void) {
        self.onSample = onSample
    }

    func consume(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        if line.hasPrefix(",bytes_in") {
            // O cabeçalho fecha a amostra anterior. A primeira traz os totais desde que cada
            // processo abriu; só a partir da segunda é "quanto passou nos últimos 2 s".
            if samples >= 2 { onSample(block) }
            samples += 1
            block = []
            return
        }
        let cols = line.split(separator: ",", omittingEmptySubsequences: false)
        guard cols.count >= 3, let dot = cols[0].lastIndex(of: "."),
              let pid = Int32(cols[0][cols[0].index(after: dot)...]),
              let rx = Double(cols[1]), let tx = Double(cols[2]) else { return }
        block.append((String(cols[0][..<dot]), pid, rx, tx))
    }
}
