// swift-tools-version: 6.2
import PackageDescription

// Measures how much of real LaTeX manuscripts the reader reads. The manuscripts stay outside the repository; this
// package only reads a folder the developer names.
let package = Package(
    name: "SurimonoLaTeXCoverage", platforms: [.macOS("15.6")],
    products: [.executable(name: "latex-coverage", targets: ["LaTeXCoverage"])],
    dependencies: [.package(path: "../../Packages/SurimonoKit")],
    targets: [
        // Finding manuscripts, counting and comparing: no dependency on the reader, so its tests build quickly.
        .target(name: "LaTeXCoverageCore"),
        .executableTarget(
            name: "LaTeXCoverage",
            dependencies: ["LaTeXCoverageCore", .product(name: "SurimonoFormats", package: "SurimonoKit")]),
        .testTarget(name: "LaTeXCoverageTests", dependencies: ["LaTeXCoverageCore"]),
    ],
    swiftLanguageModes: [.v6]
)
