// swift-tools-version:5.9
import PackageDescription
import Foundation

// M2 verification: exercises the REAL production code (ConversationEngine,
// ParakeetStt, AudioFileInput, QwenTts, AppSettings — symlinked into
// Sources/ from App/, see setup-symlinks.sh) outside the app's sandbox, so
// file-input transcription can be tested against arbitrary fixture paths
// without fighting sandbox entitlements.
let sttsRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // FileTranscribeTest
    .deletingLastPathComponent()  // Tools
    .deletingLastPathComponent()  // stts
    .path

let package = Package(
    name: "FileTranscribeTest",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../Packages/NativeShims"),
    ],
    targets: [
        .executableTarget(
            name: "FileTranscribeTest",
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
                .linkedFramework("AVFoundation"),
            ]
        ),
    ]
)
