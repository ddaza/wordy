// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WordyCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "WordyCore", targets: ["WordyCore"])],
    targets: [
        .target(name: "WordyCore", path: "Core", resources: [.copy("SpeechModels.json")]),
        .testTarget(
            name: "WordyCoreTests",
            dependencies: ["WordyCore"],
            path: "Tests",
            resources: [.copy("Fixtures")],
        ),
    ],
)
