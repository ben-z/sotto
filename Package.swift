// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sotto",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "SottoCore", targets: ["SottoCore"]), .executable(name: "sotto", targets: ["sotto"])],
    targets: [
        .target(name: "SottoCore"),
        .executableTarget(name: "sotto", dependencies: ["SottoCore"]),
        .testTarget(name: "SottoCoreTests", dependencies: ["SottoCore"])
    ]
)
