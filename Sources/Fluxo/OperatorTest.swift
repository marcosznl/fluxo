import Foundation

/// Teste no estilo do Speedtest (Ookla): escolhe um servidor da rede Speedtest perto de
/// você, de preferência da própria operadora, e mede com várias conexões em paralelo.
/// Usa a lista pública de servidores e os endpoints HTTPS deles (não é uma API oficial).
enum OperatorTest {
    struct Server: Decodable {
        let id: String
        let host: String
        let name: String
        let sponsor: String
        let forcePingSelect: Int?

        enum CodingKeys: String, CodingKey {
            case id, host, name, sponsor
            case forcePingSelect = "force_ping_select"
        }

        /// A API marca assim os servidores da operadora de quem está testando.
        var isOwnISP: Bool { forcePingSelect == 1 }
        var label: String { "\(sponsor) · \(name)" }
        func url(_ path: String) -> URL { URL(string: "https://\(host)\(path)")! }
    }

    /// Só para o autoteste (`--simular-falha`): faz a lista de servidores "não responder".
    nonisolated(unsafe) static var simulateFailure = false

    static let streams = 8
    static let phaseSeconds: TimeInterval = 10
    static let warmupSeconds: TimeInterval = 2

    struct Callbacks {
        var status: @MainActor (String) -> Void
        var server: @MainActor (String) -> Void
        var live: @MainActor (TestPhase, Double) -> Void
    }

    static func run(_ cb: Callbacks) async throws -> SpeedResult {
        let interface = DefaultRoute.interface()
        await cb.status("Escolhendo servidor…")
        let server = try await pickServer()
        try Task.checkCancellation()
        await cb.server(server.label)

        await cb.status("Medindo latência…")
        let pings = PingSession()
        let idle = await pings.median(server, count: 10)
        try Task.checkCancellation()

        await cb.live(.download, 0)
        async let loadedPings = pings.sample(server, seconds: phaseSeconds)
        let down = try await measure(upload: false, server: server) { mbps in await cb.live(.download, mbps) }
        let loaded = await loadedPings

        await cb.live(.upload, 0)
        let up = try await measure(upload: true, server: server) { mbps in await cb.live(.upload, mbps) }

        return SpeedResult(
            downloadMbps: down, uploadMbps: up, idleLatencyMs: idle, loadedLatencyMs: loaded,
            server: server.host, serverLabel: server.label, interface: interface)
    }

    // MARK: Servidor

    private static func pickServer() async throws -> Server {
        let list = URL(string: "https://www.speedtest.net/api/js/servers?engine=js&https_functional=true&limit=10")!
        let all: [Server]
        do {
            if simulateFailure { throw URLError(.cannotConnectToHost) }
            let (data, _) = try await URLSession.shared.data(from: list)
            all = try JSONDecoder().decode([Server].self, from: data)
        } catch {
            throw SpeedTestError(message: "Não consegui buscar a lista de servidores do Speedtest.")
        }
        // Os da operadora e mais os 4 mais próximos; fica o de menor latência,
        // dando preferência aos da operadora quando algum responde.
        let candidates = all.filter(\.isOwnISP) + all.filter { !$0.isOwnISP }.prefix(4)
        let pings = PingSession()
        var alive: [(Server, Double)] = []
        await withTaskGroup(of: (Server, Double?).self) { group in
            for s in candidates {
                group.addTask { (s, await pings.best(s, tries: 3)) }
            }
            for await (s, ms) in group {
                if let ms { alive.append((s, ms)) }
            }
        }
        let byLatency = alive.sorted { $0.1 < $1.1 }
        guard let pick = byLatency.first(where: { $0.0.isOwnISP }) ?? byLatency.first else {
            throw SpeedTestError(message: "Nenhum servidor do Speedtest respondeu.")
        }
        return pick.0
    }

    // MARK: Vazão

    private static func measure(upload: Bool, server: Server,
                                onLive: @escaping @Sendable (Double) async -> Void) async throws -> Double {
        let counter = ByteCounter(countsReceived: !upload)
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = streams
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config, delegate: counter, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let deadline = Date().addingTimeInterval(phaseSeconds)
        // Dados aleatórios, para nenhuma compressão no caminho inflar o resultado.
        let payload: Data = upload ? randomData(4_000_000) : Data()
        let start = { @Sendable in
            guard Date() < deadline else { return }
            let nocache = UUID().uuidString
            if upload {
                var req = URLRequest(url: server.url("/upload?nocache=\(nocache)"))
                req.httpMethod = "POST"
                session.uploadTask(with: req, from: payload).resume()
            } else {
                session.dataTask(with: server.url("/download?nocache=\(nocache)&size=25000000")).resume()
            }
        }
        // Cada conexão que termina já abre outra, até o fim da fase.
        counter.onTaskFinished = start
        for _ in 0..<streams { start() }

        let t0 = Date()
        var samples: [(t: TimeInterval, bytes: Int64)] = [(0, 0)]
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))   // lança CancellationError se cancelarem
            let now = (t: Date().timeIntervalSince(t0), bytes: counter.bytes)
            samples.append(now)
            // Ao vivo: média do último segundo.
            if let ref = samples.last(where: { now.t - $0.t >= 1 }) {
                await onLive(Double(now.bytes - ref.bytes) * 8 / (now.t - ref.t) / 1e6)
            }
        }

        // Resultado: descarta os primeiros segundos, enquanto as conexões aceleram.
        guard let last = samples.last, last.bytes > 0,
              let first = samples.first(where: { $0.t >= warmupSeconds }), last.t > first.t else {
            throw SpeedTestError(message: "O servidor parou de responder durante o teste.")
        }
        return Double(last.bytes - first.bytes) * 8 / (last.t - first.t) / 1e6
    }

    private static func randomData(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, count) }
        return data
    }
}

/// Soma os bytes de todas as conexões e avisa quando uma termina.
private final class ByteCounter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var total: Int64 = 0
    private let countsReceived: Bool
    var onTaskFinished: (@Sendable () -> Void)?

    init(countsReceived: Bool) {
        self.countsReceived = countsReceived
    }

    var bytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return total
    }

    private func add(_ n: Int64) {
        lock.lock()
        total += n
        lock.unlock()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if countsReceived { add(Int64(data.count)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if !countsReceived { add(bytesSent) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if (error as? URLError)?.code != .cancelled { onTaskFinished?() }
    }
}

/// Latência por HTTP (GET /hello), reaproveitando a conexão para não medir o handshake.
private final class PingSession: @unchecked Sendable {
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 3
        return URLSession(configuration: config)
    }()

    func once(_ server: OperatorTest.Server) async -> Double? {
        let t0 = Date()
        guard let (_, response) = try? await session.data(from: server.url("/hello?nocache=\(UUID().uuidString)")),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return Date().timeIntervalSince(t0) * 1000
    }

    func best(_ server: OperatorTest.Server, tries: Int) async -> Double? {
        var best: Double?
        for _ in 0..<tries {
            if let ms = await once(server) { best = min(best ?? ms, ms) }
        }
        return best
    }

    func median(_ server: OperatorTest.Server, count: Int) async -> Double? {
        _ = await once(server)   // aquece a conexão
        var all: [Double] = []
        for _ in 0..<count where !Task.isCancelled {
            if let ms = await once(server) { all.append(ms) }
        }
        return Self.median(all)
    }

    /// Pinga a cada 250 ms por um tempo (usado durante o download: latência com carga).
    func sample(_ server: OperatorTest.Server, seconds: TimeInterval) async -> Double? {
        let end = Date().addingTimeInterval(seconds)
        var all: [Double] = []
        try? await Task.sleep(for: .seconds(OperatorTest.warmupSeconds))
        while Date() < end && !Task.isCancelled {
            if let ms = await once(server) { all.append(ms) }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return Self.median(all)
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        return s[s.count / 2]
    }
}
