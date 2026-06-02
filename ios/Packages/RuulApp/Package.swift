// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RuulApp",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "RuulApp", targets: ["RuulApp"])
    ],
    dependencies: [
        .package(path: "../RuulCore"),
        // RuulApp imports Supabase directly (DependencyContainer holds a
        // SupabaseClient), so it must declare the product dependency itself —
        // relying on RuulCore's transitive module leaks compiles locally but
        // fails to link on CI (undefined Supabase.SupabaseClient symbols).
        .package(url: "https://github.com/supabase/supabase-swift", from: "2.20.0")
    ],
    targets: [
        .target(
            name: "RuulApp",
            dependencies: [
                "RuulCore",
                .product(name: "Supabase", package: "supabase-swift")
            ],
            path: "Sources/RuulApp",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
