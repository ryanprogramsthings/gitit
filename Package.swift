// swift-tools-version:5.10
import PackageDescription
import Foundation

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "gitit",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "GititApp", targets: ["GititApp"]),
    ],
    targets: [
        .executableTarget(
            name: "GititApp",
            dependencies: ["GititFFI"],
            path: "Sources/GititApp"
        ),
        .target(
            name: "GititFFI",
            dependencies: ["CGititCore"],
            path: "Sources/GititFFI"
        ),
        .target(
            name: "CGititCore",
            path: "Sources/CGititCore",
            publicHeadersPath: "include",
            linkerSettings: [
                .unsafeFlags([
                    "-L\(packageDir)/Sources/CGititCore/lib",
                    "-lgitit_core",
                ]),
            ]
        ),
    ]
)
