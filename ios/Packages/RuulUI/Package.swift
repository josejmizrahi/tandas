// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RuulUI",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "RuulUI", targets: ["RuulUI"])
    ],
    dependencies: [
        .package(path: "../RuulCore")
    ],
    targets: [
        .target(
            name: "RuulUI",
            dependencies: [
                .product(name: "RuulCore", package: "RuulCore")
            ],
            path: "Sources/RuulUI",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
