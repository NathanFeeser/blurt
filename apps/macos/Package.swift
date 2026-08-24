// swift-tools-version: 6.0
import PackageDescription

// The Rust core arrives as a prebuilt XCFramework plus UniFFI-generated Swift.
// Both are produced by scripts/build-macos-app.sh and are gitignored — they are
// build outputs, not sources, and must never be edited by hand.
let package = Package(
    name: "OpenDict",
    platforms: [.macOS(.v13)],
    targets: [
        .binaryTarget(
            name: "opendict_coreFFI",
            path: "Frameworks/OpenDictCore.xcframework"
        ),
        .target(
            name: "OpenDictCore",
            dependencies: ["opendict_coreFFI"],
            path: "Sources/OpenDictCore"
        ),
        .executableTarget(
            name: "OpenDict",
            dependencies: ["OpenDictCore"],
            path: "Sources/OpenDict"
        ),
    ]
)
