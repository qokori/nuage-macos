// swift-tools-version:5.7
import PackageDescription
let package = Package(
    name: "Deps",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/siteline/SwiftUI-Introspect", "0.1.2"..<"1.0.0"),
        .package(url: "https://github.com/dmytro-anokhin/url-image", "2.2.1"..<"3.0.0"),
        .package(url: "https://github.com/pietropizzi/GridStack", "0.4.1"..<"1.0.0"),
        .package(path: "../../SoundCloud"),
    ],
    targets: [.target(name: "Deps", dependencies: [
        .product(name: "Introspect", package: "SwiftUI-Introspect"),
        .product(name: "URLImage", package: "url-image"),
        .product(name: "GridStack", package: "GridStack"),
        .product(name: "SoundCloud", package: "SoundCloud"),
    ])]
)
