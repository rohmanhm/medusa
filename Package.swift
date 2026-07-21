// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Medusa",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4")
    ],
    targets: [
        .executableTarget(
            name: "Medusa",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Medusa",
            linkerSettings: [
                // SwiftPM links Sparkle but has no bundle model to embed it;
                // build-app.sh copies the framework into Contents/Frameworks,
                // and this rpath is how the executable finds it there.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
