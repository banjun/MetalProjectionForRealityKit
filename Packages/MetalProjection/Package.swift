// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MetalProjection",
    platforms: [.visionOS(.v26), .iOS(.v26), .macOS(.v26)],
    products: [.library(name: "MetalProjection", targets: ["MetalProjection"])],
    dependencies: [
        .package(url: "https://github.com/schwa/MetalCompilerPlugin", .upToNextMajor(from: "0.1.5")),
        .package(url: "https://github.com/banjun/ShaderGraphCoder", branch: "macos"),
    ],
    targets: [
        .target(name: "MetalProjectionBridgingHeader", publicHeadersPath: "include"),
        .target(
            name: "MetalProjection",
            dependencies: ["ShaderGraphCoder", "MetalProjectionBridgingHeader"],
            resources: [],
            plugins: [
                .plugin(name: "MetalCompilerPlugin", package: "MetalCompilerPlugin")
            ],
        ),
    ],
)
