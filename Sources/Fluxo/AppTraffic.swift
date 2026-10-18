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
/// painel aberto. A cada 2 s faz uma leitura avulsa (`-L 1`, uns 10 ms de processador) e
/// compara com a anterior: o `nettop` contínuo (`-L 0`) fica girando a ~100% de CPU.
@MainActor
final class AppTrafficMonitor: ObservableObject {
    @Published private(set) var top: [AppUsage] = []
    @Published private(set) var isRunning = false
    /// Já chegou a primeira leitura (antes dela, a lista vazia quer dizer "medindo").
    @Published private(set) var hasReading = false

    static let interval: Double = 2
    private var loop: Task<Void, Never>?

    func start() {
        guard loop == nil else { return }
        isRunning = true
        loop = Task { [weak self] in
            var previous: [String: (rx: Double, tx: Double)]?
            var previousAt = Date.now
            while !Task.isCancelled {
                let totals = await Task.detached { Self.readTotals() }.value
                let now = Date.now
                if Task.isCancelled { break }
                if let previous, let totals {
                    self?.publish(Self.deltas(previous, totals), seconds: now.timeIntervalSince(previousAt))
                }
                if totals != nil {
                    previous = totals
                    previousAt = now
                }
                try? await Task.sleep(for: .seconds(Self.interval))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        isRunning = false
        hasReading = false
        top = []
    }

    /// Totais desde que cada processo abriu, por "nome.pid". Saída em CSV: o cabeçalho
    /// ",bytes_in,bytes_out," e uma linha por processo ("nome.pid,recebidos,enviados,").
    nonisolated private static func readTotals() -> [String: (rx: Double, tx: Double)]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-P", "-x", "-n", "-L", "1", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var totals: [String: (rx: Double, tx: Double)] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let cols = line.split(separator: ",", omittingEmptySubsequences: false)
            guard cols.count >= 3, let rx = Double(cols[1]), let tx = Double(cols[2]) else { continue }
            totals[String(cols[0])] = (rx, tx)
        }
        return totals
    }

    /// Quanto cada processo trafegou entre duas leituras. Processo novo conta inteiro.
    nonisolated private static func deltas(_ before: [String: (rx: Double, tx: Double)],
                                           _ now: [String: (rx: Double, tx: Double)])
        -> [(process: String, pid: Int32, rx: Double, tx: Double)] {
        now.compactMap { key, v in
            guard let dot = key.lastIndex(of: "."), let pid = Int32(key[key.index(after: dot)...]) else { return nil }
            let old = before[key] ?? (0, 0)
            guard v.rx >= old.rx, v.tx >= old.tx else { return nil }   // pid reaproveitado
            return (String(key[..<dot]), pid, v.rx - old.rx, v.tx - old.tx)
        }
    }

    private func publish(_ bytes: [(process: String, pid: Int32, rx: Double, tx: Double)], seconds: Double) {
        guard isRunning, seconds > 0 else { return }
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
                AppUsage(name: name, downBps: v.rx * 8 / seconds, upBps: v.tx * 8 / seconds,
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
