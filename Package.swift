// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sotto",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "SottoCore", targets: ["SottoCore"]), .library(name: "SottoUI", targets: ["SottoUI"]), .executable(name: "sotto", targets: ["sotto"])],
    targets: [
        .target(name: "SottoCore"),
        .target(name: "SottoUI", dependencies: ["SottoCore"]),
        .executableTarget(name: "sotto", dependencies: ["SottoCore", "SottoUI"]),
        .testTarget(name: "SottoCoreTests", dependencies: ["SottoCore"])
    ]
)
