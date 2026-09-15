// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "managed-claude-stack",
    platforms: [
        .macOS(.v13),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "mcs",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Yams", package: "Yams"),
            ],
            path: "Sources/mcs",
            swiftSettings: [
                .unsafeFlags(["-warnings-as-errors"]),
            ]
        ),
        .testTarget(
            name: "MCSTests",
            dependencies: ["mcs"],
            path: "Tests/MCSTests",
            swiftSettings: [
                .unsafeFlags(["-warnings-as-errors"]),
            ]
        ),
    ]
)
