// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PrettyShotCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "PrettyShotCore", targets: ["PrettyShotCore"]),
    ],
    targets: [
        .target(name: "PrettyShotCore"),
        .testTarget(
            name: "PrettyShotCoreTests",
            dependencies: ["PrettyShotCore"]
        ),
    ]
)
