// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "AwakeKit",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "AwakeKit",
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
