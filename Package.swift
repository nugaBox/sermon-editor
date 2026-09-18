// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SermonCut",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SermonCutCore", targets: ["SermonCutCore"]),
        .executable(name: "sermoncut", targets: ["sermoncut"]),
    ],
    targets: [
        .target(name: "SermonCutCore"),
        .executableTarget(name: "sermoncut", dependencies: ["SermonCutCore"]),
        .testTarget(
            name: "SermonCutCoreTests",
            dependencies: ["SermonCutCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
