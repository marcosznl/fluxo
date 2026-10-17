import Foundation

enum TestPhase: Equatable {
    case idle, starting, download, upload
}

struct SpeedTestError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Roda o teste escolhido e publica o andamento ao vivo para a interface.
@MainActor
final class SpeedTester: ObservableObject {
    @Published private(set) var phase: TestPhase = .idle
    @Published private(set) var liveDownload: Double = 0
    @Published private(set) var liveUpload: Double = 0
    @Published private(set) var status: String?
    /// De onde é o servidor do teste em andamento, ex.: "servidores da Apple em São Paulo".
    @Published private(set) var serverLabel: String?
    /// Aviso sobre o último teste (por exemplo, quando caiu para o teste da Apple).
    @Published private(set) var notice: String?

    var isRunning: Bool { phase != .idle }

    /// A velocidade da fase atual, a que move o velocímetro.
    var liveSpeed: Double { phase == .upload ? liveUpload : liveDownload }

    /// Roda o teste escolhido. Se o da operadora falhar (os servidores da Ookla não são uma
    /// API oficial e podem mudar), cai para o da Apple. Retorna o teste que valeu.
    func runWithFallback(engine: TestEngine) async throws -> (SpeedResult, TestEngine) {
        notice = nil
        do {
            return (try await run(engine: engine), engine)
        } catch {
            guard engine == .operadora, !Task.isCancelled, !(error is CancellationError) else { throw error }
            let reason = error.localizedDescription.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            let result = try await run(engine: .apple)
            notice = "O teste da operadora falhou (\(reason)). Usei o da Apple."
            return (result, .apple)
        }
    }

    func run(engine: TestEngine) async throws -> SpeedResult {
        guard !isRunning else { throw SpeedTestError(message: "Já tem um teste em andamento.") }
        phase = .starting
        liveDownload = 0
        liveUpload = 0
        status = "Preparando…"
        serverLabel = nil
        defer {
            phase = .idle
            status = nil
        }

        switch engine {
        case .apple:
            serverLabel = "servidores da Apple"
            Task { [weak self] in
                if let host = await ServerName.appleTestServer(), let city = ServerName.city(host),
                   self?.isRunning == true {
                    self?.serverLabel = "servidores da Apple em \(city)"
                }
            }
            let running = RunningProcess()
            // -s: sequencial, download e upload medidos separadamente.
            let output = try await withTaskCancellationHandler {
                try await PTY.run("/usr/bin/networkQuality", ["-s", "-v"], running: running) { [weak self] line in
                    Task { @MainActor in self?.consumeLive(line) }
                }
            } onCancel: {
                running.terminate()
            }
            try Task.checkCancellation()
            if output.status != 0 && !output.text.contains("SUMMARY") {
                let tail = output.text.split(separator: "\n").suffix(2).joined(separator: " ")
                throw SpeedTestError(message: tail.isEmpty ? "O teste falhou. Você está conectado?" : tail)
            }
            return try Self.parseSummary(output.text)
        case .operadora:
            return try await OperatorTest.run(.init(
                status: { [weak self] in self?.status = $0 },
                server: { [weak self] in self?.serverLabel = $0 },
                live: { [weak self] phase, mbps in
                    guard let self else { return }
                    self.status = nil
                    self.phase = phase
                    if phase == .upload { self.liveUpload = mbps } else { self.liveDownload = mbps }
                }))
        }
    }

    private func consumeLive(_ line: String) {
        guard let m = line.firstMatch(of: Self.liveLine) else { return }
        let down = Double(m.1) ?? 0
        let up = Double(m.2) ?? 0
        liveDownload = down
        liveUpload = up
        // Teste sequencial: o upload só começa depois do download.
        phase = up > 0 ? .upload : (down > 0 ? .download : .starting)
        if phase != .starting { status = nil }
    }

    // MARK: - Processo

    nonisolated private static let liveLine =
        /Downlink: capacity ([\d.]+) Mbps.*?- Uplink: capacity ([\d.]+) Mbps/

    nonisolated static func parseSummary(_ text: String) throws -> SpeedResult {
        func number(_ regex: Regex<(Substring, Substring)>) -> Double? {
            text.firstMatch(of: regex).flatMap { Double($0.1) }
        }
        guard let down = number(/Downlink capacity: ([\d.]+) Mbps/),
              let up = number(/Uplink capacity: ([\d.]+) Mbps/) else {
            throw SpeedTestError(message: "O teste terminou sem resultado. Tente de novo.")
        }
        let server = text.firstMatch(of: /Test Endpoint: (\S+)/).map { String($0.1) }
        return SpeedResult(
            downloadMbps: down,
            uploadMbps: up,
            idleLatencyMs: number(/Idle Latency: ([\d.]+) milliseconds/),
            loadedLatencyMs: number(/Downlink Responsiveness: \w+ \(([\d.]+) milliseconds/),
            server: server,
            serverLabel: ServerName.friendly(server),
            interface: text.firstMatch(of: /Interface: (\S+)/).map { String($0.1) }
        )
    }
}
