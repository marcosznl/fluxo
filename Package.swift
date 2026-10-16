// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Speedtest",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Speedtest",
            path: "Sources/Speedtest",
            swiftSettings: [.swiftLanguageMode(.v5), .enableUpcomingFeature("BareSlashRegexLiterals")]
        )
    ]
)
