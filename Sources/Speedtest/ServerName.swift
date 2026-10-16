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
        guard let m = host.firstMatch(of: /^([a-z]{2})([a-z]{3})\d*-/) else {
            return provider ?? host
        }
        let country = String(m.1).uppercased()
        let code = String(m.2)
        let place = cities[code]
            ?? Locale.current.localizedString(forRegionCode: country).map { "\($0) (\(code.uppercased()))" }
            ?? "\(code.uppercased()), \(country)"
        return [provider, place].compactMap { $0 }.joined(separator: " · ")
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
