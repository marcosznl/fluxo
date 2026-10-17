// swift-tools-version: 6.0
import PackageDescription

// Build rápido de desenvolvimento (swift build), usado pelos modos --snapshot e --teste.
// O app de verdade, com o widget, é montado pelo Fluxo.xcodeproj (scripts/build.sh).
let package = Package(
    name: "Fluxo",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Fluxo",
            path: "Sources",
            exclude: ["FluxoWidget"],
            sources: ["Fluxo", "Shared"],
            swiftSettings: [.swiftLanguageMode(.v5), .enableUpcomingFeature("BareSlashRegexLiterals")]
        )
    ]
)
