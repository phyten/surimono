// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SurimonoSnapshots", platforms: [.macOS(.v15)],
    products: [.executable(name: "surimono-snapshots", targets: ["Snapshots"])],
    targets: [
        .executableTarget(name: "Snapshots", resources: [.copy("report.html")]),
        .testTarget(name: "SnapshotsTests", dependencies: ["Snapshots"]),
    ]
)
