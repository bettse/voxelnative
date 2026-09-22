// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LuantiKit",
    platforms: [.macOS(.v13), .visionOS(.v2)],
    products: [
        .library(name: "LuantiKit", targets: ["LuantiKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/attaswift/BigInt.git", from: "5.3.0"),
        .package(url: "https://github.com/facebook/zstd.git", from: "1.5.0"),
    ],
    targets: [
        // Ogg Vorbis decoder (public domain stb_vorbis). Apple's AVFoundation
        // can't decode Ogg, so we decode .ogg sounds to PCM ourselves.
        .target(name: "CSTBVorbis"),
        .target(name: "LuantiKit", dependencies: [
            .product(name: "BigInt", package: "BigInt"),
            .product(name: "libzstd", package: "zstd"),
            "CSTBVorbis",
        ]),
        .executableTarget(name: "luantikit-probe", dependencies: ["LuantiKit"]),
        .testTarget(name: "LuantiKitTests", dependencies: ["LuantiKit"], resources: [.copy("Fixtures")]),
    ]
)
