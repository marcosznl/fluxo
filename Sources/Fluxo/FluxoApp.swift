import IOKit.ps
import Network
import ServiceManagement
import SwiftUI
import UserNotifications

@main
struct FluxoApp: App {
    @StateObject private var controller = TestController()
    @AppStorage(ModuleKey.cpu) private var showCPU = true
    @AppStorage(ModuleKey.ram) private var showRAM = true
    @AppStorage(ModuleKey.ssd) private var showSSD = true
    @AppStorage(ModuleKey.redeLocal) private var showLocalNetwork = true

    init() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            DispatchQueue.main.async {
                Snapshot.renderAll(to: args[i + 1])
                exit(0)
            }
        }
        if let i = args.firstIndex(of: "--gerar-icone"), i + 1 < args.count {
            do {
                try GaugeIcon.writeIconset(to: URL(fileURLWithPath: args[i + 1]))
                exit(0)
            } catch {
                print("Não consegui gerar o ícone: \(error.localizedDescription)")
                exit(1)
            }
        }
        if let i = args.firstIndex(of: "--opcoes-icone"), i + 1 < args.count {
            try? GaugeIcon.writeOptionsSheet(to: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }
        if args.contains("--apps") {
            DispatchQueue.main.async { AppTrafficSelfTest.run() }
        }
        if args.contains("--rede-local") {
            DispatchQueue.main.async { LocalNetworkScanner.selfTest() }
        }
        if args.contains("--trafego") {
            DispatchQueue.main.async { TrafficSelfTest.run() }
        }
        if let i = args.firstIndex(of: "--teste") {
            let engine = args.dropFirst(i + 1).first.flatMap(TestEngine.init(rawValue:)) ?? .apple
            let cancelAfter = args.firstIndex(of: "--cancelar-em").flatMap { j in
                args.dropFirst(j + 1).first.flatMap(Double.init)
            }
            OperatorTest.simulateFailure = args.contains("--simular-falha")
            DispatchQueue.main.async { SelfTest.run(engine: engine, cancelAfter: cancelAfter) }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            panel
        } label: {
            MenuBarLabel(history: controller.history, tester: controller.tester, traffic: controller.traffic)
        }
        .menuBarExtraStyle(.window)

        // CPU, RAM e disco, cada um no seu item e com o seu painel.
        MenuBarExtra(isInserted: $showCPU) {
            systemPanel(CPUColumn(), caption: "CPU") { CPUSettings() }
        } label: {
            SystemMenuBarLabel(badges: controller.system.badges, kind: .cpu)
        }
        .menuBarExtraStyle(.window)
        MenuBarExtra(isInserted: $showRAM) {
            systemPanel(MemoryColumn(), caption: "Memória") { RAMSettings() }
        } label: {
            SystemMenuBarLabel(badges: controller.system.badges, kind: .ram)
        }
        .menuBarExtraStyle(.window)
        MenuBarExtra(isInserted: $showSSD) {
            systemPanel(DiskColumn(), caption: "Disco") { SSDSettings() }
        } label: {
            SystemMenuBarLabel(badges: controller.system.badges, kind: .ssd)
        }
        .menuBarExtraStyle(.window)
    }

    private var panel: some View {
        PopoverView()
            .fitsWindow()
            .environmentObject(controller)
            .environmentObject(controller.history)
            .environmentObject(controller.tester)
            .environmentObject(controller.appTraffic)
            .environmentObject(controller.localNetwork)
            // A lista de apps e a rede local só são medidas com o painel aberto.
            .onAppear { panelOpen(true) }
            .onDisappear { panelOpen(false) }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                panelOpen(false)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                panelOpen(true)
            }
            .onChange(of: showLocalNetwork) { _, on in
                if on { controller.localNetwork.start() } else { controller.localNetwork.stop() }
            }
    }

    /// Painel de um item do sistema. Os processos só são medidos enquanto ele está aberto.
    private func systemPanel(_ content: some View, caption: String,
                             @ViewBuilder settings: @escaping () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content
            ModuleFooter(caption: caption, settings: settings)
        }
            .padding(14)
            .frame(width: PopoverView.columnWidth + 28)
            .fitsWindow()
            .environmentObject(controller.system)
            .onAppear { controller.system.setDetailed(true) }
            .onDisappear { controller.system.setDetailed(false) }
    }

    private func panelOpen(_ open: Bool) {
        if open {
            controller.appTraffic.start()
            if showLocalNetwork { controller.localNetwork.start() }
        } else {
            controller.appTraffic.stop()
            controller.localNetwork.stop()
        }
    }
}

/// O que aparece na barra de menus: o tráfego ao vivo, a última velocidade ou só o ícone.
/// Durante um teste, sempre a velocidade do teste.
struct MenuBarLabel: View {
    @ObservedObject var history: HistoryStore
    @ObservedObject var tester: SpeedTester
    @ObservedObject var traffic: TrafficMonitor

    var body: some View {
        if tester.isRunning {
            let speed = tester.liveSpeed
            iconAndText(speed > 0 ? "\(Int(speed))\(tester.phase == .upload ? "↑" : "↓")" : "…")
        } else {
            switch history.menuBarMode {
            case .trafego:
                Image(nsImage: TrafficBadge.image(traffic.label))
            case .ultimoTeste:
                iconAndText(history.last.map { "\(Int($0.downloadMbps.rounded()))" })
            case .icone:
                Image(nsImage: GaugeIcon.menuBarImage)
            }
        }
    }

    private func iconAndText(_ text: String?) -> some View {
        HStack(spacing: 4) {
            Image(nsImage: GaugeIcon.menuBarImage)
            if let text {
                Text(text).monospacedDigit()
            }
        }
    }
}

/// Roda o teste, guarda no histórico e cuida do teste automático.
@MainActor
final class TestController: ObservableObject {
    let history: HistoryStore
    let tester = SpeedTester()
    let traffic = TrafficMonitor()
    let appTraffic = AppTrafficMonitor()
    let system = SystemMonitor()
    let localNetwork = LocalNetworkScanner()

    @Published var errorMessage: String?
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// Por que o último teste automático foi adiado (nil = nada adiado).
    @Published private(set) var autoSkipReason: String?

    private var autoTimer: Timer?
    private var currentTest: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()
    private var path: NWPath?

    init(history: HistoryStore? = nil) {
        self.history = history ?? HistoryStore()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.path = path }
        }
        pathMonitor.start(queue: .global(qos: .utility))
        updateTrafficMonitor()
        system.start()
        // A cada minuto, confere se está na hora de um teste automático.
        autoTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.autoTestIfDue() }
        }
    }

    func start(automatic: Bool = false) {
        guard !tester.isRunning else { return }
        errorMessage = nil
        let engine = history.engine
        // O Wi-Fi é lido antes de a rede encher, para refletir o sinal real.
        let interface = DefaultRoute.interface()
        let wifi = ConnectionKind.of(interface: interface) == .wifi ? WifiInfo.current(interface: interface) : nil
        currentTest = Task {
            do {
                let (result, used) = try await tester.runWithFallback(engine: engine)
                let record = history.add(result, engine: used, automatic: automatic, wifi: wifi)
                if automatic { notifyIfUnusual(record) }
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                errorMessage = error.localizedDescription
                if automatic {
                    Notifier.send("O teste automático falhou", error.localizedDescription)
                }
            }
        }
    }

    func cancel() {
        currentTest?.cancel()
    }

    // MARK: Barra de menus

    func setMenuBarMode(_ mode: MenuBarMode) {
        history.setMenuBarMode(mode)
        updateTrafficMonitor()
    }

    /// O monitor de tráfego só roda quando a barra de menus mostra o tráfego.
    private func updateTrafficMonitor() {
        if history.menuBarMode == .trafego { traffic.start() } else { traffic.stop() }
    }

    // MARK: Teste automático

    func setAutoInterval(hours: Int) {
        history.setAutoInterval(hours: hours)
        if hours > 0 { Notifier.requestPermission() }
    }

    private func autoTestIfDue() {
        let hours = history.state.autoIntervalHours
        guard hours > 0, !tester.isRunning else { return }
        let due = history.last.map { Date.now.timeIntervalSince($0.date) >= Double(hours) * 3600 } ?? true
        guard due else { return }
        autoSkipReason = skipReason()
        if autoSkipReason == nil { start(automatic: true) }
    }

    /// Situações em que um teste automático (≈1 GB de tráfego) não vale a pena.
    private func skipReason() -> String? {
        if let path {
            if path.status != .satisfied { return "sem conexão" }
            if path.isExpensive { return "conexão cara (hotspot do celular)" }
            if path.isConstrained { return "Modo de Poucos Dados ativo" }
        }
        if history.autoOnlyOnAC && Power.onBattery { return "Mac na bateria" }
        return nil
    }

    /// Só incomoda quando o resultado foge do normal para aquela conexão.
    private func notifyIfUnusual(_ r: SpeedRecord) {
        guard let typical = history.typicalDownload(on: r.connection, excluding: r.id),
              r.downloadMbps < typical * 0.5 else { return }
        var body = "↓ \(Int(r.downloadMbps.rounded())) Mbps"
            + (r.connection.map { " no \($0.title)" } ?? "")
            + " (o normal é ~\(Int(typical.rounded())))."
        if let wifi = r.wifi, wifi.rssi < -70 {
            body += " Sinal do Wi-Fi fraco: \(wifi.rssi) dBm."
        }
        Notifier.send("Internet mais lenta que o normal", body)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = "Não deu para mudar a abertura automática: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

enum Power {
    static var onBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == "Battery Power"
    }
}

/// Notificações do macOS (só para os testes automáticos).
enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func send(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

// MARK: - Janela do painel acompanha o conteúdo

extension View {
    /// A janela do MenuBarExtra cresce sozinha, mas não encolhe quando uma coluna some
    /// (sobra uma área transparente). Isto ajusta a janela ao tamanho do conteúdo
    /// sempre que ele muda.
    func fitsWindow() -> some View {
        fixedSize().background(WindowFitter())
    }
}

private struct WindowFitter: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { FitterView() }
    func updateNSView(_ view: NSView, context: Context) {}

    /// Fica atrás do conteúdo e tem exatamente o tamanho dele; quando muda de tamanho,
    /// leva a janela junto.
    final class FitterView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            fit()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            // Depois do ciclo de layout atual, para não brigar com o SwiftUI.
            DispatchQueue.main.async { [weak self] in self?.fit() }
        }

        private func fit() {
            guard let window, bounds.width > 0, bounds.height > 0 else { return }
            let content = window.frameRect(forContentRect: NSRect(origin: .zero, size: bounds.size)).size
            guard abs(window.frame.width - content.width) > 0.5 || abs(window.frame.height - content.height) > 0.5
            else { return }
            // Mantém o topo no lugar (o painel "pendura" na barra de menus).
            var frame = window.frame
            frame.origin.y += frame.height - content.height
            frame.size = content
            window.setFrame(frame, display: true)
        }
    }
}
