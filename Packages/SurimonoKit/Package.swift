// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SurimonoKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SurimonoCore", targets: ["SurimonoCore"]),
        .library(name: "SurimonoRendering", targets: ["SurimonoRendering"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.9.0")
    ],
    targets: [
        .target(
            name: "SurimonoCore",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")],
            resources: [.process("Resources")]
        ),
        .target(name: "SurimonoRendering", dependencies: ["SurimonoCore"]),
        .testTarget(name: "SurimonoCoreTests", dependencies: ["SurimonoCore"]),
        .testTarget(
            name: "SurimonoRenderingTests", dependencies: ["SurimonoRendering"],
            resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v6]
)
