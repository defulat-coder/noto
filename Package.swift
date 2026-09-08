// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Noto",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NotoDesktop", targets: ["NotoApp"]),
        .executable(name: "noto", targets: ["NotoCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
    ],
    targets: [
        .target(name: "NotoCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "NotoApp", dependencies: ["NotoCore"]),
        .executableTarget(name: "NotoCLI", dependencies: ["NotoCore", .product(name: "ArgumentParser", package: "swift-argument-parser")]),
        .testTarget(name: "NotoCoreTests", dependencies: ["NotoCore"]),
        .testTarget(name: "NotoAppTests", dependencies: ["NotoApp", "NotoCore"])
    ],
    swiftLanguageModes: [.v5]
)
