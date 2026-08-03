// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ModelBundle",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ModelBundle", targets: ["ModelBundle"]),
    ],
    targets: [
        .target(name: "ModelBundle"),
        .testTarget(name: "ModelBundleTests", dependencies: ["ModelBundle"]),
    ]
)
