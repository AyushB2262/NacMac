// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NacMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "NacMac", targets: ["NacMac"])
    ],
    targets: [
        .executableTarget(
            name: "NacMac",
            path: "Sources/NacMac"
        ),
        .testTarget(
            name: "NacMacTests",
            dependencies: ["NacMac"],
            path: "Tests/NacMacTests"
        )
    ]
)
