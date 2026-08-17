// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "JBench",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "JBenchCore", targets: ["JBenchCore"]),
        .executable(name: "JBench", targets: ["JBenchApp"]),
        .executable(name: "JBenchProcessLauncher", targets: ["JBenchProcessLauncher"])
    ],
    targets: [
        .target(name: "JBenchCore"),
        .executableTarget(name: "JBenchApp", dependencies: ["JBenchCore"]),
        .executableTarget(name: "JBenchProcessLauncher"),
        .testTarget(name: "JBenchCoreTests", dependencies: ["JBenchCore"])
    ]
)
