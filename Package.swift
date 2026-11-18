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
                // and the first rpath is how the executable finds it there.
                // The second finds the copy SwiftPM stages beside the binary,
                // for unbundled runs (`.build/debug/Medusa --self-test`): the
                // Swift 6.4 build system no longer adds that rpath itself.
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path"
                ])
            ]
        ),
        .testTarget(
            name: "MedusaTests",
            dependencies: ["Medusa"],
            path: "Tests/MedusaTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
