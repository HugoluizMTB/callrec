// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CallRec",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "CallRec", targets: ["CallRec"]),
    ],
    targets: [
        .executableTarget(
            name: "CallRec",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
