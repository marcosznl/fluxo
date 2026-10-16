import Darwin
import Foundation

struct SpeedResult {
    var downloadMbps: Double
    var uploadMbps: Double
    var idleLatencyMs: Double?
    var loadedLatencyMs: Double?   // latência durante o download
    var server: String?            // nome técnico, ex.: brsao4-edge-bx-021.aaplimg.com
    var serverLabel: String?       // nome amigável, ex.: Apple · São Paulo
    var interface: String?
}

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
    @Published private(set) var serverLabel: String?

    var isRunning: Bool { phase != .idle }

    /// A velocidade da fase atual, a que move o velocímetro.
    var liveSpeed: Double { phase == .upload ? liveUpload : liveDownload }

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
            serverLabel = "Apple"
            // O networkQuality só imprime a velocidade ao vivo num terminal, daí o pseudo-terminal.
            let running = RunningProcess()
            let output = try await withTaskCancellationHandler {
                try await Self.runInPTY(running) { [weak self] line in
                    Task { @MainActor in self?.consumeLive(line) }
                }
            } onCancel: {
                running.terminate()
            }
            try Task.checkCancellation()
            return try Self.parseSummary(output)
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
    }

    // MARK: - Processo

    nonisolated private static let liveLine =
        /Downlink: capacity ([\d.]+) Mbps.*?- Uplink: capacity ([\d.]+) Mbps/

    nonisolated private static func runInPTY(_ running: RunningProcess,
                                             onLine: @escaping @Sendable (String) -> Void) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var master: Int32 = 0
                var slave: Int32 = 0
                var size = winsize(ws_row: 50, ws_col: 400, ws_xpixel: 0, ws_ypixel: 0)
                guard openpty(&master, &slave, nil, nil, &size) == 0 else {
                    cont.resume(throwing: SpeedTestError(message: "Não consegui abrir um terminal para o teste."))
                    return
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/networkQuality")
                process.arguments = ["-s", "-v"]   // sequencial: download e upload medidos separadamente
                let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
                process.standardOutput = slaveHandle
                process.standardError = slaveHandle
                process.standardInput = FileHandle.nullDevice
                do {
                    try running.start(process)
                } catch {
                    close(master)
                    close(slave)
                    cont.resume(throwing: SpeedTestError(message: "O networkQuality não abriu: \(error.localizedDescription)"))
                    return
                }
                // Sem a nossa cópia do slave, o read() abaixo termina quando o processo sai.
                close(slave)

                var all = Data()
                var pending = ""
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let n = read(master, &buffer, buffer.count)
                    if n <= 0 { break }
                    all.append(buffer, count: n)
                    pending += String(decoding: buffer[0..<n], as: UTF8.self)
                    // O networkQuality reescreve a mesma linha com \r.
                    var parts = pending.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
                    pending = parts.removeLast()
                    for line in parts where !line.isEmpty {
                        onLine(stripANSI(line))
                    }
                }
                close(master)
                process.waitUntilExit()

                let text = stripANSI(String(decoding: all, as: UTF8.self))
                if process.terminationStatus != 0 && !text.contains("SUMMARY") {
                    let tail = text.split(separator: "\n").suffix(2).joined(separator: " ")
                    cont.resume(throwing: SpeedTestError(message: tail.isEmpty ? "O teste falhou. Você está conectado?" : tail))
                } else {
                    cont.resume(returning: text)
                }
            }
        }
    }

    nonisolated private static func stripANSI(_ s: String) -> String {
        s.replacing(/\u{1B}\[[0-9;?]*[A-Za-z]/, with: "")
    }

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

/// Guarda o processo do teste para poder encerrá-lo se o usuário cancelar.
private final class RunningProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func start(_ p: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try p.run()
        process = p
    }

    func terminate() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if process?.isRunning == true { process?.terminate() }
    }
}
