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
        .target(name: "YapcamDesign"),
        .target(name: "YapcamEditor", dependencies: ["YapcamCore", "YapcamRender", "YapcamDesign"]),
        .target(
            name: "YapcamUI",
            dependencies: ["YapcamCore", "YapcamCapture", "YapcamRender", "YapcamEditor", "YapcamDesign"]
        ),
        .executableTarget(name: "Yapcam", dependencies: ["YapcamUI"], path: "Sources/Yapcam"),
        .testTarget(name: "YapcamCoreTests", dependencies: ["YapcamCore"]),
        .testTarget(name: "YapcamUITests", dependencies: ["YapcamUI"]),
        .testTarget(name: "YapcamCaptureTests", dependencies: ["YapcamCapture"]),
        .testTarget(name: "YapcamRenderTests", dependencies: ["YapcamRender", "YapcamCore"]),
        .testTarget(name: "E2E", dependencies: ["YapcamRender", "YapcamCore"], path: "Tests/E2E"),
        .testTarget(name: "YapcamEditorTests", dependencies: ["YapcamEditor", "YapcamCore"]),
    ]
)
