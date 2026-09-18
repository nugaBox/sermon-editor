// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SermonCut",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SermonCutCore", targets: ["SermonCutCore"]),
        .executable(name: "sermoncut", targets: ["sermoncut"]),
        .executable(name: "SermonCutApp", targets: ["SermonCutApp"]),
    ],
    targets: [
        .target(name: "SermonCutCore"),
        .executableTarget(name: "sermoncut", dependencies: ["SermonCutCore"]),
        // SwiftUI 앱. scripts/build-app.sh 로 .app 번들을 만든다 (Xcode 프로젝트 없이)
        .executableTarget(name: "SermonCutApp", dependencies: ["SermonCutCore"]),
        .testTarget(
            name: "SermonCutCoreTests",
            dependencies: ["SermonCutCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
