// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SlurmMonitor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "SlurmMonitorCore",
            targets: ["SlurmMonitorCore"]
        ),
        .executable(
            name: "SlurmMonitorApp",
            targets: ["SlurmMonitorApp"]
        )
    ],
    targets: [
        .target(
            name: "SlurmMonitorCore"
        ),
        .executableTarget(
            name: "SlurmMonitorApp",
            dependencies: ["SlurmMonitorCore"],
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        .testTarget(
            name: "SlurmMonitorCoreTests",
            dependencies: ["SlurmMonitorCore"]
        )
    ],
    swiftLanguageModes: [.v5]
)
