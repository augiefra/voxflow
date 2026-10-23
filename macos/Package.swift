// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "VoxFlow",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VoxFlow", targets: ["VoxFlow"]),
    ],
    dependencies: [
        // Mises à jour automatiques (flux appcast signé EdDSA).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .target(
            name: "VoxFlowCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "VoxFlow",
            dependencies: ["VoxFlowCore", .product(name: "Sparkle", package: "Sparkle")],
            // Sparkle.framework est copié dans VoxFlow.app/Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "VoxFlowCoreTests", dependencies: ["VoxFlowCore"]),
    ]
)
