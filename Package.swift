// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Fluxo",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Fluxo",
            path: "Sources/Fluxo",
            swiftSettings: [.swiftLanguageMode(.v5), .enableUpcomingFeature("BareSlashRegexLiterals")]
        )
    ]
)
