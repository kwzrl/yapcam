// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Yapcam",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Yapcam",
            path: "Sources/Yapcam"
        ),
    ]
)
