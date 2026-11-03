// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "harnessmd",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HarnessKit", targets: ["HarnessKit"]),
        .executable(name: "HarnessApp", targets: ["HarnessApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .target(name: "HarnessKit", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "HarnessApp", dependencies: ["HarnessKit", .product(name: "Sparkle", package: "Sparkle")]),
        .testTarget(name: "HarnessAppTests", dependencies: ["HarnessApp"]),
        .testTarget(name: "HarnessKitTests", dependencies: ["HarnessKit", .product(name: "GRDB", package: "GRDB.swift")])
    ]
)
