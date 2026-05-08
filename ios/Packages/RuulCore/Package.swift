// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RuulCore",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "RuulCore", targets: ["RuulCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift", from: "2.20.0")
    ],
    targets: [
        .target(
            name: "RuulCore",
            dependencies: [
                .product(name: "Supabase", package: "supabase-swift")
            ],
            path: "Sources/RuulCore",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
