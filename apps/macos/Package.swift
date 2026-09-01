// swift-tools-version: 6.0
import PackageDescription

// The Rust core arrives as a prebuilt XCFramework plus UniFFI-generated Swift.
// Both are produced by scripts/build-macos-app.sh and are gitignored — they are
// build outputs, not sources, and must never be edited by hand.
let package = Package(
    name: "Blurt",
    platforms: [.macOS(.v13)],
    dependencies: [
        // WhisperKit runs Whisper on the Neural Engine via CoreML. Pinned to a
        // minor version: it is the piece most likely to move underneath us.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0"),
        // Sparkle delivers updates to installs outside the App Store, which is
        // the only kind this app has. Arrives as a prebuilt XCFramework that the
        // build script copies into the bundle and re-signs.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .binaryTarget(
            name: "blurt_coreFFI",
            path: "Frameworks/BlurtCore.xcframework"
        ),
        .target(
            name: "BlurtCore",
            dependencies: ["blurt_coreFFI"],
            path: "Sources/BlurtCore",
            // UniFFI's generated async-callback plumbing does not satisfy Swift
            // 6 strict concurrency. This is machine-generated code we do not
            // edit, so it builds in Swift 5 mode; our own target stays on 6.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // All the logic lives in a library so it can be tested. The executable
        // is only an entry point: an executable target's top-level code cannot
        // be linked into a test bundle.
        .target(
            name: "BlurtKit",
            dependencies: [
                "BlurtCore",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/BlurtKit"
        ),
        .executableTarget(
            name: "Blurt",
            dependencies: ["BlurtKit"],
            path: "Sources/Blurt",
            // Sparkle is a dynamic framework, and this executable is copied
            // into a hand-assembled .app bundle. Without this rpath the loader
            // only knows the build directory the framework was linked from,
            // which does not exist on anybody else's Mac.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(
            name: "BlurtKitTests",
            dependencies: ["BlurtKit"],
            path: "Tests/BlurtKitTests"
        ),
    ]
)
