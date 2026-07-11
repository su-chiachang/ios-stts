// swift-tools-version:5.9
import PackageDescription

// Header-only C shims exposing the two native engines' C APIs as Clang
// modules. Symbols are resolved at app link time from the static archives
// (parakeet) / embedded dylib (qwen3tts) in stts/vendor/.
let package = Package(
    name: "NativeShims",
    products: [
        .library(name: "CParakeet", targets: ["CParakeet"]),
        .library(name: "CQwen3TTS", targets: ["CQwen3TTS"]),
    ],
    targets: [
        .target(name: "CParakeet"),
        .target(name: "CQwen3TTS"),
    ]
)
