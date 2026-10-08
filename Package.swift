// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "msxiv",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "msxiv", targets: ["msxiv"])
    ],
    targets: [
        .executableTarget(
            name: "msxiv",
            path: "Sources/msxiv"
        )
    ]
)
