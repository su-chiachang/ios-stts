// swift-tools-version:5.9
import PackageDescription

// Header-only C shims exposing the native engines' C APIs as Clang modules.
// Symbols are resolved at app link time from the static archives (parakeet,
// Audio8) / embedded dylib (qwentts) in stts/vendor/.
let package = Package(
    name: "NativeShims",
    products: [
        .library(name: "CParakeet", targets: ["CParakeet"]),
        .library(name: "CQwenTTS", targets: ["CQwenTTS"]),
        .library(name: "CAudio8", targets: ["CAudio8"]),
    ],
    targets: [
        .target(name: "CParakeet"),
        .target(name: "CQwenTTS"),
        .target(name: "CAudio8"),
    ]
)
