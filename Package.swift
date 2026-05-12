// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FXBacktest",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "FXBacktest", targets: ["FXBacktest"]),
        .library(name: "FXBacktestCore", targets: ["FXBacktestCore"]),
        .library(name: "FXBacktestPlugins", targets: ["FXBacktestPlugins"])
    ],
    dependencies: [
        .package(path: "../FXExport/MT5Research")
    ],
    targets: [
        .target(
            name: "FXBacktestCore",
            dependencies: [
                .product(name: "FXExportHistoryData", package: "MT5Research"),
                .product(name: "FXExportMetalData", package: "MT5Research")
            ]
        ),
        .target(
            name: "FXBacktestPlugins",
            dependencies: ["FXBacktestCore"]
        ),
        .executableTarget(
            name: "FXBacktest",
            dependencies: [
                "FXBacktestCore",
                "FXBacktestPlugins"
            ]
        ),
        .testTarget(
            name: "FXBacktestCoreTests",
            dependencies: [
                "FXBacktestCore",
                "FXBacktestPlugins"
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
