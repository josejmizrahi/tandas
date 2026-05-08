// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RuulFeatures",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "RuulFeatures", targets: ["RuulFeatures"])
    ],
    dependencies: [
        .package(path: "../RuulCore"),
        .package(path: "../RuulUI"),
        .package(url: "https://github.com/supabase/supabase-swift", from: "2.20.0")
    ],
    targets: [
        .target(
            name: "RuulFeatures",
            dependencies: [
                .product(name: "RuulCore", package: "RuulCore"),
                .product(name: "RuulUI", package: "RuulUI"),
                .product(name: "Supabase", package: "supabase-swift")
            ],
            path: "Sources/RuulFeatures",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
