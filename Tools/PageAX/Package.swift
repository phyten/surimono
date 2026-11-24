// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SurimonoPageAX", platforms: [.macOS(.v15)],
    products: [.executable(name: "surimono-page-ax", targets: ["PageAX"])],
    targets: [
        .executableTarget(name: "PageAX"),
        .testTarget(name: "PageAXTests", dependencies: ["PageAX"]),
    ]
)
