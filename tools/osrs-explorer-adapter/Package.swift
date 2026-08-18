// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "osrs-explorer-adapter",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ExplorerAdapterCore", targets: ["ExplorerAdapterCore"]),
        .executable(name: "osrs-explorer-adapter", targets: ["ExplorerAdapterApp"]),
        .executable(name: "osrs-explorerctl", targets: ["ExplorerAdapterCLI"]),
        .executable(name: "osrs-explorer-lab-target", targets: ["ExplorerAdapterLabTarget"])
    ],
    targets: [
        .target(
            name: "ExplorerAdapterCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "ExplorerAdapterApp",
            dependencies: ["ExplorerAdapterCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "ExplorerAdapterCLI",
            dependencies: ["ExplorerAdapterCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "ExplorerAdapterLabTarget",
            dependencies: ["ExplorerAdapterCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ExplorerAdapterCoreTests",
            dependencies: ["ExplorerAdapterCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
