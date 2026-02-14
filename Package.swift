// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "OpenClawToggle",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(url: "https://github.com/soffes/HotKey", from: "0.2.1"),
    ],
    targets: [
        .executableTarget(
            name: "OpenClawToggle",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "HotKey", package: "HotKey"),
            ],
            path: "Sources/OpenClawToggle"
        )
    ]
)
