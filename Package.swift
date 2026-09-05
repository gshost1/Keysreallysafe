// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Keysreallysafe",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "keys", targets: ["keys"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "KeysCore",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/KeysCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("AppKit"),
                .linkedFramework("Security"),
                .linkedFramework("LocalAuthentication"),
            ]
        ),
        .executableTarget(
            name: "keys",
            dependencies: ["KeysCore"],
            path: "Sources/keys"
        ),
        .testTarget(
            name: "KeysreallysafeTests",
            dependencies: ["KeysCore"],
            path: "Tests/KeysreallysafeTests"
        ),
    ]
)
