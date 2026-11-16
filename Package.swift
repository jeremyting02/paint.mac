// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Paint",
    platforms: [.macOS(.v13)],
    targets: [.executableTarget(name: "Paint")]
)
