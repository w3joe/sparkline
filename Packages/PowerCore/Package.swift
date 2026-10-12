// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PowerCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PowerShared", targets: ["PowerShared"]),
        .library(name: "PowerCore", targets: ["PowerCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
    ],
    targets: [
        .target(name: "PowerShared"),
        .target(
            name: "PowerCore",
            dependencies: [
                "PowerShared",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "PowerCoreTests",
            dependencies: ["PowerCore", "PowerShared"]
        ),
    ]
)
