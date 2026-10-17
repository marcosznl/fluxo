import AppKit
import WidgetKit

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

    static func icon(for name: String, pid: Int32) -> NSImage? {
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

/// A cada 15 minutos, lê os totais do nettop e grava quem mais usou a rede nesse intervalo,
/// para o widget "Usando a internet". Uma leitura dessas leva centésimos de segundo; não
/// precisa deixar o nettop rodando.
@MainActor
final class AppUsageSampler {
    static let intervalMinutes = 15
    static let widgetKind = "FluxoApps"

    private var timer: Timer?
    private var previous: (totals: [String: (rx: Double, tx: Double)], at: Date)?

    func start() {
        guard timer == nil else { return }
        sample()   // a primeira leitura é só a base de comparação
        timer = Timer.scheduledTimer(withTimeInterval: Double(Self.intervalMinutes) * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    private func sample() {
        Task.detached(priority: .utility) {
            let totals = Self.readTotals()
            await MainActor.run { self.consume(totals) }
        }
    }

    /// Totais desde que cada processo abriu, por "nome.pid".
    nonisolated static func readTotals() -> [String: (rx: Double, tx: Double)] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        p.arguments = ["-P", "-L", "1", "-x", "-n", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [:] }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        var totals: [String: (rx: Double, tx: Double)] = [:]
        for line in out.split(separator: "\n") {
            let cols = line.split(separator: ",", omittingEmptySubsequences: false)
            guard cols.count >= 3, cols[0].contains("."), let rx = Double(cols[1]), let tx = Double(cols[2]) else { continue }
            totals[String(cols[0])] = (rx, tx)
        }
        return totals
    }

    private func consume(_ totals: [String: (rx: Double, tx: Double)]) {
        defer { previous = (totals, .now) }
        guard let previous, !totals.isEmpty else { return }

        let top = Self.topUsage(before: previous.totals, now: totals)

        let icons = AppsSnapshot.iconsDirectory
        try? FileManager.default.removeItem(at: icons)
        try? FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
        let apps = top.enumerated().map { i, item in
            let file = "\(i).png"
            let saved = AppTrafficMonitor.icon(for: item.name, pid: item.pid)
                .flatMap { Self.png($0) }
                .map { (try? $0.write(to: icons.appendingPathComponent(file))) != nil } ?? false
            return AppsSnapshot.App(name: item.name, downBytes: item.rx, upBytes: item.tx,
                                    iconFile: saved ? "icones/\(file)" : nil)
        }
        let minutes = max(1, Int((Date.now.timeIntervalSince(previous.at) / 60).rounded()))
        AppsSnapshot(date: .now, intervalMinutes: minutes, apps: apps).save()
        WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
    }

    /// Os 5 apps que mais usaram a rede entre duas leituras. Processo novo conta tudo;
    /// contador que zerou conta nada. Auxiliares somam no app principal.
    static func topUsage(before: [String: (rx: Double, tx: Double)], now: [String: (rx: Double, tx: Double)])
        -> [(name: String, rx: Double, tx: Double, pid: Int32)] {
        var grouped: [String: (rx: Double, tx: Double, pid: Int32)] = [:]
        for (key, current) in now {
            guard let dot = key.lastIndex(of: "."), let pid = Int32(key[key.index(after: dot)...]) else { continue }
            let old = before[key] ?? (0, 0)
            let rx = max(0, current.rx - old.rx)
            let tx = max(0, current.tx - old.tx)
            guard rx + tx > 0 else { continue }
            let name = AppTrafficMonitor.displayName(process: String(key[..<dot]), pid: pid)
            let g = grouped[name] ?? (0, 0, pid)
            grouped[name] = (g.rx + rx, g.tx + tx, g.pid)
        }
        return grouped
            .filter { $0.value.rx + $0.value.tx >= 100_000 }   // ignora o que ficou abaixo de 100 KB
            .sorted { $0.value.rx + $0.value.tx > $1.value.rx + $1.value.tx }
            .prefix(5)
            .map { ($0.key, $0.value.rx, $0.value.tx, $0.value.pid) }
    }

    /// Ícone em 64 × 64, pequeno o bastante para o widget.
    private static func png(_ image: NSImage) -> Data? {
        let size = 64
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
