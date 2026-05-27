// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RuulApp",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "RuulApp", targets: ["RuulApp"])
    ],
    dependencies: [
        .package(path: "../RuulCore")
    ],
    targets: [
        .target(
            name: "RuulApp",
            dependencies: ["RuulCore"],
            path: "Sources/RuulApp",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
