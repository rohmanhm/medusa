// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Medusa",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Medusa",
            path: "Sources/Medusa"
        )
    ],
    swiftLanguageModes: [.v5]
)
