// swift-tools-version:5.9

import PackageDescription

/// Client for the unofficial Yandex Music API (api.music.yandex.net).
/// Endpoints and the download-info signing follow MarshalX/yandex-music-api
/// (LGPL-3.0) as a reference; no code is copied from it.
let package = Package(
    name: "YandexMusic",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "YandexMusic", targets: ["YandexMusic"]),
    ],
    targets: [
        .target(name: "YandexMusic"),
        .testTarget(
            name: "YandexMusicTests",
            dependencies: ["YandexMusic"],
            resources: [.copy("Fixtures")]),
    ]
)
