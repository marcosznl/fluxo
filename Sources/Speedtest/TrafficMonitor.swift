import AppKit
import Darwin

/// Tráfego de rede ao vivo do Mac (tudo que entra e sai), lido dos contadores de bytes
/// das interfaces físicas uma vez por segundo.
@MainActor
final class TrafficMonitor: ObservableObject {
    @Published private(set) var downBps: Double = 0
    @Published private(set) var upBps: Double = 0

    private var timer: Timer?
    private var last: (counters: [String: Counters], at: Date)?

    struct Counters {
        var rx: UInt64
        var tx: UInt64
    }

    func start() {
        guard timer == nil else { return }
        last = nil
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        downBps = 0
        upBps = 0
    }

    private func sample() {
        let now = Date()
        let counters = Self.readCounters()
        if let last {
            let dt = now.timeIntervalSince(last.at)
            var rx: UInt64 = 0
            var tx: UInt64 = 0
            for (name, c) in counters {
                guard let before = last.counters[name] else { continue }
                rx += Self.delta(before.rx, c.rx)
                tx += Self.delta(before.tx, c.tx)
            }
            downBps = Double(rx) * 8 / dt
            upBps = Double(tx) * 8 / dt
        }
        last = (counters, now)
    }

    /// O macOS entrega a apps comuns contadores de 32 bits, que dão a volta a cada 4 GB.
    /// Entre duas leituras com 1 s de intervalo, no máximo uma volta é possível.
    nonisolated static func delta(_ before: UInt64, _ now: UInt64) -> UInt64 {
        if now >= before { return now - before }
        if before <= UInt64(UInt32.max) { return now &+ (UInt64(UInt32.max) + 1) &- before }
        return 0   // interface reiniciada
    }

    /// Totais somados (só para conferência).
    nonisolated static func readTotals() -> (rx: UInt64, tx: UInt64) {
        readCounters().values.reduce((0, 0)) { ($0.0 &+ $1.rx, $0.1 &+ $1.tx) }
    }

    /// Bytes recebidos/enviados por interface "en*" (Wi-Fi e cabo). Ficam de fora o
    /// loopback e as interfaces virtuais (VPN, AirDrop), para não contar em dobro.
    nonisolated static func readCounters() -> [String: Counters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &len, nil, 0) == 0, len > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &len, nil, 0) == 0 else { return [:] }

        var result: [String: Counters] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                if Int32(header.ifm_type) == RTM_IFINFO2 {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(info.ifm_index), &name) != nil {
                        let ifname = String(cString: name)
                        if ifname.hasPrefix("en") {
                            result[ifname] = Counters(rx: info.ifm_data.ifi_ibytes, tx: info.ifm_data.ifi_obytes)
                        }
                    }
                }
                guard header.ifm_msglen > 0 else { break }
                offset += Int(header.ifm_msglen)
            }
        }
        return result
    }
}

/// Desenha o selo de duas linhas da barra de menus (↓ em cima, ↑ embaixo). É uma imagem
/// "template": o macOS pinta de preto ou branco conforme a barra.
enum TrafficBadge {
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    /// Largura fixa, para o selo não ficar "pulando" quando os números mudam.
    private static let width: CGFloat = 54

    static func image(down: Double, up: Double) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: 22), flipped: false) { _ in
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            ("↓ " + format(down)).draw(at: NSPoint(x: 0, y: 10.5), withAttributes: attrs)
            ("↑ " + format(up)).draw(at: NSPoint(x: 0, y: 0.5), withAttributes: attrs)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Download \(format(down)), upload \(format(up))"
        return image
    }

    /// Bits por segundo em texto curto: "850 kbps", "1,2 Mbps", "45 Mbps".
    static func format(_ bps: Double) -> String {
        switch bps {
        case ..<1_000: return "0 kbps"
        case ..<1_000_000: return "\(Int((bps / 1_000).rounded())) kbps"
        case ..<10_000_000: return (bps / 1_000_000).formatted(.number.precision(.fractionLength(1))) + " Mbps"
        default: return "\(Int((bps / 1_000_000).rounded())) Mbps"
        }
    }
}
