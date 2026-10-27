// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "AwakeKit",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        // Auto-update framework: appcast feed + EdDSA-signed DMG downloads.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "AwakeKit",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .testTarget(
            name: "AwakeKitTests",
            dependencies: ["AwakeKit"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
    ]
)
