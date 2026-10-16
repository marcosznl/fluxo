import AppKit
import SwiftUI

/// `Fluxo --snapshot <pasta>` salva PNGs do painel e sai, para conferir o
/// visual sem abrir a barra de menus (nem precisar de permissão de gravação de tela).
@MainActor
enum Snapshot {
    static func renderAll(to dir: String) {
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        // Barra de menus, como o macOS pinta as imagens "template" em cada modo.
        for (name, down, up) in [("parado", 0.0, 0.0), ("navegando", 1_200_000.0, 85_000.0), ("baixando", 512e6, 3.2e6)] {
            saveMenuBarPreview(TrafficBadge.image(down: down, up: up), to: out, name: "barra-\(name)")
        }
        saveMenuBarPreview(GaugeIcon.menuBarImage, to: out, name: "barra-icone")
        try? GaugeIcon.writeIconset(to: out.appendingPathComponent("AppIcon.iconset"))

        for (mode, appearance) in [("claro", NSAppearance.Name.aqua), ("escuro", .darkAqua)] {
            save(popover(TestController(history: sampleHistory(empty: true))), appearance,
                 to: out.appendingPathComponent("painel-vazio-\(mode).png"))
            save(popover(TestController(history: sampleHistory(empty: false))), appearance,
                 to: out.appendingPathComponent("painel-\(mode).png"))
            // O gráfico do histórico: todas as conexões com o mouse num ponto, só Wi-Fi e upload.
            let records = sampleHistory(empty: false).state.records
            let chartCases: [(String, [SpeedRecord], Date?, String)] = [
                ("todos-mouse", records, records[records.count - 3].date, "download"),
                ("wifi", records.filter { $0.connection == .wifi }, nil, "download"),
                ("upload", records, nil, "upload"),
            ]
            for (name, recs, hover, metric) in chartCases {
                UserDefaults.standard.set(metric, forKey: "graficoMetrica")
                let chart = TrendChart(records: recs, previewHover: hover)
                    .padding(14)
                    .frame(width: 330)
                    .background(Color(nsColor: .windowBackgroundColor))
                save(chart, appearance, to: out.appendingPathComponent("grafico-\(name)-\(mode).png"))
            }
            UserDefaults.standard.set("download", forKey: "graficoMetrica")

            // O gráfico com o seu histórico de verdade (só leitura).
            let real = HistoryStore().state.records
            if real.count >= 2 {
                let chart = TrendChart(records: real)
                    .padding(14)
                    .frame(width: 330)
                    .background(Color(nsColor: .windowBackgroundColor))
                save(chart, appearance, to: out.appendingPathComponent("grafico-seu-historico-\(mode).png"))
            }

            // O velocímetro como fica durante o teste.
            for (speed, upload) in [(37.0, false), (480.0, false), (230.0, true)] {
                let gauge = SpeedGauge(value: speed, caption: upload ? "Mbps · upload" : "Mbps · download",
                                       colors: upload ? PhaseColors.upload : PhaseColors.download)
                    .padding(14)
                    .background(Color(nsColor: .windowBackgroundColor))
                save(gauge, appearance, to: out.appendingPathComponent("gauge-\(Int(speed))-\(mode).png"))
            }
        }
    }

    private static func saveMenuBarPreview(_ image: NSImage, to out: URL, name: String) {
        for (mode, bg, ink) in [("claro", NSColor(white: 0.93, alpha: 1), NSColor.black),
                                ("escuro", NSColor(white: 0.17, alpha: 1), NSColor.white)] {
            let scale: CGFloat = 4
            let size = NSSize(width: image.size.width + 16, height: 22)
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            bg.setFill()
            NSRect(origin: .zero, size: size).fill()
            let tinted = NSImage(size: image.size, flipped: false) { r in
                image.draw(in: r)
                ink.set()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: 8, y: (size.height - image.size.height) / 2,
                                   width: image.size.width, height: image.size.height))
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name)-\(mode).png"))
        }
    }

    /// Histórico de exemplo num arquivo temporário (o seu fica intacto).
    private static func sampleHistory(empty: Bool) -> HistoryStore {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fluxo-snapshot-\(empty).json")
        try? FileManager.default.removeItem(at: tmp)
        let history = HistoryStore(fileURL: tmp)
        guard !empty else { return history }
        let samples: [(hoursAgo: Double, down: Double, up: Double, ping: Double, loaded: Double,
                       auto: Bool, engine: TestEngine, conn: ConnectionKind)] = [
            (70, 312, 180, 24, 190, true, .apple, .wifi), (52, 455, 230, 22, 170, false, .apple, .wifi),
            (30, 498, 250, 21, 160, true, .apple, .wifi), (20, 120, 90, 40, 260, false, .apple, .wifi),
            (8, 905, 470, 4, 12, false, .operadora, .cabo), (6, 515, 255, 23, 150, true, .apple, .wifi),
            (2, 931, 488, 3, 11, false, .operadora, .cabo),
            (0.2, 529, 260, 30, 178, false, .apple, .wifi),
        ]
        for s in samples {
            let ookla = s.engine == .operadora
            history.add(
                SpeedResult(downloadMbps: s.down, uploadMbps: s.up, idleLatencyMs: s.ping, loadedLatencyMs: s.loaded,
                            server: ookla ? "speedtestpr.vtal.net.br" : "brsao4-edge-bx-021.aaplimg.com",
                            serverLabel: ookla ? "Vtal · Curitiba" : "Apple · São Paulo",
                            interface: s.conn == .wifi ? "en0" : "en6"),
                engine: s.engine, automatic: s.auto, at: Date.now.addingTimeInterval(-s.hoursAgo * 3600),
                connection: s.conn,
                wifi: s.conn == .wifi
                    ? WifiInfo(rssi: s.down < 200 ? -74 : -54, noise: -97, channel: s.down < 200 ? 6 : 48,
                               bandGHz: s.down < 200 ? "2,4" : "5", widthMHz: s.down < 200 ? 20 : 160,
                               linkMbps: s.down < 200 ? 144 : 864, standard: "Wi-Fi 6")
                    : nil)
        }
        return history
    }

    private static func popover(_ controller: TestController) -> some View {
        PopoverView()
            .environmentObject(controller)
            .environmentObject(controller.history)
            .environmentObject(controller.tester)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    private static func save(_ view: some View, _ appearance: NSAppearance.Name, to url: URL) {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Dá um ciclo para o SwiftUI desenhar antes de capturar.
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// `Fluxo --teste [apple|operadora] [--cancelar-em <s>]` faz um teste real pelo mesmo
/// motor do app, mostrando a velocidade ao vivo no terminal, sem gravar no histórico.
@MainActor
enum SelfTest {
    static func run(engine: TestEngine, cancelAfter: Double? = nil) {
        let tester = SpeedTester()
        let ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                print("  \(tester.phase)  ↓ \(Int(tester.liveDownload))  ↑ \(Int(tester.liveUpload)) Mbps"
                      + "  \(tester.serverLabel ?? "")  \(tester.status ?? "")")
            }
        }
        let started = Date()
        let test = Task {
            defer { ticker.invalidate() }
            do {
                let r = try await tester.run(engine: engine)
                print("Resultado: \(r)")
                print("Conexão: \(ConnectionKind.of(interface: r.interface)?.title ?? "?")")
                exit(0)
            } catch {
                if Task.isCancelled || error is CancellationError {
                    print(String(format: "Cancelado; parou %.1f s depois do início.", Date().timeIntervalSince(started)))
                    exit(0)
                }
                print("Falhou: \(error.localizedDescription)")
                exit(1)
            }
        }
        if let cancelAfter {
            Task {
                try? await Task.sleep(for: .seconds(cancelAfter))
                print("→ cancelando…")
                test.cancel()
            }
        }
    }
}

/// `Fluxo --trafego` imprime o tráfego ao vivo por alguns segundos (confere os contadores).
@MainActor
enum TrafficSelfTest {
    static func run() {
        let totals = TrafficMonitor.readTotals()
        print("Totais en*: recebidos \(totals.rx) bytes, enviados \(totals.tx) bytes")
        let monitor = TrafficMonitor()
        monitor.start()
        var ticks = 0
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            Task { @MainActor in
                ticks += 1
                print("  ↓ \(TrafficBadge.format(monitor.downBps))   ↑ \(TrafficBadge.format(monitor.upBps))")
                if ticks == 5 { exit(0) }
            }
        }
    }
}
