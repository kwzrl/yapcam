// swift-tools-version: 6.0
import PackageDescription

// The Rust static library is built by scripts/build-core.sh into core/target/<profile>.
let rustLibDir = Context.packageDirectory + "/core/target/release"

let package = Package(
    name: "Yapcam",
    platforms: [.macOS(.v15)],
    targets: [
        .systemLibrary(name: "CYapcamCore", path: "Sources/CYapcamCore"),
        .target(
            name: "YapcamCore",
            dependencies: ["CYapcamCore"],
            linkerSettings: [.unsafeFlags(["-L", rustLibDir])]
        ),
        .target(name: "YapcamCapture"),
        .target(name: "YapcamRender", dependencies: ["YapcamCore"]),
        .target(name: "YapcamEditor", dependencies: ["YapcamCore", "YapcamRender"]),
        .executableTarget(
            name: "Yapcam",
            dependencies: ["YapcamCore", "YapcamCapture", "YapcamRender", "YapcamEditor"],
            path: "Sources/Yapcam"
        ),
        .testTarget(name: "YapcamCoreTests", dependencies: ["YapcamCore"]),
        .testTarget(name: "YapcamCaptureTests", dependencies: ["YapcamCapture"]),
        .testTarget(name: "YapcamRenderTests", dependencies: ["YapcamRender", "YapcamCore"]),
        .testTarget(name: "YapcamEditorTests", dependencies: ["YapcamEditor", "YapcamCore"]),
    ]
)
