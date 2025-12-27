// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ViewPerformance",
    platforms: [.iOS(.v18), .macOS(.v15), .visionOS(.v1), .watchOS(.v11), .tvOS(.v18)],
    products: [
        .library(
            name: "ViewPerformance",
            targets: ["ViewPerformance"]),
    ],
    dependencies: [
      .package(url: "https://github.com/EmergeTools/SimpleDebugger", revision: "8970983a2d1c68f0579eaaa0c22a4a4dd9d710b4"),
    ],
    targets: [
        .target(
            name: "ViewPerformance", dependencies: ["ViewPerformanceObjC"]),
        .target(name: "ViewPerformanceObjC", dependencies: ["SimpleDebugger"]),
    ],
    cxxLanguageStandard: .cxx20
)

