// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FontoryCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "FontoryCore", targets: ["FontoryCore"])],
    targets: [
        .target(name: "FontoryCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "FontoryCoreTests", dependencies: ["FontoryCore"]),
    ]
)
