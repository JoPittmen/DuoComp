// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DuoComp",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [.library(name: "DuoComp", targets: ["DuoComp"])],
    targets: [
        .target(name: "DuoComp", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "DuoCompTests", dependencies: ["DuoComp"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
