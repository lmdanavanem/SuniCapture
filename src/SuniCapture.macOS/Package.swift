// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SuniCapture",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "SuniCapture",
            path: "Sources/SuniCapture",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        )
    ]
)
