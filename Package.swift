// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EchoType",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "EchoType",
            path: "Sources/EchoType"
        )
    ]
)
