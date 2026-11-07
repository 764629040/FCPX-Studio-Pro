// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FCPXStudio",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "FCPXStudio", targets: ["FCPXStudio"])
    ],
    targets: [
        .executableTarget(
            name: "FCPXStudio",
            path: "Sources/FCPXStudio"
        )
    ]
)
