// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "OpenClawToggle",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "OpenClawToggle",
            path: "Sources/OpenClawToggle"
        )
    ]
)
