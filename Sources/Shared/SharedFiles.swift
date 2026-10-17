import Foundation

/// A pasta que o app e os widgets compartilham (o App Group). No build de desenvolvimento
/// (swift build), sem App Group, usa ~/Library/Application Support/Fluxo.
enum SharedFiles {
    /// O App Group vem do Info.plist (o Xcode troca "$(TeamIdentifierPrefix)" pelo time).
    static var appGroup: String? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "FluxoAppGroup") as? String,
              !group.contains("$(") else { return nil }
        return group
    }

    /// Onde os dados ficavam antes do widget (e onde ficam no build de desenvolvimento).
    static var legacyDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fluxo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var directory: URL {
        if let group = appGroup,
           let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        return legacyDirectory
    }
}

/// Quem mais usou a rede num intervalo, gravado pelo app para o widget "Usando a internet".
struct AppsSnapshot: Codable {
    struct App: Codable, Identifiable {
        var id: String { name }
        let name: String
        let downBytes: Double
        let upBytes: Double
        /// PNG do ícone, dentro da pasta compartilhada (o widget não enxerga os apps abertos).
        let iconFile: String?

        var totalBytes: Double { downBytes + upBytes }
    }

    let date: Date
    let intervalMinutes: Int
    let apps: [App]

    static var fileURL: URL { SharedFiles.directory.appendingPathComponent("apps.json") }
    static var iconsDirectory: URL { SharedFiles.directory.appendingPathComponent("icones", isDirectory: true) }

    static func load() -> AppsSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AppsSnapshot.self, from: data)
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
