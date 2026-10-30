// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Butler",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "Butler", path: "Sources/Butler"),
        .testTarget(name: "Tests", dependencies: ["Butler"], path: "Tests"),
    ]
)
