// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DashboardCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "DashboardCore", targets: ["DashboardCore"])
    ],
    targets: [
        .target(name: "DashboardCore"),
        .testTarget(name: "DashboardCoreTests", dependencies: ["DashboardCore"]),
    ]
)
