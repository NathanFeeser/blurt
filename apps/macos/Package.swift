// swift-tools-version: 6.0
import PackageDescription

// The Rust core arrives as a prebuilt XCFramework plus UniFFI-generated Swift.
// Both are produced by scripts/build-macos-app.sh and are gitignored — they are
// build outputs, not sources, and must never be edited by hand.
let package = Package(
    name: "OpenDict",
    platforms: [.macOS(.v13)],
    dependencies: [
        // WhisperKit runs Whisper on the Neural Engine via CoreML. Pinned to a
        // minor version: it is the piece most likely to move underneath us.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0")
    ],
    targets: [
        .binaryTarget(
            name: "opendict_coreFFI",
            path: "Frameworks/OpenDictCore.xcframework"
        ),
        .target(
            name: "OpenDictCore",
            dependencies: ["opendict_coreFFI"],
            path: "Sources/OpenDictCore",
            // UniFFI's generated async-callback plumbing does not satisfy Swift
            // 6 strict concurrency. This is machine-generated code we do not
            // edit, so it builds in Swift 5 mode; our own target stays on 6.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // All the logic lives in a library so it can be tested. The executable
        // is only an entry point: an executable target's top-level code cannot
        // be linked into a test bundle.
        .target(
            name: "OpenDictKit",
            dependencies: [
                "OpenDictCore",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            path: "Sources/OpenDictKit"
        ),
        .executableTarget(
            name: "OpenDict",
            dependencies: ["OpenDictKit"],
            path: "Sources/OpenDict"
        ),
        .testTarget(
            name: "OpenDictKitTests",
            dependencies: ["OpenDictKit"],
            path: "Tests/OpenDictKitTests"
        ),
    ]
)
