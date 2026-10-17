import Foundation
import SystemConfiguration

/// Transforma o nome técnico do servidor em algo legível:
/// "brsao4-edge-bx-021.aaplimg.com" → "Apple · São Paulo".
enum ServerName {
    // Os servidores de borda da Apple começam com país (2 letras) + cidade (código de 3 letras).
    private static let cities: [String: String] = [
        "sao": "São Paulo", "rio": "Rio de Janeiro", "bsb": "Brasília", "for": "Fortaleza",
        "poa": "Porto Alegre", "cwb": "Curitiba", "bhz": "Belo Horizonte", "rec": "Recife",
        "ssa": "Salvador", "bue": "Buenos Aires", "scl": "Santiago", "bog": "Bogotá", "lim": "Lima",
        "mex": "Cidade do México", "mia": "Miami", "nyc": "Nova York", "lax": "Los Angeles",
        "sjc": "San José", "chi": "Chicago", "dfw": "Dallas", "atl": "Atlanta", "sea": "Seattle",
        "lon": "Londres", "par": "Paris", "fra": "Frankfurt", "ams": "Amsterdã", "mad": "Madri",
        "lis": "Lisboa", "mil": "Milão", "tyo": "Tóquio", "sin": "Singapura", "syd": "Sydney",
        "hkg": "Hong Kong",
    ]

    static func friendly(_ host: String?) -> String {
        guard let host, !host.isEmpty else { return "—" }
        let provider = host.hasSuffix("aaplimg.com") || host.hasSuffix("apple.com") ? "Apple" : nil
        guard let place = city(host) else { return provider ?? host }
        return [provider, place].compactMap { $0 }.joined(separator: " · ")
    }

    /// "brsao4-edge-bx-021.aaplimg.com" → "São Paulo".
    static func city(_ host: String) -> String? {
        guard let m = host.firstMatch(of: /^([a-z]{2})([a-z]{3})\d*-/) else { return nil }
        let country = String(m.1).uppercased()
        let code = String(m.2)
        return cities[code]
            ?? Locale.current.localizedString(forRegionCode: country).map { "\($0) (\(code.uppercased()))" }
            ?? "\(code.uppercased()), \(country)"
    }

    /// O servidor que o networkQuality vai usar, pela mesma configuração que ele consulta.
    /// Serve só para mostrar "de onde" durante o teste; o servidor real vem no resultado.
    static func appleTestServer() async -> String? {
        struct Config: Decodable {
            let test_endpoint: String?
        }
        let url = URL(string: "https://mensura.cdn-apple.com/api/v1/gm/config")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return (try? JSONDecoder().decode(Config.self, from: data))?.test_endpoint
    }
}

/// "en0" → "Wi-Fi", "en6" → "USB 10/100/1000 LAN": o nome que aparece nos Ajustes do Sistema.
enum InterfaceName {
    static func friendly(_ bsdName: String?) -> String {
        guard let bsdName else { return "—" }
        let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        let match = all.first { SCNetworkInterfaceGetBSDName($0) as String? == bsdName }
        return match.flatMap { SCNetworkInterfaceGetLocalizedDisplayName($0) as String? } ?? bsdName
    }
}
