import CoreWLAN
import Foundation
import SystemConfiguration

/// Qual teste rodar.
enum TestEngine: String, Codable, CaseIterable, Identifiable {
    case apple, operadora
    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: "Apple"
        case .operadora: "Operadora"
        }
    }

    var symbol: String {
        switch self {
        case .apple: "applelogo"
        case .operadora: "antenna.radiowaves.left.and.right"
        }
    }

    var explanation: String {
        switch self {
        case .apple: "Teste da Apple (networkQuality): mede até a rede da Apple em São Paulo."
        case .operadora: "Teste da operadora: mede até um servidor da sua operadora (ou o mais rápido por perto)."
        }
    }
}

/// Por onde o Mac estava conectado no teste.
enum ConnectionKind: String, Codable, CaseIterable, Identifiable {
    case wifi, cabo, outra
    var id: String { rawValue }

    static func of(interface bsdName: String?) -> ConnectionKind? {
        guard let bsdName else { return nil }
        let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        guard let iface = all.first(where: { SCNetworkInterfaceGetBSDName($0) as String? == bsdName }),
              let type = SCNetworkInterfaceGetInterfaceType(iface) else { return .outra }
        if CFEqual(type, kSCNetworkInterfaceTypeIEEE80211) { return .wifi }
        if CFEqual(type, kSCNetworkInterfaceTypeEthernet) { return .cabo }
        return .outra
    }

    var title: String {
        switch self {
        case .wifi: "Wi-Fi"
        case .cabo: "Cabo"
        case .outra: "Outra"
        }
    }

    var symbol: String {
        switch self {
        case .wifi: "wifi"
        case .cabo: "cable.connector.horizontal"
        case .outra: "network"
        }
    }
}

/// A interface da rota padrão: é por ela que o tráfego do teste sai.
enum DefaultRoute {
    static func interface() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/route")
        p.arguments = ["-n", "get", "default"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return out.firstMatch(of: /interface:\s*(\S+)/).map { String($0.1) }
    }
}

/// Como estava o Wi-Fi no começo do teste (não precisa de permissão de Localização;
/// só o nome da rede precisaria, por isso ele fica de fora).
struct WifiInfo: Codable {
    var rssi: Int          // dBm, quanto mais perto de 0, melhor
    var noise: Int         // dBm
    var channel: Int?
    var bandGHz: String?   // "2,4", "5" ou "6"
    var widthMHz: Int?
    var linkMbps: Double?  // taxa negociada com o roteador
    var standard: String?  // "Wi-Fi 6", …

    static func current(interface: String?) -> WifiInfo? {
        let client = CWWiFiClient.shared()
        guard let iface = interface.flatMap({ client.interface(withName: $0) }) ?? client.interface(),
              iface.powerOn(), iface.rssiValue() != 0 else { return nil }
        let ch = iface.wlanChannel()
        return WifiInfo(
            rssi: iface.rssiValue(),
            noise: iface.noiseMeasurement(),
            channel: ch?.channelNumber,
            bandGHz: ch.flatMap { band($0.channelBand) },
            widthMHz: ch.flatMap { width($0.channelWidth) },
            linkMbps: iface.transmitRate() > 0 ? iface.transmitRate() : nil,
            standard: standard(iface.activePHYMode()))
    }

    var quality: String {
        switch rssi {
        case (-50)...: "excelente"
        case (-60)..<(-50): "bom"
        case (-70)..<(-60): "razoável"
        default: "fraco"
        }
    }

    /// "5 GHz · canal 48 · sinal −54 dBm (bom)"
    var summary: String {
        var parts: [String] = []
        if let bandGHz { parts.append("\(bandGHz) GHz") }
        if let channel { parts.append("canal \(channel)") }
        parts.append("sinal \(rssi) dBm (\(quality))")
        return parts.joined(separator: " · ")
    }

    /// Texto completo para a ajuda ao passar o mouse.
    var details: String {
        var lines = [summary]
        if let standard { lines.append(standard + (widthMHz.map { " · \($0) MHz" } ?? "")) }
        if let linkMbps { lines.append("Taxa do link: \(Int(linkMbps)) Mbps") }
        lines.append("Ruído: \(noise) dBm · margem \(rssi - noise) dB")
        return lines.joined(separator: "\n")
    }

    private static func band(_ b: CWChannelBand) -> String? {
        switch b {
        case .band2GHz: "2,4"
        case .band5GHz: "5"
        case .band6GHz: "6"
        default: nil
        }
    }

    private static func width(_ w: CWChannelWidth) -> Int? {
        switch w {
        case .width20MHz: 20
        case .width40MHz: 40
        case .width80MHz: 80
        case .width160MHz: 160
        default: nil
        }
    }

    private static func standard(_ m: CWPHYMode) -> String? {
        switch m {
        case .mode11n: "Wi-Fi 4"
        case .mode11ac: "Wi-Fi 5"
        case .mode11ax: "Wi-Fi 6"
        case .modeNone: nil
        default: "802.11 \(m.rawValue)"
        }
    }
}
