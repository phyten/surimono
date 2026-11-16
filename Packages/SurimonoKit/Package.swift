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
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.9.0"),
        // The parser swift-markdown itself uses, at the same requirement. Clipboard format detection reads its tree
        // directly, which is several times faster than building swift-markdown's document for a text that is only
        // being looked at.
        .package(url: "https://github.com/swiftlang/swift-cmark.git", from: "0.9.0"),
        // KaTeX-compatible math in pure Swift. Pinned: 0.x may change its output between minor versions.
        .package(url: "https://github.com/PhraseHQ/SwaTex.git", exact: "0.5.0"),
    ],
    targets: [
        .target(
            name: "SurimonoCore",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"), .product(name: "SwaTex", package: "SwaTex"),
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            ],
            resources: [.process("Resources")]
        ),
        .target(
            name: "SurimonoRendering", dependencies: ["SurimonoCore"], resources: [.process("Resources")]),
        .testTarget(
            name: "SurimonoCoreTests", dependencies: ["SurimonoCore"], resources: [.copy("Fixtures")]),
        .testTarget(
            name: "SurimonoRenderingTests", dependencies: ["SurimonoRendering"],
            resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v6]
)
