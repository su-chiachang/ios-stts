// swift-tools-version:5.9
import PackageDescription
import Foundation

// M0 verification: links BOTH engines into one process — parakeet (static,
// ggml v0.13 private to the executable) and qwentts (dylib with its own
// ggml v0.15 dylibs, resolved via rpath). Proves the two ggml copies coexist
// under two-level namespace and both Metal backends initialize.
let sttsRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // SmokeTest
    .deletingLastPathComponent()  // Tools
    .deletingLastPathComponent()  // stts
    .path

let package = Package(
    name: "SmokeTest",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../Packages/NativeShims"),
    ],
    targets: [
        .executableTarget(
            name: "SmokeTest",
            dependencies: [
                .product(name: "CParakeet", package: "NativeShims"),
                .product(name: "CQwenTTS", package: "NativeShims"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(sttsRoot)/vendor/parakeet/lib",
                    "-lparakeet", "-lggml", "-lggml-base", "-lggml-cpu",
                    "-lggml-metal", "-lggml-blas",
                    "-L\(sttsRoot)/vendor/qwentts/lib",
                    "-lqwen",
                    "-Xlinker", "-rpath", "-Xlinker", "\(sttsRoot)/vendor/qwentts/lib",
                ]),
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Foundation"),
                .linkedFramework("CoreML"),
            ]
        ),
    ]
)
