// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SurimonoKit",
    platforms: [.macOS("15.6")],
    products: [
        .library(name: "SurimonoFormats", targets: ["SurimonoFormats"]),
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
        .package(url: "https://github.com/PhraseHQ/SwaTex.git", exact: "0.6.0"),
    ],
    targets: [
        .target(
            name: "SurimonoFormats",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"), .product(name: "SwaTex", package: "SwaTex"),
                // MarkdownNesting measures a document's depth with cmark before swift-markdown converts it.
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
                // StackSpace measures the stack from a real frame address, which Swift cannot take.
                "SurimonoStackFrame",
            ],
            resources: [.process("Resources")]
        ),
        .target(name: "SurimonoStackFrame"),
        .target(
            name: "SurimonoCore",
            dependencies: [
                "SurimonoFormats",
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            ],
            resources: [.process("Resources")]
        ),
        .target(
            name: "SurimonoRendering", dependencies: ["SurimonoCore"], resources: [.process("Resources")]),
        .target(name: "LaTeXCorpusSupport", dependencies: ["SurimonoFormats"], path: "Tests/LaTeXCorpusSupport"),
        // Seeded inputs, hostile documents and the small-stack runner shared by the robustness tests.
        .target(name: "RobustnessSupport", dependencies: ["SurimonoFormats"], path: "Tests/RobustnessSupport"),
        .testTarget(
            name: "SurimonoFormatsTests", dependencies: ["SurimonoFormats", "LaTeXCorpusSupport", "RobustnessSupport"],
            resources: [.copy("Fixtures")]),
        .testTarget(
            name: "SurimonoCoreTests", dependencies: ["SurimonoCore", "LaTeXCorpusSupport", "RobustnessSupport"],
            resources: [.copy("Fixtures")]),
        .testTarget(
            name: "SurimonoRenderingTests",
            dependencies: ["SurimonoRendering", "LaTeXCorpusSupport", "RobustnessSupport"],
            resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v6]
)
