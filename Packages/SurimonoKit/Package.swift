// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SurimonoKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SurimonoCore", targets: ["SurimonoCore"]),
        .library(name: "SurimonoRendering", targets: ["SurimonoRendering"]),
    ],
    targets: [
        .target(name: "SurimonoCore"),
        .target(name: "SurimonoRendering", dependencies: ["SurimonoCore"]),
        .testTarget(name: "SurimonoCoreTests", dependencies: ["SurimonoCore"]),
        .testTarget(name: "SurimonoRenderingTests", dependencies: ["SurimonoRendering"]),
    ],
    swiftLanguageModes: [.v6]
)
